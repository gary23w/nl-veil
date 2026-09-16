#!/usr/bin/env python3
"""Keep the model menus current: sync each opted-in provider's newest models from models.dev.

WHY THIS EXISTS
    Providers ship new models every week and a hand-kept catalog is always behind. Both binaries embed
    models.yaml at comptime, so a stale file is a stale app. When this script landed (2026-09-16) the yaml's
    newest OpenAI model was GPT-5 with two dozen newer releases live, and the Anthropic list had neither
    Opus 5 nor Fable 5.1. .github/workflows/models-sync.yml runs this daily and opens one pull request.

WHAT IT MAY EDIT
    Only providers that opt in with a `sync: models.dev/<provider id> ...` line, and in each of those only the
    block between `# >>> synced` and `# <<< synced` at the end of its model list — plus the
    web/public/models.json entries it marks "synced". Hand-written entries and their comments are never edited,
    moved or removed, so models[0] (the model a provider switch selects) never changes.

    The block is REWRITTEN every run and holds at most KEEP models, newest first: a new release pushes the
    oldest synced entry out instead of growing a menu past what the desk can draw (desk/src/catalog.zig
    refuses to compile a catalog that outgrows one). Leaving the menu re-points nothing — saved selections
    are model-id strings (desk/src/store.zig), not indices.

    To keep a synced model for good, move it above its `# >>> synced` line: from then on it is hand-written.
    To reject one, add it to scripts/sync-models.ignore.

WHICH MODELS QUALIFY — generic rules only; no provider is special-cased
    - text output, tool calling, not deprecated: the chat brain lives on the tool channel (the FIM note under
      deepseek in models.yaml shows what a model without one does)
    - not a moving alias (`*-latest`, `~vendor/...`): an alias swaps the model out from under its entry
    - released after the provider's newest hand-written model: that list already decided everything older
    - where the hand-written ids carry vendor prefixes (an aggregator's `openai/...`), only those vendors:
      newest-first across hundreds of vendors is a feed of long-tail releases
    - not an id another provider already lists: modelcfg.providerForModel resolves a bare id to the FIRST
      provider listing it, so a second listing earlier in the file would hand an existing cast another
      vendor's key
    - confirmed by a free source other than models.dev, as below

FREE SOURCES ONLY — no API key is read or sent, ever
    models.dev proposes a model; something anyone can read must confirm it before it is offered:
    - the provider's own GET {base}/models, when it answers WITHOUT a key (OpenRouter and Hugging Face do). It
      is the authority: a model it does not serve is never offered, and nothing else is consulted.
    - otherwise any one of: the documentation page models.dev links for the provider, and each source after
      the models.dev one on the `sync:` line — `litellm/<provider>` (LiteLLM's open model catalog) or the URL
      of a public page that lists the provider's models. A source that names NONE of the provider's models
      (a docs landing page, a page that only renders in a browser) does not get a vote.
    - when nothing can confirm anything that day, the provider's synced block stays exactly as it was: an
      outage never adds an unconfirmed model and never churns the pull request.

USAGE
    python scripts/sync-models.py                 # rewrite the synced blocks and web/public/models.json
    python scripts/sync-models.py --dry-run       # report what would change; write nothing
    python scripts/sync-models.py --summary FILE  # also write the markdown report (the PR body)
"""

import argparse
import datetime
import fnmatch
import html
import importlib.util
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
YAML = ROOT / "models.yaml"
JSON = ROOT / "web" / "public" / "models.json"
IGNORE = ROOT / "scripts" / "sync-models.ignore"
SOURCE = "https://models.dev/api.json"
SOURCE_PREFIX = "models.dev/"
LITELLM = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
LITELLM_PREFIX = "litellm/"
USER_AGENT = "nl-veil-models-sync (+https://github.com/gary23w/neuron-loops)"

