# hot_py.py - the Python a hot runs. A second Worker ("veil-hots-py") the veil server uploads beside the hot
# runtime; the runtime reaches it through a service binding (env.PY), so it has no public address.
#
# One request = one script: {"code": "...", "files": {"name": "text"}, "args": <any JSON>, "packages": [...],
# "install": [...]}. The files are written into a scratch directory the script starts in, the code runs with
# the whole standard library (top-level `await` allowed), and the answer is
# {"ok": bool, "out": "<stdout + stderr + traceback>", "files": {...changed text files...}, "installed": [...]}.
#
# A Worker's Python (Pyodide) has no sockets, no processes and no pip. A script written for an ordinary machine
# expects all three, so this file supplies them:
#
#   HTTP        `import requests` and `urllib.request.urlopen` work, on the Worker's own fetch. Where the runtime
#               can wait on a fetch (Pyodide's run_sync) they simply do; where it cannot, the script is stopped at
#               the request, the fetch is made, and the script is run again from the top with the answer in hand
#               (REPLAY). A script's output and files are those of its last, complete run.
#   packages    a missing import is looked up on PyPI and its pure-Python wheel unpacked onto sys.path, then the
#               script is run again; `pip install x` through pip.main or subprocess does the same. A package
#               that needs native code has no such wheel, and the script is told so in words.
#   processes   there are none. subprocess answers `pip install/freeze/list` itself and refuses anything else
#               with a sentence that says why and what to use instead.
#
# Nothing persists here between requests except what the Worker's isolate happens to keep (installed packages);
# the hot remembers its packages and sends them with every script.

import ast
import asyncio
import contextlib
import inspect
import io
import json
import os
import re
import sys
import tempfile
import traceback
import types
import zipfile

try:
    from workers import Response, WorkerEntrypoint
except ImportError:  # run outside Cloudflare (cloud/hot_py_test.py): the same code under plain CPython

    class WorkerEntrypoint:  # type: ignore
        pass

    class Response:  # type: ignore
        def __init__(self, body, headers=None, status=200):
            self.body, self.headers, self.status = body, headers or {}, status


OUT_MAX = 20000  # characters of output kept (the tail: where a traceback is)
FILE_MAX = 60000  # a file larger than this is not sent back
FILES_MAX = 40
REPLAYS_MAX = 24  # fetches + installs one script may need before it is given up on
WHEEL_MAX = 20 << 20
PACKAGES_MAX = 40
PYPI = "https://pypi.org/pypi/{}/json"  # a test points this at a stand-in

# import name -> PyPI name, where they differ
ALIASES = {"bs4": "beautifulsoup4", "yaml": "pyyaml", "dateutil": "python-dateutil", "dotenv": "python-dotenv", "attr": "attrs", "markdown": "Markdown", "jwt": "PyJWT", "serial": "pyserial"}
# supplied here, on the Worker's fetch: never installed over
SHIMMED = {"requests", "urllib3", "pip"}

SITE = tempfile.mkdtemp(prefix="hotsite")  # where wheels are unpacked; lives as long as this isolate
if SITE not in sys.path:
    sys.path.insert(0, SITE)
INSTALLED = {}  # PyPI name (lowercase) -> version


class _NeedFetch(BaseException):
    """The script needs this HTTP answer and the runtime cannot wait for it in place."""

    def __init__(self, key, req):
        self.key, self.req = key, req


class _NeedInstall(BaseException):
    """The script asked for these packages (pip install ...)."""

    def __init__(self, names):
        self.names = names


def _safe_name(name):
    return isinstance(name, str) and 0 < len(name) <= 64 and all(c.isalnum() or c in "._-" for c in name) and name not in (".", "..")


# ------------------------------------------------------------------------------------------ HTTP


async def _fetch(method, url, headers, body):
    """One HTTP call -> (status, headers dict, bytes). Pyodide's fetch in a Worker; urllib elsewhere."""
    try:
        from pyodide.http import pyfetch
    except ImportError:
        import urllib.error
        import urllib.request

        def go():
            rq = urllib.request.Request(url, data=body, method=method, headers=headers or {})
            try:
                with _REAL_URLOPEN(rq, timeout=30) as r:
                    return r.status, dict(r.headers.items()), r.read()
            except urllib.error.HTTPError as e:
                return e.code, dict(e.headers.items()), e.read()

        return await asyncio.get_running_loop().run_in_executor(None, go)
    kw = {"method": method, "headers": headers or {}}
    if body is not None:
        kw["body"] = body if isinstance(body, str) else bytes(body).decode("utf-8", "replace")
    r = await pyfetch(url, **kw)
    return r.status, dict(r.headers), await r.bytes()


_HTTP_CACHE = {}  # per script: answers already fetched, by request


