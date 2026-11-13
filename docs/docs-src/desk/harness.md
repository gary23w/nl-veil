# harness

**File:** `desk/src/harness.zig`  
**Module:** `desk`  
**Description:** The desk's picture of the web veil's worker harness: its status, job queue, schedules and one job's outcome as fixed-size values, the readers that fill them from the server's JSON, and the writer for a queued job's request body. No I/O.

---

## Purpose Summary

The Tasks tab has a third inner view, **Web harness** (drawn in `main.zig`, `drawSchedHarness`). It shows the job queue of the user's `veil-web` Worker as the server reads it through `/api/v1/harness` (see [cf_harness](../config/cf_harness.md)). This file is the data under it.

The view shows the harness's version and address, today's model calls against the limit, and how many jobs are waiting and running. A text line queues a job (Enter or **Queue**); the job runs in the user's Cloudflare account on the server's default Cloudflare model. The queue is listed newest first. Clicking a row fetches that job whole and shows its state, model, how many model calls, tool calls and files it used, and its result, or its error when it failed. The `x` on a row cancels a waiting or running job and deletes a finished one. The harness's schedules are listed below the result; they are not edited from the desk.

A checkbox, **run the harness's local jobs on this machine**, is the owner's switch for local jobs (see [cf_harness](../config/cf_harness.md)): off until ticked, kept by the server. A local job's row says `for this machine`. The desk does not queue local jobs; its line queues cloud jobs.

To the right, under the selected job, is the **mesh**: every veil of the account the harness lists (see [cf_harness](../config/cf_harness.md)), with this machine marked. Each row says whether the node is online, what it is (kind, operating system, version), whether it runs work sent to it, whether it has a browser, Agent Garrett or MCP servers, and how many jobs wait for it. Clicking a row that runs work makes it the target of the task line: the button reads **Send**, and the task goes to that machine as a job only it is handed (`harness_send`). Clicking the row again returns the line to the cloud queue. A harness older than version 10 lists no nodes.

A second checkbox, **keep this desk's settings level with my other veils**, is the switch for the shared settings (see [meshsync](meshsync.md)); it is shown when the window is at least 900 wide, is on by default and is saved with the desk's settings.

Under the queue is the list of chats the harness keeps (the web chat's conversations), newest first, 60 at most. Clicking one shows it on the right as a transcript: who spoke, then what they said. The tab keeps the last 12000 characters of a long chat and says so. **Push open chat** copies the conversation open in the Chat tab up to the harness as text (see [cf_harness](../config/cf_harness.md) for what is and is not sent); the desk says when the harness kept a newer copy instead. The chat list is asked every 30 seconds, and at once after a push.

The poller asks the server only while this view is on screen: the view raises `Store.harness_watch` each frame and the poller reads and lowers it, then polls every 10 seconds (`GET /api/v1/harness`, then the jobs and schedules when a harness answered). A selected job is fetched once, and again on each poll while it has not ended. A list that does not answer keeps the rows it showed last. Queueing, cancelling, selecting and the switch ride the poller's command ring (`harness_queue`, `harness_cancel`, `harness_select`, `harness_local`, `harness_chat_select`, `harness_push`).

When there is nothing to show, the view says why: the admin token is missing, the server is offline, the login has no Cloudflare connection, or no harness answered (with the server's reason).

## Key Exports

- `MAX_JOBS`, `MAX_SCHED`, `RESULT_MAX`, `TASK_MAX` — `72` rows held, `12` schedules, `6000` characters of a result kept (a longer one ends in `...`), `3000` bytes of a task the desk queues (it rides a command's text to the poller)
- `Status` / `parseStatus` — `GET /api/v1/harness` reduced: connected, reachable, the address, the reason there is no harness, the version, the default model, calls and queue counts
- `Job` / `parseJobs` — the queue's rows, newest first; a row whose id the server would refuse in a path is dropped
- `Sched` / `parseScheds` / `everyStr` — the schedules and how a repeat reads (`every 5m`, `every 1h`)
- `Detail` / `parseJob` — one job whole: state, model, task, result or error, and counts of model calls, tool calls and files
- `Conv` / `parseConvs`, `Chat` / `parseChat`, `pushBody` — the harness's chat list, one chat as a transcript (its end when it is long), and the body of a push
- `Node` / `parseNodes`, `validNode`, `sendBody` — the mesh's rows (16 at most), the node id rule, and the body of a job sent to one node
- `queueBody` — the body of `POST /api/v1/harness/jobs`; an empty model is left out so the server sends its default
- `validId`, `activeState` — the id rule the server applies, and whether a state is still in the queue

## The local web app

The web app's Tasks page (`web/public/app.js`) has a **Web harness** section on the same routes: the status line, a box that queues a job, the jobs newest first with **Result** and **Cancel**/**Delete**, the schedules, the mesh's nodes (when another node runs work, a menu beside **Queue** sends the job to it instead), a button for the local-jobs switch that asks before turning it on, and the harness's chats: each opens as a transcript, and **Push the open chat** copies the conversation open in the Chat tab up. It reads when the page opens and when **Refresh** is pressed; it does not poll.
