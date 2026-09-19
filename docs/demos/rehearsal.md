# SignalDesk: a substantial build walkthrough

Use a new Veil conversation and synthetic data only. Keep account headers, profile cards, console paths and authentication screens outside every capture.

## 1. Install and connect (30 seconds)

Download the full desktop ZIP from the latest release, extract it, and open `veil.exe` on Windows (`./veil` on macOS/Linux). Keep `bin/` and `veil-install.txt` with the app. Open Settings and select **Log in with Cloudflare**. Complete authentication privately, review permissions, and return to select a Workers AI model.

## 2. Give the system a real brief

The following prompt was submitted to Veil during the rehearsal:

> Build SignalDesk, a substantial customer-support operations workspace, in this new conversation's build directory. Use only synthetic ticket data and fictional companies. Do not read personal files, accounts, credentials, unrelated history or other projects. Create a polished responsive web app with a dark sidebar, ticket queue, text search, status and priority filters, a ticket detail drawer, editable assignment and status, a searchable knowledge base, and analytics showing backlog, resolution times and priority distribution. Seed 24 realistic tickets and 6 articles. Persist edits in localStorage. Use HTML/CSS/JS with no build step or external services. All navigation and controls must work; include empty states and keyboard-accessible dialogs. Plan briefly, implement, run meaningful checks, and state exactly what was tested and what remains unverified. This is a synthetic-data prototype, not a production service. Do not deploy publicly. Finish after one implementation and verification pass.

Narration: “This is a multi-view support workflow. The brief names the data, interactions, persistence and acceptance checks, so we can assess the result.”

## 3. Show the work

Capture real planning, file creation and verification from Veil. Skip idle waiting in the presentation. Do not relabel intermediate work as completed or imply that separate checkpoints are a continuous recording.

## 4. Walk through the result

Verify and show: filter the queue, search a ticket, change its status, reload to check persistence, search the knowledge base, and inspect analytics. Record observed results and limitations. A synthetic local prototype does not establish production readiness, secure authentication or server persistence.

## 5. Make one meaningful change

Follow-up prompt for the next rehearsal pass:

> Add an SLA-risk view that flags unresolved high-priority tickets older than 24 hours. Derive the count from the existing ticket data, link the KPI to the filtered queue, and ensure resolving a ticket updates both immediately. Keep the existing visual design. Test a ticket at the threshold, a resolved ticket, and an empty result. Report what you verified.

Do not present this follow-up as completed until it has been run and checked.

## 6. Close with evidence

Show the working interface and a short, accurate verification list. Invite viewers to try the brief with their own model. No fixed speed, cost or quality claims: results depend on the model, settings and task.

## Observed rehearsal results — 19 September 2026

Veil generated a 36 KB standalone HTML/CSS/JavaScript app in its conversation workspace. A copy was served locally for browser verification. The following were checked through the rendered interface:

- The ticket queue initially contained 24 synthetic records.
- Searching `VPN` narrowed the queue to ticket #1001.
- Changing #1001 to Resolved and assigning it to Demo team survived a page reload.
- Filtering Open excluded the resolved ticket and showed four open records.
- Knowledge Base displayed six articles; searching `webhook` returned the matching article.
- Analytics displayed priority and status distributions reflecting the changed ticket.

The first output's analytics labels overstated the calculations. A follow-up to Veil changed “Resolved this week” to “Resolved tickets”, “Avg resolution time” to “Avg time to last update”, and “SLA met” to “Non-critical or completed”. A source comparison confirmed only these three label lines changed; a browser reload confirmed the corrected labels. These are label corrections, not implementation of SLA tracking.

This was a functional smoke check, not an exhaustive accessibility, responsive-layout or production-readiness audit. The proposed SLA-risk feature above remains a future rehearsal prompt.