def _http(method, url, headers=None, body=None):
    """The synchronous door every shim goes through."""
    if isinstance(body, str):
        body = body.encode("utf-8")
    key = json.dumps([method.upper(), url, sorted((headers or {}).items()), (body or b"").decode("latin1")])
    if key in _HTTP_CACHE:
        return _HTTP_CACHE[key]
    req = (method.upper(), url, dict(headers or {}), body)
    try:
        from pyodide.ffi import run_sync  # waits on the fetch in place, where the runtime can

        ans = run_sync(_fetch(*req))
    except BaseException as e:  # no run_sync here, or it cannot suspend: stop, fetch, run again
        if isinstance(e, (KeyboardInterrupt, SystemExit)):
            raise
        raise _NeedFetch(key, req) from None
    _HTTP_CACHE[key] = ans
    return ans


class _Resp:
    def __init__(self, url, status, headers, content):
        self.url, self.status_code, self.headers, self.content = url, status, headers, content
        self.ok = status < 400
        self.reason = ""
        self.encoding = "utf-8"

    @property
    def text(self):
        return self.content.decode(self.encoding or "utf-8", "replace")

    def json(self, **kw):
        return json.loads(self.text, **kw)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise _requests.exceptions.HTTPError("%d Error for url: %s" % (self.status_code, self.url), response=self)

    def iter_lines(self):
        return iter(self.text.splitlines())

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _request(method, url, params=None, data=None, json=None, headers=None, timeout=None, **_ignored):
    import urllib.parse

    h = {str(k): str(v) for k, v in (headers or {}).items()}
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params, doseq=True)
    body = None
    if json is not None:
        body = globals()["json"].dumps(json).encode("utf-8")
        h.setdefault("content-type", "application/json")
    elif isinstance(data, dict):
        body = urllib.parse.urlencode(data).encode("utf-8")
        h.setdefault("content-type", "application/x-www-form-urlencoded")
    elif data is not None:
        body = data if isinstance(data, bytes) else str(data).encode("utf-8")
    h.setdefault("user-agent", "veil-hot-python")
    status, rh, content = _http(method, url, h, body)
    return _Resp(url, status, rh, content)


def _make_requests():
    m = types.ModuleType("requests")
    m.__doc__ = "requests, on the Worker's fetch: get/post/put/patch/delete/head/request, Session, Response, exceptions."
    m.request = _request
    for name in ("get", "post", "put", "patch", "delete", "head", "options"):
        setattr(m, name, (lambda meth: lambda url, **kw: _request(meth.upper(), url, **kw))(name))

    class RequestException(IOError):
        def __init__(self, *a, response=None, **kw):
            super().__init__(*a)
            self.response = response

    ex = types.ModuleType("requests.exceptions")
    ex.RequestException = RequestException
    for n in ("HTTPError", "ConnectionError", "Timeout", "TooManyRedirects", "JSONDecodeError"):
        setattr(ex, n, type(n, (RequestException,), {}))
    m.exceptions = ex
    for n in ("RequestException", "HTTPError", "ConnectionError", "Timeout"):
        setattr(m, n, getattr(ex, n))

    class Session:
        def __init__(self):
            self.headers = {}

        def request(self, method, url, headers=None, **kw):
            return _request(method, url, headers={**self.headers, **(headers or {})}, **kw)

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def close(self):
            pass

    for name in ("get", "post", "put", "patch", "delete", "head"):
        setattr(Session, name, (lambda meth: lambda self, url, **kw: self.request(meth.upper(), url, **kw))(name))
    m.Session = Session
    m.Response = _Resp
    m.codes = types.SimpleNamespace(ok=200, not_found=404)
    m.__version__ = "2.32.0+veil"
    return m, ex


_requests, _requests_ex = _make_requests()
sys.modules["requests"] = _requests
sys.modules["requests.exceptions"] = _requests_ex

import urllib.request as _urlreq  # noqa: E402

_REAL_URLOPEN = _urlreq.urlopen


class _UrlResp(io.BytesIO):
    def __init__(self, url, status, headers, content):
        super().__init__(content)
        self.url, self.status, self.code, self.headers = url, status, status, headers

    def getcode(self):
        return self.status

    def geturl(self):
        return self.url

    def info(self):
        return self.headers


def _urlopen(url, data=None, timeout=None, **_ignored):
    import urllib.error

    if isinstance(url, _urlreq.Request):
        method, target, headers, data = url.get_method(), url.full_url, dict(url.header_items()), url.data if data is None else data
    else:
        method, target, headers = ("POST" if data is not None else "GET"), url, {}
    status, rh, content = _http(method, target, headers, data)
    if status >= 400:
        raise urllib.error.HTTPError(target, status, "HTTP %d" % status, rh, io.BytesIO(content))
    return _UrlResp(target, status, rh, content)


