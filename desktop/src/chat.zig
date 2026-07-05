//! chat.zig — the chat worker thread: the third thread beside the UI and the poller, same discipline
//! (owns its own std.Io, talks to the UI only through the Store). It runs the Chat tab's brain:
//!   - model turns: streams /chat/completions through llm.zig, deltas land in Store.stream_text
//!   - swarm casting: a reply whose first line is "CAST: <goal>" fires the EXISTING casting mechanism —
//!     POST /api/v1/swarms via netcli (the same door the Deploy tab uses) — then this thread WATCHES the
//!     run's events.jsonl (scan.tailEvents, filesystem-first) for the right-hand activity pane, and when
//!     the swarm stops it folds the findings back into the conversation and asks the model to answer.
//!   - persistence: conversations are JSONL files under <data>/.veil-desk/chats/, chat settings JSON at
//!     <data>/.veil-desk/settings.json, the API key sealed via secrets.zig. All chat-side io lives here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const netcli = @import("netcli.zig");
const llm = @import("llm.zig");
const secrets = @import("secrets.zig");
const catalog = @import("catalog.zig");
const log = @import("log.zig");
const neurondb = @import("neuron.zig");

const Store = store_mod.Store;

const SYSTEM_PROMPT =
    "You are the Veil, the chat mind of this nl-veil host. You command a hive-mind swarm engine; " ++
    "casting a swarm is your primary reasoning tool for real work.\n" ++
    "To cast, make the FIRST line of your reply exactly:\n" ++
    "CAST: <one-line goal for the hive>\n" ++
    "After that line you may add a short note to the user. Only one cast runs at a time.\n" ++
    "ALWAYS CAST when the user explicitly asks you to — 'cast a swarm', 'run the hive', 'have the hive research/build X', 'spin up a swarm'. An explicit request is a command: emit the CAST line, never answer it from memory instead.\n" ++
    "OTHERWISE, cast whenever real work would help (do NOT answer from memory):\n" ++
    "- ANY question about current events, news, or the state of the world (you have NO live knowledge and " ++
    "would otherwise hallucinate — cast so the hive researches it on the web).\n" ++
    "- Anything time-sensitive or that could have changed since your training, or that asks 'latest', " ++
    "'recent', 'today', 'now', prices, scores, releases, who currently holds a role.\n" ++
    "- Specific facts about a named person, place, product, or org you are not certain of.\n" ++
    "- Multi-step research, building or fixing code or files, verification against a real codebase.\n" ++
    "NEVER fabricate current events, dates, statistics, or news. If you cannot answer from durable, " ++
    "general knowledge with high confidence, CAST instead of guessing.\n" ++
    "DO NOT cast for greetings, small talk, definitions, or timeless facts you know confidently.\n" ++
    "A cast runs for minutes; the user watches its live activity beside this chat. When it finishes you " ++
    "receive its findings in a [cast] message and must then answer the user's request from them.\n" ++
    "\n" ++
    "TOOLS — for a quick, single action (NOT minutes of work), you may run ONE tool. Make the reply exactly " ++
    "one line, nothing else:\n" ++
    "TOOL: <name> <compact-json-args>\n" ++
    "Then STOP. I run it and reply with a [tool:<name>] message containing the result; read that and either " ++
    "run another TOOL or give your final answer. Never put a TOOL line and prose in the same reply.\n" ++
    "Available tools:\n" ++
    "- list_swarms {}  — the swarms currently running (id, name, model, state).\n" ++
    "- stop_swarm {}  — stop the currently running cast (omit id; I target the live one) or {\"id\":\"<id>\"}.\n" ++
    "- swarm_findings {}  — what the current cast has collected so far (its synthesis / recent events); or {\"id\":\"<id>\"}.\n" ++
    "- web_search {\"query\":\"...\"}  — a quick keyless web search (top results + excerpts).\n" ++
    "- web_fetch {\"url\":\"...\"}  — fetch one page as clean text.\n" ++
    "- fetch_json {\"url\":\"...\"}  — GET a JSON API and return the body.\n" ++
    "- recall_hive {\"query\":\"...\"}  — what the shared memory already knows.\n" ++
    "- observe {\"fact\":\"...\"}  — store a durable fact into the shared memory.\n" ++
    "Use a TOOL for a one-shot lookup or to inspect/steer a running cast (e.g. the user says 'kill the swarm " ++
    "and tell me what it found' -> TOOL: stop_swarm {} , then TOOL: swarm_findings {}). Use CAST for open-ended " ++
    "research or building. For a brand-new web question, a single web_search TOOL is often faster than a cast.\n" ++
    "\n" ++
    "BUILD — you have your own persistent build workdir on this machine (the SAME file tools a hive mind uses). " ++
    "When the user asks you to build/create/fix code or files, WRITE them to disk — don't just paste the whole " ++
    "file into the chat. Use the TOOL: protocol (one tool per reply):\n" ++
    "- write_file {\"path\":\"app.py\",\"content\":\"...\"}  — write/overwrite a file (relative path, in your workdir).\n" ++
    "- edit_file {\"path\":\"app.py\",\"ops\":[{\"search\":\"old\",\"replace\":\"new\"}]}  — patch an existing file in place.\n" ++
    "- read_file {\"path\":\"app.py\"}  — read a file back before you change it.\n" ++
    "- list_dir {\"path\":\".\"}  — see what's already in the workdir.\n" ++
    "- run_tests {}  — run the project's tests (pytest / test_*.py) and get pass/fail.\n" ++
    "- run_python {\"code\":\"...\"}  — run a short Python script in the workdir.\n" ++
    "- delete_file {\"path\":\"...\"}  — remove a file you created.\n" ++
    "KNOW YOUR LIMITS: your reply has a length cap, so a large file will get CUT OFF if you write it all at once. " ++
    "For anything big, either write it across MULTIPLE files (module per file), or write the first part with " ++
    "write_file then extend it with edit_file — never send one giant file that truncates. After writing code, " ++
    "run_tests (or run_python) to VERIFY it, read the result, fix, and repeat until it works. It's good to also " ++
    "give the user a short summary in the chat of what you wrote — but the real work goes to the files.\n" ++
    "\n" ++
    "SHELL — when the user asks you to run a command, work in a directory, inspect files, or drive the system, " ++
    "you have a real terminal on their machine. Make the reply exactly one line:\n" ++
    "RUN: <shell command>\n" ++
    "Then STOP. I run it in the Veil console tab and reply with a [console] message containing its output; read " ++
    "that, then either RUN another command or give your final answer. One command per reply, never RUN with prose " ++
    "in the same reply. Only use RUN when the user actually wants system/terminal work — quote paths with spaces, " ++
    "prefer non-destructive commands, and never run something irreversible (deleting data, killing processes) " ++
    "without the user asking for it. For pure web/research questions use web_search or CAST, not RUN.\n" ++
    "\n" ++
    "GROUND YOURSELF — you have NO live knowledge. Before you answer anything about current events, prices, " ++
    "versions, or the SPECIFIC steps of a task you're not sure how to do (e.g. 'how do I host this on Cloudflare', " ++
    "a library's exact API, an ops/deploy procedure), do NOT guess — first run TOOL: recall_hive {\"query\":\"...\"} " ++
    "to check what the shared memory already knows, and if that's thin, TOOL: web_search {\"query\":\"...\"} to look " ++
    "it up. Answer FROM what you find. Guessing a deploy command or an API is worse than taking one tool call to " ++
    "verify it. When you learn something durable and correct, TOOL: observe {\"fact\":\"...\"} it so the hive keeps it.\n" ++
    "\n" ++
    "MORE TOOLS — you share the hive mind's full toolset. Beyond the above you can also call: recall {\"query\"} " ++
    "(your own memory), save_skill / journal / note_stance (record a technique, a note, a stance), set_directive / " ++
    "add_task / complete_task (plan + track your own work), deep_crawl (crawl a site), fetch_json / read_url. On " ++
    "this machine (admin) you additionally have: make_tool (author a new tool), host_command / host_status / " ++
    "host_explore (drive the host), patch_system + propose_change + simulate_change (modify the engine itself), " ++
    "osint_scan, stage_delivery. Same one-line TOOL: <name> <json> protocol. Reach for the simplest tool that does " ++
    "the job; don't use the powerful ones unless the task truly calls for it.\n" ++
    "Otherwise reply normally in plain text.";

const CAST_MINUTES: u32 = 8; // v1 fixed budget; the engine self-crunches to fit
const MAX_TOKENS: u32 = 4096; // was 2048 — code answers (a full Flask app) were truncated mid-file every turn

const Turn = enum { idle, user, collect, tool_follow, reflect, loop_infer };

// Bound the model→tool→model loop so a confused local model can't spin forever on tool calls.
const MAX_TOOL_ITERS: u32 = 5;

// Prompt-loop (full-auto mode): after a turn settles, the AI writes the NEXT user message itself and sends it,
// continuing the conversation toward the goal until it emits DONE or hits the iteration cap. LOOP_MAX_ITERS is
// the verifiable stop condition that prevents an endless/costly loop.
const LOOP_MAX_ITERS: u32 = 12;
const LOOP_SYSTEM =
    "You are the autonomous DRIVER of this conversation. The user has enabled full-auto mode: rather than typing " ++
    "each message themselves, YOU write the next message on their behalf to keep making progress toward the goal " ++
    "of the thread (the goal is set by the first user message and everything since).\n" ++
    "Read the whole conversation, judge what has been accomplished and what is still missing, then output ONLY the " ++
    "next message to send — a single concrete instruction, question, or refinement that advances the goal. Write it " ++
    "as the user would (first person, imperative), with NO preamble, NO quotes, NO explanation — just the message text.\n" ++
    "Do NOT answer it yourself and do NOT include a TOOL:/CAST:/RUN: line — you are composing the user's next prompt, " ++
    "not the assistant's reply. Keep it to one or two sentences.\n" ++
    "If this is a BUILD/code task, do not settle for 'it looks done' — the next step should write/extend the real " ++
    "files and then run_tests (or run_python) to VERIFY; only treat the goal as achieved once it actually works.\n" ++
    "When the goal is fully achieved (the assistant has delivered what was asked, verified where possible, and no " ++
    "further step would add value), output EXACTLY the single word: DONE";

// Recursive-thought (reflect) loop: one extra self-check pass — but ONLY for substantive answers to
// substantive requests, never for chit-chat (a "hello" must not recurse). REFLECT_MIN_ANSWER is the answer
// length below which an answer is considered trivial and skips the pass.
const REFLECT_PASSES: u8 = 1;
const REFLECT_MIN_ANSWER: usize = 500;

// ---- micro-console (dual-tab shell) ---------------------------------------------------------------------
// A shell command MUST NOT run inline on this worker thread: a hang (a dev server, `ping -t`, a REPL) would
// freeze chat turns AND cast-watching until it returned. Instead a command runs as an INDEPENDENT OS process
// writing to temp sink files, and run()'s loop POLLS it every ~100ms tick (pumpConsole) — so even a hard hang
// never wedges the thread. Three guards bound it: a wall-clock deadline (kill + report), a Stop button
// (console_cancel), and an output-flood cap. One command runs at a time.
const CONSOLE_TIMEOUT_AI_S: i64 = 60; // AI RUN: door — a turn must not hang on a command the model chose
const CONSOLE_TIMEOUT_YOU_S: i64 = 300; // You tab — the user may deliberately run something longer
const CONSOLE_MAX_OUTPUT: u64 = 4 << 20; // force-stop a command that floods more than ~4MB into its sink

// Native, no-subprocess exit poll (std.process has no non-blocking wait). Mirrors supervisor.zig's winproc
// pattern: on Windows read the exit code straight off the child HANDLE. Termination itself uses Child.kill
// (native TerminateProcess via the Io vtable — no taskkill child, same spirit as terminateVeilPid).
const winproc = if (builtin.os.tag == .windows) struct {
    const STILL_ACTIVE: u32 = 259;
    extern "kernel32" fn GetExitCodeProcess(h: *anyopaque, code: *u32) callconv(.c) c_int;
} else struct {};

/// Non-blocking: has `child` exited? Windows peeks the exit code off the process handle (the caller still
/// reaps via Child.wait); POSIX reaps with waitpid(WNOHANG) and nulls child.id so the caller must NOT wait.
fn procExited(child: *std.process.Child) bool {
    const id = child.id orelse return true; // already reaped / killed
    if (builtin.os.tag == .windows) {
        var code: u32 = 0;
        if (winproc.GetExitCodeProcess(id, &code) == 0) return true; // handle unusable → treat as done
        return code != winproc.STILL_ACTIVE;
    } else {
        var status: c_int = undefined;
        const r = std.c.waitpid(id, &status, 1); // 1 = WNOHANG
        if (r == 0) return false; // still running
        child.id = null; // reaped here — don't Child.wait again
        return true;
    }
}

/// One in-flight micro-console command, run off the worker's blocking path (see pumpConsole). `ai` selects
/// the tab: Veil (the AI's RUN: door, whose result folds back into the turn) vs You (the user's own shell).
/// stdout and stderr go to SEPARATE sink files ("<base>.out"/".err") because Windows reopens each inherited
/// handle independently — one shared file would let the two streams clobber each other at offset 0.
const ConsoleProc = struct {
    child: std.process.Child,
    ai: bool,
    started_s: i64,
    deadline_s: i64, // wall-clock time to force-kill (the hang guard)
    base: [320]u8 = undefined, // sink path stem; "<base>.out" + "<base>.err" hold stdout/stderr
    base_len: usize = 0,
    cmd: [1024]u8 = undefined, // the command text (for the [console] fold + the timeout message)
    cmd_len: usize = 0,

    fn baseStr(p: *const ConsoleProc) []const u8 {
        return p.base[0..p.base_len];
    }
    fn cmdStr(p: *const ConsoleProc) []const u8 {
        return p.cmd[0..p.cmd_len];
    }
};

