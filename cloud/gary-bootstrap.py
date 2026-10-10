import http.server
import io
import json
import os
import pathlib
import secrets
import signal
import socket
import socketserver
import subprocess
import tarfile
import threading
import time
import urllib.request

data = pathlib.Path('/app/data')
pgdir = data / 'postgres'
pgbin = None
token = os.environ.get('GARY_RUNTIME_TOKEN', '')
lock = threading.RLock()
postgres = None
runtime = None
limit = 256 * 1024 * 1024

def restore(stream):
    with tarfile.open(fileobj=stream, mode='r|gz') as archive:
        total = 0
        count = 0
        for member in archive:
            count += 1
            total += member.size
            dest = (data / member.name).resolve()
            if count > 100000 or total > 1024 * 1024 * 1024 or not dest.is_relative_to(data.resolve()) or not (member.isfile() or member.isdir()):
                raise ValueError('Invalid Gary state archive')
            if member.isdir():
                dest.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source = archive.extractfile(member)
                with dest.open('wb') as target:
                    while chunk := source.read(65536):
                        target.write(chunk)
                dest.chmod(0o600)

def stop():
    global runtime, postgres
    if runtime and runtime.poll() is None:
        runtime.terminate()
        try:
            runtime.wait(timeout=15)
        except subprocess.TimeoutExpired:
            runtime.kill()
            runtime.wait(timeout=5)
    runtime = None
    if postgres and postgres.poll() is None:
        subprocess.run([str(pgbin/'pg_ctl'), '-D', str(pgdir), '-m', 'fast', '-w', 'stop'], check=True, timeout=30)
        postgres.wait(timeout=5)
    postgres = None

def start_runtime():
    global runtime, postgres, pgbin
    if pgbin is None:
        pgroot = pathlib.Path('/usr/lib/postgresql')
        pgbin = pgroot / max((p.name for p in pgroot.iterdir() if p.is_dir() and p.name.isdigit()), key=int) / 'bin'
    keyfile = data / 'db.key'
    if not keyfile.exists():
        keyfile.write_text(secrets.token_hex(32))
        keyfile.chmod(0o600)
    password = keyfile.read_text().strip()
    fresh = not (pgdir/'PG_VERSION').exists()
    if fresh:
        subprocess.run([str(pgbin/'initdb'), '-D', str(pgdir), '-U', 'gary', '--pwfile='+str(keyfile), '--auth-host=scram-sha-256', '--auth-local=trust', '--locale=C.UTF-8', '-E', 'UTF8'], check=True, stdout=subprocess.DEVNULL, timeout=30)
    env = os.environ.copy()
    env['PGPASSWORD'] = password
    postgres = subprocess.Popen([str(pgbin/'postgres'), '-D', str(pgdir), '-h', '127.0.0.1', '-k', str(data)])
    for _ in range(60):
        if postgres.poll() is not None:
            raise RuntimeError('Gary database failed to start')
        if subprocess.run([str(pgbin/'pg_isready'), '-h', '127.0.0.1', '-U', 'gary'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('Gary database startup timed out')
    database = subprocess.run([str(pgbin/'psql'), '-h', '127.0.0.1', '-U', 'gary', '-d', 'postgres', '-At', '-c', "SELECT 1 FROM pg_database WHERE datname='gary'"], env=env, check=True, capture_output=True, text=True, timeout=20)
    if database.stdout.strip() != '1':
        subprocess.run([str(pgbin/'createdb'), '-h', '127.0.0.1', '-U', 'gary', 'gary'], env=env, check=True, timeout=20)
    env['GARY_PG_DSN'] = 'postgres://gary:'+password+'@127.0.0.1:5432/gary?sslmode=disable'
    env.pop('PGPASSWORD', None)
    runtime = subprocess.Popen(['/app/gary', '-addr', '0.0.0.0:8790', '-admin', '', '-data', str(data/'runtime'), '-skills', str(data/'skills')], env=env)
    for _ in range(120):
        if runtime.poll() is not None:
            raise RuntimeError('Gary runtime failed to start')
        try:
            with socket.create_connection(('127.0.0.1', 8790), timeout=0.2):
                return
        except OSError:
            time.sleep(0.25)
    raise RuntimeError('Gary runtime startup timed out')

def boot():
    if runtime and runtime.poll() is None:
        return
    stop()
    try:
        start_runtime()
    except Exception:
        stop()
        raise

class Control(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if not secrets.compare_digest(self.headers.get('Authorization',''), 'Bearer '+token):
            self.send_error(401)
            return
        with lock:
            try:
                if self.path == '/boot':
                    length = int(self.headers.get('Content-Length', '0'))
                    if self.headers.get('Transfer-Encoding'):
                        raise ValueError('State restore requires a content length')
                    if length < 0 or length > limit:
                        raise ValueError('Gary state exceeds 256 MiB')
                    if length and not (runtime and runtime.poll() is None):
                        snapshot = self.rfile.read(length)
                        if len(snapshot) != length:
                            raise ValueError('Incomplete Gary state archive')
                        restore(io.BytesIO(snapshot))
                    boot()
                    self.respond({'ok':True})
                elif self.path == '/status':
                    self.respond({'running':bool(runtime and runtime.poll() is None)})
                elif self.path == '/busy':
                    req = urllib.request.Request('http://127.0.0.1:8790/health', headers={'Authorization':'Bearer '+token})
                    with urllib.request.urlopen(req, timeout=5) as response:
                        self.respond(json.load(response))
                elif self.path == '/checkpoint':
                    stop()
                    archive = pathlib.Path('/tmp/gary-state.tar.gz')
                    with tarfile.open(archive, 'w:gz') as target:
                        target.add(data, arcname='.', filter=lambda member: member if member.isfile() or member.isdir() else None)
                    size = archive.stat().st_size
                    if size > limit:
                        raise ValueError('Gary state exceeds 256 MiB')
                    self.send_response(200)
                    self.send_header('Content-Type','application/gzip')
                    self.send_header('Content-Length',str(size))
                    self.end_headers()
                    with archive.open('rb') as source:
                        while chunk := source.read(65536):
                            self.wfile.write(chunk)
                    archive.unlink()
                else:
                    self.send_error(404)
            except Exception as error:
                self.respond({'ok':False,'error':str(error)}, 500)

    def respond(self, value, status=200):
        payload=json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        return

class ControlServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'gary'
        self.server_port = self.server_address[1]

def shutdown(*args):
    with lock:
        stop()
    os._exit(0)

def main():
    if len(token) < 24:
        raise RuntimeError('GARY_RUNTIME_TOKEN must contain at least 24 characters')
    data.mkdir(mode=0o700, exist_ok=True)
    server = ControlServer(('0.0.0.0',8791),Control)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    server.serve_forever()

if __name__ == '__main__':
    main()
