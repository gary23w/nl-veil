# tot_py_test.py - the tot's Python runner (tot_py.py) under plain CPython: `python cloud/tot_py_test.py`.
# The oracle runs it; it exits non-zero on the first failed check. Plain CPython has no run_sync, so every
# HTTP call here goes the REPLAY way (stop at the request, fetch, run again) - the path a Worker without it takes.
# The web and PyPI are a loopback server in this file; nothing leaves the machine.
import asyncio
import http.server
import io
import json
import os
import sys
import threading
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tot_py  # noqa: E402


def run(data):
    return asyncio.run(tot_py.run(data))


def check(name, cond, detail=None):
    if not cond:
        print("FAIL:", name)
        if detail is not None:
            print(detail)
        sys.exit(1)
    print("ok:", name)


def wheel(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, text in files.items():
            z.writestr(name, text)
    return buf.getvalue()


HITS = []
WHEELS = {
    "halfkit": wheel({"halfkit/__init__.py": "def ok():\n    return 'yes'\n", "halfkit-1.0.dist-info/METADATA": "Name: halfkit\n"}),
    "tidekit": wheel({"tidekit/__init__.py": "from tidehelp import twice\n\ndef high(n):\n    return twice(n) + 1\n", "tidekit-1.0.dist-info/METADATA": "Name: tidekit\n"}),
    "tidehelp": wheel({"tidehelp.py": "def twice(n):\n    return n * 2\n", "../escape.py": "x = 1\n"}),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        HITS.append(("GET", self.path))
        base = "http://127.0.0.1:%d" % self.server.server_port
        if self.path == "/page":
            return self._send(200, "hello from the web", "text/plain")
        if self.path.startswith("/json"):
            return self._send(200, json.dumps({"path": self.path, "ua": self.headers.get("user-agent")}))
        if self.path == "/missing":
            return self._send(404, "nope", "text/plain")
        if self.path.startswith("/pypi/"):
            name = self.path.split("/")[2]
            if name == "tidekit":
                return self._send(200, json.dumps({"info": {"version": "1.0", "requires_dist": ["tidehelp>=1", 'extra-only ; extra == "dev"']}, "urls": [{"packagetype": "bdist_wheel", "filename": "tidekit-1.0-py3-none-any.whl", "url": base + "/w/tidekit", "size": 500}]}))
            if name == "tidehelp":
                return self._send(200, json.dumps({"info": {"version": "2.1", "requires_dist": None}, "urls": [{"packagetype": "bdist_wheel", "filename": "tidehelp-2.1-py3-none-any.whl", "url": base + "/w/tidehelp", "size": 300}]}))
            if name == "halfkit":
                return self._send(200, json.dumps({"info": {"version": "1.0", "requires_dist": ["nativepkg"]}, "urls": [{"packagetype": "bdist_wheel", "filename": "halfkit-1.0-py3-none-any.whl", "url": base + "/w/halfkit", "size": 300}]}))
            if name == "nativepkg":
                return self._send(200, json.dumps({"info": {"version": "9"}, "urls": [{"packagetype": "bdist_wheel", "filename": "nativepkg-9-cp312-cp312-manylinux_x86_64.whl", "url": base + "/w/x", "size": 1}, {"packagetype": "sdist", "filename": "nativepkg-9.tar.gz", "url": base + "/w/y", "size": 1}]}))
            return self._send(404, "{}")
        if self.path.startswith("/w/"):
            return self._send(200, WHEELS[self.path[3:]], "application/zip")
        self._send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode()
        HITS.append(("POST", self.path, body))
        self._send(201, json.dumps({"got": json.loads(body) if self.headers.get("content-type") == "application/json" else body}))


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % srv.server_port
tot_py.PYPI = BASE + "/pypi/{}/json"

# ------------------------------------------------------------------ the basics

r = run({"code": "print(sum(range(10)))"})
check("a script's output comes back", (r["ok"], r["out"], r["files"]) == (True, "45\n", {}), r)

r = run({"code": "import json\nd = json.load(open('in.json'))\nd['n'] += 1\njson.dump(d, open('out.json', 'w'))\nprint(open('in.json').read())", "files": {"in.json": '{"n": 1}'}})
check("files go in, and what the script wrote comes back (unchanged inputs do not)", r["ok"] and r["files"] == {"out.json": '{"n": 2}'} and '"n": 1' in r["out"], r)

r = run({"code": "open('in.txt', 'w').write('changed')", "files": {"in.txt": "original"}})
check("a changed input comes back", r["files"] == {"in.txt": "changed"}, r)

r = run({"code": "print('before')\n1/0"})
check("an exception is a failed run with its traceback, and the output before it kept", (not r["ok"]) and "before" in r["out"] and "ZeroDivisionError" in r["out"], r)
check("the traceback starts at the script's own frame, not the runner's", "tot_py.py" not in r["out"] and 'File "<tot>", line 2' in r["out"], r)

r = run({"code": "import asyncio\nawait asyncio.sleep(0)\nprint('awaited', ARGS['x'])", "args": {"x": 7}})
check("top-level await runs, and ARGS carries the caller's arguments", r["ok"] and r["out"] == "awaited 7\n", r)

r = run({"code": "import sys\nprint('bye')\nsys.exit(3)"})
check("sys.exit(3) is a failed run, not a crash", (not r["ok"]) and "bye" in r["out"], r)

r = run({"code": "print(open('x').read())", "files": {"../escape": "no", "x": "yes", "a/b": "no"}})
check("a file name never leaves the scratch directory", r["ok"] and r["out"] == "yes\n", r)

r = run({"code": "print('y' * 50000)"})
check("long output keeps its tail", len(r["out"]) <= tot_py.OUT_MAX + 40 and r["out"].startswith("...(earlier output cut)"), len(r["out"]))

cwd = os.getcwd()
run({"code": "import os\nos.chdir('/')"})
check("the caller's working directory is put back", os.getcwd() == cwd)

# ------------------------------------------------------------------ HTTP: requests and urllib, with no sockets of the script's own

HITS.clear()
r = run({"code": "import requests\nprint('start')\nr = requests.get('%s/page')\nprint(r.status_code, r.text, r.ok)\nj = requests.get('%s/json', params={'q': 'tides'}).json()\nprint(j['path'])" % (BASE, BASE)})
check("requests.get works, twice in one script, and the script's output is that of its one complete run", r["ok"] and r["out"] == "start\n200 hello from the web True\n/json?q=tides\n", r)
check("each request went out exactly once, however many times the script was run again", [h[1] for h in HITS] == ["/page", "/json?q=tides"], HITS)

HITS.clear()
r = run({"code": "import requests\nr = requests.post('%s/echo', json={'a': 1}, headers={'x-k': 'v'})\nprint(r.status_code, r.json()['got'])\ntry:\n    requests.get('%s/missing').raise_for_status()\nexcept requests.exceptions.HTTPError as e:\n    print('caught', e.response.status_code)\ns = requests.Session()\ns.headers['user-agent'] = 'mine'\nprint(s.get('%s/json').json()['ua'])" % (BASE, BASE, BASE)})
check("post with json, raise_for_status, and a Session's headers", r["ok"] and r["out"] == "201 {'a': 1}\ncaught 404\nmine\n", r)
check("a POST is sent once: a script run again does not post again", [h for h in HITS if h[0] == "POST"] == [("POST", "/echo", '{"a": 1}')], HITS)

r = run({"code": "import urllib.request, urllib.error\nwith urllib.request.urlopen('%s/page') as f:\n    print(f.status, f.read().decode())\ntry:\n    urllib.request.urlopen('%s/missing')\nexcept urllib.error.HTTPError as e:\n    print('http error', e.code)" % (BASE, BASE)})
check("urllib.request.urlopen works too, 4xx as HTTPError", r["ok"] and r["out"] == "200 hello from the web\nhttp error 404\n", r)

r = run({"code": "import requests\ntry:\n    print(requests.get('%s/page').text)\nexcept Exception as e:\n    print('swallowed', e)" % BASE})
check("a script's own `except Exception` cannot swallow the stop-and-fetch", r["ok"] and r["out"] == "hello from the web\n", r)

r = run({"code": "import requests\nprint(requests.get('http://127.0.0.1:1/x').text)"})
check("a request that cannot be made is a failed run that says so", (not r["ok"]) and "the request to http://127.0.0.1:1/x failed" in r["out"], r)

# ------------------------------------------------------------------ packages

HITS.clear()
r = run({"code": "import tidekit\nprint(tidekit.high(20))"})
check("a missing import is installed from PyPI with what it requires, and the script runs", r["ok"] and r["out"] == "(installed: tidekit 1.0, tidehelp 2.1)\n41\n", r)
check("the installed list names both, and an optional (extra) requirement was not fetched", r["installed"] == ["tidehelp", "tidekit"] and not any("extra-only" in h[1] for h in HITS), (r["installed"], HITS))
check("a wheel member cannot leave the site directory", not os.path.exists(os.path.join(os.path.dirname(tot_py.SITE), "escape.py")))

HITS.clear()
r = run({"code": "import tidekit\nprint(tidekit.high(1))"})
check("an installed package is not fetched again", r["ok"] and r["out"] == "3\n" and HITS == [], (r, HITS))

for k in ("tidekit", "tidehelp"):
    tot_py.INSTALLED.pop(k, None)
    for m in [m for m in sys.modules if m.startswith(k)]:
        del sys.modules[m]
r = run({"code": "import subprocess, sys\nsubprocess.check_call([sys.executable, '-m', 'pip', 'install', 'tidekit'])\nimport tidekit\nprint(tidekit.high(2))\nprint(subprocess.check_output(['pip', 'freeze']).decode().strip())"})
check("`pip install` through subprocess installs, and `pip freeze` lists", r["ok"] and r["out"].endswith("5\ntidehelp==2.1\ntidekit==1.0\n"), r)

r = run({"code": "import pip\nprint(pip.main(['install', 'tidekit']))"})
check("pip.main(['install', ...]) of something already there is a no-op 0", r["ok"] and r["out"] == "0\n", r)

r = run({"code": "import nativepkg"})
check("a package that needs native code is refused in words", (not r["ok"]) and "has no pure-Python wheel (it needs native code)" in r["out"] and "ModuleNotFoundError" in r["out"], r)

r = run({"code": "import nosuchpackage_xyz"})
check("a package PyPI does not have is said so", (not r["ok"]) and "there is no package named 'nosuchpackage_xyz' on PyPI" in r["out"], r)

r = run({"code": "", "install": ["nativepkg"]})
check("an explicit install that fails is a failed answer", (not r["ok"]) and r["out"].startswith("pip install failed: nativepkg has no pure-Python wheel"), r)

check("the refusal says what to do instead, and the name is remembered as one that cannot be had", "Use the standard library or a pure-Python package." in r["out"] and r["unavailable"] == ["nativepkg"], r)
HITS.clear()
r = run({"code": "import nativepkg"})
check("a name already found to need native code is refused without a second trip to PyPI", (not r["ok"]) and "has no pure-Python wheel" in r["out"] and HITS == [], (r, HITS))
check("the script's own error is shown once, without the runner's lookup inside it", r["out"].count("Traceback") == 1 and "tot_py.py" not in r["out"] and "During handling" not in r["out"], r)
tot_py.UNAVAILABLE.clear()
r = run({"code": "import nativepkg", "skip": ["NativePkg"]})
check("the names a tot was already refused ride with the script", (not r["ok"]) and "has no pure-Python wheel" in r["out"] and not any("nativepkg" in h[1] for h in HITS), (r, HITS))
tot_py.UNAVAILABLE.clear()

r = run({"code": "import halfkit\nprint(halfkit.ok())"})
check("a package whose requirement needs native code is installed without it, and says so", r["ok"] and r["out"] == "(installed: halfkit 1.0)\n(halfkit is installed WITHOUT nativepkg, which it requires: nativepkg has no pure-Python wheel (it needs native code))\nyes\n" and "halfkit" in r["installed"] and "nativepkg" not in r["installed"], r)
tot_py.UNAVAILABLE.clear()

r = run({"caps": True})
check("asked what it is, the runner names the native packages it has", r["ok"] and isinstance(r["native"], list) and r["native"] == tot_py._caps() and r["python"][0] == "3", r)
check("the standard library is never looked up on PyPI", run({"code": "", "install": ["json"]})["ok"] and not any("/json" in h[1] and "pypi/json/" in h[1] for h in HITS), HITS)
check("a matplotlib that is not here is refused with what to do instead", tot_py._has("matplotlib") or "write the SVG or HTML text yourself" in tot_py._native_words("matplotlib"), tot_py._native_words("matplotlib"))

r = run({"code": "open('pic.png', 'wb').write(bytes([137, 80, 78, 71, 255, 254]))\nopen('ok.svg', 'w').write('<svg/>')"})
check("a binary file a script writes is not kept, and the output says so", r["ok"] and r["files"] == {"ok.svg": "<svg/>"} and "(not kept: pic.png - only text files" in r["out"], r)

tot_py.INSTALLED.clear()
r = run({"code": "import tidehelp\nprint(tidehelp.twice(4))", "packages": ["tidehelp"]})
check("the packages a tot remembers are there before its script starts", r["ok"] and r["out"] == "(installed: tidehelp 2.1)\n8\n", r)

# ------------------------------------------------------------------ processes

r = run({"code": "import subprocess\nsubprocess.run(['ls', '-la'])"})
check("there are no processes, and the refusal says what to use instead", (not r["ok"]) and "there are no processes and no shell" in r["out"] and "`requests` for HTTP" in r["out"], r)

r = run({"code": "import os\nos.system('rm -rf /')"})
check("os.system is refused the same way", (not r["ok"]) and "there are no processes" in r["out"], r)

# ------------------------------------------------------------------ the Worker entry


class Req:
    def __init__(self, body):
        self.body = body

    async def text(self):
        return self.body


resp = asyncio.run(tot_py.Default().fetch(Req(json.dumps({"code": "print(2+2)"}))))
j = json.loads(resp.body)
check("the Worker entry answers JSON", (j["ok"], j["out"], j["files"]) == (True, "4\n", {}), j)
resp = asyncio.run(tot_py.Default().fetch(Req("not json")))
check("a bad request is answered, not raised", json.loads(resp.body)["ok"] is False)
srv.shutdown()
print("all passed")