# Synced models per provider. Ten providers at four apiece on top of the ~66 hand-written entries leaves the
# desk's flat Tasks menu (127 model rows) a wide margin.
KEEP = 4

# At or above this window ctx_k stays unstated: senseModel's largest tier default is 128K, so leaving it out can
# only UNDER-estimate the window, the safe direction engine.zig names (fold early, never overflow). Below it a
# tier default could claim room the model does not have, so the real window is written down.
CTX_K_UNSTATED_FROM = 128_000

BEGIN = "# >>> synced"
END = "# <<< synced"
BEGIN_LINE = BEGIN + " from models.dev by scripts/sync-models.py — rewritten every run; move an entry above this line to keep it"

ALIAS = re.compile(r"^~|(^|[-_./:])latest($|[-_./:])", re.IGNORECASE)  # gemini-flash-latest, ~openai/gpt-latest
PLAIN_ID = re.compile(r"[A-Za-z0-9@][A-Za-z0-9._:/@+-]*")  # what both yaml parsers read back verbatim


def die(msg):
    raise SystemExit(f"sync-models: {msg}")


def unquote(v):
    v = v.strip()
    return v[1:-1] if len(v) >= 2 and v[0] == '"' and v[-1] == '"' else v


def scalar(v):
    """A value written the way models.yaml's header says: quoted when it leads with @ or holds a colon."""
    return f'"{v}"' if v.startswith("@") or ":" in v else v


def scan(lines):
    """Where each provider's fields, hand-written models and synced block sit, by line index.

    Reads the YAML subset modelcfg.zig parses: providers at indent 2, their fields at 4, model items at 6, model
    fields at 8. Every rewrite is read back with gen-models-json.py's parser before anything is written, and a
    disagreement stops the run, so this scan never edits blind."""
    provs, cur, in_providers = [], None, False
    for i, raw in enumerate(lines):
        line = raw.rstrip()
        body = line.lstrip(" ")
        indent = len(line) - len(body)
        if not body:
            continue
        if body.startswith("#"):
            if cur is not None and indent == 6 and body.startswith(BEGIN):
                if cur["begin"] is not None:
                    die(f"{cur['key']}: a second '{BEGIN}' marker at line {i + 1}")
                cur["begin"] = i
            elif cur is not None and indent == 6 and body.startswith(END):
                if cur["begin"] is None or cur["end"] is not None:
                    die(f"{cur['key']}: a stray '{END}' marker at line {i + 1}")
                cur["end"] = i
            continue
        if indent == 0:
            in_providers, cur = body.startswith("providers:"), None
            continue
        if not in_providers:
            continue
        if indent == 2 and body.startswith("- key:"):
            cur = {"key": unquote(body[len("- key:"):]), "fields": {}, "curated": [], "synced": [], "order": [],
                   "begin": None, "end": None, "insert_at": None}
            provs.append(cur)
            continue
        if cur is None:
            continue
        in_block = cur["begin"] is not None and cur["end"] is None
        models = cur["synced"] if in_block else cur["curated"]
        if indent == 4:
            k, _, v = body.partition(":")
            cur["fields"][k.strip()] = unquote(v)
        elif indent == 6 and body.startswith("- id:"):
            models.append({"id": unquote(body[len("- id:"):])})
            cur["order"].append(models[-1]["id"])
            if not in_block:
                cur["insert_at"] = i + 1
        elif indent == 8 and models:
            k, _, v = body.partition(":")
            models[-1][k.strip()] = unquote(v)
            if not in_block:
                cur["insert_at"] = i + 1
    for p in provs:
        if p["begin"] is not None and p["end"] is None:
            die(f"{p['key']}: '{BEGIN}' is never closed by '{END}'")
    return provs


