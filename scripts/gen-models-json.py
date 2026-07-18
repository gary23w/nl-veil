#!/usr/bin/env python3
"""Generate web/public/models.json from models.yaml.

WHY THIS EXISTS
    models.yaml is the one catalog: it is @embedFile'd into modelcfg.zig at comptime and drives every
    model menu in the server and the desk. web/public/models.json is a SECOND copy, served to the
    browser, and the two had drifted badly — the yaml carried the first-party Moonshot/Kimi provider
    and four live model ids that the json had never heard of, so the web UI simply could not offer
    them. Hand-editing both is how that happened; this script makes the yaml the source of truth.

WHY IT IS ADDITIVE, NOT AUTHORITATIVE
    Neither file is a superset of the other. The yaml has the first-party Moonshot/Kimi provider the
    json lacks; the json has four providers (custom, fireworks, mistral, together) and ~30 model ids
    the yaml lacks, plus prose the yaml has no field for (`note`, `cost`, `tools`, `context`).
    A straight regeneration measured at 62 models against the json's 79 — it would have DELETED 30
    working entries to add 14.

    So this merges in one direction only: it ADDS what the yaml has and the json does not, and
    updates labels/base URLs where the yaml disagrees. It never removes a provider or a model. The
    `mock` provider is skipped — it is an internal test backend, not something to offer a user.

    Reconciling the two lists properly (moving those 30 ids into the yaml so one file really is the
    source of truth) is a separate job that needs each id verified against its live API, which is
    exactly how the yaml's Moonshot comment says its four ids were established.

USAGE
    python scripts/gen-models-json.py            # merge models.yaml into web/public/models.json
    python scripts/gen-models-json.py --check    # exit 1 if the json is missing anything (for CI)

    the veil — https://github.com/gary23w/nl-veil
    Author / publisher: gary23w — https://github.com/gary23w
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
YAML = ROOT / "models.yaml"
JSON = ROOT / "web" / "public" / "models.json"

# models.yaml is a deliberate YAML SUBSET (documented at the top of that file): two-space indents,
# "- " list items with an inline first field, bare or "double-quoted" scalars, true/false booleans,
# full-line comments. modelcfg.zig parses the same subset at comptime. Matching that parser's
# strictness here means a file this script accepts is a file the Zig side accepts.
SCALAR = re.compile(r'^\s*([a-z_]+):\s*(.*)$')


def unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1]
    return v


def parse_yaml(text: str):
    providers, defaults = [], {}
    prov, model, in_models, in_defaults = None, None, False, False

    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        body = line.lstrip()

        if body.startswith("defaults:"):
            in_defaults, prov, model = True, None, None
            continue
        if in_defaults:
            if indent == 0:
                in_defaults = False
            else:
                m = SCALAR.match(line)
                if m:
                    defaults[m.group(1)] = unquote(m.group(2))
                continue

        # a provider item: "- key: anthropic"
        if body.startswith("- key:"):
            prov = {"key": unquote(body[len("- key:"):]), "models": []}
            providers.append(prov)
            model, in_models = None, False
            continue

        if prov is None:
            continue

        if body.startswith("models:"):
            in_models = True
            continue

        # a model item: "- id: kimi-k3"
        if in_models and body.startswith("- id:"):
            model = {"id": unquote(body[len("- id:"):])}
            prov["models"].append(model)
            continue

        m = SCALAR.match(line)
        if not m:
            continue
        k, v = m.group(1), unquote(m.group(2))
        if v in ("true", "false"):
            v = v == "true"
        elif v.isdigit():
            v = int(v)

        target = model if (in_models and model is not None) else prov
        target[k] = v

    return providers, defaults


SKIP_PROVIDERS = {"mock"}  # internal test backend; never offer it in a user-facing picker


def main() -> int:
    check = "--check" in sys.argv
    yprov, ydefaults = parse_yaml(YAML.read_text(encoding="utf-8"))

    doc = json.loads(JSON.read_text(encoding="utf-8"))
    providers = doc.setdefault("providers", [])
    models = doc.setdefault("models", [])
    by_prov = {p["key"]: p for p in providers}
    by_model = {m["id"]: m for m in models}

    added_p, added_m, updated = [], [], []

    for p in yprov:
        key = p["key"]
        if key in SKIP_PROVIDERS:
            continue
        base = p.get("base", "")
        # Cloudflare's base carries an "{account}" placeholder no client can resolve; the web UI
        # reaches Workers AI through the OAuth path, so it keeps the sentinel the json already used.
        if "{account}" in base:
            base = "cloudflare"
        elif p.get("local"):
            base = "local"

        if key not in by_prov:
            entry = {
                "key": key,
                "label": p.get("label", key),
                "kind": "openai-compatible",
                "base_url": base,
                "needs_key": bool(p.get("needs_key", False)),
            }
            providers.append(entry)
            by_prov[key] = entry
            added_p.append(key)
        else:
            # The yaml is authoritative on ENDPOINTS — a stale base URL reads to the user as a broken
            # model, so that one is worth syncing.
            #
            # needs_key is deliberately NOT synced. The two files mean different things by it: the
            # yaml's is "a deploy must carry credentials", the json's is "the user must paste a BYOK
            # key into the picker". They disagree exactly where it matters — Workers AI is yaml
            # needs_key:true (it does need a credential) but json needs_key:false (the user pastes
            # nothing; the server resolves a Cloudflare OAuth token). Propagating it would make the
            # web UI demand a key for the one provider whose whole selling point is not needing one.
            cur = by_prov[key]
            if base and cur.get("base_url") != base and cur.get("base_url") not in ("cloudflare", "local"):
                cur["base_url"] = base
                updated.append(f"{key}.base_url")

        for m in p.get("models", []):
            mid = m["id"]
            if mid in by_model:
                continue
            entry = {
                "id": mid,
                "label": m.get("label", mid),
                "provider": key,
                "hosting": "local" if p.get("local") else "hosted",
            }
            if m.get("ctx_k"):
                entry["context"] = int(m["ctx_k"]) * 1000
            models.append(entry)
            by_model[mid] = entry
            added_m.append(mid)

    defaults = doc.setdefault("defaults", {})
    if ydefaults.get("cf_model"):
        defaults["workers_ai"] = ydefaults["cf_model"]

    if check:
        if added_p or added_m or updated:
            print("models.json is STALE against models.yaml:", file=sys.stderr)
            for k in added_p:
                print(f"  missing provider: {k}", file=sys.stderr)
            for k in added_m:
                print(f"  missing model:    {k}", file=sys.stderr)
            for k in updated:
                print(f"  out of date:      {k}", file=sys.stderr)
            print("run: python scripts/gen-models-json.py", file=sys.stderr)
            return 1
        print("models.json covers models.yaml")
        return 0

    JSON.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{JSON.relative_to(ROOT)}: +{len(added_p)} providers, +{len(added_m)} models, "
          f"{len(updated)} fields updated (nothing removed)")
    for k in added_p:
        print(f"  + provider {k}")
    for k in added_m:
        print(f"  + model    {k}")
    for k in updated:
        print(f"  ~ updated  {k}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