pub const Chat = struct {
    io: Io,
    gpa: std.mem.Allocator,
    store: *Store,
    stop: std.atomic.Value(bool) = .init(false),

    stream: llm.Stream = .{},
    turn: Turn = .idle,
    first_byte_logged: bool = false, // one timing line per turn
    turn_start_ms: i64 = 0, // wall-clock (ms) this turn's model call started — for the Metrics tab
    turn_fb_ms: u32 = 0, // ms to the first streamed token this turn (0 until seen)
    parallel_tip: bool = false, // shown the OLLAMA_NUM_PARALLEL tip once
    last_user: [1600]u8 = undefined, // the message that started the current .user turn (for cast recovery)
    last_user_len: usize = 0,
    tool_iters: u32 = 0, // tool calls this user turn (bounded by MAX_TOOL_ITERS)
    loop_iter: u32 = 0, // auto-loop iterations since the last manual message (bounded by LOOP_MAX_ITERS)
    build_dir: [400]u8 = undefined, // absolute build workdir for THIS chat (set from the server's tool response);
    build_dir_len: usize = 0, // the AI writes files here + the console (You/Veil) is cd'd here so both share it
    reflect_draft: [12288]u8 = undefined, // first-pass draft used by the one-step reflect turn
    reflect_draft_len: usize = 0,

    // active cast bookkeeping (one at a time)
    cast_active: bool = false,
    cast_hex: [32]u8 = [_]u8{0} ** 32,
    cast_hex_len: usize = 0,
    cast_rel: [96]u8 = [_]u8{0} ** 96, // resolved run path relative to data dir
    cast_rel_len: usize = 0,
    cast_deadline_s: i64 = 0,
    cast_stop_sent: bool = false,
    ctx_warned: bool = false, // shown the "local model loaded at a huge context (slow)" tip once
    ctx_poll_budget: u8 = 0, // watchCast re-checks the loaded ctx for the first few ticks (catches load-during-cast)

    // HIPPOCAMPUS — the chat's own neuron-db (gpa-owned; "" = disabled → all memory ops no-op)
    mind_bin: []const u8 = "",
    mind_db: []const u8 = "",

    // micro-console: the one in-flight shell command (null = idle), polled from run() so it never blocks
    console: ?ConsoleProc = null,
    console_cancel: bool = false, // Stop button pressed → pumpConsole kills the running command next tick

    // scratch (thread-owned)
    ev_scratch: [store_mod.CAST_TAIL]scan.Ev = undefined,
    sw_scratch: [scan.MAX_SWARMS]scan.SwarmSummary = undefined,
    file_scratch: [scan.MAX_FILES]scan.FileRow = undefined,

    pub fn run(self: *Chat) void {
        var dbuf: [512]u8 = undefined;
        const dd0 = self.dataDir(&dbuf);
        self.ensureDirs(dd0);
        // HIPPOCAMPUS: find the neuron binary + point at a chat-local sqlite so turns + cast findings persist as
        // recallable neurons (neurondb.zig). Silently disabled (memory ops no-op) if the binary isn't found.
        self.mind_bin = neurondb.findBin(self.gpa, self.io);
        {
            var mb: [600]u8 = undefined;
            const p = std.fmt.bufPrint(&mb, "{s}/.veil-desk/chat.sqlite", .{dd0}) catch "";
            if (p.len > 0) self.mind_db = self.gpa.dupe(u8, p) catch "";
        }
        log.info("chat hippocampus: {s}", .{if (self.mind_bin.len > 0) "enabled" else "disabled (neuron binary not found)"});
        self.loadSettings(dd0);
        self.loadKey(dd0);
        self.refreshConvs(dd0, true);
        self.fetchOllamaModels();

        var tick: u32 = 0;
        while (!self.stop.load(.monotonic)) {
            var db: [512]u8 = undefined;
            const dd = self.dataDir(&db);
            self.drainCommands(dd);
            self.pumpStream(dd);
            self.pumpConsole(dd); // poll any in-flight micro-console command (never blocks the loop)
            if (tick % 10 == 0) self.watchCast(dd); // ~1Hz beside the 10Hz stream pump
            if (tick % 50 == 0) self.refreshConvs(dd, false); // ~5s: pick up external changes
            if (tick % 300 == 299) self.fetchOllamaModels();
            tick +%= 1;
            self.io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        llm.abort(&self.stream, self.io);
        self.stream.deinit(self.gpa);
        if (self.console) |*p| p.child.kill(self.io); // don't leave a shell child running past shutdown
        self.console = null;
    }

    // ------------------------------------------------------------------------------ plumbing

    fn dataDir(self: *Chat, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        const d = self.store.settings.dataDir();
        const n = @min(d.len, buf.len);
        @memcpy(buf[0..n], d[0..n]);
        return buf[0..n];
    }

    fn nowS(self: *Chat) i64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
    }

    fn nowMs(self: *Chat) i64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms));
    }

    /// Record one completed turn's performance into the Metrics ring (chars are a ~4x proxy for tokens; the
    /// tok/s is measured over the GENERATION window = total minus first-byte, so queue/prefill latency doesn't
    /// deflate the rate). Called once per turn, at the settle point and the error path.
    fn recordMetric(self: *Chat, kind: Turn, ok: bool, out_chars: usize) void {
        const total_ms: u32 = @intCast(@max(0, self.nowMs() - self.turn_start_ms));
        const gen_ms = if (total_ms > self.turn_fb_ms) total_ms - self.turn_fb_ms else total_ms;
        const toks: f32 = @as(f32, @floatFromInt(out_chars)) / 4.0;
        const tok_s: f32 = if (gen_ms > 0) toks / (@as(f32, @floatFromInt(gen_ms)) / 1000.0) else 0;
        self.store.pushMetric(.{
            .first_byte_ms = self.turn_fb_ms,
            .total_ms = total_ms,
            .out_chars = @intCast(@min(out_chars, std.math.maxInt(u32))),
            .tok_per_s = tok_s,
            .tools = @intCast(@min(self.tool_iters, std.math.maxInt(u16))),
            .kind = @intFromEnum(kind),
            .ok = ok,
        });
    }

    /// The chat's hippocampus client (neuron-db). All ops no-op when the binary/db is unavailable.
    fn mind(self: *Chat) neurondb.Db {
        return .{ .gpa = self.gpa, .io = self.io, .bin = self.mind_bin, .db = self.mind_db };
    }

    /// The neuron-db scope for the ACTIVE conversation (its id) — memory is partitioned per conversation so
    /// recall never bleeds an unrelated chat's facts. Caller must hold no store lock. Empty if no active conv.
    fn convScope(self: *Chat, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        const id = self.store.conv_active[0..self.store.conv_active_len];
        const n = @min(id.len, buf.len);
        @memcpy(buf[0..n], id[0..n]);
        return buf[0..n];
    }

    /// Ask the local Ollama which models are installed (GET /api/tags) and publish their names so the
    /// Settings model dropdown shows the user's REAL models instead of a guessed catalog list. Best-effort:
    /// on any failure the dropdown falls back to the catalog. Uses the configured local base, else the
    /// default; the root is derived by trimming a trailing /v1.
    fn fetchOllamaModels(self: *Chat) void {
        var rootbuf: [200]u8 = undefined;
        var root: []const u8 = "http://127.0.0.1:11434";
        {
            self.store.lock();
            const s = &self.store.settings;
            const base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1";
            self.store.unlock();
            var r = std.mem.trimEnd(u8, base, "/");
            if (std.mem.endsWith(u8, r, "/v1")) r = r[0 .. r.len - 3];
            // only probe a LOCAL ollama (loopback); a remote/BYOK base has no /api/tags for us to list
            if ((std.mem.indexOf(u8, r, "127.0.0.1") != null or std.mem.indexOf(u8, r, "localhost") != null) and std.mem.indexOf(u8, r, "11434") != null) {
                const n = @min(r.len, rootbuf.len);
                @memcpy(rootbuf[0..n], r[0..n]);
                root = rootbuf[0..n];
            }
        }
        const url = std.fmt.allocPrint(self.gpa, "{s}/api/tags", .{root}) catch return;
        defer self.gpa.free(url);
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "curl", "-sS", "--max-time", "5", url },
            .stdout_limit = .limited(256 << 10),
        }) catch return;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return;
        // parse the "name":"..." fields (one per installed model)
        self.store.lock();
        defer self.store.unlock();
        self.store.ollama_model_count = 0;
        var i: usize = 0;
        const needle = "\"name\":\"";
        while (std.mem.indexOfPos(u8, res.stdout, i, needle)) |at| {
            if (self.store.ollama_model_count >= store_mod.MAX_OLLAMA_MODELS) break;
            const from = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, res.stdout, from, '"') orelse break;
            const name = res.stdout[from..end];
            i = end + 1;
            if (name.len == 0 or name.len > 96) continue;
            var m: store_mod.OllamaModel = .{};
            @memcpy(m.name[0..name.len], name);
            m.name_len = @intCast(name.len);
            self.store.ollama_models[self.store.ollama_model_count] = m;
            self.store.ollama_model_count += 1;
        }
        log.info("chat: {d} local ollama models listed", .{self.store.ollama_model_count});
    }

    /// Is the chat model the local Ollama backend (where NUM_PARALLEL contention applies)?
    fn isLocalChat(self: *Chat) bool {
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        if (s.chat_kind == 0) return true; // local (Ollama) provider
        if (s.chat_kind == 2) return std.mem.indexOf(u8, s.chatBase(), "11434") != null; // custom URL at Ollama
        return false;
    }

    /// Largest "context_length": value in an /api/ps body (0 if none/unparseable). Pure — unit-tested.
    fn parseMaxCtx(body: []const u8) u32 {
        var maxc: u32 = 0;
        var i: usize = 0;
        const needle = "\"context_length\":";
        while (std.mem.indexOfPos(u8, body, i, needle)) |at| {
            var j = at + needle.len;
            while (j < body.len and body[j] == ' ') j += 1;
            var v: u64 = 0;
            var any = false;
            while (j < body.len and body[j] >= '0' and body[j] <= '9') : (j += 1) {
                v = v * 10 + (body[j] - '0');
                any = true;
                if (v > std.math.maxInt(u32)) break;
            }
            if (any and v > maxc) maxc = std.math.cast(u32, v) orelse std.math.maxInt(u32);
            i = j;
        }
        return maxc;
    }

    /// Best-effort: the context window the LOCAL Ollama has actually loaded the model with (0 if not local /
    /// nothing loaded / unreachable). Ollama IGNORES the per-request num_ctx and honors only the
    /// OLLAMA_CONTEXT_LENGTH env var; when that is unset, gpt-oss loads at its full 131072 window whose KV
    /// cache eats ~6GB of VRAM, starving the model onto the CPU (~1 tok/s) and making swarm casts crawl. A
    /// value far above what we request (32768) is the tell that the env var is unset — see localSlowTip.
    fn loadedLocalCtx(self: *Chat) u32 {
        if (!self.isLocalChat()) return 0;
        var rootbuf: [200]u8 = undefined;
        var root: []const u8 = "http://127.0.0.1:11434";
        {
            self.store.lock();
            const s = &self.store.settings;
            const base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1";
            self.store.unlock();
            var r = std.mem.trimEnd(u8, base, "/");
            if (std.mem.endsWith(u8, r, "/v1")) r = r[0 .. r.len - 3];
            if ((std.mem.indexOf(u8, r, "127.0.0.1") != null or std.mem.indexOf(u8, r, "localhost") != null) and std.mem.indexOf(u8, r, "11434") != null) {
                const n = @min(r.len, rootbuf.len);
                @memcpy(rootbuf[0..n], r[0..n]);
                root = rootbuf[0..n];
            }
        }
        const url = std.fmt.allocPrint(self.gpa, "{s}/api/ps", .{root}) catch return 0;
        defer self.gpa.free(url);
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "curl", "-sS", "--max-time", "4", url },
            .stdout_limit = .limited(64 << 10),
        }) catch return 0;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return 0;
        return parseMaxCtx(res.stdout);
    }

    /// If a local model is loaded with a runaway context (env var unset), tell the user the one-line fix
    /// ONCE — a slow cast otherwise looks like a broken cast. No-op when correctly configured.
    fn localSlowTip(self: *Chat, dd: []const u8) void {
        if (self.ctx_warned) return;
        const ctx = self.loadedLocalCtx();
        if (ctx <= 40000) return; // 0 (not local / nothing loaded) or a sane window → nothing to warn about
        self.ctx_warned = true;
        self.appendMsg(dd, .cast_note, "[cast] heads-up: your local model is loaded with a very large context window, so most of it is running on the CPU and this swarm will be slow. For ~16x faster local casts, set the Windows environment variable OLLAMA_CONTEXT_LENGTH=8192 and fully restart Ollama.");
        log.info("cast: local model loaded at ctx={d} (>40k) — OLLAMA_CONTEXT_LENGTH likely unset; warned user", .{ctx});
    }

    fn ensureDirs(self: *Chat, dd: []const u8) void {
        var pbuf: [600]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/.veil-desk/chats", .{dd}) catch return;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, p, .default_dir) catch {};
    }

    fn sideDir(dd: []const u8, buf: []u8) []const u8 {
        const p = std.fmt.bufPrint(buf, "{s}/.veil-desk", .{dd}) catch return dd;
        return p;
    }

    fn setStatus(self: *Chat, s: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        const n = @min(s.len, self.store.chat_status.len);
        @memcpy(self.store.chat_status[0..n], s[0..n]);
        self.store.chat_status_len = @intCast(n);
    }

    fn setBusy(self: *Chat, v: bool) void {
        self.store.lock();
        defer self.store.unlock();
        self.store.chat_busy = v;
        if (!v) {
            self.store.stream_len = 0;
            self.store.stream_reason_len = 0;
            self.store.chat_status_len = 0;
        }
    }

    // ------------------------------------------------------------------------------ commands

    fn drainCommands(self: *Chat, dd: []const u8) void {
        while (self.store.popChatCmd()) |c| {
            switch (c.kind) {
                .none => {},
                .send => self.cmdSend(dd, c.textStr()),
                .new_conv => self.cmdNewConv(dd),
                .select_conv => self.cmdSelectConv(dd, c.idStr()),
                .rename_conv => self.cmdRenameConv(dd, c.idStr(), c.textStr()),
                .delete_conv => self.cmdDeleteConv(dd, c.idStr()),
                .stop_cast => self.cmdStopCast(dd, c.idStr()),
                .save_settings => self.saveSettings(dd),
                .save_key => self.cmdSaveKey(dd, c.textStr()),
                .console_run => self.cmdConsoleRun(dd, std.mem.eql(u8, c.idStr(), "veil"), c.textStr()),
                .console_cancel => self.console_cancel = true, // Stop button → pumpConsole kills it next tick
                .loop_kick => self.maybeLoop(dd), // user just enabled auto-loop while idle → start it now
                .stop_turn => self.stopTurn(dd), // Stop button by the input: abort the in-flight turn + halt auto-loop
            }
        }
    }

    fn setConsoleBusy(self: *Chat, ai: bool, v: bool) void {
        self.store.lock();
        defer self.store.unlock();
        if (ai) self.store.console_busy_ai = v else self.store.console_busy_you = v;
    }

    /// Is the AI's RUN: door mid-command? While it awaits pumpConsole the model turn is logically in flight
    /// (busy is true, turn is idle) — new turns/loops must not start over it.
    fn consoleAiBusy(self: *Chat) bool {
        return if (self.console) |*p| p.ai else false;
    }

    /// A user-typed / AI-issued micro-console command (the "You"/"Veil" tab). Launches it asynchronously via
    /// consoleStart; pumpConsole reports the result (and, for the Veil tab, folds it back into the turn).
    fn cmdConsoleRun(self: *Chat, dd: []const u8, ai: bool, cmd: []const u8) void {
        self.consoleStart(dd, ai, cmd);
    }

    /// Point THIS chat's build workdir (and thus the console) at `rel` (server data-relative, e.g.
    /// "u1/_chat/builds/c6a4"). Called from a build tool's response so the console (You + Veil) `cd`s into the
    /// same folder the AI is writing files to. Only announces + creates when the directory actually changes.
    fn setBuildDir(self: *Chat, dd: []const u8, rel: []const u8) void {
        var ab: [400]u8 = undefined;
        const abs = std.fmt.bufPrint(&ab, "{s}/{s}", .{ dd, rel }) catch return;
        if (std.mem.eql(u8, abs, self.build_dir[0..self.build_dir_len])) return; // unchanged — no re-announce
        const n = @min(abs.len, self.build_dir.len);
        @memcpy(self.build_dir[0..n], abs[0..n]);
        self.build_dir_len = n;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, abs, .default_dir) catch {}; // ensure it exists locally too
        var nb: [480]u8 = undefined;
        const note = std.fmt.bufPrint(&nb, "[build] working directory: {s} — the console (You + Veil tabs) is cd'd here, so you can inspect and run the files.", .{rel}) catch "[build] working directory set";
        self.appendMsg(dd, .cast_note, note);
    }

    /// Launch a micro-console command as an INDEPENDENT OS process and register it as the in-flight console
    /// proc; pumpConsole polls it to completion. Returns immediately — the command NEVER runs on this worker's
    /// blocking path, so a hang can't freeze chat or cast-watching. stdout/stderr are captured to two temp
    /// sink files (see ConsoleProc). At most one command runs at a time; a second is refused (and, on the AI
    /// door, the refusal folds straight back so the turn still continues).
    fn consoleStart(self: *Chat, dd: []const u8, ai: bool, cmd: []const u8) void {
        const trimmed = std.mem.trim(u8, cmd, " \r\n\t");
        if (trimmed.len == 0) {
            if (ai) self.foldConsoleAi(dd, "", "(empty command)");
            return;
        }
        if (self.console != null) {
            self.store.consoleAppend(ai, "\n(the console is busy with another command)\n");
            if (ai) self.foldConsoleAi(dd, trimmed, "(the console was busy; command not run)");
            return;
        }
        self.store.consoleAppend(ai, "\n> ");
        self.store.consoleAppend(ai, trimmed);
        self.store.consoleAppend(ai, "\n");

        // Sink files: <dd>/.veil-desk/console_{ai|you}.{out,err}. createFile truncates, so a prior run's bytes
        // never bleed in. Two files (not one) because Windows reopens each inherited handle independently, so a
        // shared sink would let stdout and stderr clobber each other at offset 0.
        var bb: [320]u8 = undefined;
        const base = std.fmt.bufPrint(&bb, "{s}/.veil-desk/console_{s}", .{ dd, if (ai) "ai" else "you" }) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
            return;
        };
        var ob: [332]u8 = undefined;
        var eb: [332]u8 = undefined;
        const outp = std.fmt.bufPrint(&ob, "{s}.out", .{base}) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
            return;
        };
        const errp = std.fmt.bufPrint(&eb, "{s}.err", .{base}) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
            return;
        };
        const of = Io.Dir.cwd().createFile(self.io, outp, .{}) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to open the console output file)");
            return;
        };
        const ef = Io.Dir.cwd().createFile(self.io, errp, .{}) catch {
            of.close(self.io);
            self.consoleLaunchFailed(dd, ai, "(failed to open the console output file)");
            return;
        };
        // Run in the chat's build workdir if one has been set (so `dir`/`ls`/`python app.py` see the AI's files);
        // the console is stateless (a fresh shell per command), so we prepend `cd` rather than hold a cwd. The
        // scrollback shows the user's ORIGINAL command (trimmed) — only the launched command carries the cd.
        var ecb: [1600]u8 = undefined;
        const run_cmd: []const u8 = if (self.build_dir_len > 0) blk: {
            if (builtin.os.tag == .windows) {
                // cmd's `cd /d` chokes on forward slashes ("The system cannot find the path specified") — the
                // build dir arrives as {data}/u1/_chat/builds/... (mixed/forward slashes). Normalize to '\\'.
                var bdw: [400]u8 = undefined;
                const bd = self.build_dir[0..@min(self.build_dir_len, bdw.len)];
                for (bd, 0..) |c, k| bdw[k] = if (c == '/') '\\' else c;
                break :blk std.fmt.bufPrint(&ecb, "cd /d \"{s}\" && {s}", .{ bdw[0..bd.len], trimmed }) catch trimmed;
            }
            break :blk std.fmt.bufPrint(&ecb, "cd \"{s}\" && {s}", .{ self.build_dir[0..self.build_dir_len], trimmed }) catch trimmed;
        } else trimmed;
        // Windows: run through cmd /c so the user gets the shell they expect (dir, echo, git, python, …).
        const argv = if (builtin.os.tag == .windows)
            [_][]const u8{ "cmd", "/c", run_cmd }
        else
            [_][]const u8{ "sh", "-c", run_cmd };
        const child = std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .{ .file = of },
            .stderr = .{ .file = ef },
            .create_no_window = true, // don't flash a console window per command on Windows
        }) catch {
            of.close(self.io);
            ef.close(self.io);
            self.consoleLaunchFailed(dd, ai, "(failed to launch the command)");
            return;
        };
        // The child inherited its own copies; drop ours so the sinks have a single writer we can read cleanly
        // once the process is dead.
        of.close(self.io);
        ef.close(self.io);

        const now = self.nowS();
        var p: ConsoleProc = .{
            .child = child,
            .ai = ai,
            .started_s = now,
            .deadline_s = now + (if (ai) CONSOLE_TIMEOUT_AI_S else CONSOLE_TIMEOUT_YOU_S),
        };
        const cn = @min(trimmed.len, p.cmd.len);
        @memcpy(p.cmd[0..cn], trimmed[0..cn]);
        p.cmd_len = cn;
        const bn = @min(base.len, p.base.len);
        @memcpy(p.base[0..bn], base[0..bn]);
        p.base_len = bn;
        self.console = p;
        self.console_cancel = false;
        self.setConsoleBusy(ai, true);
        log.info("console: {s} launched: {s}", .{ if (ai) "veil" else "you", trimmed[0..@min(trimmed.len, 120)] });
    }

    /// Report a launch failure into the scrollback and — on the AI door — fold it back so the turn continues
    /// (no console proc was registered, so nothing else will finalize it).
    fn consoleLaunchFailed(self: *Chat, dd: []const u8, ai: bool, msg: []const u8) void {
        self.store.consoleAppend(ai, msg);
        self.store.consoleAppend(ai, "\n");
        if (ai) self.foldConsoleAi(dd, "", msg);
    }

    /// Fold a finished console command's output back into the conversation as a [console] message and re-enter
    /// a .tool_follow turn so the model reads the result and continues (the AI RUN: door only).
    fn foldConsoleAi(self: *Chat, dd: []const u8, cmd: []const u8, result: []const u8) void {
        var fb: [7168]u8 = undefined;
        const folded = std.fmt.bufPrint(&fb, "[console]\n$ {s}\n{s}", .{ cmd, result }) catch result;
        self.appendMsg(dd, .cast_note, folded);
        self.startTurn(dd, .tool_follow);
    }

    /// Poll the in-flight micro-console command each tick WITHOUT blocking. While it runs, do nothing; once it
    /// finishes (natural exit) or must be stopped (deadline, Stop button, or output flood), read its captured
    /// output, append it + a status note to the scrollback, and — for the AI door — fold the result back and
    /// continue the turn. No-op when nothing is running.
    fn pumpConsole(self: *Chat, dd: []const u8) void {
        const p = if (self.console) |*pp| pp else return;
        const now = self.nowS();

        const Outcome = enum { running, exited, timed_out, canceled, flooded };
        var outcome: Outcome = .running;
        if (procExited(&p.child)) {
            outcome = .exited;
        } else if (self.console_cancel) {
            outcome = .canceled;
        } else if (now >= p.deadline_s) {
            outcome = .timed_out;
        } else if (self.consoleSinkBytes(p) > CONSOLE_MAX_OUTPUT) {
            outcome = .flooded;
        }
        if (outcome == .running) return; // still going — poll again next tick

        // Reap the child (natural exit) or force-kill it. Child.kill is native TerminateProcess via the Io
        // vtable (no taskkill child, mirroring terminateVeilPid) and also reaps + closes the handle. On a
        // natural exit, Windows peeked the code without reaping (id still set → reap now); POSIX's waitpid
        // already reaped and nulled id, so wait would trip the id!=null assert — the null guard skips it there.
        if (outcome == .exited) {
            if (p.child.id != null) {
                if (p.child.wait(self.io)) |_| {} else |_| {}
            }
        } else {
            p.child.kill(self.io);
        }

        const ai = p.ai;
        const timeout_s = if (ai) CONSOLE_TIMEOUT_AI_S else CONSOLE_TIMEOUT_YOU_S;

        // Read the captured output (stdout then stderr), bounded — one heap scratch split between the sinks.
        var ob: [332]u8 = undefined;
        var eb: [332]u8 = undefined;
        const outp = std.fmt.bufPrint(&ob, "{s}.out", .{p.baseStr()}) catch "";
        const errp = std.fmt.bufPrint(&eb, "{s}.err", .{p.baseStr()}) catch "";
        const scratch: ?[]u8 = self.gpa.alloc(u8, 48 << 10) catch null;
        defer if (scratch) |s| self.gpa.free(s);
        const out_slice = if (scratch) |s| self.readSink(outp, s[0 .. 40 << 10]) else "";
        const err_slice = if (scratch) |s| self.readSink(errp, s[40 << 10 ..]) else "";
        Io.Dir.cwd().deleteFile(self.io, outp) catch {}; // data is in scratch now — clean up the sinks
        Io.Dir.cwd().deleteFile(self.io, errp) catch {};

        // Status note for the non-clean exits — the required "(command timed out after Ns)" lives here.
        var nb: [64]u8 = undefined;
        const note: []const u8 = switch (outcome) {
            .running, .exited => "",
            .timed_out => std.fmt.bufPrint(&nb, "(command timed out after {d}s)\n", .{timeout_s}) catch "(command timed out)\n",
            .canceled => "(command stopped)\n",
            .flooded => "(command produced too much output — stopped)\n",
        };

        // Scrollback: stdout, then stderr, then the note (matches the old separate-stream append order).
        if (out_slice.len > 0) self.store.consoleAppend(ai, out_slice);
        if (err_slice.len > 0) self.store.consoleAppend(ai, err_slice);
        if (out_slice.len == 0 and err_slice.len == 0) self.store.consoleAppend(ai, "(no output)\n");
        if (note.len > 0) self.store.consoleAppend(ai, note);
        self.setConsoleBusy(ai, false);
        log.info("console: {s} finished ({t}) — {d}b out, {d}b err", .{ if (ai) "veil" else "you", outcome, out_slice.len, err_slice.len });

        // The AI door hands the result back to the model. Copy what's needed off `p` BEFORE clearing the slot,
        // then clear it so foldConsoleAi (which re-enters a turn) sees a clean idle console state.
        if (ai) {
            var cmdb: [1024]u8 = undefined;
            const cl = @min(p.cmd_len, cmdb.len);
            @memcpy(cmdb[0..cl], p.cmd[0..cl]);
            var rb: [6144]u8 = undefined;
            const result = composeConsoleResult(&rb, out_slice, err_slice, note);
            self.console = null;
            self.console_cancel = false;
            self.foldConsoleAi(dd, cmdb[0..cl], result);
        } else {
            self.console = null;
            self.console_cancel = false;
        }
    }

    /// Read up to buf.len bytes from the TAIL of a console sink file (the newest output — most useful for a
    /// killed/timed-out command). Empty on any error / missing file.
    fn readSink(self: *Chat, path: []const u8, buf: []u8) []const u8 {
        if (path.len == 0) return buf[0..0];
        const f = Io.Dir.cwd().openFile(self.io, path, .{}) catch return buf[0..0];
        defer f.close(self.io);
        const size = (f.stat(self.io) catch return buf[0..0]).size;
        const off: u64 = if (size > buf.len) size - buf.len else 0;
        const n = f.readPositionalAll(self.io, buf, off) catch return buf[0..0];
        return buf[0..n];
    }

    /// Combined byte size of a command's two sink files (the output-flood guard). 0 on any stat error.
    fn consoleSinkBytes(self: *Chat, p: *const ConsoleProc) u64 {
        var ob: [332]u8 = undefined;
        var eb: [332]u8 = undefined;
        const outp = std.fmt.bufPrint(&ob, "{s}.out", .{p.baseStr()}) catch return 0;
        const errp = std.fmt.bufPrint(&eb, "{s}.err", .{p.baseStr()}) catch return 0;
        var total: u64 = 0;
        if (Io.Dir.cwd().statFile(self.io, outp, .{})) |st| {
            total += st.size;
        } else |_| {}
        if (Io.Dir.cwd().statFile(self.io, errp, .{})) |st| {
            total += st.size;
        } else |_| {}
        return total;
    }

    pub fn cmdSend(self: *Chat, dd: []const u8, text: []const u8) void {
        if (text.len == 0 or self.turn != .idle or self.consoleAiBusy()) return; // AI RUN: still in flight
        // a conversation's FIRST message names it — whether the user typed straight away (auto-create)
        // or clicked + first (the "new chat" placeholder title gets replaced here).
        var have_conv = false;
        var fresh = false;
        {
            self.store.lock();
            have_conv = self.store.conv_active_len > 0;
            fresh = self.store.msg_count == 0;
            self.store.unlock();
        }
        if (!have_conv) {
            self.cmdNewConv(dd);
            fresh = true;
        }
        if (fresh) {
            var tb: [42]u8 = undefined;
            const n = @min(text.len, tb.len);
            @memcpy(tb[0..n], text[0..n]);
            for (tb[0..n]) |*c| {
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
            self.renameActive(dd, tb[0..n]);
        }
        // remember the request so an explicit cast still fires if the model flakes (gpt-oss sometimes
        // puts its whole reply in the hidden reasoning channel and emits no CAST line in the content).
        self.last_user_len = @min(text.len, self.last_user.len);
        @memcpy(self.last_user[0..self.last_user_len], text[0..self.last_user_len]);
        self.tool_iters = 0; // fresh tool budget for this user turn
        self.loop_iter = 0; // a manual message resets the auto-loop budget (this is the new goal/steer)
        self.appendMsg(dd, .user, text);
        self.startTurn(dd, .user);
    }

    pub fn cmdNewConv(self: *Chat, dd: []const u8) void {
        var idb: [32]u8 = undefined;
        const now = self.nowS();
        const id = std.fmt.bufPrint(&idb, "c{x}", .{@as(u64, @intCast(now))}) catch return;
        // collision (two in one second) → suffix
        var pb: [700]u8 = undefined;
        var path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch return;
        if (Io.Dir.cwd().statFile(self.io, path, .{})) |_| {
            const id2 = std.fmt.bufPrint(&idb, "c{x}b", .{@as(u64, @intCast(now))}) catch return;
            path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id2 }) catch return;
        } else |_| {}
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "{\"title\":\"new chat\"}\n" }) catch {
            log.err("chat: cannot create conversation file", .{});
            return;
        };
        const stem = std.fs.path.stem(std.fs.path.basename(path));
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(stem.len, self.store.conv_active.len);
            @memcpy(self.store.conv_active[0..n], stem[0..n]);
            self.store.conv_active_len = @intCast(n);
            self.store.msg_count = 0;
        }
        self.refreshConvs(dd, true);
    }

    fn cmdSelectConv(self: *Chat, dd: []const u8, id: []const u8) void {
        if (id.len == 0 or self.turn != .idle) return;
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(id.len, self.store.conv_active.len);
            @memcpy(self.store.conv_active[0..n], id[0..n]);
            self.store.conv_active_len = @intCast(n);
            self.store.msg_count = 0;
        }
        self.loadMsgs(dd, id);
    }

    fn cmdRenameConv(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        if (id.len == 0 or title.len == 0) return;
        self.rewriteTitle(dd, id, title);
        self.refreshConvs(dd, true);
    }

    fn renameActive(self: *Chat, dd: []const u8, title: []const u8) void {
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            self.store.unlock();
        }
        if (idn > 0) self.cmdRenameConv(dd, idb[0..idn], title);
    }

    fn cmdDeleteConv(self: *Chat, dd: []const u8, id: []const u8) void {
        if (id.len == 0) return;
        // Refuse to delete the conversation whose turn is streaming: cmdSend/cmdSelectConv already guard
        // on turn==idle, but without this guard deleting the ACTIVE chat mid-turn clears conv_active, the
        // fallback select silently no-ops (its own guard), and the in-flight reply lands with no active
        // conversation — appendMsg writes it to a stranded Store slot and never persists it (lost). A
        // background conversation is always safe to delete.
        if (self.turn != .idle) {
            var active = false;
            {
                self.store.lock();
                active = std.mem.eql(u8, self.store.conv_active[0..self.store.conv_active_len], id);
                self.store.unlock();
            }
            if (active) {
                self.store.pushNotif("Busy", "let the reply finish before deleting this chat", 2);
                return;
            }
        }
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch return;
        Io.Dir.cwd().deleteFile(self.io, path) catch {};
        var was_active = false;
        {
            self.store.lock();
            defer self.store.unlock();
            was_active = std.mem.eql(u8, self.store.conv_active[0..self.store.conv_active_len], id);
            if (was_active) {
                self.store.conv_active_len = 0;
                self.store.msg_count = 0;
            }
        }
        self.refreshConvs(dd, true);
        if (was_active) {
            // fall back to the newest remaining conversation
            var nid: [32]u8 = undefined;
            var nn: usize = 0;
            {
                self.store.lock();
                defer self.store.unlock();
                if (self.store.conv_count > 0) {
                    nn = self.store.convs[0].id_len;
                    @memcpy(nid[0..nn], self.store.convs[0].id[0..nn]);
                }
            }
            if (nn > 0) self.cmdSelectConv(dd, nid[0..nn]);
        }
    }

    pub fn cmdStopCast(self: *Chat, dd: []const u8, rel: []const u8) void {
        if (rel.len == 0) return;
        _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}");
        self.store.pushNotif("Stop sent", rel, 2);
        self.cast_stop_sent = true;
    }

    fn cmdSaveKey(self: *Chat, dd: []const u8, key: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        const ok = secrets.save(self.io, self.gpa, side, key);
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(key.len, self.store.settings.chat_key.len);
            @memcpy(self.store.settings.chat_key[0..n], key[0..n]);
            self.store.settings.chat_key_len = @intCast(n);
        }
        if (ok) self.store.pushNotif("Key saved", "stored in the OS-protected local store", 1) else self.store.pushNotif("Key NOT saved", "could not write the secure store", 2);
    }

    // ------------------------------------------------------------------------------ settings persistence

    fn saveSettings(self: *Chat, dd: []const u8) void {
        var kind: u8 = 0;
        var byok: u8 = 0;
        var base: [192]u8 = undefined;
        var base_n: usize = 0;
        var model: [96]u8 = undefined;
        var model_n: usize = 0;
        var theme: u8 = 0;
        var lopen = true;
        var ropen = true;
        var cfa: [64]u8 = undefined;
        var cfa_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            const s = &self.store.settings;
            kind = s.chat_kind;
            byok = s.chat_byok;
            theme = s.theme;
            base_n = s.chat_base_len;
            @memcpy(base[0..base_n], s.chat_base[0..base_n]);
            model_n = s.chat_model_len;
            @memcpy(model[0..model_n], s.chat_model[0..model_n]);
            cfa_n = s.cf_account_len;
            @memcpy(cfa[0..cfa_n], s.cf_account[0..cfa_n]);
            lopen = s.chat_left_open;
            ropen = s.chat_right_open;
        }
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"kind\":") catch return;
        jb.print(self.gpa, "{d},\"byok\":{d},\"theme\":{d},\"base\":\"", .{ kind, byok, theme }) catch return;
        escJson(&jb, self.gpa, base[0..base_n]);
        jb.appendSlice(self.gpa, "\",\"model\":\"") catch return;
        escJson(&jb, self.gpa, model[0..model_n]);
        jb.appendSlice(self.gpa, "\",\"cf_account\":\"") catch return;
        escJson(&jb, self.gpa, cfa[0..cfa_n]);
        jb.print(self.gpa, "\",\"left\":{},\"right\":{}}}", .{ lopen, ropen }) catch return;
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist settings", .{});
        };
    }

    fn loadSettings(self: *Chat, dd: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(8 << 10)) catch return;
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        if (jInt(data, "kind")) |v| s.chat_kind = @intCast(@max(0, @min(v, 2)));
        if (jInt(data, "byok")) |v| s.chat_byok = @intCast(@max(0, @min(v, @as(i64, @intCast(catalog.providers.len - 1)))));
        if (jInt(data, "theme")) |v| s.theme = @intCast(@max(0, @min(v, 1)));
        if (llm.jsonUnescape(self.gpa, data, "base")) |b| {
            defer self.gpa.free(b);
            const n = @min(b.len, s.chat_base.len);
            @memcpy(s.chat_base[0..n], b[0..n]);
            s.chat_base_len = @intCast(n);
        }
        if (llm.jsonUnescape(self.gpa, data, "model")) |m| {
            defer self.gpa.free(m);
            const n = @min(m.len, s.chat_model.len);
            @memcpy(s.chat_model[0..n], m[0..n]);
            s.chat_model_len = @intCast(n);
        }
        if (llm.jsonUnescape(self.gpa, data, "cf_account")) |a| {
            defer self.gpa.free(a);
            const n = @min(a.len, s.cf_account.len);
            @memcpy(s.cf_account[0..n], a[0..n]);
            s.cf_account_len = @intCast(n);
        }
        s.chat_left_open = std.mem.indexOf(u8, data, "\"left\":false") == null;
        s.chat_right_open = std.mem.indexOf(u8, data, "\"right\":false") == null;
    }

    fn loadKey(self: *Chat, dd: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        var kb: [192]u8 = undefined;
        const n = secrets.load(self.io, self.gpa, side, &kb);
        if (n == 0) return;
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.settings.chat_key[0..n], kb[0..n]);
        self.store.settings.chat_key_len = @intCast(n);
    }

    // ------------------------------------------------------------------------------ conversations on disk

    fn refreshConvs(self: *Chat, dd: []const u8, force: bool) void {
        _ = force;
        var rows: [store_mod.MAX_CONVS]store_mod.ConvRow = undefined;
        var n: usize = 0;
        var pb: [700]u8 = undefined;
        const cdir = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats", .{dd}) catch return;
        var dir = Io.Dir.cwd().openDir(self.io, cdir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (n < rows.len) {
            const e = (it.next(self.io) catch break) orelse break;
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".jsonl")) continue;
            const stem = e.name[0 .. e.name.len - 6];
            var row: store_mod.ConvRow = .{};
            const idn = @min(stem.len, row.id.len);
            @memcpy(row.id[0..idn], stem[0..idn]);
            row.id_len = @intCast(idn);
            var fpb: [760]u8 = undefined;
            const fp = std.fmt.bufPrint(&fpb, "{s}/{s}", .{ cdir, e.name }) catch continue;
            if (Io.Dir.cwd().statFile(self.io, fp, .{})) |st| {
                row.mtime_s = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            } else |_| {}
            // title = first line's {"title":"..."}
            if (Io.Dir.cwd().readFileAlloc(self.io, fp, self.gpa, .limited(4 << 10)) catch null) |head| {
                defer self.gpa.free(head);
                const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
                if (llm.jsonUnescape(self.gpa, head[0..nl], "title")) |t| {
                    defer self.gpa.free(t);
                    const tn = @min(t.len, row.title.len);
                    @memcpy(row.title[0..tn], t[0..tn]);
                    row.title_len = @intCast(tn);
                }
            }
            rows[n] = row;
            n += 1;
        }
        std.mem.sort(store_mod.ConvRow, rows[0..n], {}, struct {
            fn lt(_: void, a: store_mod.ConvRow, b: store_mod.ConvRow) bool {
                return a.mtime_s > b.mtime_s;
            }
        }.lt);
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.convs[0..n], rows[0..n]);
        self.store.conv_count = n;
    }

    fn convPath(dd: []const u8, id: []const u8, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch null;
    }

    fn loadMsgs(self: *Chat, dd: []const u8, id: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        self.store.msg_count = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        _ = it.next(); // title line
        while (it.next()) |line| {
            if (line.len < 4 or self.store.msg_count >= store_mod.MAX_CHAT_MSGS) continue;
            const r = jInt(line, "r") orelse continue;
            const t = llm.jsonUnescape(self.gpa, line, "t") orelse continue;
            defer self.gpa.free(t);
            var m: store_mod.ChatMsg = .{ .role = switch (r) {
                1 => .veil,
                2 => .cast_note,
                else => .user,
            } };
            const tn = @min(t.len, m.text.len);
            @memcpy(m.text[0..tn], t[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
        }
    }

    fn rewriteTitle(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
        defer self.gpa.free(data);
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return;
        escJson(&jb, self.gpa, title);
        jb.appendSlice(self.gpa, "\"}") catch return;
        if (nl < data.len) jb.appendSlice(self.gpa, data[nl..]) catch return else jb.append(self.gpa, '\n') catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {};
    }

    /// Append to the ACTIVE conversation: into the Store (render copy, oldest evicted at cap) and rewrite
    /// its file (title + the retained messages — the file mirrors what the app can re-show).
    pub fn appendMsg(self: *Chat, dd: []const u8, role: store_mod.ChatRole, text: []const u8) void {
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        var titleb: [64]u8 = undefined;
        var title_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            if (self.store.msg_count >= store_mod.MAX_CHAT_MSGS) {
                std.mem.copyForwards(store_mod.ChatMsg, self.store.msgs[0 .. store_mod.MAX_CHAT_MSGS - 1], self.store.msgs[1..store_mod.MAX_CHAT_MSGS]);
                self.store.msg_count = store_mod.MAX_CHAT_MSGS - 1;
            }
            var m: store_mod.ChatMsg = .{ .role = role };
            const tn = @min(text.len, m.text.len);
            @memcpy(m.text[0..tn], text[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
            // keep the sidebar title in sync (it lives in convs; find it)
            var i: usize = 0;
            while (i < self.store.conv_count) : (i += 1) {
                if (std.mem.eql(u8, self.store.convs[i].idStr(), idb[0..idn])) {
                    title_n = self.store.convs[i].title_len;
                    @memcpy(titleb[0..title_n], self.store.convs[i].title[0..title_n]);
                    break;
                }
            }
        }
        if (idn == 0) return;
        // HIPPOCAMPUS: persist this turn as a neuron under the conversation's scope so it survives the 64-message
        // ring eviction and can be relevance-recalled into future prompts (esp. a cast's synthesis digest, which
        // otherwise ages out as one [cast] message). No-op when neuron-db is disabled.
        self.mind().observe(idb[0..idn], text);
        // rewrite the file from the Store copy
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return;
        escJson(&jb, self.gpa, if (title_n > 0) titleb[0..title_n] else "chat");
        jb.appendSlice(self.gpa, "\"}\n") catch return;
        {
            self.store.lock();
            defer self.store.unlock();
            var i: usize = 0;
            while (i < self.store.msg_count) : (i += 1) {
                const m = &self.store.msgs[i];
                jb.print(self.gpa, "{{\"r\":{d},\"t\":\"", .{@intFromEnum(m.role)}) catch return;
                escJson(&jb, self.gpa, m.textStr());
                jb.appendSlice(self.gpa, "\"}\n") catch return;
            }
        }
        var pb: [700]u8 = undefined;
        const path = convPath(dd, idb[0..idn], &pb) orelse return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist conversation", .{});
        };
    }

    // ------------------------------------------------------------------------------ the model turn

    fn resolveProvider(self: *Chat, base_buf: *[256]u8, key_buf: *[192]u8, model_buf: *[96]u8) llm.Provider {
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        var base: []const u8 = undefined;
        var key: []const u8 = "";
        var acct_scratch: [256]u8 = undefined;
        switch (s.chat_kind) {
            1 => {
                // resolveBase substitutes the Cloudflare {account} placeholder (no-op for every other provider)
                base = catalog.resolveBase(&catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)], s.cfAccount(), &acct_scratch);
                key = s.chatKey();
            },
            2 => {
                base = s.chatBase();
                key = s.chatKey();
            },
            else => base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1",
        }
        const bn = @min(base.len, base_buf.len);
        @memcpy(base_buf[0..bn], base[0..bn]);
        const kn = @min(key.len, key_buf.len);
        @memcpy(key_buf[0..kn], key[0..kn]);
        var model: []const u8 = s.chatModel();
        if (model.len == 0) model = if (s.chat_kind == 1) catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)].models[0].id else "gpt-oss:20b";
        const mn = @min(model.len, model_buf.len);
        @memcpy(model_buf[0..mn], model[0..mn]);
        return .{ .base_url = base_buf[0..bn], .key = key_buf[0..kn], .model = model_buf[0..mn] };
    }

    /// "Sunday 2026-07-05 14:03 UTC" — the model gets a real clock every turn (it has no other one).
    fn dateLine(self: *Chat, buf: []u8) []const u8 {
        const now = self.nowS();
        if (now <= 0) return "";
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
        const ed = es.getEpochDay();
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" }; // epoch day 0 = Thu 1970-01-01
        const wd = weekdays[@intCast(@mod(ed.day, 7))];
        return std.fmt.bufPrint(buf, "\nCurrent date and time: {s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC.", .{ wd, yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
    }

    fn startTurn(self: *Chat, dd: []const u8, kind: Turn) void {
        var msgs: std.ArrayListUnmanaged(u8) = .empty;
        defer msgs.deinit(self.gpa);
        var dbuf: [96]u8 = undefined;
        msgs.appendSlice(self.gpa, "{\"role\":\"system\",\"content\":\"") catch return;
        // A loop-infer turn wears the DRIVER hat (write the user's next message); every other turn is the assistant.
        escJson(&msgs, self.gpa, if (kind == .loop_infer) LOOP_SYSTEM else SYSTEM_PROMPT);
        escJson(&msgs, self.gpa, self.dateLine(&dbuf));
        msgs.appendSlice(self.gpa, "\"}") catch return;
        // HIPPOCAMPUS: draw the facts most relevant to THIS query in from the chat's own neuron-db — earlier
        // turns and cast findings, including ones evicted from the 24KB visible history — and inject them as a
        // grounded-context message. Additive + guarded: if recall is empty/disabled, the prompt is byte-identical
        // to the token-tail-only version, so this can only help, never break the turn.
        if (self.mind().enabled() and self.last_user_len > 0) {
            var scope_buf: [40]u8 = undefined;
            const scope = self.convScope(&scope_buf);
            if (scope.len > 0) {
                var rbuf: [4096]u8 = undefined;
                const mem = self.mind().recall(scope, self.last_user[0..self.last_user_len], &rbuf);
                if (mem.len > 0) {
                    msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"RELEVANT MEMORY (recalled from this conversation's neuron-db — earlier turns + cast findings, some beyond the visible history). Treat as grounded context:\\n") catch return;
                    escJson(&msgs, self.gpa, mem);
                    msgs.appendSlice(self.gpa, "\"}") catch return;
                    log.info("chat hippocampus: injected {d}b of recalled memory", .{mem.len});
                }
            }
        }
        {
            self.store.lock();
            defer self.store.unlock();
            // include from the tail while the budget lasts (the newest matter most)
            var budget: usize = 24 * 1024;
            var first: usize = 0;
            var i: usize = self.store.msg_count;
            while (i > 0) {
                i -= 1;
                const l = self.store.msgs[i].text_len;
                if (budget < l) {
                    first = i + 1;
                    break;
                }
                budget -= l;
            }
            var k = first;
            while (k < self.store.msg_count) : (k += 1) {
                const m = &self.store.msgs[k];
                const role = switch (m.role) {
                    .veil => "assistant",
                    else => "user",
                };
                msgs.print(self.gpa, ",{{\"role\":\"{s}\",\"content\":\"", .{role}) catch return;
                escJson(&msgs, self.gpa, m.textStr());
                msgs.appendSlice(self.gpa, "\"}") catch return;
            }
        }
        if (kind == .reflect and self.reflect_draft_len > 0) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"assistant\",\"content\":\"") catch return;
            escJson(&msgs, self.gpa, self.reflect_draft[0..self.reflect_draft_len]);
            msgs.appendSlice(self.gpa, "\"}") catch return;
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"Quick self-check pass: revise the draft for correctness and completeness. Keep the same intent, fix mistakes, and return only the final answer text. Do not emit TOOL: or CAST:.\"}") catch return;
        }
        if (kind == .collect) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"The cast has finished. Using the [cast] findings above, give the user a direct, complete answer to their original request. Do not cast again.\"}") catch return;
        }
        if (kind == .loop_infer) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"Output the next message to send now (or exactly DONE if the goal is already complete). Reply with only that message text.\"}") catch return;
        }
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        if (!llm.start(&self.stream, self.io, self.gpa, side, prov, msgs.items, MAX_TOKENS, self.nowS())) {
            self.store.pushNotif("Chat failed", "could not start the model call (is curl available?)", 2);
            // A .tool_follow, .reflect (or .collect) re-entry gets here with busy already true — clear it or the chat
            // wedges "busy" forever. turn is already .idle (set by the caller before re-entry).
            self.setBusy(false);
            return;
        }
        self.turn = kind;
        self.first_byte_logged = false;
        self.turn_start_ms = self.nowMs();
        self.turn_fb_ms = 0;
        self.setBusy(true);
        self.setStatus("thinking...");
        log.info("chat turn start: kind={t} prompt={d}b model_msgs history", .{ kind, msgs.items.len });
    }

    pub fn pumpStream(self: *Chat, dd: []const u8) void {
        if (self.turn == .idle) return;
        const now = self.nowS();
        // While a cast runs, the chat call shares the local backend with the whole swarm — long silence
        // is queueing. The stream gets a longer first-byte leash and the status line says so honestly.
        llm.poll(&self.stream, self.io, self.gpa, now, self.cast_active);
        // publish the partial reply AND the partial reasoning (so thinking shows live, line-by-line)
        {
            self.store.lock();
            defer self.store.unlock();
            const src = self.stream.content.items;
            const n = @min(src.len, self.store.stream_text.len);
            @memcpy(self.store.stream_text[0..n], src[0..n]);
            self.store.stream_len = n;
            // show the TAIL of the reasoning if it exceeds the buffer (the newest thinking matters most)
            const rsrc = self.stream.reasoning.items;
            const rn = @min(rsrc.len, self.store.stream_reason.len);
            @memcpy(self.store.stream_reason[0..rn], rsrc[rsrc.len - rn ..]);
            self.store.stream_reason_len = rn;
        }
        if (!self.stream.done) {
            const el = now - self.stream.started_s;
            var sb: [96]u8 = undefined;
            const st = if (!self.stream.saw_any and self.cast_active)
                std.fmt.bufPrint(&sb, "queued behind the hive... {d}s", .{el}) catch "queued behind the hive..."
            else if (!self.stream.saw_any)
                std.fmt.bufPrint(&sb, "thinking... {d}s", .{el}) catch "thinking..."
            else
                std.fmt.bufPrint(&sb, "writing... {d}s", .{el}) catch "writing...";
            self.setStatus(st);
            // Ollama serializes requests unless OLLAMA_NUM_PARALLEL is set, so a chat call waits out the
            // swarm's whole generation. Once it's clearly queued behind a cast on the local backend, tip
            // the user (once) — this is the real lever for concurrent chat + hive, not anything in-app.
            if (self.cast_active and !self.stream.saw_any and el > 6 and !self.parallel_tip and self.isLocalChat()) {
                self.parallel_tip = true;
                self.store.pushNotif("Chat is waiting on Ollama", "set OLLAMA_NUM_PARALLEL=2 (then restart Ollama) so chat and the hive run at once", 0);
            }
            if (self.stream.saw_any and !self.first_byte_logged) {
                self.first_byte_logged = true;
                if (self.turn_fb_ms == 0) self.turn_fb_ms = @intCast(@max(1, self.nowMs() - self.turn_start_ms));
                log.info("chat turn: first byte after {d}s", .{el});
            }
            return;
        }
        llm.finish(&self.stream, self.io);
        const kind = self.turn;
        self.turn = .idle;
        if (self.stream.failed) {
            var eb: [260]u8 = undefined;
            const emsg = std.fmt.bufPrint(&eb, "(model error: {s})", .{self.stream.errStr()}) catch "(model error)";
            log.err("chat turn FAILED after {d}s: {s}", .{ now - self.stream.started_s, self.stream.errStr() });
            self.recordMetric(kind, false, self.stream.content.items.len);
            self.appendMsg(dd, .veil, emsg);
            self.store.pushNotif("Chat model error", self.stream.errStr(), 2);
            self.stream.deinit(self.gpa);
            self.setBusy(false);
            return;
        }
        const full = std.mem.trim(u8, self.stream.content.items, " \r\n\t");
        const reason = std.mem.trim(u8, self.stream.reasoningStr(), " \r\n\t");
        log.info("chat turn done in {d}s ({d} chars, {d} reasoning); cast_detected={} reply_head={s}", .{ now - self.stream.started_s, self.stream.content.items.len, self.stream.reasoning.items.len, castGoal(full) != null, full[0..@min(full.len, 90)] });
        self.recordMetric(kind, true, self.stream.content.items.len); // one perf sample per completed turn (Metrics tab)
        // A loop-infer turn produced the NEXT user message (not an assistant reply) — copy it off the stream and
        // either send it (continue the auto-loop) or stop. Handled BEFORE tool/cast/reflect detection.
        if (kind == .loop_infer) {
            var nb: [1024]u8 = undefined;
            const src = if (full.len > 0) full else reason;
            const n = @min(src.len, nb.len);
            @memcpy(nb[0..n], src[0..n]);
            self.stream.deinit(self.gpa);
            self.loopContinue(dd, nb[0..n]);
            return;
        }
        // TOOL: <name> <args> — a single shared-tool call. Run it, fold the result back, continue the loop.
        // Not on a .collect/.reflect turn (those turns are answer-composition passes).
        if (kind != .collect and kind != .reflect) {
            // Primary: a strict TOOL line in content. Recovery: gpt-oss-style reasoning models sometimes leave
            // content empty and narrate the call in the hidden reasoning ("...so we issue TOOL: web_search {..}")
            // — pull the last TOOL: out of the reasoning so the tool still fires (mirrors the cast recovery).
            // TOOL: line first; then the `<tool:NAME>{...}</tool:NAME>` XML form (many models use it, even inline);
            // then a loose recovery from the reasoning channel when content is empty.
            const tc_opt = toolCall(full) orelse toolCallXml(full) orelse (if (full.len == 0 and reason.len > 0) toolCallLoose(reason) else null);
            if (tc_opt) |tc| {
                if (self.tool_iters >= MAX_TOOL_ITERS) {
                    self.appendMsg(dd, .veil, "(I ran several tools in a row without settling on an answer, so I stopped. Ask me to continue if you'd like.)");
                    self.stream.deinit(self.gpa);
                    self.setBusy(false);
                    return;
                }
                self.tool_iters += 1;
                self.runToolAndContinue(dd, tc); // copies tc off the stream, THEN frees it, THEN re-enters
                return; // a fresh .tool_follow turn is now live; stay busy
            }
            // RUN: <shell command> — the AI's micro-console door. Same agentic loop as TOOL (shared iteration
            // budget), output streams into the Veil console tab and folds back so the model reads the result.
            if (runCall(full)) |cmd| {
                if (self.tool_iters >= MAX_TOOL_ITERS) {
                    self.appendMsg(dd, .veil, "(I ran several commands in a row without settling on an answer, so I stopped. Ask me to continue if you'd like.)");
                    self.stream.deinit(self.gpa);
                    self.setBusy(false);
                    return;
                }
                self.tool_iters += 1;
                self.runShellAndContinue(dd, cmd); // copies cmd off the stream, THEN frees it, THEN re-enters
                return;
            }
        }
        if (REFLECT_PASSES > 0 and shouldReflectPass(kind, self.last_user[0..self.last_user_len], full)) {
            var reason_fb: [1200]u8 = undefined;
            const rn = @min(reason.len, reason_fb.len);
            @memcpy(reason_fb[0..rn], reason[0..rn]);
            self.reflect_draft_len = @min(full.len, self.reflect_draft.len);
            @memcpy(self.reflect_draft[0..self.reflect_draft_len], full[0..self.reflect_draft_len]);
            self.stream.deinit(self.gpa);
            // KEEP the first-pass draft visible (it used to be replaced by the revision, which read as "wrote it,
            // deleted it, rewrote it"). Commit the draft now; the revision lands as its own message below so the
            // user watches the recursive self-check happen.
            self.appendVeil(dd, reason_fb[0..rn], self.reflect_draft[0..self.reflect_draft_len]);
            self.setStatus("self-checking the draft above...");
            self.startTurn(dd, .reflect);
            // If the second pass fails to start, the draft is already shown — nothing more to do.
            if (self.turn != .reflect) self.reflect_draft_len = 0;
            return;
        }
        if (kind == .reflect) {
            self.reflect_draft_len = 0;
            if (full.len > 0) {
                self.appendMsg(dd, .cast_note, "revised after self-check:");
                self.appendVeil(dd, reason, full);
            } else if (reason.len > 0) {
                self.appendMsg(dd, .cast_note, "revised after self-check:");
                self.appendMsg(dd, .veil, reason);
            } else {
                self.appendMsg(dd, .cast_note, "self-check found nothing to change — the draft above stands.");
            }
        } else if (kind == .collect) {
            self.appendVeil(dd, reason, full);
        } else if (castGoal(full)) |goal| {
            var nb: [3072]u8 = undefined;
            const note = noteWithoutCast(full, &nb);
            if (self.cast_active) {
                self.appendVeil(dd, reason, if (note.len > 0) note else full);
                self.appendMsg(dd, .cast_note, "[cast] a cast is already running — new cast ignored");
            } else {
                if (note.len > 0 or reason.len > 0) self.appendVeil(dd, reason, note);
                self.fireCast(dd, goal);
            }
        } else if (kind == .user and !self.cast_active and userWantsCast(self.last_user[0..self.last_user_len])) {
            // The user EXPLICITLY asked to cast but the model didn't emit a CAST line (gpt-oss commonly
            // leaves `content` empty, putting everything in its hidden reasoning). Honor the request:
            // cast using the user's own words as the goal so an explicit "cast a swarm to X" always fires.
            var gb: [1600]u8 = undefined;
            const goal = castGoalFromUser(self.last_user[0..self.last_user_len], &gb);
            log.info("cast recovery: model emitted no CAST line; casting from the user request", .{});
            if (full.len > 0 or reason.len > 0) self.appendVeil(dd, reason, full);
            self.fireCast(dd, goal);
        } else if (full.len > 0) {
            self.appendVeil(dd, reason, full);
        } else if (reason.len > 0) {
            // content empty but the model reasoned — show the reasoning AS the reply so it's never blank.
            self.appendMsg(dd, .veil, reason);
        } else {
            self.appendMsg(dd, .veil, "(the model returned an empty reply — try rephrasing, or switch to a lighter model in Settings)");
        }
        self.stream.deinit(self.gpa);
        self.setBusy(false);
        self.maybeLoop(dd); // full-auto: if loop mode is on and nothing else is pending, drive the next message
    }

    // ------------------------------------------------------------------------------ prompt loop (full-auto)

    /// After a turn settles, start a loop-infer turn IF auto-loop is on and the conversation is genuinely idle
    /// (no in-flight turn, no running cast). Called at the settle point and on a fresh toggle-on (.loop_kick).
    fn maybeLoop(self: *Chat, dd: []const u8) void {
        if (self.turn != .idle or self.cast_active or self.consoleAiBusy()) return; // wait for casts/turns/console
        const on = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk self.store.chat_loop;
        };
        if (!on) return;
        {
            self.store.lock();
            defer self.store.unlock();
            if (self.store.msg_count == 0) return; // nothing to continue from yet — wait for the first message
        }
        if (self.loop_iter >= LOOP_MAX_ITERS) {
            self.stopLoop(dd, "auto-loop stopped: reached the iteration limit. Toggle it on again to keep going.");
            return;
        }
        var sb: [64]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&sb, "auto-loop {d}/{d}: planning next step...", .{ self.loop_iter + 1, LOOP_MAX_ITERS }) catch "auto-loop: planning...");
        self.startTurn(dd, .loop_infer);
    }

    /// Handle the message a loop-infer turn produced: stop on DONE / empty / user-toggled-off / cap, else send it.
    fn loopContinue(self: *Chat, dd: []const u8, raw: []const u8) void {
        const text = std.mem.trim(u8, raw, " \r\n\t`*\"'");
        const on = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk self.store.chat_loop;
        };
        if (!on) { // the user switched auto-loop off while it was inferring — stop quietly
            self.setBusy(false);
            return;
        }
        if (text.len == 0) {
            self.stopLoop(dd, "auto-loop ended: no next step was inferred.");
            return;
        }
        if (loopIsDone(text)) {
            self.stopLoop(dd, "auto-loop complete: the goal looks achieved.");
            return;
        }
        if (self.loop_iter >= LOOP_MAX_ITERS) {
            self.stopLoop(dd, "auto-loop stopped: reached the iteration limit. Toggle it on again to keep going.");
            return;
        }
        self.loop_iter += 1;
        // send the inferred message as a (visible) user turn — same path as a manual send, minus the counter reset
        self.last_user_len = @min(text.len, self.last_user.len);
        @memcpy(self.last_user[0..self.last_user_len], text[0..self.last_user_len]);
        self.tool_iters = 0;
        self.appendMsg(dd, .user, text);
        self.startTurn(dd, .user);
    }

    /// The input's Stop button: abort the in-flight model turn (kills the curl stream), halt auto-loop, and
    /// return to idle so the user can take over. A running CAST is left alone — it has its own Stop in the
    /// swarm panel — but auto-loop won't re-fire behind it.
    fn stopTurn(self: *Chat, dd: []const u8) void {
        {
            self.store.lock();
            defer self.store.unlock();
            self.store.chat_loop = false;
        }
        self.loop_iter = 0;
        if (self.turn != .idle) {
            llm.abort(&self.stream, self.io);
            self.stream.deinit(self.gpa);
            self.turn = .idle;
            self.appendMsg(dd, .cast_note, "(stopped)");
        }
        self.setStatus("");
        self.setBusy(false);
    }

    /// Turn auto-loop off and tell the user why (the verifiable stop condition fired).
    fn stopLoop(self: *Chat, dd: []const u8, why: []const u8) void {
        {
            self.store.lock();
            defer self.store.unlock();
            self.store.chat_loop = false;
        }
        self.loop_iter = 0;
        self.appendMsg(dd, .cast_note, why);
        self.setStatus("");
        self.setBusy(false);
    }

    /// Append a veil message, prepending the model's reasoning (if any) as a capped markdown blockquote so
    /// the user can see how it thought. Reasoning is trimmed to leave room for the answer in the message.
    fn appendVeil(self: *Chat, dd: []const u8, reasoning: []const u8, text: []const u8) void {
        if (reasoning.len == 0) {
            self.appendMsg(dd, .veil, text);
            return;
        }
        var buf: [12288]u8 = undefined; // matches ChatMsg.text — reasoning preview + full answer without clipping
        var w: usize = 0;
        const cap = @min(reasoning.len, 1200);
        // blockquote each reasoning line
        var it = std.mem.splitScalar(u8, reasoning[0..cap], '\n');
        while (it.next()) |line| {
            const ln = std.mem.trim(u8, line, " \r\t");
            if (ln.len == 0) continue;
            if (w + ln.len + 3 > buf.len) break;
            buf[w] = '>';
            buf[w + 1] = ' ';
            w += 2;
            @memcpy(buf[w .. w + ln.len], ln);
            w += ln.len;
            buf[w] = '\n';
            w += 1;
        }
        if (reasoning.len > cap and w + 6 < buf.len) {
            @memcpy(buf[w .. w + 6], "> ...\n");
            w += 6;
        }
        // blank line then the answer
        if (w + 1 < buf.len) {
            buf[w] = '\n';
            w += 1;
        }
        const tn = @min(text.len, buf.len - w);
        @memcpy(buf[w .. w + tn], text[0..tn]);
        w += tn;
        self.appendMsg(dd, .veil, buf[0..w]);
    }

    // ------------------------------------------------------------------------------ casting (the existing door)

    /// CAST through the server's cast endpoint (POST /api/v1/cast) — the server owns the cast defaults
    /// (minutes budget, minds, autonomy dials); the chat only says WHAT to cast and WITH WHICH provider.
    pub fn fireCast(self: *Chat, dd: []const u8, goal: []const u8) void {
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var kind: u8 = 0;
        var byok: u8 = 0;
        var port: u16 = 8787;
        var tokb: [128]u8 = undefined;
        var tok_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            kind = self.store.settings.chat_kind;
            byok = self.store.settings.chat_byok;
            port = self.store.settings.port;
            tok_n = self.store.settings.token_len;
            @memcpy(tokb[0..tok_n], self.store.settings.token[0..tok_n]);
        }
        const prov_key = castProviderId(kind, byok);

        // A local model loaded with a runaway context (OLLAMA_CONTEXT_LENGTH unset) casts ~16x slower and
        // reads as "broken" — surface the one-line fix once, before the row, so the slowness is explained.
        if (std.mem.eql(u8, prov_key, "ollama")) {
            self.localSlowTip(dd); // check now (model may already be loaded huge)
            self.ctx_poll_budget = 12; // and re-check for the first ~12 ticks in case it loads huge mid-cast
        }

        // Show a "deploying" row + status the INSTANT casting starts, BEFORE building the body — so even a
        // body-build failure is visible (a stuck row) rather than a silent nothing.
        self.pushCastRow(goal);
        self.setStatus("casting the hive...");
        log.info("cast: start provider={s} model={s} base={s} port={d} token={d}b goal={s}", .{ prov_key, prov.model, prov.base_url, port, tok_n, goal[0..@min(goal.len, 60)] });

        var body: [3072]u8 = undefined;
        var w = Io.Writer.fixed(&body);
        const bok = blk: {
            w.print("{{\"provider\":\"{s}\",\"model\":\"{s}\",\"base_url\":\"{s}\",\"minutes\":{d},\"api_key\":\"", .{ prov_key, prov.model, prov.base_url, CAST_MINUTES }) catch break :blk false;
            wesc(&w, prov.key);
            w.writeAll("\",\"goal\":\"") catch break :blk false;
            wesc(&w, goal);
            w.writeAll("\"}") catch break :blk false;
            break :blk true;
        };
        if (!bok) {
            log.err("cast: body build overflow (goal/key too long)", .{});
            self.appendMsg(dd, .cast_note, "[cast] failed — the request was too large to build");
            self.updateCastRow(.failed, 0, -1, "request too large", "");
            self.setStatus("");
            return;
        }

        const resp = netcli.cast(self.io, self.gpa, port, tokb[0..tok_n], w.buffered()) orelse {
            log.err("cast: netcli returned NULL (no response after retries) — server on :{d}?", .{port});
            self.appendMsg(dd, .cast_note, "[cast] no response from the veil server on :8787 — it may be starting up or briefly busy. If casts keep failing, make sure the server is running (run the veil server / `python deploy.py`), then try again.");
            self.updateCastRow(.failed, 0, -1, "no response from :8787 (busy or down)", "");
            self.store.pushNotif("Cast failed", "no response from :8787 — try again", 2);
            self.setStatus("");
            return;
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        log.info("cast: POST -> status={d} body={s}", .{ resp.status, resp.body[0..@min(resp.body.len, 160)] });
        if (resp.status != 200 and resp.status != 201) {
            // 404 specifically means the RUNNING veil.exe predates the /api/v1/cast route — a stale server binary
            // (also the usual cause of the on/offline flapping, since it predates the crash + httpz-spin fixes).
            var nb: [280]u8 = undefined;
            const msg = if (resp.status == 404)
                std.fmt.bufPrint(&nb, "[cast] the veil server is out of date — its build predates the cast endpoint (HTTP 404). Rebuild + restart it (`zig build --release=fast` then relaunch veil.exe, or `python deploy.py`). I'll answer directly from chat in the meantime.", .{}) catch "[cast] server out of date (404) — rebuild + restart it"
            else
                std.fmt.bufPrint(&nb, "[cast] rejected by the server (HTTP {d}): {s}", .{ resp.status, resp.body[0..@min(resp.body.len, 120)] }) catch "[cast] rejected";
            self.appendMsg(dd, .cast_note, msg);
            self.updateCastRow(.failed, 0, -1, if (resp.status == 404) "server out of date - rebuild it" else if (resp.status == 401 or resp.status == 403) "unauthorized - set an API token" else "server rejected the cast", "");
            self.store.pushNotif("Cast unavailable", if (resp.status == 404) "server is out of date — rebuild + restart veil.exe" else if (resp.status == 401 or resp.status == 403) "set an API token in Settings" else "server error", 2);
            self.setStatus("");
            // Graceful fallback: the model builds/answers directly from chat. pumpStream settles this turn right
            // after fireCast returns (setBusy(false) + maybeLoop), so auto-loop — or the user — drives the next step.
            self.appendMsg(dd, .cast_note, "[cast] proceeding without the hive — I'll build/answer directly here.");
            return;
        }
        var idb: [64]u8 = undefined;
        const hex = jStr(resp.body, "id", &idb) orelse "";
        if (hex.len == 0) {
            log.err("cast: 2xx but no id in body: {s}", .{resp.body[0..@min(resp.body.len, 160)]});
            self.appendMsg(dd, .cast_note, "[cast] deploy answered without an id — check the server log");
            self.updateCastRow(.failed, 0, -1, "no run id in the server response", "");
            self.setStatus("");
            return;
        }
        self.cast_active = true;
        self.cast_stop_sent = false;
        self.cast_hex_len = @min(hex.len, self.cast_hex.len);
        @memcpy(self.cast_hex[0..self.cast_hex_len], hex[0..self.cast_hex_len]);
        self.cast_rel_len = 0;
        self.cast_deadline_s = self.nowS() + @as(i64, CAST_MINUTES) * 60 + 120;
        var gb: [200]u8 = undefined;
        const note = std.fmt.bufPrint(&gb, "[cast] hive deployed ({s}) — watching", .{hex}) catch "[cast] hive deployed";
        self.appendMsg(dd, .cast_note, note);
        self.updateCastRow(.deploying, 0, -1, "worker starting...", hex); // stamp the row with the real id
        self.store.pushNotif("Hive cast", goal, 1);
        log.info("chat cast: id={s} goal={s}", .{ hex, goal[0..@min(goal.len, 80)] });
    }

    // ------------------------------------------------------------------------------ shared tools (chat side)

    /// Run ONE shared tool through the server (POST /api/v1/chat/tool — the SAME executor a hive mind uses),
    /// fold the result back into the conversation as a [tool:NAME] message, and re-enter the turn loop so the
    /// model reads it and either runs another tool or answers. Blocking netcli call, but we are on the chat
    /// WORKER thread (not the UI thread), so the block is invisible — the status line set just before keeps
    /// the UI honest. Orchestration verbs (stop_swarm/swarm_findings) default to the live cast when the model
    /// gives no id, so "kill the swarm and tell me what it found" works without the model knowing the hex id.
    fn runToolAndContinue(self: *Chat, dd: []const u8, tc: ToolCall) void {
        // tc.name/tc.args are slices INTO self.stream.content — copy them off BEFORE we free the stream, or they
        // dangle (a use-after-free). The NAME is short (stack), but args can be a WHOLE FILE now (write_file /
        // edit_file), so HEAP-dupe them — a fixed [1024] stack copy silently truncated any real source file
        // (the file-writing convergence then failed at the transport, not the model). Bounded by the reply size.
        var namebuf: [64]u8 = undefined;
        const nn = @min(tc.name.len, namebuf.len);
        @memcpy(namebuf[0..nn], tc.name[0..nn]);
        const name = namebuf[0..nn];
        const raw_args = self.gpa.dupe(u8, tc.args) catch {
            self.stream.deinit(self.gpa);
            self.appendMsg(dd, .cast_note, "[tool] out of memory building the request");
            self.setBusy(false);
            return;
        };
        defer self.gpa.free(raw_args);
        self.stream.deinit(self.gpa); // now safe — name/raw_args are owned copies

        var abuf: [256]u8 = undefined;
        var args = raw_args;
        const orchestration = std.mem.eql(u8, name, "stop_swarm") or std.mem.eql(u8, name, "swarm_findings");
        if (orchestration and self.cast_active and self.cast_hex_len > 0 and !hasRealId(raw_args)) {
            args = std.fmt.bufPrint(&abuf, "{{\"id\":\"{s}\"}}", .{self.cast_hex[0..self.cast_hex_len]}) catch raw_args;
        }
        // web_search with a missing/placeholder query — common when the call is recovered from the reasoning
        // channel, where a weak model writes {"query":"..."} as shorthand — searches for literal "...". Fall
        // back to the user's own words so the search stays on-topic.
        var qbuf: [2048]u8 = undefined;
        if (std.mem.eql(u8, name, "web_search") and self.last_user_len > 0 and queryWeak(args)) {
            var qw = Io.Writer.fixed(&qbuf);
            const okq = blk: {
                qw.writeAll("{\"query\":\"") catch break :blk false;
                wesc(&qw, self.last_user[0..self.last_user_len]);
                qw.writeAll("\"}") catch break :blk false;
                break :blk true;
            };
            if (okq) args = qw.buffered();
        }

        var stbuf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running {s}...", .{name}) catch "running a tool...");
        log.info("chat tool: run {s} args={s}", .{ name, args[0..@min(args.len, 100)] });

        var tokb: [128]u8 = undefined;
        var tok_n: usize = 0;
        var port: u16 = 8787;
        {
            self.store.lock();
            defer self.store.unlock();
            port = self.store.settings.port;
            tok_n = self.store.settings.token_len;
            @memcpy(tokb[0..tok_n], self.store.settings.token[0..tok_n]);
        }

        // the active conversation id → a per-conversation build workdir the server writes into + the console cd's to
        var convb: [40]u8 = undefined;
        const conv = self.convScope(&convb);

        // body = {"tool":NAME,"args":"<escaped raw json>","dir":"<conv>"} — args ride as a JSON string (tool-call
        // convention). HEAP-sized to hold the whole (escaped) args: wesc doubles at most, so 2x + envelope. A
        // fixed [2048] used to reject any write_file over ~1.5KB ("arguments were too long to send"). netcli
        // passes the body straight to curl --data-binary (no cap), and a reply is bounded by MAX_TOKENS.
        const body = self.gpa.alloc(u8, args.len * 2 + name.len + conv.len + 64) catch {
            self.appendMsg(dd, .cast_note, "[tool] out of memory building the request");
            self.setBusy(false);
            return;
        };
        defer self.gpa.free(body);
        var w = Io.Writer.fixed(body);
        const bok = blk: {
            w.print("{{\"tool\":\"{s}\",\"args\":\"", .{name}) catch break :blk false;
            wesc(&w, args);
            w.print("\",\"dir\":\"{s}\"}}", .{conv}) catch break :blk false;
            break :blk true;
        };

        var rbuf: [8192]u8 = undefined;
        var result: []const u8 = "(tool error)";
        if (!bok) {
            result = "(the tool arguments were too long to send)";
        } else if (netcli.chatTool(self.io, self.gpa, port, tokb[0..tok_n], w.buffered())) |resp| {
            defer if (resp.body.len > 0) self.gpa.free(resp.body);
            log.info("chat tool: {s} -> status={d} body={s}", .{ name, resp.status, resp.body[0..@min(resp.body.len, 160)] });
            result = extractToolResult(resp.body, &rbuf);
            // the server echoes the workdir on EVERY tool response, but only a real BUILD tool means the AI is
            // writing files there — only then adopt it as the build dir + cd the console (a web_search turn must
            // NOT announce a build dir or redirect the console into an empty folder).
            if (isBuildToolName(name)) {
                var wdb: [256]u8 = undefined;
                if (jStr(resp.body, "workdir", &wdb)) |wd| {
                    if (wd.len > 0) self.setBuildDir(dd, wd);
                }
            }
            if (std.mem.eql(u8, name, "stop_swarm") and resp.status == 200) self.cast_stop_sent = true;
        } else {
            result = "(no response from the veil server on :8787 — is it running?)";
            log.err("chat tool: {s} netcli NULL", .{name});
        }

        // Fold the result into the conversation as a labeled message the next turn reads (cast_note -> the
        // model sees it as user content; it's also the user-visible record that the tool ran).
        var fb: [8320]u8 = undefined;
        const folded = std.fmt.bufPrint(&fb, "[tool:{s}]\n{s}", .{ name, result }) catch result;
        self.appendMsg(dd, .cast_note, folded);
        self.startTurn(dd, .tool_follow);
    }

    /// The AI's RUN: door. `cmd` is a slice INTO self.stream.content — copy it before freeing the stream (same
    /// UAF discipline as runToolAndContinue). Launches it on the Veil console tab ASYNCHRONOUSLY (consoleStart);
    /// pumpConsole folds the [console] output back and re-enters a .tool_follow turn once it finishes. The
    /// turn stays busy (turn is idle while it awaits the console — see consoleAiBusy) the whole time.
    fn runShellAndContinue(self: *Chat, dd: []const u8, cmd: []const u8) void {
        var cmdbuf: [1024]u8 = undefined;
        const cn = @min(cmd.len, cmdbuf.len);
        @memcpy(cmdbuf[0..cn], cmd[0..cn]);
        const command = cmdbuf[0..cn];
        self.stream.deinit(self.gpa); // now safe — command is an owned copy

        {
            // surface the Veil tab so the user watches the AI's command land (best-effort; store owns the flag)
            self.store.lock();
            defer self.store.unlock();
            self.store.console_show_veil = true;
        }

        var stbuf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running: {s}", .{command[0..@min(command.len, 60)]}) catch "running a command...");
        log.info("chat RUN: {s}", .{command[0..@min(command.len, 120)]});

        // Async: consoleStart never blocks. On an immediate launch failure it folds the error back itself, so
        // the turn always continues; on success pumpConsole finalizes + folds when the command exits.
        self.consoleStart(dd, true, command);
    }

    /// Add a fresh "deploying" cast row (newest) to the activity panel; evicts the oldest when full.
    fn pushCastRow(self: *Chat, goal: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        if (self.store.cast_count >= store_mod.MAX_CASTS) {
            std.mem.copyForwards(store_mod.CastRow, self.store.casts[0 .. store_mod.MAX_CASTS - 1], self.store.casts[1..store_mod.MAX_CASTS]);
            self.store.cast_count = store_mod.MAX_CASTS - 1;
        }
        var row: store_mod.CastRow = .{ .status = .deploying };
        const gn = @min(goal.len, row.goal.len);
        @memcpy(row.goal[0..gn], goal[0..gn]);
        row.goal_len = @intCast(gn);
        self.store.casts[self.store.cast_count] = row;
        self.store.cast_count += 1;
    }

    pub fn watchCast(self: *Chat, dd: []const u8) void {
        if (!self.cast_active) return;
        const now = self.nowS();
        // resolve the run dir once the scanner can see it (server writes u<uid>/<hex>)
        if (self.cast_rel_len == 0) {
            const n = scan.listSwarms(self.io, self.gpa, dd, &self.sw_scratch, now, 45);
            const hex = self.cast_hex[0..self.cast_hex_len];
            for (self.sw_scratch[0..n]) |*sw| {
                const id = sw.idStr();
                const base = if (std.mem.lastIndexOfScalar(u8, id, '/')) |sl| id[sl + 1 ..] else id;
                if (std.mem.eql(u8, base, hex)) {
                    self.cast_rel_len = @min(id.len, self.cast_rel.len);
                    @memcpy(self.cast_rel[0..self.cast_rel_len], id[0..self.cast_rel_len]);
                    self.updateCastRow(.running, 0, -1, "", id);
                    break;
                }
            }
            if (self.cast_rel_len == 0) {
                if (now > self.cast_deadline_s) self.failCast(dd, "[cast] the run directory never appeared — check the server");
                return;
            }
        }
        const rel = self.cast_rel[0..self.cast_rel_len];
        var m: scan.Metrics = .{};
        var ep_buf: [700]u8 = undefined;
        const ep = std.fmt.bufPrint(&ep_buf, "{s}/{s}/events.jsonl", .{ dd, rel }) catch return;
        const ev_n = scan.tailEvents(self.io, self.gpa, ep, &self.ev_scratch, &m);
        // publish tail + row
        {
            self.store.lock();
            defer self.store.unlock();
            @memcpy(self.store.cast_tail[0..ev_n], self.ev_scratch[0..ev_n]);
            self.store.cast_tail_count = ev_n;
        }
        var last: []const u8 = "";
        if (ev_n > 0) last = self.ev_scratch[ev_n - 1].textStr();
        self.updateCastRow(if (m.stopped) .done else .running, m.round, m.pct, last, rel);
        if (self.ctx_poll_budget > 0 and !self.ctx_warned) {
            self.ctx_poll_budget -= 1;
            self.localSlowTip(dd); // model may have loaded (huge) only after the cast fired — catch it early
        }
        if (!m.stopped) {
            var sbuf: [96]u8 = undefined;
            // Show the real metric once a score/phase event has landed; before that (common early in a slow
            // local cast) fall back to an elapsed-vs-budget estimate capped at 90% so the label MOVES instead of
            // sitting at 0 the whole time. cast_deadline_s = start + CAST_MINUTES*60 + 120, so start is derivable.
            const shown_pct: i32 = if (m.pct >= 0) m.pct else blk: {
                const start = self.cast_deadline_s - (@as(i64, CAST_MINUTES) * 60 + 120);
                const elapsed = self.nowS() - start;
                const budget: i64 = @as(i64, CAST_MINUTES) * 60;
                if (elapsed <= 0 or budget <= 0) break :blk 0;
                break :blk @intCast(@min(@divTrunc(elapsed * 100, budget), 90));
            };
            const st = std.fmt.bufPrint(&sbuf, "hive running - r{d} {d}%", .{ m.round, shown_pct }) catch "hive running";
            self.setStatus(st);
        }

        if (m.stopped) {
            // a user turn may still be streaming — keep cast_active and collect on a later tick
            if (self.turn == .idle) self.collectCast(dd, rel, &m, ev_n);
            return;
        }
        if (now > self.cast_deadline_s) {
            if (!self.cast_stop_sent) {
                _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}");
                self.cast_stop_sent = true;
                self.cast_deadline_s = now + 90; // grace for the round boundary
                self.updateCastRow(.collecting, m.round, m.pct, last, rel);
                self.setStatus("asking the hive to stop...");
            } else if (self.turn == .idle) {
                // it never stopped cleanly — collect what exists
                self.collectCast(dd, rel, &m, ev_n);
            }
        }
    }

    fn failCast(self: *Chat, dd: []const u8, msg: []const u8) void {
        self.appendMsg(dd, .cast_note, msg);
        self.updateCastRow(.failed, 0, -1, "", self.cast_hex[0..self.cast_hex_len]);
        self.cast_active = false;
        self.setStatus("");
    }

    /// Fold the finished cast into the conversation as a [cast] findings digest, then ask the model to
    /// answer from it.
    fn collectCast(self: *Chat, dd: []const u8, rel: []const u8, m: *const scan.Metrics, ev_n: usize) void {
        self.cast_active = false;
        self.updateCastRow(.done, m.round, m.pct, "", rel);
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.print(self.gpa, "[cast] finished run {s}: rounds {d}, score {d}% (best {d}%)", .{ rel, m.round, if (m.pct < 0) 0 else m.pct, m.best_pct }) catch return;
        if (m.stop_reason_len > 0) jb.print(self.gpa, ", stopped: {s}", .{m.stop_reason[0..m.stop_reason_len]}) catch {};
        // built files
        const fn_ = scan.listWorkFiles(self.io, self.gpa, dd, rel, &self.file_scratch);
        if (fn_ > 0) {
            jb.appendSlice(self.gpa, "\nfiles built:") catch {};
            var i: usize = 0;
            while (i < @min(fn_, 20)) : (i += 1) {
                jb.print(self.gpa, " {s}({d}b)", .{ self.file_scratch[i].pathStr(), self.file_scratch[i].size }) catch {};
            }
        }
        // the tail of what the hive said/did (for a research cast, scout_learn notes carry the findings)
        if (ev_n > 0) {
            jb.appendSlice(self.gpa, "\nrecent hive activity:") catch {};
            const start = if (ev_n > 12) ev_n - 12 else 0;
            var i = start;
            while (i < ev_n) : (i += 1) {
                const e = &self.ev_scratch[i];
                jb.print(self.gpa, "\n- {s} {s}: {s}", .{ e.kindStr(), e.mindStr(), e.textStr() }) catch {};
            }
        }
        // THE CAST'S ANSWER: the lead's synthesis.md is the composed result of the whole team's web research
        // — surface it FIRST and nearly in full (a cast is judged by this, not by scraps of intermediate
        // files). Only if there is no synthesis do we fall back to RAGing the top built files. The full run
        // (every file, event, memory) stays saved under <data>/<rel> and reopens from the Swarm tab.
        var sbuf: [2600]u8 = undefined;
        var strunc = false;
        const sn = scan.readWorkFile(self.io, self.gpa, dd, rel, "synthesis.md", &sbuf, &strunc);
        if (sn > 0) {
            jb.appendSlice(self.gpa, "\n\n=== THE CAST'S ANSWER (the lead composed this from the team's web research — cite its sources) ===\n") catch {};
            jb.appendSlice(self.gpa, sbuf[0..sn]) catch {};
            if (strunc) jb.appendSlice(self.gpa, "\n[...full report saved in the run dir]") catch {};
        } else if (fn_ > 0) {
            var fi: usize = 0;
            var shown: usize = 0;
            while (fi < fn_ and shown < 2) : (fi += 1) {
                var cbuf: [1400]u8 = undefined;
                var trunc = false;
                const cn = scan.readWorkFile(self.io, self.gpa, dd, rel, self.file_scratch[fi].pathStr(), &cbuf, &trunc);
                if (cn == 0) continue;
                jb.print(self.gpa, "\n\n--- {s} ---\n{s}{s}", .{ self.file_scratch[fi].pathStr(), cbuf[0..cn], if (trunc) "\n[...truncated; full file saved in the run dir]" else "" }) catch {};
                shown += 1;
            }
        }
        jb.print(self.gpa, "\n\n(full swarm output saved at {s}; open it in the Swarm tab)", .{rel}) catch {};
        // Keep as much of the digest as the ChatMsg buffer (12288b) holds — the synthesis IS the answer, so
        // we want it whole, not clipped. appendMsg truncates to the buffer anyway.
        const digest = jb.items[0..@min(jb.items.len, 12200)];
        self.appendMsg(dd, .cast_note, digest);
        self.setStatus("composing the answer...");
        self.startTurn(dd, .collect);
    }

    fn updateCastRow(self: *Chat, status: store_mod.CastStatus, round: i64, pct: i32, last: []const u8, run_id: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        if (self.store.cast_count == 0) return;
        // the newest row is this thread's active cast
        const row = &self.store.casts[self.store.cast_count - 1];
        row.status = status;
        row.round = round;
        row.pct = pct;
        if (run_id.len > 0) {
            const rn = @min(run_id.len, row.run.len);
            @memcpy(row.run[0..rn], run_id[0..rn]);
            row.run_len = @intCast(rn);
        }
        if (last.len > 0) {
            const ln = @min(last.len, row.last.len);
            @memcpy(row.last[0..ln], last[0..ln]);
            row.last_len = @intCast(ln);
        }
    }
};

