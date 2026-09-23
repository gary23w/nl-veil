#!/usr/bin/env python3
"""Exercise a native release in a disposable install, never the user's running veil/data.

Python is a maintainer/CI dependency only. The shipped updater is compiled Zig.
--release downloads a published, digest-verified bundle; --bundle tests a local archive.
--cloudflare checks HTTPS and runs a real quick tunnel exposing ONLY a random test marker.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import zipfile

REPO = "https://api.github.com/repos/gary23w/nl-veil/releases/"
WINDOWS = os.name == "nt"


def fetch(url):
    headers = {"User-Agent": "nl-veil-release-smoke", "Accept": "application/dns-json" if "cloudflare-dns.com/" in url else "application/json"}
    # Anonymous api.github.com calls share 60 an hour per IP, and the hosted macOS runners share IPs: v1.1.5's
    # arm64 bundle failed twice on "403 rate limit exceeded" fetching cloudflared's latest release. Authenticated
    # calls get the workflow token's own limit. Only ever sent to api.github.com.
    token = os.environ.get("GITHUB_TOKEN", "")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read(2 << 20)


def download(asset, destination):
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", digest):
        raise RuntimeError("GitHub asset has no valid SHA-256 digest")
    h = hashlib.sha256()
    size = 0
    req = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "nl-veil-release-smoke"})
    with urllib.request.urlopen(req, timeout=60) as response, destination.open("wb") as out:
        while block := response.read(1 << 20):
            size += len(block)
            if size > 512 << 20:
                raise RuntimeError("Release download exceeds limit")
            h.update(block)
            out.write(block)
    if size != asset["size"] or h.hexdigest() != digest[7:].lower():
        raise RuntimeError("Release size/checksum mismatch")


def host():
    system = {"Windows": "windows", "Darwin": "macos", "Linux": "linux"}[platform.system()]
    arch = {"AMD64": "x86_64", "x86_64": "x86_64", "arm64": "arm64", "aarch64": "arm64"}[platform.machine()]
    return system, arch


def extract(archive, target):
    def checked(name):
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
            raise RuntimeError(f"Unsafe archive member: {name}")
        return target.joinpath(*path.parts)

    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                dest = checked(entry.filename)
                if stat.S_ISLNK(entry.external_attr >> 16):
                    raise RuntimeError("Release must not contain symlinks")
                if entry.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(entry) as src, dest.open("wb") as out:
                        shutil.copyfileobj(src, out)
    else:
        with tarfile.open(archive) as tar:
            for entry in tar:
                dest = checked(entry.name)
                if entry.isdir():
                    dest.mkdir(parents=True, exist_ok=True)
                elif entry.isfile():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(entry) as src, dest.open("wb") as out:
                        shutil.copyfileobj(src, out)
                else:
                    raise RuntimeError("Release must contain only regular files/directories")


def spawn(argv, **kwargs):
    return subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                            creationflags=subprocess.CREATE_NO_WINDOW if WINDOWS else 0,
                            start_new_session=not WINDOWS, **kwargs)


def stop(process):
    if process.poll() is None:
        if WINDOWS:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        else:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            if not WINDOWS:
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait(timeout=10)


def smoke_bundle(archive, work, version, legacy):
    install = work / "install with spaces"
    install.mkdir()
    extract(archive, install)
    apps = list(install.glob("*/veil.exe" if WINDOWS else "*/veil"))
    if len(apps) != 1:
        raise RuntimeError("Bundle must contain exactly one app")
    app = apps[0]
    engine = app.parent / "bin" / ("neuron.exe" if WINDOWS else "neuron")
    if not engine.is_file():
        raise RuntimeError("Memory engine missing from bundle")
    for p in install.rglob("*"):
        if p.name in {"data", ".desktop_key", ".server.key"} or ".sqlite" in p.name:
            raise RuntimeError(f"Runtime state shipped in release: {p.name}")
    if not legacy and (app.parent / "veil-install.txt").read_text().strip() != "veil-bundle-v1":
        raise RuntimeError("Update install marker missing")
    app.chmod(0o700)
    engine.chmod(0o700)
    if not legacy:
        result = subprocess.run([str(app), "--build-version"], capture_output=True, text=True, timeout=20)
        if result.returncode or result.stdout.strip() != version:
            raise RuntimeError("Packaged binary version does not match release")
    # Reserve an ephemeral port, then hand it to the app. A bind race causes failure, never reuse of 8787.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = os.environ.copy()
    env.update(NL_PORT=str(port), NL_BIND="127.0.0.1", NL_TUNNEL="0",
               NEURON_LOOPS_DATA=str(work / "runtime"), NL_MODELS_DIR=str(work / "models"))
    with (work / "server.log").open("wb") as log:
        process = spawn([str(app), "--server-only"], cwd=app.parent, env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 75
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Packaged app exited: {process.returncode}")
                try:
                    reply = json.loads(fetch(f"http://127.0.0.1:{port}/api/v1/health"))
                    if reply.get("ok") is True and reply.get("version") == version:
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(0.5)
            else:
                raise RuntimeError("Packaged app did not serve matching health/version within 75s")
            print(f"PASS native bundle: {version}, memory engine present, isolated server healthy", flush=True)
        finally:
            stop(process)
    if not legacy:
        smoke_updater(app, engine, work, version)


def smoke_updater(app, engine, work, version):
    """Run the shipped helper for real, including waiting for the old process and replacing both files."""
    stage = app.parent / ".veil-update-smoke"
    stage.mkdir()
    helper = stage / ("helper.exe" if WINDOWS else "helper")
    staged_app = stage / ("app.exe" if WINDOWS else "app")
    shutil.copy2(app, helper)
    shutil.copy2(app, staged_app)
    shutil.copy2(engine, stage / "neuron")
    helper.chmod(0o700)
    def asset(path):
        return dict(name=path.name, browser_download_url="", size=path.stat().st_size,
                    digest="sha256:" + hashlib.sha256(path.read_bytes()).hexdigest())
    version_probe = subprocess.run([str(staged_app), "--build-version"], capture_output=True, text=True, timeout=15)
    if version_probe.returncode or version_probe.stdout.strip() != version:
        raise RuntimeError("Staged update cannot execute its version probe")
    plan = dict(app=asset(staged_app), engine=asset(stage / "neuron"),
                args=["--build-version"], cwd=str(app.parent))
    (stage / "plan.json").write_text(json.dumps(plan))
    # Distinguish old and new bytes; overlays are only added to the disposable originals.
    with app.open("ab") as out:
        out.write(b"old-app-probe")
    with engine.open("ab") as out:
        out.write(b"old-engine-probe")
    old_app = hashlib.sha256(app.read_bytes()).hexdigest()
    old_engine = hashlib.sha256(engine.read_bytes()).hexdigest()
    sentinel = app.parent / "preserve-user-state"
    sentinel.write_text("unchanged")
    parent = spawn([sys.executable, "-c", "import time; time.sleep(90)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with (work / "updater.log").open("wb") as log:
        child = spawn([str(helper), "--veil-apply-update", str(parent.pid)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not (stage / "ready").exists():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Update helper did not acknowledge the parent")
                time.sleep(0.1)
            if hashlib.sha256(app.read_bytes()).hexdigest() != old_app:
                raise RuntimeError("Updater replaced a file before parent shutdown")
            stop(parent)
            if child.wait(timeout=30):
                raise RuntimeError("Update helper failed; see updater.log")
            for current, backup, expected, old in ((app, stage / "old-app", plan["app"], old_app),
                                                   (engine, stage / "old-neuron", plan["engine"], old_engine)):
                if hashlib.sha256(current.read_bytes()).hexdigest() != expected["digest"][7:]:
                    raise RuntimeError("Updater did not install the expected component")
                if hashlib.sha256(backup.read_bytes()).hexdigest() != old:
                    raise RuntimeError("Updater did not preserve the old component")
            if sentinel.read_text() != "unchanged":
                raise RuntimeError("Updater modified user state")
            print("PASS shipped update helper: waits for exit, replaces both components, preserves backups/data, relaunches", flush=True)
        finally:
            stop(parent)
            stop(child)


def smoke_cloudflare(work):
    # This checks TLS to Cloudflare without a token. It does not claim an account OAuth grant worked.
    if json.loads(fetch("https://api.cloudflare.com/client/v4/ips")).get("success") is not True:
        raise RuntimeError("Cloudflare HTTPS API probe failed")
    print("PASS Cloudflare HTTPS API on port 443", flush=True)
    system, arch = host()
    os_name = {"windows": "windows", "macos": "darwin", "linux": "linux"}[system]
    suffix = ".exe" if WINDOWS else ".tgz" if system == "macos" else ""
    asset_name = f"cloudflared-{os_name}-{'amd64' if arch == 'x86_64' else 'arm64'}{suffix}"
    rel = json.loads(fetch("https://api.github.com/repos/cloudflare/cloudflared/releases/latest"))
    asset = next(a for a in rel["assets"] if a["name"] == asset_name)
    connector = work / ("cloudflared.exe" if WINDOWS else "cloudflared")
    if suffix == ".tgz":
        archive = work / "cloudflared.tgz"
        download(asset, archive)
        extract(archive, work)
    else:
        download(asset, connector)
    connector.chmod(0o700)
    marker = "veil-release-probe-" + uuid.uuid4().hex

    class Probe(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(marker.encode())

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Probe)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        # Prove both transports separately. No app, account data or filesystem is publicly served.
        for protocol in ("http2", "quic"):
            logfile = work / f"tunnel-{protocol}.log"
            with logfile.open("wb") as log:
                child = spawn([str(connector), "tunnel", "--no-autoupdate", "--protocol", protocol,
                               "--url", f"http://127.0.0.1:{server.server_port}"], cwd=work, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 100
                    url = None
                    while time.monotonic() < deadline:
                        if child.poll() is not None:
                            raise RuntimeError(f"cloudflared {protocol} exited; inspect {logfile}")
                        text = logfile.read_text(errors="replace")
                        match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", text)
                        if match and "Registered tunnel connection" in text:
                            url = match.group(0)
                            break
                        time.sleep(1)
                    if not url:
                        raise RuntimeError(f"No {protocol} connection on outbound 7844; inspect {logfile}")
                    # Wait for authoritative publication via DoH before using the local DNS resolver.
                    deadline = time.monotonic() + 100
                    hostname = url.removeprefix("https://")
                    while time.monotonic() < deadline:
                        dns = json.loads(fetch(f"https://cloudflare-dns.com/dns-query?name={hostname}&type=A"))
                        if dns.get("Answer"):
                            try:
                                if fetch(url).decode() == marker:
                                    print(f"PASS Cloudflare {protocol}: outbound 7844 + public HTTPS round trip", flush=True)
                                    break
                            except OSError:
                                pass
                        time.sleep(2)
                    else:
                        raise RuntimeError(f"Connected tunnel {protocol} did not return the probe")
                finally:
                    stop(child)
    finally:
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--bundle", type=Path)
    source.add_argument("--release", help="GitHub tag, or latest")
    parser.add_argument("--version", help="Expected local bundle version")
    parser.add_argument("--legacy", action="store_true", help="Older release without the updater/build-version flag")
    parser.add_argument("--cloudflare", action="store_true")
    parser.add_argument("--output", type=Path, required=True, help="New directory for isolated artifacts and diagnostic logs")
    args = parser.parse_args()
    work = args.output.resolve()
    work.mkdir(parents=True, exist_ok=False)
    archive = args.bundle.resolve() if args.bundle else None
    version = args.version
    if args.release:
        endpoint = "latest" if args.release == "latest" else "tags/" + args.release
        rel = json.loads(fetch(REPO + endpoint))
        version = rel["tag_name"].removeprefix("v")
        system, arch = host()
        stem = f"veil-v{version}-{system}-{arch}"
        asset = next(a for a in rel["assets"] if a["name"] in {stem + ".zip", stem + ".tar.gz"})
        archive = work / asset["name"]
        download(asset, archive)
        print(f"PASS GitHub asset digest: {asset['name']}", flush=True)
    if not version:
        parser.error("--version is required with --bundle")
    smoke_bundle(archive, work, version, args.legacy)
    if args.cloudflare:
        smoke_cloudflare(work)
    print("PASS requested release checks. Logs: " + str(work), flush=True)


if __name__ == "__main__":
    main()