def fetch(url, timeout):
    """GET a public URL. It never carries a credential: nothing this script reads needs one."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


def unreadable(e):
    return f"HTTP {e.code}" if isinstance(e, urllib.error.HTTPError) else f"unreadable ({type(e).__name__})"


def api_listing(base):
    """The provider's own GET {base}/models, read WITHOUT a key: casefolded id -> the endpoint's spelling, or None
    when it wants a key or cannot be read. The second value says which, for the report."""
    if not base.startswith("http"):
        return None, "no endpoint"
    try:
        doc = json.loads(fetch(base.rstrip("/") + "/models", timeout=45))
    except Exception as e:  # a key wall, a transport or a decode failure: this source does not answer today
        return None, unreadable(e)
    items = doc.get("data", doc.get("models")) if isinstance(doc, dict) else doc
    ids = {}
    for it in items if isinstance(items, list) else []:
        mid = (it.get("id") or it.get("name")) if isinstance(it, dict) else it
        if isinstance(mid, str) and mid:
            mid = mid.removeprefix("models/")  # a listing may qualify its ids as models/<id>
            ids[mid.casefold()] = mid
    return (ids, "served publicly") if ids else (None, "named no models")


def page_text(url):
    """A public page as searchable text. Ids hide in HTML entities and in the escaped JSON a framework ships
    (`z-ai\\/glm-5.3`, `\\u002F`), so both are undone before matching."""
    text = html.unescape(fetch(url, timeout=45))
    return re.sub(r"\\u002[fF]", "/", text).replace("\\/", "/").casefold()


def names(text, mid):
    """Does the text name this model id as a whole token? gpt-5.6 inside gpt-5.6-luna does not count; a URL path
    segment (/models/gpt-5.6) or a quoted string does."""
    needle = mid.casefold()
    at = text.find(needle)
    while at != -1:
        before = text[at - 1] if at else " "
        after = text[at + len(needle):at + len(needle) + 2]
        if not (before.isalnum() or before in "_.:@-") and not (
                after[:1].isalnum() or after[:1] in "_/:@-" or (after[:1] == "." and after[1:2].isalnum())):
            return True
        at = text.find(needle, at + 1)
    return False


def litellm_catalog():
    """LiteLLM's open model catalog as provider name -> casefolded ids (keys lose their "<provider>/" prefix)."""
    catalog = {}
    for key, entry in json.loads(fetch(LITELLM, timeout=120)).items():
        prov = entry.get("litellm_provider") if isinstance(entry, dict) else None
        if isinstance(prov, str):
            catalog.setdefault(prov, set()).add(key.removeprefix(prov + "/").casefold())
    return catalog


def evidence(p, up, extra, shared):
    """What can confirm this provider's models today, keylessly: (listing, confirmers, notes).

    `listing` is the provider's own GET /models (api_listing); when it answers, nothing else is consulted.
    `confirmers` are (label, test) pairs for every other source that could be read AND names at least one model
    models.dev lists for the provider. `notes` say what each source did, for the report. `shared` holds LiteLLM
    (or its failure) so the catalog is fetched once per run."""
    listing, status = api_listing(p["fields"].get("base", ""))
    notes = [f"own `/models`: {status}"]
    if listing is not None:
        return listing, [], notes
    known = list(up["models"])
    confirmers = []
    doc = up.get("doc") if isinstance(up.get("doc"), str) and up["doc"].startswith("http") else None
    for src in ([doc] if doc else []) + extra:
        if src.startswith(LITELLM_PREFIX):
            label = src
            if "litellm" not in shared:
                try:
                    shared["litellm"] = litellm_catalog()
                except Exception as e:
                    shared["litellm"] = e
            if isinstance(shared["litellm"], Exception):
                notes.append(f"`{label}`: {unreadable(shared['litellm'])}")
                continue
            ids = shared["litellm"].get(src[len(LITELLM_PREFIX):], set())
            test = lambda mid, ids=ids: mid.casefold() in ids
        else:
            parts = urllib.parse.urlsplit(src)
            label = (parts.netloc + parts.path).rstrip("/")
            try:
                text = page_text(src)
            except Exception as e:  # an unreadable page simply has no vote today
                notes.append(f"`{label}`: {unreadable(e)}")
                continue
            test = lambda mid, text=text: names(text, mid)
        if not any(test(mid) for mid in known):
            notes.append(f"`{label}`: names none of its models, not used")
            continue
        confirmers.append((label, test))
        notes.append(f"`{label}`: used")
    return None, confirmers, notes