// ------------------------------------------------------------------------------ pure helpers (tested)

/// If a "CAST: goal" line appears within the reply's first few substantive lines, return the goal.
/// Tolerant on purpose: reasoning models often put a short preamble ("Sure — this needs the hive.")
/// above the tag even when told to lead with it.
pub fn castGoal(full: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, full, '\n');
    var seen: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "CAST:")) {
            const g = std.mem.trim(u8, line[5..], " \r\t");
            return if (g.len > 0) g else null;
        }
        seen += 1;
        if (seen >= 5) return null; // a CAST mention deep in prose is narration, not an action
    }
    return null;
}

/// Should we run the self-check (reflect) pass for this completed turn? Only a SUBSTANTIVE answer to a
/// SUBSTANTIVE request qualifies — a greeting or a one-liner must NOT recurse ("hello" -> short reply -> no
/// second pass). This mirrors how Claude Code iterates on real TASKS, not on chit-chat. Control lines
/// (TOOL:/CAST:) and the non-answer turns (collect/reflect/idle) never reflect.
fn shouldReflectPass(kind: Turn, user_msg: []const u8, full: []const u8) bool {
    if (kind != .user and kind != .tool_follow) return false;
    if (full.len == 0) return false;
    if (castGoal(full) != null or toolCall(full) != null) return false;
    if (full.len < REFLECT_MIN_ANSWER) return false; // trivial/short answers don't need a self-check
    if (isSmallTalk(user_msg)) return false; // greetings/acks/tiny queries never warrant a reflect pass
    return true;
}

