# hot_py.py - the Python a hot runs. A second Worker ("veil-hots-py") the veil server uploads beside the hot
# runtime; the runtime reaches it through a service binding (env.PY), so it has no public address.
#
# One request = one script: {"code": "...", "files": {"name": "text"}, "args": <any JSON>}.
# The files are written into a scratch directory the script starts in, the code runs with the whole standard
# library (top-level `await` allowed: `from pyodide.http import pyfetch` fetches the web), and the answer is
# {"ok": bool, "out": "<stdout + stderr + traceback>", "files": {"name": "text"}} with every text file the
# script created or changed. Nothing persists here between requests; the hot keeps what comes back.

import ast
import contextlib
import inspect
import io
import json
import os
import tempfile
import traceback

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


def _safe_name(name):
    return isinstance(name, str) and 0 < len(name) <= 64 and all(c.isalnum() or c in "._-" for c in name) and name not in (".", "..")


async def run(data):
    """Run one script. Pure of the Worker runtime, so a test can call it."""
    code = data.get("code") or ""
    files = data.get("files") or {}
    out = io.StringIO()
    ok = True
    work = tempfile.mkdtemp(prefix="hot")
    before = {}
    for name, text in files.items():
        if not _safe_name(name) or not isinstance(text, str):
            continue
        with open(os.path.join(work, name), "w", encoding="utf-8") as f:
            f.write(text)
        before[name] = text
    old_cwd = os.getcwd()
    os.chdir(work)
    scope = {"__name__": "__main__", "ARGS": data.get("args")}
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            compiled = compile(code, "<hot>", "exec", flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT)
            result = eval(compiled, scope)
            if inspect.isawaitable(result):
                await result
    except SystemExit as e:
        ok = e.code in (None, 0)
    except BaseException:
        ok = False
        out.write(traceback.format_exc())
    finally:
        os.chdir(old_cwd)
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
    if len(text) > OUT_MAX:
        text = "...(earlier output cut)...\n" + text[-OUT_MAX:]
    return {"ok": ok, "out": text, "files": changed}


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        try:
            data = json.loads(await request.text())
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except Exception as e:
            return Response(json.dumps({"ok": False, "out": "bad request: %s" % e, "files": {}}), headers={"content-type": "application/json"})
        return Response(json.dumps(await run(data)), headers={"content-type": "application/json"})