def load_ignore():
    rules = []
    if IGNORE.exists():
        for n, raw in enumerate(IGNORE.read_text(encoding="utf-8").splitlines(), 1):
            parts = raw.split("#", 1)[0].split()
            if not parts:
                continue
            if len(parts) != 2:
                die(f"{IGNORE.name}:{n}: expected '<provider key> <model id>', got {raw.strip()!r}")
            rules.append((parts[0], parts[1]))
    return rules


def vendor(mid):
    return mid.rsplit("/", 1)[0].lower() if "/" in mid else ""


def owners(provs, blocks):
    """The first provider listing each model id, in file order — whom modelcfg.providerForModel resolves it to.
    Providers already processed this run count with their NEW block."""
    first = {}
    for p in provs:
        for m in p["curated"] + blocks.get(p["key"], p["synced"]):
            first.setdefault(m["id"], p["key"])
    return first


def pick(prov, catalog, listing, confirmers, taken, rules):
    """This provider's synced block: its KEEP newest qualifying models, newest first. Also returns why each
    upstream model was passed over (casefolded id -> reason; the report explains removals with it) and how many
    qualified before the KEEP cut."""
    curated = {m["id"].casefold() for m in prov["curated"]}
    listed = {mid.casefold(): mid for mid in catalog}
    watermark = max((catalog[listed[c]].get("release_date") or "" for c in curated if c in listed), default="")
    vendors = {vendor(m["id"]) for m in prov["curated"]}

    def disqualified(mid, m, wire):
        if (m.get("modalities") or {}).get("output") != ["text"]:
            return "not a text-only model"
        if not m.get("tool_call"):
            return "no tool calling"
        if m.get("status") == "deprecated":
            return "deprecated upstream"
        if ALIAS.search(mid):
            return "a moving alias"
        if not PLAIN_ID.fullmatch(mid):
            return "an id models.yaml cannot carry"
        if (m.get("release_date") or "") <= watermark:
            return "no newer than the hand-written list"
        if vendors - {""} and vendor(mid) not in vendors:
            return "from a vendor this provider's list does not carry"
        if any(fnmatch.fnmatchcase(prov["key"], pk) and fnmatch.fnmatchcase(mid, pat) for pk, pat in rules):
            return "listed in scripts/sync-models.ignore"
        if listing is not None:
            if mid.casefold() not in listing:
                return "not served by the provider's own /models"
        elif not any(test(mid) for _, test in confirmers):
            return "no free source confirms it"
        owner = taken.get(wire)
        if owner is not None and owner != prov["key"]:
            return f"already listed by {owner}"
        return None

    eligible, why = [], {}
    for mid in sorted(catalog):
        m = catalog[mid]
        if mid.casefold() in curated:
            continue
        wire = listing.get(mid.casefold(), mid) if listing is not None else mid  # the endpoint's own spelling wins
        reason = disqualified(mid, m, wire)
        if reason:
            why[mid.casefold()] = reason
        else:
            by = ["own /models"] if listing is not None else [label for label, test in confirmers if test(mid)]
            eligible.append((m.get("release_date") or "", wire, m, by))
    eligible.sort(key=lambda e: e[0], reverse=True)  # stable, so same-day releases stay in id order
    for _, wire, _, _ in eligible[KEEP:]:
        why[wire.casefold()] = "newer releases took the synced slots"
    return [block_entry(wire, m, by) for _, wire, m, by in eligible[:KEEP]], why, len(eligible)


