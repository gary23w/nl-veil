# prod-sim — multi-paradigm production-shaped build

Scales the [lowparam-repro](../lowparam-repro/README.md) harness up to a
production-shaped target: **linkboard**, a self-hosted bookmarks web service
built from the Python standard library only (no pip installs, so it runs in an
offline swarm).

The build spans five paradigms and six layers, which is the point — cross-layer
coherence is where multi-mind builds break, and the corpus makes that coherence
gradeable:

| layer | file(s) | paradigm |
|---|---|---|
| storage | `db.py` (SQLite schema + data functions) | declarative SQL + imperative Python |
| service | `app.py` (`http.server` JSON API + static serving) | OO / event-loop |
| frontend | `static/index.html`, `static/app.js` | markup + event-driven JS |
| operator | `cli.py` (argparse) | imperative CLI |
| config | `config.json` | declarative data |
| verification | `test_db.py`, `test_api.py` | pytest |

`linkboard.facts` pins the exact cross-layer contracts (table schema, function
signatures, route paths, JSON shapes, config keys, fetch endpoints). Grading:

- does `app.js` fetch exactly the routes `app.py` serves?
- does `app.py` call exactly the functions `db.py` exposes?
- do the tests exercise the documented JSON shapes, and pass?
- did the corpus conventions land in the code (write-time RAG), or did each
  layer invent its own interface?

## Run

```sh
veil cast "Build linkboard, a small self-hosted bookmarks web service ready for production use, using ONLY the Python standard library (no pip installs). Files: db.py (SQLite data layer: init_db/add_link/list_links/delete_link), app.py (http.server JSON API under /api/ plus static file serving, reads config.json), static/index.html and static/app.js (frontend that lists/adds/deletes links via fetch), cli.py (argparse add/list/delete), config.json, test_db.py and test_api.py (pytest), README.md. Follow the conventions in hive memory exactly." \
  --name linkboard --minds 3 --minutes 18 \
  --model llama3.1:8b --provider ollama --offline --continuous
```

Analyze with `python examples/lowparam-repro/sim_analyze.py data/linkboard`,
then boot the deliverable (`python app.py` in `data/linkboard/work/`) and click
around — the smoke gate probes `/api/*`, but production-shaped means a human
can actually use it.
