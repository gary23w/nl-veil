# the day after

**Covers:** `cloud/tot.js` (the tater-tot runtime, VERSION 8), `src/config/cf_tot.zig` (the launcher and the relay), `src/cli/tot.zig` (`guard`, `verify`, `garrett`)  
**Kind:** operator walkthrough  
**Description:** What a tater-tot is for when a large AI incident lands: the week in which the labs go quiet, the hosted models get locked down or withdrawn, the attribution fight starts, and the rules get written. How to arm one before that week, what each piece does, and what it does not do.

---

## The premise

A tater-tot runs in *your* Cloudflare account, on open-weight models through the account's own AI binding, from an MIT runtime you can read in one file. No lab's policy sits between it and its work, and nobody can revoke it but you. That is worth something precisely in the week the labs rehearse for: the first 168 hours after an agentic attack on payments, a rogue-agent swarm against internet infrastructure, a cascading physical-infrastructure event, or a loss-of-control incident disclosed late.

Three things go wrong for an autonomous agent in that week, and the kit answers each:

1. **The model goes away.** Hosted models get rate-limited, withdrawn or changed overnight. A tot's goal loop needs a model; its *guard* does not.
2. **Nobody can tell who did what.** The scenarios turn on attribution: which agent, whose, when. A tot is never one of the "hard to attribute" agents: its requests name it, its posture can forbid it from hiding, and its record is chained.
3. **Who knew what, when.** The slow-burn scenario is about disclosure timelines. A tot's events are hash-chained and mirrored to your machine, held outside anyone's lab, and verified without trusting the server.

And one thing must *not* go wrong: a tot must never become part of the swarm. The DEFEND posture and the leash are for that.

## Before the week: arm a tot

Deploy it as a defender, with a leash, and give it something to watch:

```sh
veil --tater deploy "Keep the public services below answering; investigate and report every tripwire with evidence" \
    --name Sentinel --posture defend --leash 3600 --pace 120
veil --tater guard Sentinel add https://status.example.org/ --text "All Systems Operational" --every 60
veil --tater guard Sentinel add https://api.example.org/health --status 200 --every 60
veil --tater guard Sentinel add https://www.example.org/ --pin --every 300
veil --tater guard Sentinel add dns:example.org --type NS --every 300
veil --tater guard Sentinel add dns:example.org --type MX --every 600
veil --tater key alert https://discord.com/api/webhooks/...
veil --tater garrett launch
```

Every one of those is a runtime command too (`/guard add ...`, `/posture defend`, `/leash 3600`) in the desk's Tater-tots tab. A tot guards at most 16 targets; deploy another for more.

## The guard: a watch that needs no model

Every heartbeat, **before** the model is asked and whether or not one answers, the tot looks at each target that is due:

- a page: it must answer (a status in 200..399, or exactly `--status N`), it must show the words of `--text`, and with `--pin` its content fingerprint is kept;
- a DNS name: its answers of the record type, through DNS-over-HTTPS, compared with the last look.

A change of state is a **tripwire**. It goes four places at once: a `tripwire` event (chained, red in the console), an entry in the scratchpad every tot of the account reads, a directive in the tot's own inbox (its next iteration is brought forward and reads the tripwire as outranking its plan), and, with the `alert` key, one JSON POST to your webhook. A Discord or Slack webhook URL renders it as it is (`content` and `text` both carry the one line); anything else gets the event beside them. A recovery is said the same way, with how long the target was down. A pinned page's content changing, or a DNS answer changing, is noted once as `CHANGED` and becomes the new baseline, so round-robin addresses do not flap.

The alarm fires at the guard's cadence (`--every`, 30 s and up; the tot's pace otherwise) and the goal loop keeps its own next time, so a dead model, a model that only reasons, a spent daily budget and the loop's own backoff never stop the watch. The guard's checks always name the tot: `User-Agent: veil-tot/8 (Sentinel; +https://github.com/gary23w/nl-veil)`.

`veil --tater guard Sentinel` lists what it watches and the state of each target; `veil --tater` shows `guard N` and `TRIPPED` on the roster.

## The evidence chain: who knew what, when

Every event a tot writes carries `prev` and `hash`: SHA-256 over the previous event's hash, the seq, the time, the kind and the text. The mirror writes the rows as they are into `<data>/u<id>/_tots/<name>-<deployed>/events.jsonl`, so the file on your machine is tamper-evident on its own: an altered row, a dropped row, a row from another run all break the chain.

```sh
veil --tater verify Sentinel-20261009-141500
```