def block_entry(mid, m, confirmed_by):
    label = " ".join(str(m.get("name") or "").replace('"', "").split()) or mid
    entry = {"id": mid, "label": label, "upstream": m, "confirmed_by": confirmed_by}
    ctx = (m.get("limit") or {}).get("context") or 0
    if isinstance(ctx, (int, float)) and 1000 <= ctx < CTX_K_UNSTATED_FROM:
        entry["ctx_k"] = int(ctx) // 1000
    return entry


def render(block):
    out = ["      " + BEGIN_LINE]
    for e in block:
        out += [f"      - id: {scalar(e['id'])}", f"        label: {scalar(e['label'])}"]
        if "ctx_k" in e:
            out.append(f"        ctx_k: {e['ctx_k']}")
    return out + ["      " + END]


def rewrite(lines, provs, blocks):
    out, edits = list(lines), []
    for p in provs:
        if p["key"] not in blocks:
            continue
        new = render(blocks[p["key"]]) if blocks[p["key"]] else []
        if p["begin"] is not None:
            edits.append((p["begin"], p["end"] + 1, new))
        elif new:
            edits.append((p["insert_at"], p["insert_at"], new))
    for start, stop, new in sorted(edits, key=lambda e: e[0], reverse=True):  # bottom-up keeps indices valid
        out[start:stop] = new
    return out


def verify(new_lines, provs, blocks):
    """Refuse to write a rewrite the catalog's other parser would read differently than intended."""
    spec = importlib.util.spec_from_file_location("gen_models_json", ROOT / "scripts" / "gen-models-json.py")
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    parsed, _ = gen.parse_yaml("\n".join(new_lines))
    rescanned = scan(new_lines)
    if [p["key"] for p in parsed] != [p["key"] for p in rescanned] or [p["key"] for p in rescanned] != [p["key"] for p in provs]:
        die("the rewrite changed the provider list — not writing")
    for gp, sp, op in zip(parsed, rescanned, provs):
        if [m["id"] for m in gp["models"]] != sp["order"]:
            die(f"{sp['key']}: gen-models-json.py reads the rewrite differently — not writing")
        if [m["id"] for m in sp["curated"]] != [m["id"] for m in op["curated"]]:
            die(f"{sp['key']}: the rewrite touched hand-written models — not writing")
        if sp["key"] in blocks and [m["id"] for m in sp["synced"]] != [e["id"] for e in blocks[sp["key"]]]:
            die(f"{sp['key']}: the synced block reads back differently — not writing")


def price(m):
    c = m.get("cost") or {}
    i, o = c.get("input"), c.get("output")
    if not (isinstance(i, (int, float)) and isinstance(o, (int, float))):
        return ""
    return "free" if i == 0 and o == 0 else f"${round(i, 2):g} in / ${round(o, 2):g} out per MTok"


def note(m):
    """Shown under a picked model in the web UI: facts from the listing, and where they came from."""
    caps = ["tool calling"] + (["reasoning"] if m.get("reasoning") else [])
    media = [x for x in (m.get("modalities") or {}).get("input", []) if x != "text"]
    if media:
        caps.append(" / ".join(media) + " input")
    parts = [f"Released {m['release_date']}"] if m.get("release_date") else []
    ctx = (m.get("limit") or {}).get("context") or 0
    if ctx:
        parts.append(f"{int(ctx) // 1000:,}K context")
    parts.append(", ".join(caps).capitalize())
    if price(m):
        parts.append(price(m))
    return ". ".join(parts) + ". Listed automatically from models.dev."