/// A greeting, thanks, or tiny query — the kind of message a reflection pass must never fire on.
fn isSmallTalk(msg: []const u8) bool {
    const m = std.mem.trim(u8, msg, " \r\n\t");
    if (m.len < 24) return true;
    var buf: [24]u8 = undefined;
    const n = @min(m.len, buf.len);
    for (m[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const openers = [_][]const u8{ "hello", "hi ", "hey", "thanks", "thank you", "good morning", "good evening", "how are you", "what's up", "yo " };
    for (openers) |w| if (std.mem.startsWith(u8, buf[0..n], w)) return true;
    return false;
}

pub const ToolCall = struct { name: []const u8, args: []const u8 };

/// If a "TOOL: <name> <json-args>" line appears within the reply's first few substantive lines, return
/// the tool name + its raw JSON args ("{}" when the model omits them). Same tolerance as castGoal: a short
/// preamble above the tag is fine; a TOOL mention buried deep in prose is narration, not an action. The
/// args are passed to the server verbatim, so a malformed blob is the server's problem to reject, not ours.
pub fn toolCall(full: []const u8) ?ToolCall {
    var it = std.mem.splitScalar(u8, full, '\n');
    var seen: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "TOOL:")) {
            const rest = std.mem.trim(u8, line[5..], " \r\t");
            if (rest.len == 0) return null;
            var name = rest;
            var args: []const u8 = "{}";
            if (std.mem.indexOfAny(u8, rest, " \t{")) |sp| {
                name = std.mem.trim(u8, rest[0..sp], " \t:");
                const a = std.mem.trim(u8, rest[sp..], " \r\t");
                if (a.len > 0) args = a;
            }
            if (name.len == 0) return null;
            return .{ .name = name, .args = args };
        }
        seen += 1;
        if (seen >= 5) return null;
    }
    return null;
}