_urlreq.urlopen = _urlopen

# ------------------------------------------------------------------------------------------ packages


def _dist_name(spec):
    """'requests>=2 ; python_version > "3"' -> 'requests'; None for an optional (extra) or foreign-platform line."""
    head, _, marker = spec.partition(";")
    if "extra" in marker or "win32" in marker or 'os_name == "nt"' in marker or "platform_system" in marker:
        return None
    m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", head)
    return m.group(1) if m else None


def _key(name):
    return re.sub(r"[-_.]+", "-", name).lower()


async def _install(name, seen, log):
    """Unpack `name`'s pure-Python wheel, and those it requires, onto sys.path. Raises with a sentence on failure."""
    k = _key(name)
    if k in INSTALLED or k in seen or k in SHIMMED:
        return
    seen.add(k)
    if len(INSTALLED) >= PACKAGES_MAX:
        raise RuntimeError("%d packages are installed already; that is this Python's limit" % PACKAGES_MAX)
    status, _h, body = await _fetch("GET", PYPI.format(name), {"accept": "application/json"}, None)
    if status == 404:
        raise RuntimeError("there is no package named %r on PyPI" % name)
    if status != 200:
        raise RuntimeError("PyPI answered HTTP %d for %r" % (status, name))
    meta = json.loads(body)
    wheel = next((f for f in meta.get("urls", []) if f.get("packagetype") == "bdist_wheel" and f.get("filename", "").endswith("-none-any.whl")), None)
    if wheel is None:
        raise RuntimeError("%s has no pure-Python wheel (it needs native code): it cannot be installed in this Python, which runs inside a Worker. Use the standard library or a pure-Python package" % name)
    if wheel.get("size", 0) > WHEEL_MAX:
        raise RuntimeError("%s is too large to install here (%d MB)" % (name, wheel["size"] >> 20))
    status, _h, data = await _fetch("GET", wheel["url"], {}, None)
    if status != 200:
        raise RuntimeError("downloading %s answered HTTP %d" % (wheel["filename"], status))
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for member in z.namelist():
            if member.startswith("/") or ".." in member.split("/"):
                continue
            z.extract(member, SITE)
    INSTALLED[k] = meta.get("info", {}).get("version", "?")
    log.append("%s %s" % (name, INSTALLED[k]))
    for spec in meta.get("info", {}).get("requires_dist") or []:
        dep = _dist_name(spec)
        if dep:
            await _install(dep, seen, log)


def _pip_main(args=None):
    args = [str(a) for a in (args or [])]
    if args and args[0] == "install":
        names = [a for a in args[1:] if not a.startswith("-")]
        want = [n for n in names if _key(re.split(r"[<>=!~\[]", n)[0]) not in INSTALLED and _key(re.split(r"[<>=!~\[]", n)[0]) not in SHIMMED]
        if want:
            raise _NeedInstall([re.split(r"[<>=!~\[]", n)[0] for n in want])
        return 0
    if args and args[0] in ("freeze", "list"):
        print("\n".join("%s==%s" % kv for kv in sorted(INSTALLED.items())) or "(no packages installed; the standard library and requests are built in)")
        return 0
    return 0


_pip = types.ModuleType("pip")
_pip.main = _pip_main
_pip.__version__ = "24.0+veil"
sys.modules["pip"] = _pip

import subprocess as _sp  # noqa: E402

NO_PROCESS = ("this Python runs inside a Worker: there are no processes and no shell, so %s cannot run. "
              "Use the standard library, `requests` for HTTP, and `pip install <name>` (pip.main or subprocess) for pure-Python packages")


def _pip_args(cmd):
    parts = cmd.split() if isinstance(cmd, str) else [str(c) for c in (cmd or [])]
    for i, p in enumerate(parts):
        base = os.path.basename(p)
        if base in ("pip", "pip3") or (p == "-m" and i + 1 < len(parts) and parts[i + 1] == "pip"):
            return parts[i + (2 if p == "-m" else 1):]
    return None


def _sp_run(cmd, *a, capture_output=False, stdout=None, text=False, check=False, **kw):
    pa = _pip_args(cmd)
    if pa is None:
        raise OSError(NO_PROCESS % repr(cmd if isinstance(cmd, str) else " ".join(str(c) for c in cmd)))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        _pip_main(pa)
    out = buf.getvalue()
    if not (capture_output or stdout is not None):
        sys.stdout.write(out)
    return _sp.CompletedProcess(cmd, 0, out if text or kw.get("universal_newlines") else out.encode(), "" if text else b"")