def sync_json(doc, provs, blocks):
    """Mirror the synced blocks into web/public/models.json. The sync owns exactly the entries it marked "synced":
    those are rebuilt in block order each run and dropped once models.yaml stops listing them. An id the json
    already carries unmarked (hand-written, or under another provider) is left alone — gen-models-json.py keys
    the json by id, and the picker resolves a model's provider by id, so a second entry would be ambiguous."""
    in_yaml = {(p["key"], m["id"]) for p in provs for m in p["curated"] + blocks.get(p["key"], p["synced"])}
    rebuilt = {(k, e["id"]) for k, block in blocks.items() for e in block}
    kept = [m for m in doc.get("models", [])
            if not (m.get("synced") and ((m.get("provider"), m.get("id")) not in in_yaml or (m.get("provider"), m.get("id")) in rebuilt))]
    present = {m["id"] for m in kept}
    for p in provs:
        for e in blocks.get(p["key"], []):
            if e["id"] in present:
                continue
            m = e["upstream"]
            entry = {"id": e["id"], "label": e["label"], "provider": p["key"],
                     "hosting": "local" if p["fields"].get("local") == "true" else "hosted"}
            ctx = (m.get("limit") or {}).get("context") or 0
            if ctx:
                entry["context"] = int(ctx)
            entry["note"] = note(m)
            entry["synced"] = "models.dev"
            kept.append(entry)
            present.add(e["id"])
    doc["models"] = kept


def stale_curated(p, catalog, listing, confirmers):
    """Hand-written ids the free sources no longer vouch for — reported, never removed. A provider's own keyless
    /models is the authority when it answers; otherwise models.dev, with which confirming sources still name it."""
    if listing is not None:
        where = p["fields"].get("base", "").rstrip("/") + "/models"
        return [f"`{m['id']}` ({p['key']}) is not served by `{where}`" for m in p["curated"] if m["id"].casefold() not in listing]
    listed = {i.casefold() for i in catalog}
    out = []
    for m in p["curated"]:
        if m["id"].casefold() in listed:
            continue
        still = [label for label, test in confirmers if test(m["id"])]
        out.append(f"`{m['id']}` ({p['key']}) is not listed on models.dev"
                   + (f", though `{'`, `'.join(still)}` still names it" if still else ", and no free source names it"))
    return out


def cell(s):
    return str(s).replace("|", "\\|")