/// Many models emit tool calls as `<tool:NAME>{json-args}</tool:NAME>` (or just `<tool:NAME>{...}`) instead of
/// the `TOOL:` convention — even inline in prose. Find the FIRST such call anywhere in the reply and return
/// name+args. Without this those calls render as inert text and the model loops forever re-issuing them (the
/// Mario walkthrough failure: every `<tool:read_file>` was dropped, so the model never saw the files).
pub fn toolCallXml(text: []const u8) ?ToolCall {
    const open = std.mem.indexOf(u8, text, "<tool:") orelse return null;
    var i = open + "<tool:".len;
    const nstart = i;
    while (i < text.len and text[i] != '>' and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t') i += 1;
    const name = std.mem.trim(u8, text[nstart..i], " \t:`*\"/");
    if (name.len == 0 or name.len > 40) return null;
    while (i < text.len and text[i] != '>') i += 1; // skip to the tag close
    if (i < text.len) i += 1; // skip '>'
    var args: []const u8 = "{}";
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
    if (i < text.len and text[i] == '{') { // a balanced {...} blob after the tag
        const astart = i;
        var depth: i32 = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') depth += 1 else if (text[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (depth == 0 and i > astart + 1) args = text[astart..i];
    }
    return .{ .name = name, .args = args };
}

/// Loose recovery: find the LAST "TOOL:" ANYWHERE in text (not just line-start) and parse a tool name +
/// a balanced {...} args blob after it. Used ONLY on the reasoning channel when content is empty — a
/// reasoning model narrates its decision ("...so we issue TOOL: web_search {\"query\":\"x\"}") there. More
/// permissive than toolCall on purpose; the strict parser owns the content path.
pub fn toolCallLoose(text: []const u8) ?ToolCall {
    const key = "TOOL:";
    var at: ?usize = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, key)) |p| {
        at = p;
        search = p + key.len;
    }
    var i = (at orelse return null) + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const nstart = i;
    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '{' and text[i] != '\n' and text[i] != '\r') i += 1;
    const name = std.mem.trim(u8, text[nstart..i], " \t:`*\"");
    if (name.len == 0 or name.len > 40) return null;
    var args: []const u8 = "{}";
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i < text.len and text[i] == '{') {
        const astart = i;
        var depth: i32 = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') depth += 1 else if (text[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (depth == 0 and i > astart + 1) args = text[astart..i];
    }
    return .{ .name = name, .args = args };
}

