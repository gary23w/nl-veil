# hot_py_test.py - the hot's Python runner (hot_py.py) under plain CPython: `python cloud/hot_py_test.py`.
# The oracle runs it; it exits non-zero on the first failed check.
import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hot_py  # noqa: E402


def run(data):
    return asyncio.run(hot_py.run(data))


def check(name, cond):
    if not cond:
        print("FAIL:", name)
        sys.exit(1)
    print("ok:", name)


r = run({"code": "print(sum(range(10)))"})
check("a script's output comes back", r == {"ok": True, "out": "45\n", "files": {}})

r = run({"code": "import json\nd = json.load(open('in.json'))\nd['n'] += 1\njson.dump(d, open('out.json', 'w'))\nprint(open('in.json').read())", "files": {"in.json": '{"n": 1}'}})
check("files go in, and what the script wrote comes back (unchanged inputs do not)", r["ok"] and r["files"] == {"out.json": '{"n": 2}'} and '"n": 1' in r["out"])

r = run({"code": "open('in.txt', 'w').write('changed')", "files": {"in.txt": "original"}})
check("a changed input comes back", r["files"] == {"in.txt": "changed"})

r = run({"code": "print('before')\n1/0"})
check("an exception is a failed run with its traceback, and the output before it kept", (not r["ok"]) and "before" in r["out"] and "ZeroDivisionError" in r["out"])

r = run({"code": "import asyncio\nawait asyncio.sleep(0)\nprint('awaited', ARGS['x'])", "args": {"x": 7}})
check("top-level await runs, and ARGS carries the caller's arguments", r["ok"] and r["out"] == "awaited 7\n")

r = run({"code": "import sys\nprint('bye')\nsys.exit(3)"})
check("sys.exit(3) is a failed run, not a crash", (not r["ok"]) and "bye" in r["out"])

r = run({"code": "print(open('x').read())", "files": {"../escape": "no", "x": "yes", "a/b": "no"}})
check("a file name never leaves the scratch directory", r["ok"] and r["out"] == "yes\n")

r = run({"code": "print('y' * 50000)"})
check("long output keeps its tail", len(r["out"]) <= hot_py.OUT_MAX + 40 and r["out"].startswith("...(earlier output cut)"))

cwd = os.getcwd()
run({"code": "import os\nos.chdir('/')"})
check("the caller's working directory is put back", os.getcwd() == cwd)


class Req:
    def __init__(self, body):
        self.body = body

    async def text(self):
        return self.body


resp = asyncio.run(hot_py.Default().fetch(Req(json.dumps({"code": "print(2+2)"}))))
check("the Worker entry answers JSON", json.loads(resp.body) == {"ok": True, "out": "4\n", "files": {}})
resp = asyncio.run(hot_py.Default().fetch(Req("not json")))
check("a bad request is answered, not raised", json.loads(resp.body)["ok"] is False)
print("all passed")