def report(results, warnings, today):
    added = [(r, e) for r in results for e in r["added"]]
    removed = [(r, mid, why) for r in results for mid, why in r["removed"]]
    out = [f"## Model catalog sync — {today}", ""]
    if added or removed:
        out += ["Newer models from [models.dev](https://models.dev), each confirmed by a free source — no API keys — and "
                "written into its provider's `# >>> synced` block in `models.yaml`, mirrored into `web/public/models.json`. "
                "Hand-written entries are untouched; the rules are in `scripts/sync-models.py`.", ""]
    else:
        out += ["No new models: every synced block is already current.", ""]
    if added:
        out += ["### Added", "", "| Provider | Model | Released | Context | Price | Confirmed by |", "|---|---|---|---|---|---|"]
        for r, e in added:
            m = e["upstream"]
            ctx = (m.get("limit") or {}).get("context") or 0
            out.append(f"| {r['key']} | `{cell(e['id'])}` {cell(e['label'])} | {m.get('release_date') or '?'} | "
                       f"{f'{int(ctx) // 1000:,}K' if ctx else '?'} | {cell(price(m)) or '?'} | {cell(', '.join(e['confirmed_by']))} |")
        out.append("")
    if removed:
        out += ["### Left the synced block", "", "| Provider | Model | Why |", "|---|---|---|"]
        out += [f"| {r['key']} | `{cell(mid)}` | {cell(why)} |" for r, mid, why in removed]
        out.append("")
    held = [r for r in results if r["kept"]]
    if held:
        out += ["### Not checked today", ""]
        out += [f"- `{r['key']}`: no free source could confirm anything ({'; '.join(r['notes'])}), so its synced block "
                "was left exactly as it was" for r in held] + [""]
    stale = [s for r in results for s in r["stale"]]
    if stale:
        out += ["### Worth a look — hand-written entries, left as they are", ""] + [f"- {s}" for s in stale] + [""]
    if warnings:
        out += ["### Warnings", ""] + [f"- {w}" for w in warnings] + [""]
    out += ["<details><summary>Per provider</summary>", "",
            "| Provider | Sources | Qualifying | Synced |", "|---|---|---|---|"]
    out += [f"| {r['key']} | {cell('; '.join(r['notes']))} | {'—' if r['kept'] else r['eligible']} | {len(r['block'])} |" for r in results]
    out += ["", "</details>", "",
            "Keep a synced model for good: move it above its provider's `# >>> synced` line. "
            "Reject one: add `<provider> <model id>` to `scripts/sync-models.ignore`."]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Sync each opted-in provider's newest models from models.dev.")
    ap.add_argument("--dry-run", action="store_true", help="report what would change; write nothing")
    ap.add_argument("--summary", metavar="FILE", help="also write the markdown report to FILE")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    text = YAML.read_text(encoding="utf-8")
    lines = text.split("\n")
    provs = scan(lines)
    rules = load_ignore()
    try:
        source = json.loads(fetch(SOURCE, timeout=120))
    except Exception as e:
        die(f"could not read {SOURCE}: {e}")

    blocks, results, warnings, shared = {}, [], [], {}
    for p in provs:
        spec = p["fields"].get("sync", "").split()
        if not spec:
            continue
        if not spec[0].startswith(SOURCE_PREFIX):
            warnings.append(f"`{p['key']}`: the sync line must start with `{SOURCE_PREFIX}<provider id>`, skipped")
            continue
        extra = [s for s in spec[1:] if s.startswith((LITELLM_PREFIX, "https://", "http://"))]
        if len(extra) != len(spec) - 1:
            warnings.append(f"`{p['key']}`: ignored unknown sources {', '.join(s for s in spec[1:] if s not in extra)}")
        up = source.get(spec[0][len(SOURCE_PREFIX):])
        if not isinstance(up, dict) or not isinstance(up.get("models"), dict):
            warnings.append(f"`{p['key']}`: models.dev lists no provider `{spec[0][len(SOURCE_PREFIX):]}`, skipped")
            continue
        if not p["curated"]:
            warnings.append(f"`{p['key']}`: no hand-written models, so a synced one would become the provider's default, skipped")
            continue
        listing, confirmers, notes = evidence(p, up, extra, shared)
        result = {"key": p["key"], "notes": notes, "kept": False, "eligible": 0, "block": p["synced"],
                  "added": [], "removed": [], "stale": []}
        results.append(result)
        if listing is None and not confirmers:
            result["kept"] = True  # nothing can confirm today: the block is not touched at all
            continue
        block, why, eligible = pick(p, up["models"], listing, confirmers, owners(provs, blocks), rules)
        blocks[p["key"]] = block
        old, new = [m["id"] for m in p["synced"]], {e["id"] for e in block}
        result.update({
            "eligible": eligible, "block": block,
            "added": [e for e in block if e["id"] not in old],
            "removed": [(mid, why.get(mid.casefold(), "no longer listed on models.dev")) for mid in old if mid not in new],
            "stale": stale_curated(p, up["models"], listing, confirmers),
        })

    new_lines = rewrite(lines, provs, blocks)
    verify(new_lines, provs, blocks)
    doc = json.loads(JSON.read_text(encoding="utf-8"))
    before = json.dumps(doc, sort_keys=True)
    sync_json(doc, provs, blocks)

    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    summary = report(results, warnings, today)
    print(summary)
    if args.summary:
        Path(args.summary).write_text(summary, encoding="utf-8")
    if args.dry_run:
        print("dry run: nothing written")
        return 0
    new_text = "\n".join(new_lines)
    if new_text != text:
        with open(YAML, "w", encoding="utf-8", newline="\n") as f:
            f.write(new_text)
        print(f"wrote {YAML.relative_to(ROOT)}")
    if json.dumps(doc, sort_keys=True) != before:
        with open(JSON, "w", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {JSON.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