_sp.run = _sp_run
_sp.call = lambda cmd, *a, **kw: _sp_run(cmd, *a, **kw).returncode
_sp.check_call = lambda cmd, *a, **kw: _sp_run(cmd, *a, **kw).returncode
_sp.check_output = lambda cmd, *a, **kw: _sp_run(cmd, *a, **{**kw, "capture_output": True}).stdout
_sp.getoutput = lambda cmd: _sp_run(cmd, capture_output=True, text=True).stdout


def _sp_popen(cmd, *a, **kw):
    raise OSError(NO_PROCESS % repr(cmd if isinstance(cmd, str) else " ".join(str(c) for c in cmd)))


_sp.Popen = _sp_popen


def _os_system(cmd):
    return _sp_run(cmd).returncode


os.system = _os_system

# ------------------------------------------------------------------------------------------ one script


def _own_trace():
    """The traceback from the script's own first frame on: the runner's frames above it are not the script's."""
    text = traceback.format_exc()
    at = text.find('  File "<hot>"')
    return ("Traceback (most recent call last):\n" + text[at:]) if at >= 0 else text


async def run(data):
    """Run one script. Pure of the Worker runtime, so a test can call it."""
    code = data.get("code") or ""
    files = data.get("files") or {}
    notes = []  # what was installed for this script, said once at the top of its output
    _HTTP_CACHE.clear()
    work = tempfile.mkdtemp(prefix="hot")
    before = {}
    for name, text in files.items():
        if not _safe_name(name) or not isinstance(text, str):
            continue
        with open(os.path.join(work, name), "w", encoding="utf-8") as f:
            f.write(text)
        before[name] = text
    old_cwd = os.getcwd()
    out = io.StringIO()
    ok = True

    # the packages this hot already uses, and any it asks for now
    try:
        seen = set()
        for name in list(data.get("packages") or []) + list(data.get("install") or []):
            if isinstance(name, str) and name:
                await _install(name, seen, notes)
    except Exception as e:
        if data.get("install"):
            return {"ok": False, "out": "pip install failed: %s" % e, "files": {}, "installed": sorted(INSTALLED)}
        notes.append("(a remembered package could not be installed: %s)" % e)

    tried = set()
    for _attempt in range(REPLAYS_MAX + 1):
        out = io.StringIO()
        ok = True
        os.chdir(work)
        scope = {"__name__": "__main__", "ARGS": data.get("args")}
        again = False
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                compiled = compile(code, "<hot>", "exec", flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT)
                result = eval(compiled, scope)
                if inspect.isawaitable(result):
                    await result
        except _NeedFetch as e:
            try:
                _HTTP_CACHE[e.key] = await _fetch(*e.req)
                again = True
            except Exception as fe:
                ok = False
                out.write("the request to %s failed: %s\n" % (e.req[1], fe))
        except _NeedInstall as e:
            try:
                seen = set()
                for n in e.names:
                    await _install(n, seen, notes)
                again = True
            except Exception as ie:
                ok = False
                out.write("pip install failed: %s\n" % ie)
        except ModuleNotFoundError as e:
            mod = (e.name or "").split(".")[0]
            if mod and mod not in tried:
                tried.add(mod)
                try:
                    await _install(ALIASES.get(mod, mod), set(), notes)
                    again = True
                except Exception as ie:
                    ok = False
                    out.write(_own_trace())
                    out.write("(%s was looked up on PyPI: %s)\n" % (mod, ie))
            else:
                ok = False
                out.write(_own_trace())
        except SystemExit as e:
            ok = e.code in (None, 0)
        except BaseException:
            ok = False
            out.write(_own_trace())
        finally:
            os.chdir(old_cwd)
        if not again:
            break
    else:
        ok = False
        out.write("the script needed more than %d fetches or installs; split it up\n" % REPLAYS_MAX)

    changed = {}
    try:
        for name in sorted(os.listdir(work)):
            path = os.path.join(work, name)
            if len(changed) >= FILES_MAX or not _safe_name(name) or not os.path.isfile(path):
                continue
            if os.path.getsize(path) > FILE_MAX * 4:
                continue
            try:
                with open(path, "r", encoding="utf-8") as f:
                    text = f.read()
            except (UnicodeDecodeError, OSError):
                continue
            if len(text) <= FILE_MAX and before.get(name) != text:
                changed[name] = text
    except OSError:
        pass
    text = out.getvalue()
    if notes:
        text = "(installed: %s)\n" % ", ".join(notes) + text
    if len(text) > OUT_MAX:
        text = "...(earlier output cut)...\n" + text[-OUT_MAX:]
    return {"ok": ok, "out": text, "files": changed, "installed": sorted(INSTALLED)}


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        try:
            data = json.loads(await request.text())
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except Exception as e:
            return Response(json.dumps({"ok": False, "out": "bad request: %s" % e, "files": {}, "installed": []}), headers={"content-type": "application/json"})
        return Response(json.dumps(await run(data)), headers={"content-type": "application/json"})