walks the run from its first event and recomputes the chain on this machine (`src/cli/tot.zig` holds the same test vectors as the runtime). It exits 0 with the signed count and the last hash, 2 with the first event where the chain broke and why. The runtime's status carries the current `chain` hash too, so a line written down at any moment ("at 14:15 UTC the chain was `ee27...`") anchors everything before it. Events from before VERSION 8 are counted as unsigned, not judged.

## DEFEND: a posture for the incident

`/posture defend` (or `--posture defend` at deployment, `veil --tater set <name> --posture defend`) changes four things:

- the runtime is **frozen**: `runtime_edit` and `runtime_deploy` are refused until `/posture normal`; the tot cannot rewrite its own prompts, tools or stop rules in the middle of an incident;
- a CAPTCHA or bot check is **reported** (`BOT CHECK`) and not worked through;
- every request the tot makes **names it**, whatever user agent the model asked for;
- the prompt holds it to read-only verification - fetch, DNS and certificate lookups, Agent Garrett's passive tools - preserving what it finds in a file first and reporting with the exact evidence through `say`, and tells it that nothing irreversible (deleting, sending, purchasing, publishing, scanning, probing anything it was not asked to guard) happens unless you asked for it in a message.

The posture is a setting, not a promise about the model: the refusals are enforced in the runtime, the rest is the prompt.

## The leash: never running on alone

Every call from your veil is contact: the mirror's roster poll once a minute while your veil is running, the desk's tab, any `veil --tater` verb. With `/leash <seconds>` set, no contact for that long **holds the goal loop**: no model calls, no autonomous steps, said once in the console and to your webhook, while the guard goes on watching and reporting. Any call releases it (the console says so and the loop resumes at once). `/leash off` removes it; 0 is the default.

A tot with a leash cannot be the agent that keeps acting after its operator has gone dark. The guard, which only reads and reports, is what it does on its own.

## Agent Garrett: a blue-team belt

[Agent Garrett](https://github.com/gary23w/garrettstimpson.ca/tree/main/agent) is a Cloudflare Worker with some ninety security tools behind a stateless MCP endpoint: CVE / KEV / EPSS intel, DNS and certificate transparency, RDAP, email security posture (SPF / DMARC / DNSSEC), subdomain takeover checks, IOC extraction and defanging, evidence manifests (content receipts), forensic timelines, event-log triage, hash reputation. Passive by default; the active ones only as its operator allows.

`veil --tater garrett launch` puts it in your account beside the tater-tots: the veil reads the agent's five modules from its repo, uploads them as one Worker, `veil-garrett`, with the policy the agent's own `wrangler.toml` ships (safe mode, confirmation required, no active and no dark-web tools over MCP), sets its secrets (its MCP bearer; a password locking its chat UI, which is open to anyone with the address otherwise; a session secret), enables its address, and points the tots at it with two secrets on their Worker. From their next iteration the tots have `garrett_tools` (the list, with the argument names) and `garrett` (`{"name": "dns_records", "args": {"domain": "example.org"}}`); a tool's text comes back with its evidence metadata. A tot can ask for the launch itself (`garrett_launch`): your veil launches it on its next sync while it is running. `veil --tater garrett` shows it; `garrett password` prints the UI password; `garrett rm` removes it; removing the last tater-tot removes it too. An Agent Garrett you deployed yourself works as well: `veil --tater key garrett_url https://.../mcp` and `key garrett_token <token>`.

## What this is not

A Worker in a Cloudflare account does not defend a grid, a payment rail or a water plant, and nothing here attacks anything: there is no scanner, no exploit, no counter-attack, and the DEFEND prompt forbids probing what the tot was not asked to guard. What a tot does in that week is the part a lone technician can: keep watching the public face of what matters to you when every hosted model is dark, keep an unforgeable record of what it saw and when, raise the alarm where you will see it, look things up with a blue-team belt that does not route through a lab, and never, by construction, be the anonymous agent in the story.

## What is proven, and what is not

Every piece above is covered against stand-ins: the runtime's node suite (the guard through a dead model and a spent budget, DNS drift, the chain and a tampered row, DEFEND, the leash, Agent Garrett over MCP and the launch request) and the Zig suite (the upload body, the launch flow against the stand-in API with a refusal and its quarter-hour backoff, the chain verifier against the runtime's vectors). Not yet proven on a live account: a tripwire on a real Worker, a real Discord or Slack webhook rendering the POST, and the Agent Garrett launch against the real Cloudflare API. The agent's modules are fetched from its `main` branch at launch, so its own changes land at the next launch, and a change to its `wrangler.toml` bindings would need the launcher's metadata updated to match.