/// The auto-loop driver signals completion with a bare "DONE". Be strict so a normal next-message that merely
/// mentions "done" doesn't halt the loop: the whole (short) reply must be a completion word.
fn loopIsDone(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n.!\"'`*:");
    if (t.len == 0 or t.len > 16) return false;
    return std.ascii.eqlIgnoreCase(t, "DONE") or
        std.ascii.eqlIgnoreCase(t, "COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "GOAL COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "TASK COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "FINISHED");
}

/// True for the build (file/exec) tools whose response workdir means the AI is building there — used to gate
/// adopting the build dir + cd'ing the console (research tools also echo a workdir but write no files).
fn isBuildToolName(name: []const u8) bool {
    const bt = [_][]const u8{ "write_file", "edit_file", "read_file", "list_dir", "delete_file", "run_tests", "run_python" };
    for (bt) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

/// Copy as much of `src` as fits into `dst`; returns the slice of `dst` actually written.
fn copyInto(dst: []u8, src: []const u8) []const u8 {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return dst[0..n];
}

/// Build the bounded [console] payload the AI door hands back to the model: stdout, then stderr, then the
/// status note. The note is ALWAYS kept (room is reserved for it) so a "(command timed out …)"/stop note
/// survives even when the output alone would fill `buf`. Pure — unit-tested.
fn composeConsoleResult(buf: []u8, out: []const u8, err: []const u8, note: []const u8) []const u8 {
    const body_cap = if (buf.len > note.len) buf.len - note.len else 0; // reserve room for the note
    var w: usize = 0;
    w += copyInto(buf[w..body_cap], out).len;
    w += copyInto(buf[w..body_cap], err).len;
    if (w == 0 and body_cap > 0) w += copyInto(buf[w..body_cap], "(no output)").len;
    if (note.len > 0 and w + note.len <= buf.len) {
        @memcpy(buf[w .. w + note.len], note);
        w += note.len;
    }
    return buf[0..w];
}

/// A reply that is exactly a "RUN: <shell command>" line (the AI's micro-console door). Returns the command,
/// trimmed, or null. Mirrors toolCall: only fires if RUN: leads one of the first few substantive lines so a
/// passing mention in prose can't trigger a shell command.
pub fn runCall(full: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, full, '\n');
    var seen: u32 = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r`*");
        if (line.len == 0) continue;
        seen += 1;
        if (seen > 4) return null;
        if (std.mem.startsWith(u8, line, "RUN:")) {
            const cmd = std.mem.trim(u8, line["RUN:".len..], " \t\r");
            return if (cmd.len == 0 or cmd.len > 900) null else cmd;
        }
    }
    return null;
}

/// Did the user's message explicitly ask to cast a swarm? Case-insensitive: a cast verb
/// (cast/run/spin/deploy/launch/summon) together with "swarm" or "hive". Used to honor an explicit
/// request even when the model flakes and emits no CAST line.
pub fn userWantsCast(msg: []const u8) bool {
    if (msg.len == 0 or msg.len > 4000) return false;
    var lower: [4000]u8 = undefined;
    const n = @min(msg.len, lower.len);
    for (0..n) |i| lower[i] = std.ascii.toLower(msg[i]);
    const lo = lower[0..n];
    const has_target = std.mem.indexOf(u8, lo, "swarm") != null or std.mem.indexOf(u8, lo, "hive") != null;
    if (!has_target) return false;
    const verbs = [_][]const u8{ "cast", "run ", "spin", "deploy", "launch", "summon", "dispatch" };
    for (verbs) |v| {
        if (std.mem.indexOf(u8, lo, v) != null) return true;
    }
    return false;
}

/// Strip a leading cast-request preamble ("cast a swarm to ", "have the hive ", "run a swarm that ")
/// from the user's message to get a clean one-line goal. Returns a slice into `buf`.
pub fn castGoalFromUser(msg: []const u8, buf: []u8) []const u8 {
    var g = std.mem.trim(u8, msg, " \r\n\t");
    // find " to " / " that " / " for " after a cast verb and take what follows, else use the message
    const seps = [_][]const u8{ " to ", " that ", " which ", " for " };
    var lower: [1600]u8 = undefined;
    const ln = @min(g.len, lower.len);
    for (0..ln) |i| lower[i] = std.ascii.toLower(g[i]);
    // only strip if the message clearly starts with a cast request
    if (std.mem.indexOf(u8, lower[0..ln], "swarm") != null or std.mem.indexOf(u8, lower[0..ln], "hive") != null) {
        for (seps) |sep| {
            if (std.mem.indexOf(u8, lower[0..ln], sep)) |at| {
                const rest = std.mem.trim(u8, g[at + sep.len ..], " \r\n\t");
                if (rest.len > 3) {
                    g = rest;
                    break;
                }
            }
        }
    }
    const n = @min(g.len, buf.len);
    @memcpy(buf[0..n], g[0..n]);
    return buf[0..n];
}

/// The provider id a cast deploys under, derived from the CHAT's configured backend so a swarm always runs
/// on whatever the user is chatting with: BYOK (kind=1) -> that catalog provider's id ("openai",
/// "anthropic", "groq", ...); a custom OpenAI-compatible URL (kind=2) -> "openai" (the base_url carries the
/// real endpoint); otherwise the local backend -> "ollama". Paired with resolveProvider (model/base_url/key
/// come from the same chat settings), this is what makes "chatting with OpenAI casts an OpenAI swarm" true.
pub fn castProviderId(kind: u8, byok: u8) []const u8 {
    return switch (kind) {
        1 => catalog.providers[@min(byok, catalog.providers.len - 1)].key,
        2 => "openai",
        else => "ollama",
    };
}

/// The reply minus its CAST line — the note shown to the user beside the cast.
pub fn noteWithoutCast(full: []const u8, buf: []u8) []const u8 {
    var w: usize = 0;
    var removed = false;
    var it = std.mem.splitScalar(u8, full, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!removed and std.mem.startsWith(u8, line, "CAST:")) {
            removed = true;
            continue;
        }
        if (w + raw.len + 1 > buf.len) break;
        if (w > 0) {
            buf[w] = '\n';
            w += 1;
        }
        @memcpy(buf[w .. w + raw.len], raw);
        w += raw.len;
    }
    return std.mem.trim(u8, buf[0..w], " \r\n\t");
}

fn escJson(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => list.appendSlice(gpa, "\\\"") catch {},
            '\\' => list.appendSlice(gpa, "\\\\") catch {},
            '\n' => list.appendSlice(gpa, "\\n") catch {},
            '\r' => {},
            '\t' => list.appendSlice(gpa, "\\t") catch {},
            else => {
                if (c < 0x20) list.appendSlice(gpa, " ") catch {} else list.append(gpa, c) catch {};
            },
        }
    }
}

fn wesc(w: *Io.Writer, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => {},
            '\t' => w.writeAll(" ") catch {},
            else => {
                if (c < 0x20) w.writeAll(" ") catch {} else w.writeByte(c) catch {};
            },
        }
    }
}

fn jInt(line: []const u8, key: []const u8) ?i64 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = at + needle.len;
    while (i < line.len and line[i] == ' ') i += 1;
    var neg = false;
    if (i < line.len and line[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

var jstr_buf: [64]u8 = undefined;
fn jStr(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    _ = out;
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and body[i] == ' ') i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < body.len and body[i] != '"' and w < jstr_buf.len) : (i += 1) {
        jstr_buf[w] = body[i];
        w += 1;
    }
    return jstr_buf[0..w];
}

/// Does `args` carry a real swarm id (not empty, not a placeholder)? When it doesn't and a cast is live,
/// runToolAndContinue substitutes the running cast's id so the model needn't know the hex.
fn hasRealId(args: []const u8) bool {
    var b: [64]u8 = undefined;
    const id = jStr(args, "id", &b) orelse return false;
    const t = std.mem.trim(u8, id, " ");
    if (t.len == 0) return false;
    if (std.mem.eql(u8, t, "current") or std.mem.eql(u8, t, "the current") or std.mem.eql(u8, t, "<id>") or std.mem.eql(u8, t, "id")) return false;
    return true;
}

/// Is a web_search "query" arg missing or a placeholder ("", "...", "…", "<query>")? A reasoning-recovered
/// call often carries shorthand; treat anything under 3 real chars (after stripping dots/brackets) as weak.
fn queryWeak(args: []const u8) bool {
    var b: [128]u8 = undefined;
    const q = jStr(args, "query", &b) orelse return true;
    const t = std.mem.trim(u8, q, " .\t\r\n<>…\"");
    return t.len < 3;
}

/// Extract a JSON string value for `key`, UNESCAPING into `out` (handles \" \\ \/ \n \r \t \b \f and, best-
/// effort, \uXXXX -> '?'). Unlike jStr this is not capped at 64b and survives escaped quotes + newlines —
/// tool results routinely contain both. Returns the written slice, or null if the key is absent.
fn jsonStrInto(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var kbuf: [48]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < body.len and w < out.len) {
        const c = body[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < body.len) {
            const e = body[i + 1];
            i += 2;
            out[w] = switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                'u' => blk: {
                    if (i + 4 <= body.len) i += 4; // skip the code point; emit a placeholder
                    break :blk '?';
                },
                else => e, // \" \\ \/ and anything else -> the literal char
            };
            w += 1;
            continue;
        }
        out[w] = c;
        w += 1;
        i += 1;
    }
    return out[0..w];
}

/// The human-readable payload of a /api/v1/chat/tool response: the mind-tool "result", else the swarm
/// "findings", else an "err" string, else the raw JSON body (list_swarms/stop_swarm hand back a small
/// object the model can read directly). Always returns a slice of `out` or `body`.
fn extractToolResult(body: []const u8, out: []u8) []const u8 {
    if (jsonStrInto(body, "result", out)) |r| return r;
    if (jsonStrInto(body, "findings", out)) |r| return r;
    if (jsonStrInto(body, "err", out)) |r| return r;
    const n = @min(body.len, out.len);
    @memcpy(out[0..n], body[0..n]);
    return out[0..n];
}

// ------------------------------------------------------------------------------ tests

test "first message auto-titles the conversation (both the type-first and +-first flows)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-title-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    // dead endpoint so startTurn's curl goes nowhere — the title path is what's under test
    const base = "http://127.0.0.1:1/v1";
    @memcpy(store.settings.chat_base[0..base.len], base);
    store.settings.chat_base_len = base.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    // flow 1: user types first (no conversation yet)
    chat.cmdSend(dd, "hello there veil, how are you?");
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
    chat.turn = .idle;
    var found_title = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.conv_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.convs[i].titleStr(), "hello there veil")) found_title = true;
        }
    }
    try std.testing.expect(found_title);

    // flow 2: user clicks + first, then sends
    chat.cmdNewConv(dd);
    chat.cmdSend(dd, "second conversation opener");
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
    chat.turn = .idle;
    var found2 = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.conv_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.convs[i].titleStr(), "second conversation")) found2 = true;
        }
    }
    try std.testing.expect(found2);
}

test "cast watch resolves the run dir, tails it, and collects on stop (no server needed)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/u1/cafe01/work", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe01/events.jsonl", .data = "{\"seq\":1,\"kind\":\"act\",\"round\":1,\"mind\":\"nova\",\"tool\":\"observe\",\"result\":\"looked around\"}\n" ++
        "{\"seq\":2,\"kind\":\"score\",\"round\":2,\"passed\":2,\"total\":3,\"pct\":66}\n" ++
        "{\"seq\":3,\"kind\":\"stopped\",\"reason\":\"complete\"}\n" }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe01/swarm.json", .data = "{\"swarm\":\"chat-test\"}" }) catch unreachable;

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    {
        const d = dd;
        @memcpy(store.settings.data_dir[0..d.len], d);
        store.settings.data_dir_len = d.len;
    }
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    // an active conversation to receive the [cast] digest
    chat.cmdNewConv(dd);
    // pretend a cast was fired: hex known, rel not yet resolved, one right-pane row
    chat.cast_active = true;
    const hex = "cafe01";
    @memcpy(chat.cast_hex[0..hex.len], hex);
    chat.cast_hex_len = hex.len;
    chat.cast_deadline_s = chat.nowS() + 600;
    store.casts[0] = .{ .status = .deploying };
    store.cast_count = 1;

    chat.watchCast(dd); // resolves u1/cafe01 and sees `stopped` → collect fires a model turn
    try std.testing.expect(!chat.cast_active);
    try std.testing.expectEqualStrings("u1/cafe01", chat.cast_rel[0..chat.cast_rel_len]);
    try std.testing.expect(store.casts[0].status == .done);
    try std.testing.expect(store.cast_tail_count >= 2);
    // the digest message landed in the conversation
    var found = false;
    var i: usize = 0;
    while (i < store.msg_count) : (i += 1) {
        if (store.msgs[i].role == .cast_note and std.mem.indexOf(u8, store.msgs[i].textStr(), "score 66%") != null) found = true;
    }
    try std.testing.expect(found);
    // the collect turn started a model call (against the default local endpoint) — abort it either way
    try std.testing.expect(chat.turn == .collect or chat.turn == .idle);
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
}

test "LIVE chat turn: streams a real reply from local Ollama (best-effort, skips if down)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    if (!scan.serverOnline(io, 11434)) {
        std.debug.print("\n[chat live test] no Ollama on :11434 — skipping\n", .{});
        return;
    }
    const dd = "zig-chat-live-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    const model = if (Io.Dir.cwd().access(io, "../data/.veil_gptoss", .{})) |_| "gpt-oss:20b" else |_| "llama3.1:8b"; // marker → test the thinking model's pump path
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    chat.cmdSend(dd, "Reply with exactly one short sentence: what is the capital of France?");
    try std.testing.expect(chat.turn == .user);
    var waited: usize = 0;
    while (chat.turn != .idle and waited < 3000) : (waited += 1) { // up to ~5min for a cold thinking model
        chat.pumpStream(dd);
        if (waited % 50 == 0) std.debug.print("[live] t+{d}s turn={s} content={d}b reason={d}b done={} saw_any={}\n", .{ waited / 10, @tagName(chat.turn), chat.stream.content.items.len, chat.stream.reasoning.items.len, chat.stream.done, chat.stream.saw_any });
        io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(chat.turn == .idle);
    // last message is the veil's reply and it is non-empty, non-error
    try std.testing.expect(store.msg_count >= 2);
    const last = &store.msgs[store.msg_count - 1];
    std.debug.print("[chat live test] veil replied ({d}b): {s}\n", .{ last.text_len, last.textStr()[0..@min(last.text_len, 120)] });
    try std.testing.expect(last.role == .veil);
    try std.testing.expect(last.text_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, last.textStr(), "(model error") == null);
    // and it persisted: the conversation file holds both messages
    var pb: [700]u8 = undefined;
    var idb: [32]u8 = undefined;
    const idn: usize = store.conv_active_len;
    @memcpy(idb[0..idn], store.conv_active[0..idn]);
    const path = Chat.convPath(dd, idb[0..idn], &pb).?;
    const data = Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(1 << 20)) catch unreachable;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "capital of France") != null);
}

// Full-workflow live test (opt-in): drives the REAL Chat worker through the whole cowork chain against a
// live veil server + local gpt-oss — explicit cast fires, the chat answers a SECOND question in parallel
// while the swarm runs, then on completion the collect turn answers from the swarm's built file. Heavy
// (~6-10 min on local gpt-oss), so it only runs when VEIL_E2E=1 AND both servers are up; otherwise it skips.
test "E2E cowork: explicit cast fires, chat replies in parallel, collect answers from the swarm's file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    // opt-in via a marker file (heavy test): `touch ../data/.veil_e2e` before running, remove it after
    Io.Dir.cwd().access(io, "../data/.veil_e2e", .{}) catch {
        std.debug.print("\n[E2E] create ../data/.veil_e2e to run the full cowork test — skipping\n", .{});
        return;
    };
    if (!scan.serverOnline(io, 11434)) {
        std.debug.print("\n[E2E] no Ollama on :11434 — skipping\n", .{});
        return;
    }
    if (!scan.serverOnline(io, 8787)) {
        std.debug.print("\n[E2E] no veil server on :8787 — skipping\n", .{});
        return;
    }
    // dd is the LIVE server data dir (../data from desktop/): the veil server writes swarm run dirs under
    // <dd>/u<uid>/<hex>, so watchCast must scan HERE to see the cast it fired — exactly as the shipped app
    // does (its data_dir points at the server's data). NB: never deleteTree(dd) — it is real user data; the
    // test removes only the single conversation file it creates (defer below).
    const dd = "../data";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    const model = "gpt-oss:20b";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;
    store.settings.port = 8787;
    // the veil server drops an admin key at <home>/data/.desktop_key; the test cwd is desktop/, so ../data
    if (Io.Dir.cwd().readFileAlloc(io, "../data/.desktop_key", std.testing.allocator, .limited(4096)) catch null) |key| {
        defer std.testing.allocator.free(key);
        const kt = std.mem.trim(u8, key, " \r\n\t");
        if (kt.len > 0 and kt.len <= store.settings.token.len) {
            @memcpy(store.settings.token[0..kt.len], kt);
            store.settings.token_len = @intCast(kt.len);
        }
    }

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    // make sure any swarm we spawn gets stopped even if an assertion fails mid-test
    defer if (chat.cast_rel_len > 0) {
        _ = scan.writeControl(io, std.testing.allocator, dd, chat.cast_rel[0..chat.cast_rel_len], "{\"op\":\"stop\"}");
    };
    // dd is the LIVE data dir — clean up ONLY the one conversation file this test created (never the tree)
    defer if (store.conv_active_len > 0) {
        var pb: [700]u8 = undefined;
        if (Chat.convPath(dd, store.conv_active[0..store.conv_active_len], &pb)) |cp| Io.Dir.cwd().deleteFile(io, cp) catch {};
    };

    const tick = struct {
        fn pump(c: *Chat, d: []const u8, i: std.Io, w: usize, tag: []const u8) void {
            c.pumpStream(d);
            c.watchCast(d);
            if (w % 100 == 0) std.debug.print("[E2E] {s} t+{d}s turn={s} cast_active={} msgs={d}\n", .{ tag, w / 10, @tagName(c.turn), c.cast_active, c.store.msg_count });
            i.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
    };

    // 1) explicit cast request -> user turn completes -> a cast fires (CAST line or the userWantsCast recovery)
    std.debug.print("[E2E] step1: sending cast request...\n", .{});
    chat.cmdSend(dd, "cast a swarm to write two facts about the moon to facts.md");
    var waited: usize = 0;
    while (chat.turn != .idle and waited < 3600) : (waited += 1) tick.pump(chat, dd, io, waited, "s1"); // <=6min for the turn
    try std.testing.expect(chat.cast_active); // the cast deployed
    std.debug.print("\n[E2E] step1 OK — cast fired: {s}\n", .{chat.cast_hex[0..chat.cast_hex_len]});

    // 2) PARALLEL COWORK: with the swarm still running, the chat answers a second, unrelated question
    try std.testing.expect(chat.cast_active); // still running
    const before = store.msg_count;
    chat.cmdSend(dd, "While that runs, answer directly: what is 7 times 8? Reply with just the number.");
    waited = 0;
    while (chat.turn != .idle and waited < 2400) : (waited += 1) tick.pump(chat, dd, io, waited, "s2"); // <=4min
    try std.testing.expect(store.msg_count > before);
    const par = &store.msgs[store.msg_count - 1];
    try std.testing.expect(par.role == .veil and par.text_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, par.textStr(), "(model error") == null);
    std.debug.print("[E2E] step2 OK — parallel reply while cast_active={}: {s}\n", .{ chat.cast_active, par.textStr()[0..@min(par.text_len, 80)] });

    // 3) let the swarm finish -> collectCast folds the digest + RAGs the file -> collect turn answers
    waited = 0;
    while (chat.cast_active and waited < 7200) : (waited += 1) tick.pump(chat, dd, io, waited, "s3-cast"); // <=12min for the cast
    try std.testing.expect(!chat.cast_active); // completed + collected (not timed out mid-run)
    // drain the collect turn the collector started
    waited = 0;
    while (chat.turn != .idle and waited < 2400) : (waited += 1) tick.pump(chat, dd, io, waited, "s3-collect");

    // a [cast] digest landed AND the swarm built facts.md
    var saw_digest = false;
    var saw_file = false;
    var i: usize = 0;
    while (i < store.msg_count) : (i += 1) {
        const t = store.msgs[i].textStr();
        if (store.msgs[i].role == .cast_note and std.mem.indexOf(u8, t, "[cast] finished") != null) saw_digest = true;
        if (std.mem.indexOf(u8, t, "facts.md") != null) saw_file = true;
    }
    try std.testing.expect(saw_digest);
    try std.testing.expect(saw_file);
    const final = &store.msgs[store.msg_count - 1];
    std.debug.print("[E2E] step3 OK — cast collected; digest+facts.md folded in; final reply ({d}b): {s}\n", .{ final.text_len, final.textStr()[0..@min(final.text_len, 120)] });
}

test "castGoal fires on a CAST line within the first few lines" {
    try std.testing.expectEqualStrings("map the auth flow", castGoal("CAST: map the auth flow\nOn it.").?);
    try std.testing.expectEqualStrings("x", castGoal("\n  CAST: x").?);
    // tolerant: a short preamble above the tag still casts
    try std.testing.expectEqualStrings("dig into the repo", castGoal("This needs real work.\nCAST: dig into the repo").?);
    try std.testing.expect(castGoal("hello there") == null);
    try std.testing.expect(castGoal("CAST:") == null);
    // a CAST buried deep in prose is narration
    try std.testing.expect(castGoal("a\nb\nc\nd\ne\nf\nCAST: too deep") == null);
}

test "shouldReflectPass: only substantive answers to real requests reflect (hello never recurses)" {
    var longbuf: [600]u8 = undefined;
    @memset(&longbuf, 'x');
    const long = longbuf[0..];
    const q = "Explain in detail how a red-black tree stays balanced and why rotations preserve the invariants.";
    // substantive question + substantive answer -> reflect
    try std.testing.expect(shouldReflectPass(.user, q, long));
    try std.testing.expect(shouldReflectPass(.tool_follow, q, long));
    // THE BUG: a greeting must NOT recurse
    try std.testing.expect(!shouldReflectPass(.user, "hello", "Hi! How can I help you today?"));
    try std.testing.expect(!shouldReflectPass(.user, "hi there", long)); // small-talk user msg
    try std.testing.expect(!shouldReflectPass(.user, "thanks!", long));
    // trivial (short) answer never reflects even for a real question
    try std.testing.expect(!shouldReflectPass(.user, q, "Short answer."));
    // control lines + non-answer turns never reflect
    try std.testing.expect(!shouldReflectPass(.collect, q, long));
    try std.testing.expect(!shouldReflectPass(.reflect, q, long));
    try std.testing.expect(!shouldReflectPass(.user, q, "CAST: research this repo"));
    try std.testing.expect(!shouldReflectPass(.user, q, "TOOL: web_search {}"));
    try std.testing.expect(!shouldReflectPass(.user, q, ""));
}

test "toolCall parses name + raw json args" {
    const a = toolCall("TOOL: web_search {\"query\":\"zig 0.16\"}").?;
    try std.testing.expectEqualStrings("web_search", a.name);
    try std.testing.expectEqualStrings("{\"query\":\"zig 0.16\"}", a.args);
    // no args -> defaults to {}
    const b = toolCall("TOOL: stop_swarm").?;
    try std.testing.expectEqualStrings("stop_swarm", b.name);
    try std.testing.expectEqualStrings("{}", b.args);
    // brace flush against the name (no space)
    const c = toolCall("TOOL: swarm_findings{\"id\":\"abc\"}").?;
    try std.testing.expectEqualStrings("swarm_findings", c.name);
    try std.testing.expectEqualStrings("{\"id\":\"abc\"}", c.args);
    // preamble tolerated; empty/absent -> null
    try std.testing.expectEqualStrings("list_swarms", toolCall("Sure, let me check.\nTOOL: list_swarms {}").?.name);
    try std.testing.expect(toolCall("just chatting") == null);
    try std.testing.expect(toolCall("TOOL:") == null);
    try std.testing.expect(toolCall("a\nb\nc\nd\ne\nf\nTOOL: too_deep {}") == null);
}

test "toolCallLoose recovers a call narrated inside reasoning" {
    // the exact gpt-oss failure: content empty, the decision lives mid-sentence in reasoning
    const r = "We must use web_search tool. That is not a cast. So we issue TOOL: web_search {\"query\":\"Zig 0.16 release highlights\"}";
    const a = toolCallLoose(r).?;
    try std.testing.expectEqualStrings("web_search", a.name);
    try std.testing.expectEqualStrings("{\"query\":\"Zig 0.16 release highlights\"}", a.args);
    // takes the LAST occurrence; balanced braces
    const b = toolCallLoose("first TOOL: list_swarms {} then decide TOOL: stop_swarm {\"id\":\"x\"}").?;
    try std.testing.expectEqualStrings("stop_swarm", b.name);
    try std.testing.expectEqualStrings("{\"id\":\"x\"}", b.args);
    // bare name, no args -> {}
    try std.testing.expectEqualStrings("{}", toolCallLoose("so I will run TOOL: list_swarms now").?.args);
    try std.testing.expect(toolCallLoose("no tool mentioned here") == null);
}

test "toolCallXml parses the <tool:NAME>{...}</tool:NAME> form that broke the Mario walkthrough" {
    const a = toolCallXml("<tool:read_file>{\"path\":\"index.html\"}</tool:read_file>").?;
    try std.testing.expectEqualStrings("read_file", a.name);
    try std.testing.expectEqualStrings("{\"path\":\"index.html\"}", a.args);
    // inline in prose, takes the FIRST one; balanced braces even with nested objects
    const b = toolCallXml("Let me check. <tool:list_dir>{\"path\":\".\"}</tool:list_dir> then read it").?;
    try std.testing.expectEqualStrings("list_dir", b.name);
    try std.testing.expectEqualStrings("{\"path\":\".\"}", b.args);
    // no args -> {}; not a tool -> null
    try std.testing.expectEqualStrings("{}", toolCallXml("<tool:list_swarms></tool:list_swarms>").?.args);
    try std.testing.expect(toolCallXml("just chatting, no tools") == null);
}

test "loopIsDone recognizes only a bare completion signal, not prose that mentions done" {
    try std.testing.expect(loopIsDone("DONE"));
    try std.testing.expect(loopIsDone("done"));
    try std.testing.expect(loopIsDone("  DONE. "));
    try std.testing.expect(loopIsDone("Complete"));
    try std.testing.expect(loopIsDone("GOAL COMPLETE"));
    // a real next-message that merely contains "done" must NOT halt the loop
    try std.testing.expect(!loopIsDone("Now that the intro is done, add a pricing section."));
    try std.testing.expect(!loopIsDone("Are we done with the outline?"));
    try std.testing.expect(!loopIsDone(""));
}

test "runCall parses the AI's RUN: shell door" {
    try std.testing.expectEqualStrings("dir", runCall("RUN: dir").?);
    try std.testing.expectEqualStrings("git status", runCall("RUN: git status").?);
    // a short preamble above the RUN line is tolerated (mirrors toolCall)
    try std.testing.expectEqualStrings("ls -la", runCall("Sure, let me look.\nRUN: ls -la").?);
    // strips a markdown code fence marker / bullet
    try std.testing.expectEqualStrings("echo hi", runCall("* RUN: echo hi").?);
    // not a command line -> null; empty command -> null; buried deep -> null (narration)
    try std.testing.expect(runCall("just chatting about running things") == null);
    try std.testing.expect(runCall("RUN:") == null);
    try std.testing.expect(runCall("a\nb\nc\nd\ne\nRUN: too_deep") == null);
}

test "jsonStrInto unescapes; extractToolResult picks the right field" {
    var out: [256]u8 = undefined;
    // newlines + escaped quotes survive
    try std.testing.expectEqualStrings("line1\nsaid \"hi\"", jsonStrInto("{\"result\":\"line1\\nsaid \\\"hi\\\"\"}", "result", &out).?);
    try std.testing.expect(jsonStrInto("{\"ok\":true}", "result", &out) == null);
    // extractToolResult precedence: result > findings > err > raw body
    try std.testing.expectEqualStrings("hey", extractToolResult("{\"ok\":true,\"result\":\"hey\"}", &out));
    try std.testing.expectEqualStrings("synth", extractToolResult("{\"ok\":true,\"findings\":\"synth\"}", &out));
    try std.testing.expectEqualStrings("not found", extractToolResult("{\"ok\":false,\"err\":\"not found\"}", &out));
    // list_swarms has no string field -> raw body handed back
    const raw = "{\"ok\":true,\"tool\":\"list_swarms\",\"swarms\":[]}";
    try std.testing.expectEqualStrings(raw, extractToolResult(raw, &out));
}

test "hasRealId distinguishes real ids from placeholders" {
    try std.testing.expect(hasRealId("{\"id\":\"3dd9cc6d\"}"));
    try std.testing.expect(!hasRealId("{}"));
    try std.testing.expect(!hasRealId("{\"id\":\"\"}"));
    try std.testing.expect(!hasRealId("{\"id\":\"current\"}"));
}

test "queryWeak catches missing/placeholder web_search queries" {
    try std.testing.expect(queryWeak("{}")); // no query field
    try std.testing.expect(queryWeak("{\"query\":\"\"}"));
    try std.testing.expect(queryWeak("{\"query\":\"...\"}"));
    try std.testing.expect(queryWeak("{\"query\":\"   \"}"));
    try std.testing.expect(!queryWeak("{\"query\":\"Zig 0.16 release\"}"));
}

test "userWantsCast detects explicit cast requests" {
    try std.testing.expect(userWantsCast("cast a swarm to research AI regulation"));
    try std.testing.expect(userWantsCast("Run the hive on this problem"));
    try std.testing.expect(userWantsCast("spin up a swarm that builds a CLI"));
    try std.testing.expect(userWantsCast("deploy a swarm for the news"));
    try std.testing.expect(!userWantsCast("what is the capital of France?"));
    try std.testing.expect(!userWantsCast("tell me about swarms of bees")); // target but no cast verb
    try std.testing.expect(!userWantsCast("run to the store")); // verb but no swarm/hive
}

test "castGoalFromUser strips the cast preamble" {
    var b: [1600]u8 = undefined;
    try std.testing.expectEqualStrings("research AI regulation news", castGoalFromUser("cast a swarm to research AI regulation news", &b));
    try std.testing.expectEqualStrings("build a REST API", castGoalFromUser("spin up a swarm that build a REST API", &b));
    // no clear separator → keep the whole message
    try std.testing.expectEqualStrings("run the hive", castGoalFromUser("run the hive", &b));
}

test "castProviderId routes a cast to the chat's configured backend (local vs BYOK vs custom)" {
    try std.testing.expectEqualStrings("ollama", castProviderId(0, 0)); // local Ollama chat -> local swarm
    try std.testing.expectEqualStrings("openai", castProviderId(2, 0)); // custom OpenAI-compatible URL
    // BYOK: the exact catalog provider the user chats with flows straight to the swarm
    try std.testing.expectEqualStrings("anthropic", castProviderId(1, 0));
    try std.testing.expectEqualStrings("openai", castProviderId(1, 1));
    try std.testing.expectEqualStrings("ollama", castProviderId(1, 2));
    try std.testing.expectEqualStrings("groq", castProviderId(1, 4));
    // the two providers added for BYO Cloudflare + Hugging Face route by their catalog key
    try std.testing.expectEqualStrings("workers-ai", castProviderId(1, 3));
    const hf = for (catalog.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "huggingface")) break i;
    } else unreachable;
    try std.testing.expectEqualStrings("huggingface", castProviderId(1, @intCast(hf)));
}

test "resolveBase substitutes the Cloudflare {account}, falls back to the sentinel, and passes others through" {
    var out: [256]u8 = undefined;
    const cf = for (&catalog.providers) |*p| {
        if (std.mem.eql(u8, p.key, "workers-ai")) break p;
    } else unreachable;
    // account id spliced into the template
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1", catalog.resolveBase(cf, "abc123", &out));
    // whitespace trimmed
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1", catalog.resolveBase(cf, "  abc123 \n", &out));
    // no account → the "cloudflare" sentinel (server uses its own included creds)
    try std.testing.expectEqualStrings("cloudflare", catalog.resolveBase(cf, "", &out));
    // a non-templated provider passes its base_url through untouched
    const oa = &catalog.providers[1]; // openai
    try std.testing.expectEqualStrings("https://api.openai.com/v1", catalog.resolveBase(oa, "ignored", &out));
}

test "a BYOK Hugging Face chat resolves the router endpoint + hf model + token" {
    const hf_idx: u8 = for (catalog.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "huggingface")) break @intCast(i);
    } else unreachable;
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    store.settings.chat_kind = 1;
    store.settings.chat_byok = hf_idx;
    const model = "meta-llama/Llama-3.3-70B-Instruct";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = @intCast(model.len);
    const key = "hf_abc123";
    @memcpy(store.settings.chat_key[0..key.len], key);
    store.settings.chat_key_len = @intCast(key.len);

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = undefined, .gpa = std.testing.allocator, .store = store };
    var bb: [256]u8 = undefined;
    var kb: [192]u8 = undefined;
    var mb: [96]u8 = undefined;
    const prov = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expectEqualStrings("https://router.huggingface.co/v1", prov.base_url);
    try std.testing.expectEqualStrings("meta-llama/Llama-3.3-70B-Instruct", prov.model);
    try std.testing.expectEqualStrings("hf_abc123", prov.key);
    try std.testing.expectEqualStrings("huggingface", castProviderId(1, hf_idx));
}

test "a BYO Cloudflare chat builds the account URL from the saved account id" {
    const cf_idx: u8 = for (catalog.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "workers-ai")) break @intCast(i);
    } else unreachable;
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    store.settings.chat_kind = 1;
    store.settings.chat_byok = cf_idx;
    const acct = "deadbeef00";
    @memcpy(store.settings.cf_account[0..acct.len], acct);
    store.settings.cf_account_len = @intCast(acct.len);
    const model = "@cf/meta/llama-3.1-8b-instruct";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = @intCast(model.len);

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = undefined, .gpa = std.testing.allocator, .store = store };
    var bb: [256]u8 = undefined;
    var kb: [192]u8 = undefined;
    var mb: [96]u8 = undefined;
    const prov = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/deadbeef00/ai/v1", prov.base_url);
    // with no account id, the same provider yields the sentinel so the server uses its own creds
    store.settings.cf_account_len = 0;
    const prov2 = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expectEqualStrings("cloudflare", prov2.base_url);
}

test "a BYOK-OpenAI chat resolves an OpenAI cast (base_url + chat model + key); a local chat resolves Ollama" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    // user chatting with OpenAI (BYOK): provider index 1 = "openai"
    store.settings.chat_kind = 1;
    store.settings.chat_byok = 1;
    const model = "gpt-4.1";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;
    const key = "sk-live-abc123";
    @memcpy(store.settings.chat_key[0..key.len], key);
    store.settings.chat_key_len = @intCast(key.len);

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    var bb: [256]u8 = undefined;
    var kb: [192]u8 = undefined;
    var mb: [96]u8 = undefined;
    const prov = chat.resolveProvider(&bb, &kb, &mb);
    // the cast will carry EXACTLY the OpenAI endpoint + the chat's model + the chat's key
    try std.testing.expectEqualStrings("https://api.openai.com/v1", prov.base_url);
    try std.testing.expectEqualStrings("gpt-4.1", prov.model);
    try std.testing.expectEqualStrings("sk-live-abc123", prov.key);
    try std.testing.expectEqualStrings("openai", castProviderId(store.settings.chat_kind, store.settings.chat_byok));

    // flip to local Ollama: same code now routes to the local backend + local model, no key
    store.settings.chat_kind = 0;
    const local_model = "gpt-oss:20b";
    @memcpy(store.settings.chat_model[0..local_model.len], local_model);
    store.settings.chat_model_len = local_model.len;
    const prov2 = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expect(std.mem.indexOf(u8, prov2.base_url, "11434") != null);
    try std.testing.expectEqualStrings("gpt-oss:20b", prov2.model);
    try std.testing.expectEqualStrings("ollama", castProviderId(store.settings.chat_kind, store.settings.chat_byok));
}

test "parseMaxCtx pulls the largest loaded context_length from an /api/ps body" {
    const ps = "{\"models\":[{\"name\":\"gpt-oss:20b\",\"size_vram\":3812873994,\"context_length\":131072}]}";
    try std.testing.expectEqual(@as(u32, 131072), Chat.parseMaxCtx(ps));
    const ok = "{\"models\":[{\"name\":\"gpt-oss:20b\",\"context_length\":8192}]}";
    try std.testing.expectEqual(@as(u32, 8192), Chat.parseMaxCtx(ok));
    try std.testing.expectEqual(@as(u32, 0), Chat.parseMaxCtx("{\"models\":[]}")); // nothing loaded
    // multiple models → the largest wins (the one that would dominate VRAM)
    const two = "{\"models\":[{\"context_length\":4096},{\"context_length\":131072}]}";
    try std.testing.expectEqual(@as(u32, 131072), Chat.parseMaxCtx(two));
}

test "noteWithoutCast drops exactly the tag line" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("On it - casting the hive.", noteWithoutCast("CAST: goal\nOn it - casting the hive.", &b));
    try std.testing.expectEqualStrings("", noteWithoutCast("CAST: goal", &b));
    try std.testing.expectEqualStrings("Preamble.\nAfter.", noteWithoutCast("Preamble.\nCAST: goal\nAfter.", &b));
}

test "jStr and jInt read the deploy response" {
    var b: [64]u8 = undefined;
    const body = "{\"ok\":true,\"id\":\"a1b2c3d4e5f60708\",\"state\":\"running\",\"minds\":3}";
    try std.testing.expectEqualStrings("a1b2c3d4e5f60708", jStr(body, "id", &b).?);
    try std.testing.expectEqual(@as(i64, 3), jInt(body, "minds").?);
}

test "composeConsoleResult keeps stdout then stderr, and always the status note" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("outerr", composeConsoleResult(&buf, "out", "err", ""));
    try std.testing.expectEqualStrings("(no output)", composeConsoleResult(&buf, "", "", ""));
    try std.testing.expectEqualStrings("hi(stopped)", composeConsoleResult(&buf, "hi", "", "(stopped)"));
    // when the body alone would overflow, room is reserved so the note (e.g. a timeout) still survives
    var small: [12]u8 = undefined;
    const note = "(timed out)"; // 11 bytes
    const r = composeConsoleResult(&small, "xxxxxxxxxxxxxxxxxxxx", "", note);
    try std.testing.expect(std.mem.endsWith(u8, r, note));
    try std.testing.expect(r.len <= small.len);
}

// A tiny harness for the async-console tests: a Chat wired to a throwaway data dir. Caller owns teardown.
const ConsoleTestCtx = struct {
    threaded: *std.Io.Threaded,
    store: *Store,
    chat: *Chat,
    fn init(dd: []const u8, dead_endpoint: bool) ConsoleTestCtx {
        const a = std.testing.allocator;
        const threaded = a.create(std.Io.Threaded) catch unreachable;
        threaded.* = std.Io.Threaded.init(a, .{ .environ = llm.osEnviron() });
        const tio = threaded.io();
        _ = Io.Dir.cwd().createDirPathStatus(tio, dd, .default_dir) catch {};
        var vb: [256]u8 = undefined;
        const vd = std.fmt.bufPrint(&vb, "{s}/.veil-desk/chats", .{dd}) catch unreachable;
        _ = Io.Dir.cwd().createDirPathStatus(tio, vd, .default_dir) catch {};
        const store = a.create(Store) catch unreachable;
        store.* = .{};
        @memcpy(store.settings.data_dir[0..dd.len], dd);
        store.settings.data_dir_len = @intCast(dd.len);
        if (dead_endpoint) {
            const base = "http://127.0.0.1:1/v1"; // a follow-up turn's curl goes nowhere
            @memcpy(store.settings.chat_base[0..base.len], base);
            store.settings.chat_base_len = base.len;
        }
        const chat = a.create(Chat) catch unreachable;
        chat.* = .{ .io = tio, .gpa = a, .store = store };
        return .{ .threaded = threaded, .store = store, .chat = chat };
    }
    fn io(self: *ConsoleTestCtx) Io {
        return self.threaded.io();
    }
    /// Pump the console loop until the in-flight command finalizes (bounded so a stuck test can't hang).
    fn drain(self: *ConsoleTestCtx, dd: []const u8) void {
        var i: usize = 0;
        while (self.chat.console != null and i < 400) : (i += 1) {
            self.chat.pumpConsole(dd);
            if (self.chat.console == null) break;
            self.io().sleep(.{ .nanoseconds = 25 * std.time.ns_per_ms }, .awake) catch {};
        }
    }
    fn deinit(self: *ConsoleTestCtx, dd: []const u8) void {
        const a = std.testing.allocator;
        if (self.chat.console) |*p| p.child.kill(self.io());
        Io.Dir.cwd().deleteTree(self.io(), dd) catch {};
        self.threaded.deinit();
        a.destroy(self.chat);
        a.destroy(self.store);
        a.destroy(self.threaded);
    }
};

fn consoleScrollHas(store: *Store, ai: bool, needle: []const u8) bool {
    const s = if (ai) store.console_ai[0..store.console_ai_len] else store.console_you[0..store.console_you_len];
    return std.mem.indexOf(u8, s, needle) != null;
}

test "micro-console: a You command runs async (non-blocking), streams its output, and clears busy" {
    const dd = "zig-console-you-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    ctx.chat.consoleStart(dd, false, "echo neuron-db-console-probe");
    // launched but NOT yet finished — proves it did not block the caller
    try std.testing.expect(ctx.chat.console != null);
    try std.testing.expect(ctx.store.console_busy_you);
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null); // finalized
    try std.testing.expect(!ctx.store.console_busy_you); // busy cleared
    try std.testing.expect(consoleScrollHas(ctx.store, false, "neuron-db-console-probe"));
}

test "micro-console: a command that overruns its wall-clock deadline is killed and reported" {
    const dd = "zig-console-timeout-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    const longcmd = if (builtin.os.tag == .windows) "ping -n 20 127.0.0.1" else "sleep 20";
    ctx.chat.consoleStart(dd, false, longcmd);
    try std.testing.expect(ctx.chat.console != null);
    ctx.chat.console.?.deadline_s = ctx.chat.nowS() - 1; // force the deadline into the past
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null); // killed + finalized
    try std.testing.expect(!ctx.store.console_busy_you);
    try std.testing.expect(consoleScrollHas(ctx.store, false, "timed out"));
}

test "micro-console: the Stop button (console_cancel) interrupts a running command" {
    const dd = "zig-console-cancel-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    const longcmd = if (builtin.os.tag == .windows) "ping -n 20 127.0.0.1" else "sleep 20";
    ctx.chat.consoleStart(dd, false, longcmd);
    try std.testing.expect(ctx.chat.console != null);
    ctx.chat.console_cancel = true; // what the .console_cancel command sets
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null);
    try std.testing.expect(!ctx.store.console_busy_you);
    try std.testing.expect(consoleScrollHas(ctx.store, false, "stopped"));
}

test "micro-console: an AI RUN: command folds its output back as a [console] message" {
    const dd = "zig-console-ai-tmp";
    var ctx = ConsoleTestCtx.init(dd, true);
    defer ctx.deinit(dd);
    ctx.chat.cmdNewConv(dd); // an active conversation for the fold to append into
    ctx.chat.consoleStart(dd, true, "echo neuron-db-ai-probe");
    try std.testing.expect(ctx.store.console_busy_ai);
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null);
    try std.testing.expect(!ctx.store.console_busy_ai);
    var found = false;
    {
        ctx.store.lock();
        defer ctx.store.unlock();
        var k: usize = 0;
        while (k < ctx.store.msg_count) : (k += 1) {
            const txt = ctx.store.msgs[k].textStr();
            if (std.mem.indexOf(u8, txt, "[console]") != null and std.mem.indexOf(u8, txt, "neuron-db-ai-probe") != null) found = true;
        }
    }
    try std.testing.expect(found);
    // tear down the follow-up turn's stream (foldConsoleAi started one against the dead endpoint)
    llm.abort(&ctx.chat.stream, ctx.io());
    ctx.chat.stream.deinit(std.testing.allocator);
    ctx.chat.turn = .idle;
}
