# the day after

**Covers:** `cloud/tot.js` (the tater-tot runtime, VERSION 9), `src/config/cf_tot.zig` (the launcher and the relay), `src/config/cf_garrett.zig` + `src/worker/garrett.zig` (Agent Garrett's pair and belt for chats and swarms), `src/cli/tot.zig` (`guard`, `verify`, `garrett`)
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
veil --tater garrett launch
veil --tater deploy "Keep the public services below answering; investigate and report every tripwire with evidence" \
    --name Sentinel --posture defend --leash 3600 --pace 120 --garrett
veil --tater guard Sentinel add https://status.example.org/ --text "All Systems Operational" --every 60
veil --tater guard Sentinel add https://api.example.org/health --status 200 --every 60
veil --tater guard Sentinel add https://www.example.org/ --pin --every 300
veil --tater guard Sentinel add dns:example.org --type NS --every 300
veil --tater guard Sentinel add dns:example.org --type MX --every 600
veil --tater key alert https://discord.com/api/webhooks/...
```

Every one of those is a runtime command too (`/guard add ...`, `/posture defend`, `/leash 3600`, `/garrett on`) in the desk's Tater-tots tab, and the first line is the desk's Settings button, *Deploy Agent Garrett*. A tot guards at most 16 targets; deploy another for more.

## The guard: a watch that needs no model

Every heartbeat, **before** the model is asked and whether or not one answers, the tot looks at each target that is due:

- a page: it must answer (a status in 200..399, or exactly `--status N`), it must show the words of `--text`, and with `--pin` its content fingerprint is kept;
- a DNS name: its answers of the record type, through DNS-over-HTTPS, compared with the last look.

A change of state is a **tripwire**. It goes four places at once: a `tripwire` event (chained, red in the console), an entry in the scratchpad every tot of the account reads, a directive in the tot's own inbox (its next iteration is brought forward and reads the tripwire as outranking its plan), and, with the `alert` key, one JSON POST to your webhook. A Discord or Slack webhook URL renders it as it is (`content` and `text` both carry the one line); anything else gets the event beside them. A recovery is said the same way, with how long the target was down. A pinned page's content changing, or a DNS answer changing, is noted once as `CHANGED` and becomes the new baseline, so round-robin addresses do not flap.

The alarm fires at the guard's cadence (`--every`, 30 s and up; the tot's pace otherwise) and the goal loop keeps its own next time, so a dead model, a model that only reasons, a spent daily budget and the loop's own backoff never stop the watch. The guard's checks always name the tot: `User-Agent: veil-tot/9 (Sentinel; +https://github.com/gary23w/nl-veil)`.

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

## Agent Garrett: the full security toolkit

Agent Garrett now provides 166 tools: 94 existing security tools and 72 Gary tools. **Settings → Models → Deploy security tools** deploys its edge MCP Worker, private execution Worker, dedicated Cloudflare Container and R2 storage into your account. The initial build takes place in Cloudflare and shows progress in Settings. Existing Cloudflare logins need Containers permissions; reconnect once when upgrading.

Enable it separately for chat (**Agent Garrett: on/off** beside auto-loop), a swarm or a tater-tot (the deploy form's **Agent Garrett** checkbox). The CLI supports `veil chat --garrett`; a tot can change its setting with `/garrett on|off`. Each opted-in feature receives typed `security_<name>` tools. `garrett_tools` and `garrett` remain available for compatibility.

Use NL-Veil as the local harness for your machine's evidence and controls. Gary's cloud filesystem is separate; the local-machine grant for a tot remains a separate choice. The complete deployment enables active and Gary tools. Choose the checks appropriate to your incident and configure a tot's posture and leash separately. [Security setup and personal-defense workflows](security-tools.md) explains that boundary and the verified live checks.

## Choose the work and preserve its evidence

The guard keeps watching at its configured cadence; an opted-in Agent Garrett supplies the full security toolkit for the investigation you request. Active and Gary tools are enabled. Give the tot a target set and the intended actions, configure its posture and leash, and retain the local mirror of its events and findings. The dedicated cloud runtime does not automatically have access to your laptop's filesystem or home network.

## Verification

Native and cloud regression suites cover guards, event chaining, posture, leash behavior, typed MCP discovery and dispatch, feature opt-ins and deployment/removal. On October 9, 2026, a live NL-Veil chat called the deployed Cloudflare runtime: Gary's command printed the requested marker and Linux, cloud shell listing returned its session list, and IOC extraction returned defanged synthetic indicators. A fresh chat completed with the exact cloud output after the desktop restarted. The live catalogue contains 94 edge tools and 72 Gary tools. Webhook delivery still depends on the operator's configured endpoint; the release's live checks exercise MCP and the dedicated execution runtime.
