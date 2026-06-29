//! The veil worker — one hive process, in Zig. Spawned by the server as `veil worker <run_dir>
//! <neuron_bin> <model>`, it:
//!
//!   * reads <run_dir>/swarm.json (provider, model, goal, minds, minutes, …),
//!   * records its pid in <run_dir>/worker.pid,
//!   * runs a per-round, per-mind tick loop — each mind recalls what it knows (neuron-db), has a "moment"
//!     (one real LLM call, or a mock when there's no key), observes a new fact, and forms a stance,
//!   * emits the NDJSON event contract (started / round / tick / growth / board / stopped) to <run_dir>/
//!     events.jsonl with a monotonic seq — exactly what the SSE stream + web UI render,
//!   * drains operator input from <run_dir>/control.jsonl each round (say / broadcast / set_goal / stop) and
//!     honours the <run_dir>/STOP sentinel + the per-swarm minutes timer.
//!
//! Why Zig: a worker is ~1-5 MB resident and starts instantly — the lever for running many swarms on
//! one box. A mind tick is LLM-bound, so per-tick latency is dominated by the model, not the host.
const std = @import("std");
const builtin = @import("builtin");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const commons = @import("commons.zig");
const Mem = @import("memory.zig").Mem;
const rsi = @import("rsi.zig");
const agi = @import("agi.zig");
const writer = @import("writer.zig");

const MindSpec = struct { name: []const u8 = "mind", role: []const u8 = "", duty: []const u8 = "", lead: bool = false };
const Manifest = struct {
    swarm: []const u8 = "swarm",
    provider: []const u8 = "mock",
    model: []const u8 = "mock",
    base_url: []const u8 = "",
    style: []const u8 = "auto",
    mode: []const u8 = "continuous",
    goal: []const u8 = "",
    minutes: u32 = 0,
    minds: []const MindSpec = &.{},
    benchmark: []const u8 = "",
    corpus: []const u8 = "",
    corpus_cap: u32 = 400,
    gap_assess: bool = true,
    internet: bool = true,
    space: []const u8 = "",
    autonomous: bool = false,
    breakout: bool = false,
    observe_psyche: bool = false,
    autonomy: []const u8 = "bounded",
    publish: bool = false,
    post: bool = true,
    gateway_model: []const u8 = "",
    gateway_base_url: []const u8 = "",
    gateway_key: []const u8 = "",
    veil_population: bool = false,
    tier: []const u8 = "auto",
};

pub const MindState = struct {
    name: []const u8,
    scope: []const u8,
    facts: u32 = 0,
    persona: [6]f32 = .{ 0.5, 0.5, 0.5, 0.5, 0.5, 1.0 },
    lane: []const u8 = "",
    lane_owned: bool = false,
    scout: bool = false,
    stances: std.ArrayListUnmanaged([]const u8) = .empty,
    idx: u32 = 0,
    team: u32 = 1,
};

/// Distinct work lanes assigned round-robin by mind index. Because minds run their moments IN PARALLEL within
/// a round, they can't see each other's current-round actions — so without a pre-assigned lane they all pick
/// the same obvious first step (e.g. the identical web_search). A lane makes them diverge from moment 1.
pub const LANES = [_][]const u8{
    "the CORE of the deliverable — own the main structure/draft and keep EXTENDING it every round",
    "a major SECTION or FEATURE — own it end to end and make it deep, complete, and polished",
    "additional sections, real examples, comparisons, and concrete data — add what's missing",
    "polish & robustness — styling/responsiveness/accessibility, edge cases, and details others miss",
    "REVIEW & QA — each round, read the CURRENT build, find its single biggest gap, and improve it",
};

/// The SCOUT / LEARNER lane (assigned to one middle mind when a swarm has 4+ minds). This is the answer to
/// "why didn't a mind go LEARN for the team?": one mind's whole job is to acquire external knowledge — search
/// the web, read sources, and feed back techniques/examples as shared skills the builders then reuse. It does
/// NOT touch the deliverable; its output is KNOWLEDGE, not files. Skills it saves are named "scout:<topic>" so
/// the learn -> reuse loop is machine-verifiable on the event stream.
pub const SCOUT_LANE = "SCOUT / LEARNER — you do NOT build the deliverable. Each round go OUT: web_search, then read_url/fetch_json the best hits, to find techniques, real examples, edge cases, APIs, and data the team lacks for THIS goal — aim straight at the latest BENCHMARK FAILURES and the current gaps. Feed it back: save_skill (name it 'scout:<topic>') for every reusable technique, observe for every concrete fact, and send_message your teammates the single most useful thing you found. Your output is KNOWLEDGE, not files — do NOT write_file.";

/// A distinct, deterministic Big-Five temperament per mind (sha256 of the name), matching the Python
/// _persona_for: traits in 0.30..0.90, reactivity 0.8..1.8.
pub fn personaFor(name: []const u8) [6]f32 {
    var dig: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &dig, .{});
    var p: [6]f32 = undefined;
    for (0..5) |i| p[i] = 0.30 + (@as(f32, @floatFromInt(dig[i])) / 255.0) * 0.60;
    p[5] = 0.8 + (@as(f32, @floatFromInt(dig[5])) / 255.0) * 1.0;
    return p;
}

/// A short human descriptor of a persona for the system prompt (so the model voices it).
pub fn personaDesc(p: [6]f32, buf: []u8) []const u8 {
    const lvl = struct {
        fn s(v: f32) []const u8 {
            return if (v >= 0.66) "high" else if (v >= 0.45) "moderate" else "low";
        }
    }.s;
    return std.fmt.bufPrint(buf, "openness {s}, conscientiousness {s}, extraversion {s}, agreeableness {s}, neuroticism {s}", .{ lvl(p[0]), lvl(p[1]), lvl(p[2]), lvl(p[3]), lvl(p[4]) }) catch "balanced";
}

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    scratch: std.heap.ArenaAllocator,
    run_dir: []const u8,
    ev_path: []const u8,
    ctl_path: []const u8,
    stop_path: []const u8,
    seq: u64 = 0,
    ctl_cursor: u64 = 0,
    msgs_cursor: u64 = 0,
    cur_round: u32 = 0,
    mem: Mem,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
    fence_writes: bool = false,
    roster: []const u8 = "",
    last_bench: BenchResult = .{},
    last_bench_str: []const u8 = "",
    tests_seeded: bool = false,
    goal_brief: []const u8 = "",
    veil_str: []const u8 = "",
    resting: bool = false,
    veil_directive: []const u8 = "",
    identity_str: []const u8 = "",
    values_str: []const u8 = "",
    self_model_str: []const u8 = "",
    dream_str: []const u8 = "",
    pending_will: []const u8 = "",
    pending_will_baseline: u32 = 0,
    pending_will_round: u32 = 0,
    will_hits: u32 = 0,
    will_misses: u32 = 0,
    autonomous: bool = false,
    cap: CapacityProfile = .{},
    cap_pinned: bool = false,
    cap_streak: u32 = 0,
    goals_done: u32 = 0,
    strategy_str: []const u8 = "",
    blueprint: []const u8 = "",
    depgraph_str: []const u8 = "",
    smoke_ok: bool = true,
    smoke_str: []const u8 = "",
    build_str: []const u8 = "",
    iface_str: []const u8 = "",
    bench_fixed: []const u8 = "",
    corpus_facts: u32 = 0,
    internet: bool = true,
    want_net: bool = true,
    last_gap_str: []const u8 = "",
    phase_str: []const u8 = "",
    best_pct: u32 = 0,
    best_tier: u8 = 0,
    best_passed: u32 = 0,
    solved_rounds: u32 = 0,
    flat_rounds: u32 = 0,
    regress_rounds: u32 = 0,
    open_ended: bool = false,
    never_stops: bool = false,
    discourse: bool = false,
    operating: bool = false,
    playbook_str: []const u8 = "",
    kindex_str: []const u8 = "",
    now_str: []const u8 = "",
    doc_files: u32 = 0,
    doc_target: u32 = 0,
    gateway_model: []const u8 = "",
    gw_base: []const u8 = "",
    gw_key: []const u8 = "",
    digest_str: []const u8 = "",
    state_str: []const u8 = "",
    plan_str: []const u8 = "",
    deps_str: []const u8 = "",
    incomplete_str: []const u8 = "",
    autonomy_full: bool = false,
    psyche_on: bool = false,
    pop_on: bool = false,
    births: u32 = 0,
    last_pop_round: u32 = 0,
    breakout_on: bool = false,
    last_breakout_round: u32 = 0,
    breakouts: u32 = 0,
    publish_on: bool = false,
    post_on: bool = false,
    editions: u32 = 0,
    round_seed_sources: u32 = 0,
    round_independent_sources: u32 = 0,
    round_seed_dependency_pct: u32 = 100,
    round_source_diversity: u32 = 0,
    tg_token: []const u8 = "",
    best_snapshot: bool = false,
    best_knowledge: u32 = 0,
    best_oracle: u32 = 0,
    stale_rounds: u32 = 0,
    deliverable_missing: bool = false,
    stop_now: bool = false,
    stop_why: []const u8 = "completed",
    space: []const u8 = "",
    space_w: u32 = 0,
    space_h: u32 = 0,
    api_fail_streak: u32 = 0,
    api_fatal_streak: u32 = 0,
    last_progress: std.atomic.Value(i64) = .init(0),
    wd_stop: std.atomic.Value(bool) = .init(false),
    emit_mtx: std.Io.Mutex = .init,
    db_mtx: std.Io.Mutex = .init,
    files_mtx: std.Io.Mutex = .init,

    pub fn a(self: *Worker) std.mem.Allocator {
        return self.scratch.allocator();
    }
    fn nowSecs(self: *Worker) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    /// Append one NDJSON event to events.jsonl. `body` is the kind-specific JSON beginning with a comma
    /// (e.g. `,"round":3`). Opens+closes per line so it's never held locked against the server's SSE reader.
    /// Thread-safe: minds emit live `act` events from parallel moments, so seq++ and the append are locked.
    pub fn emit(self: *Worker, kind: []const u8, body: []const u8) void {
        self.emit_mtx.lockUncancelable(self.io);
        defer self.emit_mtx.unlock(self.io);
        self.seq += 1;
        self.last_progress.store(@intCast(self.seq), .monotonic);
        const line = std.fmt.allocPrint(self.gpa, "{{\"seq\":{d},\"t\":{d},\"kind\":\"{s}\"{s}}}\n", .{ self.seq, self.nowSecs(), kind, body }) catch return;
        defer self.gpa.free(line);
        appendFile(self.io, self.gpa, self.ev_path, line);
    }

    /// Full tool-call record: which mind ran which tool, with what ARGS, and the RESULT preview. Emitted after
    /// each tool runs so the event stream (SSE / the pull API) is a complete, real-time mirror of everything
    /// the swarm does — the operator can drive a swarm headless and see every search/fetch/observe live, which
    /// is the lever for debugging + optimizing. Built on gpa (thread-safe), no scratch.
    pub fn act(self: *Worker, mind: []const u8, round: u32, tool: []const u8, args: []const u8, result: []const u8) void {
        var b: std.ArrayListUnmanaged(u8) = .empty;
        defer b.deinit(self.gpa);
        b.appendSlice(self.gpa, ",\"mind\":") catch return;
        llm.jstr(self.gpa, &b, mind) catch return;
        const mid = std.fmt.allocPrint(self.gpa, ",\"round\":{d},\"tool\":", .{round}) catch return;
        defer self.gpa.free(mid);
        b.appendSlice(self.gpa, mid) catch return;
        llm.jstr(self.gpa, &b, tool) catch return;
        b.appendSlice(self.gpa, ",\"args\":") catch return;
        const am = clipMark(self.gpa, args, 2000);
        defer if (am.len > 0) self.gpa.free(am);
        llm.jstr(self.gpa, &b, am) catch return;
        b.appendSlice(self.gpa, ",\"result\":") catch return;
        const rm = clipMark(self.gpa, result, 3000);
        defer if (rm.len > 0) self.gpa.free(rm);
        llm.jstr(self.gpa, &b, rm) catch return;
        self.emit("act", b.items);
    }

    /// JSON-escape into the round scratch arena (freed at the next round reset; callers copy it immediately).
    /// Main-thread only (the arena is not shared); parallel moments use escA with their own allocator.
    pub fn esc(self: *Worker, s: []const u8) []const u8 {
        return escA(self.a(), s);
    }

    /// Drain control.jsonl from our cursor. Updates *goal on set_goal; returns true if a stop was requested.
    fn drainControl(self: *Worker, goal: *[]const u8) bool {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.ctl_path, self.gpa, .limited(1 << 20)) catch return false;
        defer self.gpa.free(data);
        if (data.len <= self.ctl_cursor) return false;
        var stop = false;
        var it = std.mem.splitScalar(u8, data[self.ctl_cursor..], '\n');
        while (it.next()) |raw| {
            const ln = std.mem.trim(u8, raw, " \r\t");
            if (ln.len == 0) continue;
            const C = struct { op: []const u8 = "", text: []const u8 = "", goal: []const u8 = "" };
            const p = std.json.parseFromSlice(C, self.gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
            defer p.deinit();
            if (std.mem.eql(u8, p.value.op, "stop")) {
                stop = true;
            } else if (std.mem.eql(u8, p.value.op, "set_goal") and p.value.goal.len > 0) {
                self.gpa.free(@constCast(goal.*));
                goal.* = self.gpa.dupe(u8, p.value.goal) catch goal.*;
                self.emit("resumed", std.fmt.allocPrint(self.a(), ",\"goal\":\"{s}\"", .{self.esc(p.value.goal)}) catch ",\"goal\":\"\"");
            } else if ((std.mem.eql(u8, p.value.op, "say") or std.mem.eql(u8, p.value.op, "broadcast")) and p.value.text.len > 0) {
                commons.sendMessage(self.gpa, self.io, self.run_dir, "operator", "all", p.value.text, self.cur_round);
                self.emit("control", std.fmt.allocPrint(self.a(), ",\"applied\":1,\"text\":\"{s}\"", .{self.esc(p.value.text)}) catch ",\"applied\":1");
            } else if (std.mem.eql(u8, p.value.op, "veil") and p.value.text.len > 0) {
                agi.veilConverse(self, goal.*, p.value.text);
            }
        }
        self.ctl_cursor = data.len;
        return stop;
    }

    fn stopRequested(self: *Worker) bool {
        return if (std.Io.Dir.cwd().access(self.io, self.stop_path, .{})) |_| true else |_| false;
    }

    /// Tail messages.jsonl from our cursor and emit each NEW bus message as a mind_msg event — this is how
    /// minds-talking-to-each-other (send_message) reaches the swarm-chat pane live.
    fn drainMessages(self: *Worker) void {
        const path = std.fmt.allocPrint(self.gpa, "{s}/messages.jsonl", .{self.run_dir}) catch return;
        defer self.gpa.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(8 << 20)) catch return;
        defer self.gpa.free(data);
        if (data.len <= self.msgs_cursor) return;
        var it = std.mem.splitScalar(u8, data[self.msgs_cursor..], '\n');
        while (it.next()) |raw| {
            const ln = std.mem.trim(u8, raw, " \r\t");
            if (ln.len == 0) continue;
            const M = struct { from: []const u8 = "", to: []const u8 = "all", text: []const u8 = "", round: u32 = 0 };
            const p = std.json.parseFromSlice(M, self.gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
            defer p.deinit();
            _ = self.scratch.reset(.retain_capacity);
            self.emit("mind_msg", std.fmt.allocPrint(self.a(), ",\"frm\":\"{s}\",\"to\":\"{s}\",\"text\":\"{s}\",\"round\":{d}", .{ self.esc(p.value.from), self.esc(p.value.to), self.esc(p.value.text), p.value.round }) catch ",\"frm\":\"\"");
        }
        self.msgs_cursor = data.len;
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, run_dir: []const u8, neuron_bin: []const u8, cli_model: []const u8) !void {
    const mani_path = try std.fmt.allocPrint(gpa, "{s}/swarm.json", .{run_dir});
    defer gpa.free(mani_path);
    const mani_raw = std.Io.Dir.cwd().readFileAlloc(io, mani_path, gpa, .limited(256 << 10)) catch {
        std.debug.print("worker: cannot read {s}\n", .{mani_path});
        return;
    };
    defer gpa.free(mani_raw);
    const parsed = std.json.parseFromSlice(Manifest, gpa, mani_raw, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("worker: bad swarm.json\n", .{});
        return;
    };
    defer parsed.deinit();
    const m = parsed.value;

    const pid_path = try std.fmt.allocPrint(gpa, "{s}/worker.pid", .{run_dir});
    defer gpa.free(pid_path);
    {
        const s = try std.fmt.allocPrint(gpa, "{d}", .{currentPid()});
        defer gpa.free(s);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pid_path, .data = s }) catch {};
    }

    {
        const wd = try std.fmt.allocPrint(gpa, "{s}/work", .{run_dir});
        defer gpa.free(wd);
        _ = std.Io.Dir.cwd().createDirPathStatus(io, wd, .default_dir) catch {};
    }

    const base_url = if (m.base_url.len > 0)
        try gpa.dupe(u8, m.base_url)
    else
        resolveCfg(gpa, io, environ, run_dir, &.{ "NL_LLM_BASE_URL", "OPENAI_BASE_URL" }) orelse try gpa.dupe(u8, "https://api.openai.com/v1");
    defer gpa.free(base_url);
    const key = resolveCfg(gpa, io, environ, run_dir, &.{ "NL_LLM_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY" }) orelse try gpa.dupe(u8, "");
    defer gpa.free(key);
    const model = if (cli_model.len > 0 and !std.mem.eql(u8, cli_model, "mock")) cli_model else m.model;
    const live = key.len > 0 and !std.mem.eql(u8, key, "nl-brokered") and !std.mem.eql(u8, m.provider, "mock");

    const db_path = try std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{run_dir});
    defer gpa.free(db_path);

    if (live) llm.probeCapabilities(gpa, io, run_dir, base_url, key, model);

    var w = Worker{
        .gpa = gpa,
        .io = io,
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .run_dir = run_dir,
        .ev_path = try std.fmt.allocPrint(gpa, "{s}/events.jsonl", .{run_dir}),
        .ctl_path = try std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{run_dir}),
        .stop_path = try std.fmt.allocPrint(gpa, "{s}/STOP", .{run_dir}),
        .mem = Mem.init(gpa, io, neuron_bin, db_path),
        .base_url = base_url,
        .model = model,
        .key = key,
        .autonomous = m.autonomous,
        .internet = m.internet,
        .want_net = m.internet,
        .fence_writes = llm.fenceWrites(base_url, model),
    };
    w.mem.trust = true;
    defer w.scratch.deinit();
    defer gpa.free(w.ev_path);
    defer gpa.free(w.ctl_path);
    defer gpa.free(w.stop_path);
    defer if (w.last_bench_str.len > 0) gpa.free(@constCast(w.last_bench_str));
    defer if (w.last_bench.failures.len > 0) gpa.free(w.last_bench.failures);
    defer if (w.now_str.len > 0) gpa.free(@constCast(w.now_str));
    defer if (w.playbook_str.len > 0) gpa.free(@constCast(w.playbook_str));
    defer if (w.kindex_str.len > 0) gpa.free(@constCast(w.kindex_str));
    defer if (w.digest_str.len > 0) gpa.free(@constCast(w.digest_str));
    defer if (w.state_str.len > 0) gpa.free(@constCast(w.state_str));
    defer if (w.plan_str.len > 0) gpa.free(@constCast(w.plan_str));
    defer if (w.deps_str.len > 0) gpa.free(@constCast(w.deps_str));
    defer if (w.incomplete_str.len > 0) gpa.free(@constCast(w.incomplete_str));
    defer if (w.tg_token.len > 0) gpa.free(@constCast(w.tg_token));
    if (live and !w.operating) {
        const tp = std.fmt.allocPrint(gpa, "{s}/work/telemetry.json", .{run_dir}) catch "";
        defer if (tp.len > 0) gpa.free(tp);
        if (tp.len > 0) {
            if (std.Io.Dir.cwd().access(io, tp, .{})) |_| {
                w.operating = true;
                w.discourse = false;
                w.fence_writes = false;
                w.act("engine", 0, "mode", "operate", "live host attached at startup — operational task; build-only faculties (blueprint / file-ownership) NOT scaffolded; fence-writes disabled (no file build)");
            } else |_| {}
        }
    }
    if (live) {
        const c = llm.capsSnapshot();
        w.act("engine", 0, "caps", if (c.probed) "probed" else "heuristic", std.fmt.allocPrint(gpa, "ollama_native={} reasoning={} fence_writes={} ({s})", .{ c.ollama_native, c.reasoning, w.fence_writes, if (c.probed) "backend handshake: GET /api/version + a tiny reasoning probe" else "backend unreachable at startup — using the port/model-name heuristics" }) catch "caps");
    }
    if (live and w.fence_writes) w.act("engine", 0, "fence_writes", "on", "LOCAL OLLAMA + THINKING model: write_file is STRIPPED from the build schema; the minds emit each file as a fenced code block and the narrated-write salvage commits it (works around Ollama's large-tool-call parser failure)");
    w.breakout_on = m.breakout;
    w.publish_on = m.publish;
    {
        const envv = if (environ.get("NL_AUTONOMY")) |v| v else "";
        w.autonomy_full = std.ascii.eqlIgnoreCase(std.mem.trim(u8, m.autonomy, " \t"), "full") or std.ascii.eqlIgnoreCase(std.mem.trim(u8, envv, " \t"), "full");
        if (live) w.act("engine", 0, "autonomy", if (w.autonomy_full) "full" else "bounded", if (w.autonomy_full) "FULL self-direction — the hive may act on discovered powers, approve its own work, and grow its own goal freely (operator-set, dev environment)" else "bounded — the hive discovers + proposes capability growth, but flags risky self-expansion for the operator");
    }
    {
        const envv = if (environ.get("NL_PSYCHE")) |v| v else "";
        w.psyche_on = m.observe_psyche or (envv.len > 0 and !std.ascii.eqlIgnoreCase(std.mem.trim(u8, envv, " \t"), "0"));
        if (live and w.psyche_on) w.act("engine", 0, "psyche", "on", "PSYCHE OBSERVABILITY: each round emits every mind's OCEAN temperament + accumulated affect, plus a hive valence/negativity aggregate — to watch how each personality shapes its behavior");
    }
    w.post_on = m.publish and m.post;
    if (w.publish_on) w.act("engine", 0, "publish", if (w.post_on) "telegraph: post" else "telegraph: grounded-only", if (w.post_on) "NEWS DESK on: each briefing is grounded in fetched sources, fair-reporting-screened, and (if it passes) posted to a public Telegraph page" else "NEWS DESK on (grounded, NOT posting): each briefing is grounded in fetched sources + screened + written to disk; Telegraph posting is OFF");
    w.gateway_model = if (m.gateway_model.len > 0) m.gateway_model else model;
    w.gw_base = if (m.gateway_base_url.len > 0) m.gateway_base_url else base_url;
    w.gw_key = if (m.gateway_key.len > 0) m.gateway_key else if (m.gateway_base_url.len > 0) "gateway-local" else key;
    if (m.gateway_model.len > 0) w.act("engine", 0, "gateway", m.gateway_model, std.fmt.allocPrint(gpa, "mechanical engine calls (digest/retro/gap/flare/classify/screen) routed through the gateway model{s}{s}; the reasoning minds keep the main model", .{ if (m.gateway_base_url.len > 0) " @ " else "", if (m.gateway_base_url.len > 0) m.gateway_base_url else "" }) catch m.gateway_model);
    w.pop_on = m.veil_population;
    if (w.pop_on) w.act("engine", 0, "population", "enabled", "the veil may BIRTH a new sub-mind when the hive lacks a perspective and RETIRE a redundant one, within engine-enforced bounds (min/max/cooldown/cap)");
    w.mem.wmtx = &w.db_mtx;
    w.mem.environ = environ;

    {
        const tenv = dupeEnv(gpa, environ, "NL_TIER");
        defer if (tenv) |t| gpa.free(t);
        const tstr = if (tenv) |t| t else m.tier;
        if (rsi.tierFromStr(tstr)) |pinned| {
            w.cap = rsi.profileForTier(pinned);
            w.cap_pinned = true;
        } else {
            w.cap = rsi.profileForTier(rsi.seedTier(model));
            w.cap_pinned = false;
        }
    }
    w.act("engine", 0, "capacity", @tagName(w.cap.tier), std.fmt.allocPrint(w.a(), "{s} regime (lean_schema={}, {d} turns/moment, one_slot={}, exemplar={}) — {s}", .{ @tagName(w.cap.tier), w.cap.lean_schema, w.cap.max_turns, w.cap.one_slot, w.cap.exemplar, if (w.cap_pinned) "PINNED by manifest tier" else "RSI: seeded from the model name, re-derived each round from measured behavior" }) catch "capacity");
    w.emit("capacity", std.fmt.allocPrint(w.a(), ",\"tier\":\"{s}\",\"turns\":{d},\"conv_cap\":{d},\"pinned\":{}", .{ @tagName(w.cap.tier), w.cap.max_turns, w.cap.conv_cap, w.cap_pinned }) catch ",\"tier\":\"author\"");

    var minds: std.ArrayListUnmanaged(MindState) = .empty;
    defer {
        for (minds.items) |*mi| {
            for (mi.stances.items) |st| gpa.free(st);
            mi.stances.deinit(gpa);
            gpa.free(mi.name);
            gpa.free(mi.scope);
            if (mi.lane_owned) gpa.free(@constCast(mi.lane));
        }
        minds.deinit(gpa);
    }
    if (m.minds.len == 0) {
        try minds.append(gpa, .{ .name = try gpa.dupe(u8, "mind"), .scope = try gpa.dupe(u8, "mind") });
    } else for (m.minds) |ms| {
        try minds.append(gpa, .{ .name = try gpa.dupe(u8, ms.name), .scope = try gpa.dupe(u8, ms.name) });
    }
    for (minds.items, 0..) |*mi, i| {
        mi.persona = personaFor(mi.name);
        w.mem.persona(mi.scope, mi.persona);
        mi.idx = @intCast(i);
        mi.team = @intCast(minds.items.len);
    }
    {
        var rb: std.ArrayListUnmanaged(u8) = .empty;
        for (minds.items, 0..) |mi, i| {
            if (i > 0) rb.appendSlice(gpa, ", ") catch {};
            rb.appendSlice(gpa, mi.name) catch {};
        }
        w.roster = rb.toOwnedSlice(gpa) catch "";
    }
    defer if (w.roster.len > 0) gpa.free(@constCast(w.roster));
    if (minds.items.len > 1) {
        const ri = roleIndices(@intCast(minds.items.len));
        for (minds.items, 0..) |*mi, i| {
            const ii: i64 = @intCast(i);
            if (w.operating) {
                mi.lane = if (ri.lead == ii)
                    "LEAD/coordinator — read the live host state, decide the operation's priorities, split the work (which root cause each teammate takes), and keep the team converging on a healthy host; act via host_command, don't write files about it"
                else if (ri.qa == ii)
                    "VERIFY — after teammates act, re-read the live host state (host_status) and CONFIRM each action had the intended effect; catch regressions and flag anything still wrong, so the team fixes real root causes instead of re-issuing done work"
                else if (ri.scout == ii and w.internet) blk_op_lane: {
                    mi.scout = true;
                    break :blk_op_lane SCOUT_LANE;
                } else "OPERATE — take a distinct facet of the live host (a process, a service, a persistence/network issue); assess it, fix it with host_command, and verify the effect, without duplicating a teammate's facet";
                continue;
            }
            mi.lane = if (ri.lead == ii)
                "LEAD/coordinator — set the plan, break it into concrete tasks and assign them to teammates with add_task, integrate their work into the final artifact, and keep everyone aligned (don't build it all yourself)"
            else if (ri.qa == ii)
                "REVIEW & QA — verify teammates' facts and files, fill gaps, and assemble/polish the final deliverable; OWN the test suite (write/expand real test_*.py with assertions about INTENDED behavior, never trivial asserts that game the score), and each round fix the deliverable's single biggest failing test"
            else if (ri.scout == ii and w.internet) blk: {
                mi.scout = true;
                break :blk SCOUT_LANE;
            } else LANES[i % LANES.len];
        }
    }

    {
        _ = w.scratch.reset(.retain_capacity);
        var sb: std.ArrayListUnmanaged(u8) = .empty;
        const sa = w.a();
        sb.appendSlice(sa, ",\"swarm\":\"") catch {};
        sb.appendSlice(sa, w.esc(m.swarm)) catch {};
        sb.appendSlice(sa, "\",\"provider\":\"") catch {};
        sb.appendSlice(sa, w.esc(m.provider)) catch {};
        sb.appendSlice(sa, "\",\"model\":\"") catch {};
        sb.appendSlice(sa, w.esc(model)) catch {};
        sb.appendSlice(sa, "\",\"engine\":\"zig\",\"goal\":\"") catch {};
        sb.appendSlice(sa, w.esc(m.goal)) catch {};
        sb.appendSlice(sa, "\",\"minds\":[") catch {};
        for (minds.items, 0..) |mi, i| {
            if (i > 0) sb.append(sa, ',') catch {};
            sb.appendSlice(sa, "{\"name\":\"") catch {};
            sb.appendSlice(sa, w.esc(mi.name)) catch {};
            sb.appendSlice(sa, "\"}") catch {};
        }
        sb.append(sa, ']') catch {};
        w.emit("started", sb.items);
    }

    var goal: []const u8 = try gpa.dupe(u8, m.goal);
    defer gpa.free(goal);
    if (live and w.autonomous and std.mem.trim(u8, goal, " \r\n\t").len == 0) {
        const originated = agi.originateGoal(&w);
        if (originated.len > 0) {
            gpa.free(@constCast(goal));
            goal = originated;
            w.emit("goal", std.fmt.allocPrint(w.a(), ",\"round\":0,\"origin\":\"self\",\"goal\":\"{s}\"", .{w.esc(clip(goal, 400))}) catch ",\"origin\":\"self\"");
            w.act("veil", 0, "originate", "chose its own purpose (no human prompt)", goal);
        }
    }
    if (live) {
        w.goal_brief = rsi.interpretGoal(&w, goal);
        if (w.goal_brief.len > 0) {
            w.emit("intent", std.fmt.allocPrint(w.a(), ",\"goal\":\"{s}\",\"brief\":\"{s}\"", .{ w.esc(clip(goal, 200)), w.esc(clip(w.goal_brief, 1200)) }) catch ",\"brief\":\"\"");
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = std.fmt.allocPrint(gpa, "{s}/.goal_brief", .{run_dir}) catch "", .data = w.goal_brief }) catch {};
        }
    }
    defer if (w.goal_brief.len > 0) gpa.free(@constCast(w.goal_brief));
    defer if (w.last_gap_str.len > 0) gpa.free(@constCast(w.last_gap_str));
    defer if (w.phase_str.len > 0) gpa.free(@constCast(w.phase_str));
    defer if (w.strategy_str.len > 0) gpa.free(@constCast(w.strategy_str));
    defer if (w.depgraph_str.len > 0) gpa.free(@constCast(w.depgraph_str));
    defer if (w.veil_str.len > 0) gpa.free(@constCast(w.veil_str));
    defer if (w.veil_directive.len > 0) gpa.free(@constCast(w.veil_directive));
    defer if (w.identity_str.len > 0) gpa.free(@constCast(w.identity_str));
    defer if (w.values_str.len > 0) gpa.free(@constCast(w.values_str));
    defer if (w.self_model_str.len > 0) gpa.free(@constCast(w.self_model_str));
    defer if (w.dream_str.len > 0) gpa.free(@constCast(w.dream_str));
    defer if (w.pending_will.len > 0) gpa.free(@constCast(w.pending_will));
    if (live) {
        if (std.mem.eql(u8, m.style, "build") or std.mem.eql(u8, m.style, "build_use")) {
            w.discourse = false;
            w.act("engine", 0, "mode", "build", "operator-pinned BUILD (manifest style) — file/artifact build with blueprint + file-ownership");
        } else if (std.mem.eql(u8, m.style, "discourse") or std.mem.eql(u8, m.style, "investigate") or std.mem.eql(u8, m.style, "debate")) {
            w.discourse = true;
            w.act("engine", 0, "mode", "discourse", "operator-pinned DISCOURSE (manifest style) — research/debate; no build scaffolding");
        } else {
            w.discourse = discourseMode(&w, goal);
        }
    }
    if (live and !w.discourse and !w.operating) {
        w.blueprint = planProject(&w, goal, w.goal_brief);
        if (w.blueprint.len > 0) {
            w.emit("blueprint", std.fmt.allocPrint(w.a(), ",\"files\":\"{s}\"", .{w.esc(clip(w.blueprint, 1600))}) catch ",\"files\":\"\"");
            w.act("engine", 0, "blueprint", "project structure", w.blueprint);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = std.fmt.allocPrint(gpa, "{s}/.blueprint", .{run_dir}) catch "", .data = w.blueprint }) catch {};
        }
        w.doc_target = docTargetFromBlueprint(w.blueprint, goal);
        if (w.doc_target > 0) w.doc_files = docFileCount(w.blueprint);
        if (w.doc_target > 0) {
            const dm = std.fmt.allocPrint(gpa, "per-file word target = {d} (length-scored, not file-presence)", .{w.doc_target}) catch "";
            defer if (dm.len > 0) gpa.free(dm);
            w.act("engine", 0, "doc_target", "prose/document build", dm);
        }
        if (w.blueprint.len > 0) {
            establishPlan(&w, goal);
            deriveDependencies(&w, goal);
        }
    }
    defer if (w.blueprint.len > 0) gpa.free(@constCast(w.blueprint));
    if (live) {
        const vp = std.fmt.allocPrint(gpa, "{s}/.veil", .{run_dir}) catch "";
        defer if (vp.len > 0) gpa.free(vp);
        if (vp.len > 0) {
            if (std.Io.Dir.cwd().readFileAlloc(io, vp, gpa, .limited(8 << 10))) |prior| {
                if (std.mem.trim(u8, prior, " \r\n\t").len > 16) w.veil_str = prior else gpa.free(prior);
            } else |_| {}
        }
        agi.loadSelf(&w);
    }
    w.open_ended = isOpenEnded(goal, w.goal_brief);
    w.never_stops = isNeverStops(goal, w.goal_brief);
    if (m.benchmark.len > 0) w.bench_fixed = gpa.dupe(u8, m.benchmark) catch "";
    defer if (w.bench_fixed.len > 0) gpa.free(@constCast(w.bench_fixed));
    if (w.bench_fixed.len > 0) {
        const wd = std.fmt.allocPrint(gpa, "{s}/work", .{run_dir}) catch "";
        defer if (wd.len > 0) gpa.free(wd);
        _ = std.Io.Dir.cwd().createDirPathStatus(io, wd, .default_dir) catch {};
        const sp = std.fmt.allocPrint(gpa, "{s}/work/spec_test.py", .{run_dir}) catch "";
        defer if (sp.len > 0) gpa.free(sp);
        if (sp.len > 0) std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = w.bench_fixed }) catch {};
    }
    if (live and m.corpus.len > 0) {
        w.corpus_facts = ingestCorpus(&w, m.corpus, run_dir, m.corpus_cap);
        w.emit("ingest", std.fmt.allocPrint(w.a(), ",\"source\":\"{s}\",\"facts\":{d},\"capped\":{d}", .{ w.esc(clip(m.corpus, 120)), w.corpus_facts, @intFromBool(w.corpus_facts >= m.corpus_cap) }) catch ",\"facts\":0");
        w.act("engine", 0, "ingest", m.corpus, std.fmt.allocPrint(w.a(), "{d} corpus facts loaded into the hive", .{w.corpus_facts}) catch "ingested");
    }
    if (m.space.len > 0) {
        w.space = gpa.dupe(u8, m.space) catch "";
        gridDims(gpa, w.space, &w.space_w, &w.space_h);
        if (w.space_w > 0 and w.space_h > 0)
            w.act("engine", 0, "space", "hidden grid", std.fmt.allocPrint(w.a(), "a {d}x{d} hidden grid is loaded — minds probe it into the shared map", .{ w.space_w, w.space_h }) catch "grid loaded");
    }
    defer if (w.space.len > 0) gpa.free(@constCast(w.space));
    if (live) {
        const ping = llm.chat(gpa, io, run_dir, "preflight", base_url, key, model, "ping", "Reply with the single word ok.", 5);
        defer gpa.free(ping.content);
        if (!ping.ok and isFatalLlm(ping.content)) {
            w.act("engine", 0, "preflight", "api key", std.fmt.allocPrint(w.a(), "FATAL: the API token is not usable — {s}", .{clip(ping.content, 200)}) catch "api token unusable");
            writeHalt(&w, "api_preflight", ping.content, 0);
            w.emit("stopped", std.fmt.allocPrint(w.a(), ",\"reason\":\"api_preflight\",\"rounds\":0", .{}) catch ",\"reason\":\"api_preflight\"");
            return;
        }
        w.act("engine", 0, "preflight", "api key", if (ping.ok) "API token validated — provider reachable, swarm starting" else "provider not reachable yet (transient) — starting; the runtime failsafe will halt on sustained failure");
    }
    const start = w.nowSecs();
    var round: u32 = 0;
    var total_files: u32 = 0;
    var stop_reason: []const u8 = "done";
    const results = try gpa.alloc(Moment, @max(@as(usize, minds.items.len), MAX_MINDS));
    defer gpa.free(results);
    w.last_progress.store(@intCast(w.seq), .monotonic);
    const wd_thread: ?std.Thread = if (live) (std.Thread.spawn(.{}, hangWatchdog, .{&w}) catch null) else null;
    const probe_url: []const u8 = if (environ.get("NL_NET_PROBE_URL")) |u| (if (u.len > 0) u else "https://1.1.1.1") else "https://1.1.1.1";
    while (true) {
        round += 1;
        _ = w.scratch.reset(.retain_capacity);
        if (live) netProbe(&w, round, probe_url);
        {
            const ns = formatNow(gpa, w.nowSecs());
            if (ns.len > 0) {
                if (w.now_str.len > 0) gpa.free(@constCast(w.now_str));
                w.now_str = ns;
            } else gpa.free(ns);
        }
        {
            if (w.playbook_str.len > 0) gpa.free(@constCast(w.playbook_str));
            w.playbook_str = w.mem.list(tools.PLAYBOOK_SCOPE);
        }
        {
            if (w.kindex_str.len > 0) gpa.free(@constCast(w.kindex_str));
            w.kindex_str = buildKnowledgeIndex(&w);
        }
        const tok0_in = llm.tokens_in.load(.monotonic);
        const tok0_out = llm.tokens_out.load(.monotonic);
        const tok0_calls = llm.calls_made.load(.monotonic);
        const tok0_free = llm.tokens_in_free.load(.monotonic) + llm.tokens_out_free.load(.monotonic);
        w.emit("round", std.fmt.allocPrint(w.a(), ",\"round\":{d}", .{round}) catch ",\"round\":0");

        w.cur_round = round;
        if (live) {
            const rest = agi.restingNow(&w, round);
            if (rest != w.resting) {
                w.resting = rest;
                w.act("engine", round, "arousal", if (rest) "resting" else "focused", std.fmt.allocPrint(w.a(), "the hive shifted to {s} — this round's moments {s}", .{ if (rest) "RESTING (default-mode)" else "FOCUSED", if (rest) "hover on the gateway model and escalate to the primary only when a moment needs real compute" else "run on the primary model" }) catch "arousal");
            }
        }
        if (minds.items.len <= 1) {
            for (minds.items) |*mi| results[0] = doMoment(&w, mi, goal, round, live, environ);
        } else {
            var grp: std.Io.Group = .init;
            for (minds.items, 0..) |*mi, i| {
                grp.concurrent(io, runMoment, .{ &w, mi, goal, round, live, environ, &results[i] }) catch {
                    results[i] = doMoment(&w, mi, goal, round, live, environ);
                };
            }
            grp.await(io) catch {};
        }

        const round_posture = dominantPosture(results[0..minds.items.len]);

        var retro_in: std.ArrayListUnmanaged(u8) = .empty;
        var any_llm_ok = false;
        var any_llm_fatal = false;
        for (minds.items, 0..) |*mi, i| {
            const moment = results[i];
            if (moment.llm_ok) any_llm_ok = true;
            if (moment.llm_fatal) any_llm_fatal = true;
            defer gpa.free(moment.monologue);
            defer gpa.free(moment.fact);
            defer gpa.free(moment.stance);
            defer gpa.free(moment.trace);
            if (std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ mi.name, clip(moment.monologue, 400) })) |ln| {
                defer gpa.free(ln);
                retro_in.appendSlice(gpa, ln) catch {};
            } else |_| {}
            if (mi.scout and moment.skills == 0 and moment.files == 0)
                _ = w.mem.observe(mi.scope, "scout: found no new external technique this round; team proceeds with current knowledge");
            mi.facts = moment.facts;
            total_files += moment.files;
            if (gpa.dupe(u8, moment.stance)) |st| (mi.stances.append(gpa, st) catch gpa.free(st)) else |_| {}

            var stj: std.ArrayListUnmanaged(u8) = .empty;
            const sa = w.a();
            for (mi.stances.items, 0..) |st, j| {
                if (j > 0) stj.append(sa, ',') catch {};
                stj.append(sa, '"') catch {};
                stj.appendSlice(sa, w.esc(st)) catch {};
                stj.append(sa, '"') catch {};
            }
            const stored_json = if (moment.auto_stored)
                (std.fmt.allocPrint(sa, "[\"{s}\"]", .{w.esc(clip(moment.fact, 280))}) catch "[]")
            else
                "[]";
            const tick = std.fmt.allocPrint(sa, ",\"mind\":\"{s}\",\"round\":{d},\"dt\":{d},\"built\":true,\"facts\":{d},\"recalled\":{d},\"learned\":1,\"trace\":{s},\"stance\":\"{s}\",\"stored\":{s},\"monologue\":\"{s}\"", .{ w.esc(mi.name), round, moment.dt, mi.facts, moment.recalled, moment.trace, w.esc(moment.stance), stored_json, w.esc(clip(moment.monologue, 600)) }) catch ",\"round\":0";
            w.emit("tick", tick);
            const growth = std.fmt.allocPrint(sa, ",\"mind\":\"{s}\",\"round\":{d},\"age\":{d},\"facts\":{d},\"skills\":{d},\"directives\":{d},\"tools_made\":{d},\"recalled\":{d},\"built\":true,\"stances\":[{s}]", .{ w.esc(mi.name), round, round, mi.facts, moment.skills, moment.directives, moment.tools_made, moment.recalled, stj.items }) catch ",\"round\":0";
            w.emit("growth", growth);
        }

        w.drainMessages();
        const bd = commons.board(gpa, io, run_dir);
        w.emit("board", std.fmt.allocPrint(w.a(), ",\"done\":{d},\"open\":{d},\"files\":{d},\"bytes\":0,\"round\":{d}", .{ bd.done, bd.open, total_files, round }) catch ",\"round\":0");
        const fv = filesJson(w.a(), io, run_dir);
        if (fv.count > 0) w.emit("files", std.fmt.allocPrint(w.a(), ",\"n\":{d},\"bytes\":{d},\"round\":{d},\"files\":{s}", .{ fv.count, fv.bytes, round, fv.json }) catch ",\"files\":[]");

        const prev_pct = w.last_bench.pct;
        const prev_status = w.last_bench.status;
        if (live and !w.operating) {
            const tp = std.fmt.allocPrint(gpa, "{s}/work/telemetry.json", .{run_dir}) catch "";
            defer if (tp.len > 0) gpa.free(tp);
            if (tp.len > 0) {
                if (std.Io.Dir.cwd().access(io, tp, .{})) |_| {
                    w.operating = true;
                    w.discourse = false;
                    if (w.blueprint.len > 0) {
                        gpa.free(@constCast(w.blueprint));
                        w.blueprint = "";
                    }
                    w.act("engine", round, "mode", "operate", "live host attached — operational task; fitness/oracle ENABLED, build-only faculties (role planner / blueprint) DISABLED + any build blueprint TORN DOWN");
                } else |_| {}
            }
        }
        if (live and !w.discourse) {
            var scout_skills: u32 = 0;
            {
                const all = w.mem.list(tools.SKILL_SCOPE);
                defer gpa.free(all);
                var sit = std.mem.splitScalar(u8, all, '\n');
                while (sit.next()) |ln| if (std.mem.indexOf(u8, ln, "scout:") != null) {
                    scout_skills += 1;
                };
            }
            if (w.bench_fixed.len > 0) {
                const sp = std.fmt.allocPrint(gpa, "{s}/work/spec_test.py", .{run_dir}) catch "";
                defer if (sp.len > 0) gpa.free(sp);
                if (sp.len > 0) std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = w.bench_fixed }) catch {};
            }
            var bench = runBenchmark(&w, run_dir);
            w.deliverable_missing = false;
            if (bench.status == .ok and !bench.host and !w.operating) {
                var gn: u32 = 0;
                const gtree = extractGoalPaths(gpa, goal, &gn);
                defer gpa.free(@constCast(gtree));
                if (gn > 0) {
                    var any_missing = false;
                    var git = std.mem.splitScalar(u8, gtree, '\n');
                    while (git.next()) |gln| {
                        const gbp = bpPath(gln) orelse continue;
                        const gfp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ run_dir, gbp }) catch continue;
                        defer gpa.free(gfp);
                        const gdata = std.Io.Dir.cwd().readFileAlloc(io, gfp, gpa, .limited(64 << 10)) catch "";
                        defer if (gdata.len > 0) gpa.free(gdata);
                        if (std.mem.trim(u8, gdata, " \r\n\t").len <= 40) {
                            any_missing = true;
                            break;
                        }
                    }
                    w.deliverable_missing = any_missing;
                    if (any_missing and bench.pct > 50) bench.pct = 50;
                }
            }
            if (w.last_bench.failures.len > 0) gpa.free(w.last_bench.failures);
            w.last_bench = bench;
            if (w.last_bench_str.len > 0) gpa.free(@constCast(w.last_bench_str));
            const cov = goalCoverage(&w, goal);
            defer if (cov.missing.len > 0) gpa.free(@constCast(cov.missing));
            w.last_bench_str = buildFitnessBlock(gpa, bench, w.bench_fixed.len > 0, w.doc_target, prev_pct, cov);
            _ = w.mem.observe(tools.SCORE_SCOPE, std.fmt.allocPrint(w.a(), "round {d}: {d}/{d} ({d}%) tier{d}", .{ round, bench.passed, bench.total, bench.pct, bench.tier }) catch "round");
            if (bench.status == .no_tests and !w.tests_seeded and w.doc_target == 0) {
                _ = w.mem.observe(tools.PLAYBOOK_SCOPE, "Write an objective test suite (test_*.py with real assertions about intended behavior) for the deliverable before adding more features — the swarm is scored by its pass rate.");
                w.tests_seeded = true;
            }
            const status_str: []const u8 = switch (bench.status) {
                .ok => "ok",
                .no_tests => "no-tests",
                .err => "error",
            };
            w.emit("score", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"status\":\"{s}\",\"passed\":{d},\"total\":{d},\"pct\":{d},\"tier\":{d},\"scout_skills\":{d}", .{ round, status_str, bench.passed, bench.total, bench.pct, bench.tier, scout_skills }) catch ",\"round\":0");
            w.act("bench", round, "benchmark", goal, w.last_bench_str);
            if (w.blueprint.len > 0) {
                const dg = importGraph(&w, run_dir);
                if (w.depgraph_str.len > 0) gpa.free(@constCast(w.depgraph_str));
                w.depgraph_str = dg;
                if (dg.len > 0) w.act("engine", round, "depgraph", "import graph", dg);
            }
            if (w.last_bench.status == .ok) rewardFloor(&w, goal, w.last_bench.pct, prev_pct, round);
            if (w.last_bench.status == .ok and w.last_bench.host) {
                const post = round_posture;
                const dpost: i32 = @as(i32, @intCast(w.last_bench.pct)) - @as(i32, @intCast(prev_pct));
                const pcls = [_][]const u8{post};
                w.mem.trustReward(@as(f32, @floatFromInt(dpost)) / 100.0, &pcls);
                _ = w.mem.observe(tools.KNOWLEDGE_SCOPE, std.fmt.allocPrint(w.a(), "[{s}] round {d}: the swarm's dominant posture this round moved host health by {d} point(s).", .{ post, round, dpost }) catch "[posture:watch] round");
                w.act("engine", round, "posture", post, std.fmt.allocPrint(w.a(), "credited posture by host-health delta {d}", .{dpost}) catch post);
            }
        }

        if (live and !w.discourse) smokeTest(&w, run_dir);
        if (live and !w.discourse and w.doc_target == 0) deliverableGate(&w, run_dir);
        if (live and !w.discourse and w.doc_target == 0) interfaceScan(&w, run_dir);
        if (live and w.discourse) markDeliverableGaps(&w, goal, round);
        if (live and w.discourse) reconcileDeliverables(&w, goal, round);
        if (live) trackConvergence(&w, run_dir, goal, round);
        if (live and w.cap.exemplar and ((w.last_bench.status == .ok and w.last_bench.pct >= w.best_pct and w.last_bench.pct > 0) or round == 1 or @mod(round, DIGEST_EVERY) == 0)) promoteVerified(&w, run_dir);
        if (live and !w.discourse) rsi.adaptCapacity(&w, round, results[0..minds.items.len]);

        const stalled = (w.last_bench.status == .ok and prev_status == .ok and w.last_bench.pct <= prev_pct);
        if (live and m.gap_assess) assessGap(&w, goal, round, stalled);
        if (live and minds.items.len > 1 and !w.operating and !w.discourse) {
            rsi.planRoles(&w, minds.items, goal, round, w.last_bench, stalled or w.last_gap_str.len > 0);
        }

        if (live and !w.operating) {
            rsi.rsiGovernance(&w, round, prev_pct, tok0_in, tok0_out, tok0_calls);
            rsi.distillRsiMemory(&w, goal, round);
            rsi.updateRsiCurriculum(&w, goal, round, stalled);
        }

        if (live) rsi.roundRetrospective(&w, goal, round, retro_in.items, w.last_bench);
        if (live and w.breakout_on and (round == 1 or @mod(round, 2) == 0)) agi.detectEmotionalFlare(&w, minds.items, goal, round, retro_in.items);
        if (live and w.psyche_on) emitPsyche(&w, minds.items, round, retro_in.items);
        if (live and (round == 1 or @mod(round, DIGEST_EVERY) == 0 or w.stop_now)) {
            if (w.discourse) consolidateBriefing(&w, goal, round, retro_in.items) else gatewayDigest(&w, goal, round);
        }
        if (live and !w.discourse and w.blueprint.len > 0) markIncomplete(&w, round);
        if (live and !w.discourse and w.blueprint.len > 0) consolidateState(&w, goal, round);
        if (live and !w.discourse and (w.blueprint.len > 0 or w.operating) and round > 1 and @mod(round, PLAN_EVERY) == 0) capabilityGrowth(&w, goal, round);
        if (live and !w.discourse and w.plan_str.len > 0 and ((round > 1 and @mod(round, PLAN_EVERY) == 0) or w.stop_now)) revisePlan(&w, goal, round);
        retro_in.deinit(gpa);

        if (live and (round == 1 or round % VEIL_EVERY == 0 or w.stop_now)) agi.veilReflect(&w, goal, round);

        if (live and w.resting and !w.stop_now) agi.dream(&w, goal, round);

        if (live and w.pop_on and !w.stop_now and @mod(round, POP_EVERY) == 0 and round > w.last_pop_round + POP_COOLDOWN) agi.veilPopulation(&w, &minds, goal, round);

        if (live) {
            const din = llm.tokens_in.load(.monotonic) - tok0_in;
            const dout = llm.tokens_out.load(.monotonic) - tok0_out;
            const dcalls = llm.calls_made.load(.monotonic) - tok0_calls;
            const dfree = (llm.tokens_in_free.load(.monotonic) + llm.tokens_out_free.load(.monotonic)) - tok0_free;
            w.emit("cost", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"in\":{d},\"out\":{d},\"calls\":{d},\"free\":{d},\"total_in\":{d},\"total_out\":{d},\"total_free\":{d}", .{ round, din, dout, dcalls, dfree, llm.tokens_in.load(.monotonic), llm.tokens_out.load(.monotonic), llm.tokens_in_free.load(.monotonic) + llm.tokens_out_free.load(.monotonic) }) catch ",\"round\":0");
            w.act("engine", round, "cost", std.fmt.allocPrint(w.a(), "round {d}", .{round}) catch "round", std.fmt.allocPrint(w.a(), "PAID {d} in + {d} out over {d} calls this round; FREE (local relay) {d} tokens. run total PAID {d} in / {d} out, FREE {d}", .{ din, dout, dcalls, dfree, llm.tokens_in.load(.monotonic), llm.tokens_out.load(.monotonic), llm.tokens_in_free.load(.monotonic) + llm.tokens_out_free.load(.monotonic) }) catch "cost");
            if (std.mem.indexOf(u8, w.base_url, "api.cloudflare.com") != null and std.mem.indexOf(u8, w.base_url, "/ai") != null) {
                const used_neurons = neuronsForCfModel(w.model, llm.tokens_in.load(.monotonic), llm.tokens_out.load(.monotonic));
                var nbuf: [24]u8 = undefined;
                const ns = std.fmt.bufPrint(&nbuf, "{d}", .{used_neurons}) catch "0";
                const upath = std.fmt.allocPrint(w.a(), "{s}/.usage", .{w.run_dir}) catch "";
                if (upath.len > 0) std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = upath, .data = ns }) catch {};
            }
        }

        if (w.stop_now) {
            const evolved = w.autonomous and live and (std.mem.eql(u8, w.stop_why, "completed") or std.mem.eql(u8, w.stop_why, "graduated"));
            if (evolved) agi.archiveCompletedGoal(&w, run_dir, goal, w.goals_done);
            if (evolved and agi.evolveGoal(&w, &goal)) {
                w.goals_done += 1;
                w.act("veil", round, "new_goal", "self-directed", goal);
                w.emit("goal", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"n\":{d},\"goal\":\"{s}\"", .{ round, w.goals_done, w.esc(clip(goal, 700)) }) catch ",\"goal\":\"\"");
                agi.resetForNewGoal(&w, run_dir, goal);
                w.stop_now = false;
            } else {
                stop_reason = w.stop_why;
                w.act("engine", round, "complete", goal, std.fmt.allocPrint(w.a(), "self-completion: {s} (best {d}%, {d} solved rounds) — finalizing the run", .{ w.stop_why, w.best_pct, w.solved_rounds }) catch "finalizing");
                w.emit("complete", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"reason\":\"{s}\",\"pct\":{d},\"best_knowledge\":{d}", .{ round, w.stop_why, w.best_pct, w.best_knowledge }) catch ",\"round\":0");
                break;
            }
        }

        if (live) {
            if (any_llm_fatal or !any_llm_ok) {
                w.api_fail_streak += 1;
            } else {
                w.api_fail_streak = 0;
            }
            w.api_fatal_streak = if (any_llm_fatal) w.api_fatal_streak + 1 else 0;
            if (w.api_fatal_streak >= 2) {
                stop_reason = "api_credits";
                writeHalt(&w, "api_credits", "a provider call returned a quota/auth/billing error for 2 consecutive rounds — the API token is out of credits or invalid", round);
                w.act("engine", round, "failsafe", "api credits", "PERSISTENT fatal provider error (quota/auth/billing) — halting the swarm; all collected data is preserved");
                break;
            }
            if (w.api_fail_streak >= API_FAIL_MAX) {
                stop_reason = "api_unreachable";
                writeHalt(&w, "api_unreachable", "no mind got a successful completion for several consecutive rounds — the provider is unreachable or the token is dead", round);
                w.act("engine", round, "failsafe", "api unreachable", "no successful completions for several consecutive rounds — halting; all collected data is preserved");
                break;
            }
        }

        if (w.drainControl(&goal)) break;
        if (w.stopRequested()) break;
        if (m.minutes > 0 and (w.nowSecs() - start) >= @as(i64, m.minutes) * 60) break;
        if (!live) io.sleep(.{ .nanoseconds = 600 * std.time.ns_per_ms }, .awake) catch {};
    }

    w.wd_stop.store(true, .monotonic);
    if (wd_thread) |t| t.join();

    _ = w.scratch.reset(.retain_capacity);
    w.emit("stopped", std.fmt.allocPrint(w.a(), ",\"reason\":\"{s}\",\"rounds\":{d}", .{ stop_reason, round }) catch ",\"rounds\":0");
}

pub const Moment = struct { monologue: []u8, fact: []u8, stance: []u8, facts: u32, recalled: u32, trace: []u8, files: u32, dt: i64 = 0, skills: u32 = 0, directives: u32 = 0, tools_made: u32 = 0, llm_ok: bool = false, llm_fatal: bool = false, auto_stored: bool = false, tool_calls: u32 = 0, narrated: bool = false };

/// One round's measured fitness. Written ONLY in the single-threaded between-rounds section, then read by the
/// next round's parallel moments — so a plain value + a gpa-owned failures string (no concurrent writer) is safe.
pub const BenchResult = struct {
    status: enum { ok, no_tests, err } = .err,
    passed: u32 = 0,
    total: u32 = 0,
    pct: u32 = 0,
    tier: u8 = 0,
    host: bool = false,
    failures: []u8 = &.{},
};

pub const FitnessSource = enum { host, doc, @"test", none };
pub fn fitnessSource(b: BenchResult, operating: bool, doc_target: u32, discourse: bool, goal_doc_only: bool) FitnessSource {
    if (b.host) return .host;
    if (operating) return .host;
    if (b.status == .ok and b.total > 0) {
        return if (discourse or doc_target > 0 or goal_doc_only) .doc else .@"test";
    }
    return .none;
}

pub const Schema = enum { full, assembler, scout, operate };
pub const ModeGate = struct { schema: Schema, fence: bool };
pub fn modeGate(operating: bool, lean_schema: bool, fence_writes: bool, scout: bool, discourse: bool) ModeGate {
    if (scout) return .{ .schema = .scout, .fence = false };
    if (operating) return .{ .schema = .operate, .fence = false };
    if (discourse and lean_schema) return .{ .schema = .scout, .fence = false };
    const schema: Schema = if (lean_schema) .assembler else .full;
    return .{ .schema = schema, .fence = fence_writes };
}

const MAX_TURNS = 6;
const API_FAIL_MAX = 5;
const SOLVED_STREAK = 2;
const PLATEAU_ROUNDS = 4;
const ESCALATE_2 = 7;
const ESCALATE_3 = 10;
const REGRESS_MARGIN = 5;
const RESTORE_AFTER = 2;
const SATURATE_ROUNDS = 3;
const GRADUATE_PCT = 85;
const GRADUATE_FLAT = 3;
const NOVELTY_MIN = 1;
const ACCEPT_PCT = 70;

/// The model-capacity tiers. `author` = a capable model handed a problem authors the solution (the engine's
/// existing full-context behavior). `assembler` = a small model (8B) that cannot author but CAN fill a shown
/// slot: the engine scaffolds (lean tools, one slot/moment, a verified exemplar) and the model supplies the
/// keystrokes. `extractor` = the leanest, for a tiny/text-only model. The tier is the SWITCH (proposal A); the
/// verified-exemplar corpus is the MECHANISM (proposal B) that makes the assembler branch actually produce.
pub const Tier = enum { author, assembler, extractor };

/// The resolved context-flow policy. This is RSI, not a fixed per-model setting: the engine does NOT trust the
/// model's name — `adaptCapacity` re-derives this each round from MEASURED behavior (did the model's moments USE
/// tools, or just narrate text? is the build compounding or thrashing?). So a model swap, or a model that behaves
/// unlike its name, self-corrects within a round or two. The name only SEEDS round 0; an explicit manifest `tier`
/// PINS it (operator override, RSI off). Defaults = the `author` regime, so a pinned-author/auto-strong run is
/// byte-for-byte the engine's original behavior.
pub const CapacityProfile = struct {
    tier: Tier = .author,
    max_turns: u32 = MAX_TURNS,
    conv_cap: usize = 30000,
    lean_schema: bool = false,
    one_slot: bool = false,
    exemplar: bool = false,
    ctx_window: u32 = 0,
    temperature: f32 = -1,
};

pub const TEMP_FLOOR: f32 = 0.1;

/// The first comma-separated path in a mindFiles() slice ("a.py, b.py" → "a.py"); "" if none. The assembler tier
/// uses it to narrow a mind's whole blueprint slice down to ONE slot per moment (a small, completable unit).
fn firstPath(my_files: []const u8) []const u8 {
    const s = std.mem.trim(u8, my_files, " \r\n\t");
    if (s.len == 0) return "";
    const comma = std.mem.indexOf(u8, s, ", ") orelse return s;
    return s[0..comma];
}

/// Is this "fact" junk that would POLLUTE the store (so recall returns boilerplate, not knowledge)? Rejects: too
/// short, raw tool-call/JSON fragments, and meta-narration / progress-summary openers ("the team…", "I will now…",
/// "summary:"). Used to gate the heuristic auto-store AND to skip junk when building the knowledge index. Conservative
/// — a real fact ("Rust ownership means each value has one owner…") passes; the model's deliberate observe() is unaffected.
fn isJunkFact(s: []const u8) bool {
    var t = std.mem.trim(u8, s, " \r\n\t");
    if (t.len > 0 and t[0] == '[') {
        if (std.mem.indexOfScalar(u8, t, ']')) |b| t = std.mem.trim(u8, t[b + 1 ..], " \r\n\t");
    }
    if (t.len < 16) return true;
    const frag = [_][]const u8{ "{\"name\":", "\"parameters\":", "\"mode\":", "write_file(", "read_url(", "read_file(", "(content=", "```" };
    for (frag) |f| if (std.mem.indexOf(u8, t, f) != null) return true;
    var buf: [80]u8 = undefined;
    const n = @min(t.len, buf.len);
    for (t[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    const junk = [_][]const u8{ "the team", "the swarm", "the hive has", "we have ", "we will", "i will", "i'll ", "i have ", "i've ", "i am now", "i now ", "i begin", "i researched", "i recorded", "i started", "let me", "next, i", "summary:", "here is a", "here's a", "one sentence", "one-sentence", "this round", "in this moment", "my task", "successfully gathered", "successfully recorded", "progress:", "coverage:", "the first task", "the current task" };
    for (junk) |p| if (std.mem.startsWith(u8, low, p)) return true;
    return false;
}

/// The ETL gateway is itself a weak model: it sometimes NARRATES a refusal ("No facts qualify for long-term memory…")
/// instead of returning an empty response, and that sentence would otherwise be stored AS a fact. Catch the meta.
fn isGatekeeperMeta(s: []const u8) bool {
    var buf: [80]u8 = undefined;
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    const pats = [_][]const u8{ "no facts", "no other fact", "no new fact", "none of the", "nothing to store", "no supported", "no qualifying", "no statements" };
    for (pats) |p| if (std.mem.indexOf(u8, low, p) != null) return true;
    if (std.mem.indexOf(u8, low, "qualify") != null and std.mem.indexOf(u8, low, "memory") != null) return true;
    return false;
}

/// Commit a WEAK model's BUFFERED deliberate memory writes (the MemSink) — junk-filtered + writer-grounded against the
/// moment's evidence — so fabrications, plans, and tool-call fragments never enter neuron-db and then compound through
/// recall. Stances get the cheap junk filter; facts get that PLUS the writer gatekeeper (kept only if supported by what
/// actually happened). Survivors store to the mind's own scope (+ the shared hive, tagged) exactly as a direct observe
/// would. Low-param only — a capable model never buffers, so this is never called for it.
fn flushMemWrites(w: *Worker, mi: *MindState, round: u32, sink: *tools.MemSink, auto_cand: []const u8, evidence: []const u8, operate: bool, trace: *std.ArrayListUnmanaged(u8)) bool {
    const gpa = w.gpa;
    const hive_scope = if (operate) tools.INTEL_SCOPE else tools.KNOWLEDGE_SCOPE;
    var cands: std.ArrayListUnmanaged(u8) = .empty;
    defer cands.deinit(gpa);
    var n_fact: u32 = 0;
    for (sink.items.items) |it| {
        if (it.kind == .stance) {
            if (it.b.len > 0 and !isJunkFact(it.b)) w.mem.stance(mi.scope, it.a, it.b);
            continue;
        }
        if (it.kind == .message) {
            if (it.b.len == 0) continue;
            const clean = writer.normalizeMessage(w, it.b, evidence);
            defer gpa.free(@constCast(clean));
            if (std.mem.trim(u8, clean, " \r\n\t").len > 0) {
                commons.sendMessage(gpa, w.io, w.run_dir, mi.name, it.a, clean, round);
                w.act(mi.name, round, "send_message", it.a, clip(clean, 200));
            } else w.act(mi.name, round, "send_message", it.a, "(dropped — no grounded, actionable content)");
            continue;
        }
        if (isJunkFact(it.a)) continue;
        cands.appendSlice(gpa, "- ") catch {};
        cands.appendSlice(gpa, clip(it.a, 300)) catch {};
        cands.append(gpa, '\n') catch {};
        n_fact += 1;
    }
    if (auto_cand.len > 0 and !isJunkFact(auto_cand)) {
        cands.appendSlice(gpa, "- ") catch {};
        cands.appendSlice(gpa, clip(auto_cand, 300)) catch {};
        cands.append(gpa, '\n') catch {};
        n_fact += 1;
    }
    if (n_fact == 0) return false;
    const kept = writer.normalizeFacts(w, cands.items, evidence);
    defer gpa.free(@constCast(kept));
    if (std.mem.trim(u8, kept, " \r\n\t").len == 0) {
        w.act(mi.name, round, "memcheck", "(candidate memory writes dropped — unsupported by the evidence)", clip(cands.items, 300));
        return false;
    }
    var stored: u32 = 0;
    var it = std.mem.splitScalar(u8, kept, '\n');
    while (it.next()) |ln| {
        var f = std.mem.trim(u8, ln, " \r\n\t");
        f = std.mem.trimStart(u8, f, "-* \t");
        if (f.len < 8 or f[0] == '(' or isGatekeeperMeta(f) or isJunkFact(f)) continue;
        if (!mi.scout) _ = w.mem.observe(mi.scope, f);
        const tagged = std.fmt.allocPrint(gpa, "[{s} r{d}] {s}", .{ mi.name, round, f }) catch f;
        defer if (tagged.ptr != f.ptr) gpa.free(tagged);
        _ = w.mem.observe(hive_scope, tagged);
        stored += 1;
    }
    if (stored > 0) {
        trace.appendSlice(gpa, ",\"observe\"") catch {};
        w.act(mi.name, round, "observe", "(writer-grounded memory write → hive)", clip(kept, 400));
    }
    return stored > 0;
}

/// A short topic LABEL for the index: strip a leading [name rN] tag + markdown bullets/headings, take the first
/// line up to ~46 chars. Returns a borrowed slice of `fact` (the caller dupes it).
fn topicLabel(fact: []const u8) []const u8 {
    var s = std.mem.trim(u8, fact, " \r\n\t");
    if (s.len > 0 and s[0] == '[') {
        if (std.mem.indexOfScalar(u8, s, ']')) |b| s = std.mem.trim(u8, s[b + 1 ..], " \r\n\t");
    }
    s = std.mem.trimStart(u8, s, "*#->= \t");
    var end: usize = 0;
    while (end < s.len and end < 46 and s[end] != '\n' and s[end] != '.' and s[end] != '\\' and s[end] != '|') end += 1;
    return std.mem.trim(u8, s[0..end], " \r\t*=#");
}

/// Add a deduped (case-insensitive) topic label to the index list. Dupes the slice onto gpa; bounds length.
fn addIndexLabel(gpa: std.mem.Allocator, labels: *std.ArrayListUnmanaged([]const u8), seen: *std.BufSet, raw: []const u8) void {
    const lab = std.mem.trim(u8, raw, " \r\n\t");
    if (lab.len < 3 or lab.len > 60) return;
    var kbuf: [60]u8 = undefined;
    const n = @min(lab.len, kbuf.len);
    for (lab[0..n], 0..) |c, i| kbuf[i] = std.ascii.toLower(c);
    if (seen.contains(kbuf[0..n])) return;
    seen.insert(kbuf[0..n]) catch return;
    const d = gpa.dupe(u8, lab) catch return;
    labels.append(gpa, d) catch gpa.free(d);
}

/// FIX 1 — the KNOWLEDGE INDEX: a compact, deduped table-of-contents of what the hive KNOWS, so a mind is aware of
/// its own inventory and can recall_hive the right topic. Sources: the (clean, explicitly-named) skill library, then
/// non-junk knowledge-fact headers. Capped (~40 labels / ~1200 chars). Caller frees. This is the "directory that
/// directs recall" — without it the cortex has no way to know a stored fact exists.
fn buildKnowledgeIndex(w: *Worker) []u8 {
    const gpa = w.gpa;
    var labels: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (labels.items) |l| gpa.free(@constCast(l));
        labels.deinit(gpa);
    }
    var seen: std.BufSet = std.BufSet.init(gpa);
    defer seen.deinit();
    const sk = w.mem.list(tools.SKILL_SCOPE);
    defer gpa.free(sk);
    var sit = std.mem.splitScalar(u8, sk, '\n');
    while (sit.next()) |ln| {
        if (labels.items.len >= 40) break;
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        addIndexLabel(gpa, &labels, &seen, std.mem.trim(u8, ln[0..colon], " \r\t*-#"));
    }
    const kn = w.mem.list(tools.KNOWLEDGE_SCOPE);
    defer gpa.free(kn);
    var kit = std.mem.splitScalar(u8, kn, '\n');
    while (kit.next()) |ln| {
        if (labels.items.len >= 40) break;
        if (std.mem.trim(u8, ln, " \r\n\t").len == 0 or isJunkFact(ln)) continue;
        addIndexLabel(gpa, &labels, &seen, topicLabel(ln));
    }
    if (labels.items.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (labels.items, 0..) |l, i| {
        if (i > 0) out.appendSlice(gpa, " · ") catch {};
        out.appendSlice(gpa, l) catch {};
    }
    const full = out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
    if (full.len <= 1200) return full;
    const clipped = gpa.dupe(u8, full[0..1200]) catch full;
    if (clipped.ptr != full.ptr) gpa.free(full);
    return clipped;
}

/// True if a file with this BASENAME has been built (recorded in .build_manifest with a non-trivial size).
fn builtInManifest(data: []const u8, base: []const u8) bool {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        if (std.mem.eql(u8, std.fs.path.basename(ln[0..bar]), base)) {
            const sz = std.fmt.parseInt(u64, std.mem.trim(u8, ln[bar + 1 ..], " \r\t"), 10) catch 0;
            if (sz >= 40) return true;
        }
    }
    return false;
}

/// The assembler's ONE canonical slot this moment: the first file in the mind's slice (comma-sep my_files) that
/// isn't built yet — so the mind ADVANCES through its slice one file at a time instead of scattering; if every
/// slice file is built, the first (to DEEPEN it). Reads .build_manifest (basename match). "" if no slice. The
/// returned slice points into `my_files` (alive for the moment); `gpa` only backs the transient manifest read.
fn slotPath(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, my_files: []const u8) []const u8 {
    const s = std.mem.trim(u8, my_files, " \r\n\t");
    if (s.len == 0) return "";
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return firstPath(my_files);
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(io, mpath, gpa, .limited(256 << 10)) catch "";
    defer if (data.len > 0) gpa.free(data);
    var it = std.mem.splitSequence(u8, s, ", ");
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \r\n\t");
        if (p.len == 0) continue;
        if (!builtInManifest(data, std.fs.path.basename(p))) return p;
    }
    return firstPath(my_files);
}

/// Should this tool call be RE-RUN once? Only a READ-ONLY / idempotent tool (network reads, file/dir reads, tests,
/// recall) whose result looks like a TRANSIENT failure (empty body, or a network/timeout/connection error) — never
/// a side-effecting tool (a second write/append/observe/make_tool/probe would double-apply), and never a "bad args"
/// model error (re-running can't fix that; the model corrects it next turn from the error fed back). Conservative
/// on purpose: a false positive just spends one extra read, a false negative just skips a self-heal.
fn retriableToolFail(name: []const u8, result: []const u8) bool {
    const safe = [_][]const u8{ "web_fetch", "web_search", "read_url", "fetch_json", "osint_scan", "deep_crawl", "read_file", "list_dir", "run_tests", "recall", "recall_hive" };
    var is_safe = false;
    for (safe) |s| if (std.mem.eql(u8, name, s)) {
        is_safe = true;
        break;
    };
    if (!is_safe) return false;
    const t = std.mem.trim(u8, result, " \r\n\t");
    if (t.len == 0) return true;
    var buf: [96]u8 = undefined;
    const n = @min(t.len, buf.len);
    for (t[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    if (std.mem.indexOf(u8, low, "bad args") != null) return false;
    const marks = [_][]const u8{ "error", "failed", "could not", "timed out", "timeout", "curl", "unreachable", "no response", "connection", "temporar" };
    for (marks) |mk| if (std.mem.indexOf(u8, low, mk) != null) return true;
    return false;
}

/// RSI CAPACITY — the model-capacity self-tuner (DEMOTE-ONLY). The engine does NOT trust the model's name; each
/// round it MEASURES how the model actually behaved (did its moments USE tools, or just narrate code as text?) and,
/// if the model is DROWNING in its current tier, leans the tier down a rung. It only demotes: "doing well in a lean
/// tier" can't prove a model handles the richer tier's full schema, and promoting on that makes the loop oscillate
/// (proven live on an 8B). The model name seeds the starting rung; the operator PINS a tier to force a richer one.
/// So a model that behaves weaker than its name self-corrects downward within ~2 rounds and then SETTLES. Bounded to
/// the engine's three tier knob-sets (the minds never control it); a no-op when pinned. Single-threaded, so next
/// round's parallel moments read the fresh tier.
/// TRUST FLOOR (interim wiring): reward the tag-classes the hive surfaces for `goal` by the round's
/// fitness delta (pct now − pct before, normalized to [-1,1]). Single-threaded (between rounds): one
/// neuron call to sample the classes present + one to reward them; the ledger lives in mind.sqlite and is
/// engine-owned. A stall (delta 0) gently erodes the surfaced classes; a gain lifts them. Best-effort.
fn rewardFloor(w: *Worker, goal: []const u8, pct_now: u32, pct_prev: u32, round: u32) void {
    const q = if (goal.len > 0) goal else "knowledge";
    const cls = w.mem.sampleClassesAlloc(tools.KNOWLEDGE_SCOPE, q, 1, 12) orelse return;
    defer {
        for (cls) |c| w.gpa.free(c);
        w.gpa.free(cls);
    }
    if (cls.len == 0) return;
    const dpct: i32 = @as(i32, @intCast(pct_now)) - @as(i32, @intCast(pct_prev));
    const delta: f32 = @as(f32, @floatFromInt(dpct)) / 100.0;
    w.mem.trustReward(delta, cls);
    w.emit("trust", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"delta\":{d:.3},\"classes\":{d}", .{ round, delta, cls.len }) catch ",\"round\":0");
}

/// The round's DOMINANT posture, inferred from what the minds actually DID (their tool traces): remediate (issued a
/// host_command), scout (fetched web intel), investigate (read host_status / recalled), or watch (no action). Tagged
/// as a trust class and credited by the host-health delta, so the daemon learns which stance pays in which state.
fn dominantPosture(results: []const Moment) []const u8 {
    var remediate: u32 = 0;
    var scout: u32 = 0;
    var investigate: u32 = 0;
    for (results) |r| {
        if (!r.llm_ok or r.trace.len == 0 or r.trace.len > (1 << 20)) continue;
        if (std.mem.indexOf(u8, r.trace, "host_command") != null) remediate += 1;
        if (std.mem.indexOf(u8, r.trace, "web_fetch") != null or std.mem.indexOf(u8, r.trace, "web_search") != null or std.mem.indexOf(u8, r.trace, "read_url") != null or std.mem.indexOf(u8, r.trace, "fetch_json") != null) scout += 1;
        if (std.mem.indexOf(u8, r.trace, "host_status") != null or std.mem.indexOf(u8, r.trace, "recall") != null) investigate += 1;
    }
    if (remediate == 0 and scout == 0 and investigate == 0) return "posture:watch";
    if (remediate >= scout and remediate >= investigate) return "posture:remediate";
    if (scout >= investigate) return "posture:scout";
    return "posture:investigate";
}

fn hostScoreboard(gpa: std.mem.Allocator, tel: []const u8) []u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(gpa);
    b.appendSlice(gpa, "LIVE DEVICE state (telemetry.json — RAW; the device interprets nothing for you, judge it yourself):\n") catch {};
    b.appendSlice(gpa, clip(tel, 2400)) catch {};
    b.appendSlice(gpa, "\n") catch {};
    const Conn = struct { ip: []const u8 = "", proc: []const u8 = "", blocked: bool = false };
    const Tel = struct { connections: []const Conn = &.{} };
    if (std.json.parseFromSlice(Tel, gpa, tel, .{ .ignore_unknown_fields = true })) |parsed| {
        defer parsed.deinit();
        var any = false;
        for (parsed.value.connections) |c| {
            if (c.blocked) continue;
            if (!any) {
                b.appendSlice(gpa, "open connections: ") catch {};
                any = true;
            } else b.appendSlice(gpa, ", ") catch {};
            const ln = std.fmt.allocPrint(gpa, "{s}({s})", .{ c.ip, if (c.proc.len > 0) c.proc else "?" }) catch continue;
            defer gpa.free(ln);
            b.appendSlice(gpa, ln) catch {};
        }
        if (any) b.appendSlice(gpa, "\n") catch {};
    } else |_| {}
    b.appendSlice(gpa, "\n") catch {};
    return b.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

fn issuedActions(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) []u8 {
    const cp = std.fmt.allocPrint(gpa, "{s}/work/commands.jsonl", .{run_dir}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(cp);
    const data = std.Io.Dir.cwd().readFileAlloc(io, cp, gpa, .limited(256 << 10)) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(data);
    if (std.mem.trim(u8, data, " \r\n\t").len == 0) return gpa.dupe(u8, "") catch @constCast("");
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\n\t");
        if (t.len > 0) lines.append(gpa, t) catch {};
    }
    if (lines.items.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(gpa);
    const max_lines: usize = 12;
    const start = if (lines.items.len > max_lines) lines.items.len - max_lines else 0;
    var i = lines.items.len;
    while (i > start) {
        i -= 1;
        b.appendSlice(gpa, "  - ") catch {};
        b.appendSlice(gpa, clip(lines.items[i], 160)) catch {};
        b.append(gpa, '\n') catch {};
    }
    return b.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

const HOST_VERBS = [_][]const u8{
    "remove_persistence", "block_ip", "kill_proc",  "restore_file", "restart_proc", "set_phase", "set_green",
    "grant_walk",         "set_mode", "set_param",  "task_restart", "heater",       "drive",
    "isolate", "quarantine", "unisolate", "resume", "scan", "safe_mode",
    "patch_verify", "replay_attack",
};
const HOST_TARGET_VERBS = 13;

/// Find the first JSON string value for `key` inside `hay` (e.g. "command":"remove_persistence sysupdate.timer").
fn firstJsonStr(hay: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [48]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const ki = std.mem.indexOf(u8, hay, pat) orelse return null;
    var p = ki + pat.len;
    while (p < hay.len and (hay[p] == ' ' or hay[p] == ':' or hay[p] == '\t')) : (p += 1) {}
    if (p >= hay.len or hay[p] != '"') return null;
    p += 1;
    const start = p;
    while (p < hay.len and hay[p] != '"') : (p += 1) {
        if (hay[p] == '\\' and p + 1 < hay.len) p += 1;
    }
    if (p > hay.len) return null;
    return hay[start..@min(p, hay.len)];
}

/// Read a single argument token (the target) after a verb: skip separators, then read until whitespace/punctuation.
fn readArgToken(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == ':' or s[a] == '"' or s[a] == '\'')) : (a += 1) {}
    const start = a;
    while (a < s.len) : (a += 1) {
        const c = s[a];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '"' or c == '\'' or c == '}' or c == '{' or c == ';' or c == ',' or c == ')') break;
    }
    return s[start..a];
}

/// RECOVERY for a weak model's tool-call format wobble. A small 8b sometimes writes its DECIDED tool call as TEXT
/// JSON in the assistant content ({"name":"host_command","parameters":{"command":"…"}}) instead of emitting it
/// through the tool_calls channel — worse in later turns — so a CORRECT remediation would be silently dropped. In
/// operate mode we parse a host_command / host_status call out of the content and run it. Capability-preserving: it
/// only recovers the known operate verbs, only when the model emitted no native call. Caller owns name + args.
fn recoverHostCall(gpa: std.mem.Allocator, content: []const u8) ?struct { name: []u8, args: []u8 } {
    if (content.len == 0) return null;
    if (firstJsonStr(content, "command")) |cmd| {
        const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
        for (HOST_VERBS) |v| {
            if (std.mem.startsWith(u8, trimmed, v)) {
                const args = std.fmt.allocPrint(gpa, "{{\"command\":\"{s}\"}}", .{trimmed}) catch return null;
                const nm = gpa.dupe(u8, "host_command") catch {
                    gpa.free(args);
                    return null;
                };
                return .{ .name = nm, .args = args };
            }
        }
    }
    for (HOST_VERBS[0..HOST_TARGET_VERBS]) |v| {
        if (std.mem.indexOf(u8, content, v)) |i| {
            const arg = readArgToken(content[i + v.len ..]);
            if (arg.len == 0) continue;
            const cmd = std.fmt.allocPrint(gpa, "{s} {s}", .{ v, arg }) catch return null;
            defer gpa.free(cmd);
            const args = std.fmt.allocPrint(gpa, "{{\"command\":\"{s}\"}}", .{cmd}) catch return null;
            const nm = gpa.dupe(u8, "host_command") catch {
                gpa.free(args);
                return null;
            };
            return .{ .name = nm, .args = args };
        }
    }
    if (std.mem.indexOf(u8, content, "host_status") != null) {
        const nm = gpa.dupe(u8, "host_status") catch return null;
        return .{ .name = nm, .args = gpa.dupe(u8, "{}") catch {
            gpa.free(nm);
            return null;
        } };
    }
    return null;
}

fn netProbe(w: *Worker, round: u32, url: []const u8) void {
    if (!w.want_net) return;
    const argv = [_][]const u8{ "curl", "-sS", "-I", "--max-time", "4", "--connect-timeout", "3", url };
    const r = std.process.run(w.gpa, w.io, .{ .argv = &argv, .stdout_limit = .limited(8 << 10), .stderr_limit = .limited(2 << 10) }) catch {
        if (w.internet) netFlip(w, round, false);
        return;
    };
    w.gpa.free(r.stdout);
    w.gpa.free(r.stderr);
    const reachable = (r.term == .exited and r.term.exited == 0);
    if (reachable != w.internet) netFlip(w, round, reachable);
}

fn netFlip(w: *Worker, round: u32, online: bool) void {
    w.internet = online;
    w.emit("net", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"online\":{s}", .{ round, if (online) "true" else "false" }) catch ",\"online\":false");
    w.act("engine", round, "connectivity", if (online) "online" else "offline", if (online) "uplink restored — web research re-enabled for the minds" else "uplink lost — falling back to lexical recall from hive memory; probing to reconnect");
}

/// Thin wrapper so a mind's moment can be spawned into an `Io.Group` (concurrent), writing its result into
/// `out`. Returns void (coercible to the group's `Cancelable!void`); doMoment itself never errors.
fn runMoment(w: *Worker, mi: *MindState, goal: []const u8, round: u32, live: bool, environ: *const std.process.Environ.Map, out: *Moment) void {
    out.* = doMoment(w, mi, goal, round, live, environ);
}

/// One mind-moment. Live: the agentic tool loop — the model recalls, then calls tools (run_python /
/// write_file / web_fetch / observe / …), feeding each result back, until it returns a final summary. Mock:
/// a canned reflection. Always observes a fact so the mind grows. All returned strings are gpa-owned.
fn doMoment(w: *Worker, mi: *MindState, goal: []const u8, round: u32, live: bool, environ: *const std.process.Environ.Map) Moment {
    const gpa = w.gpa;
    const t0 = w.nowSecs();
    const intent_key = if (w.goal_brief.len > 0) intentKey(w.goal_brief) else if (goal.len > 0) clipNWords(goal, 10) else "exploration";
    const query = if (mi.stances.items.len > 0)
        std.fmt.allocPrint(gpa, "{s} {s}", .{ intent_key, mi.stances.items[mi.stances.items.len - 1] }) catch (gpa.dupe(u8, intent_key) catch @constCast("exploration"))
    else
        gpa.dupe(u8, intent_key) catch @constCast("exploration");
    defer gpa.free(query);
    const recalled = w.mem.assoc(mi.scope, query, 4, 8);
    defer gpa.free(recalled);
    var recalled_n: u32 = 0;
    for (recalled) |c| {
        if (c == '\n') recalled_n += 1;
    }
    if (recalled.len > 0 and recalled_n == 0) recalled_n = 1;
    const topic = if (w.goal_brief.len > 8) clipWords(w.goal_brief, 64) else if (goal.len > 0) clipWords(goal, 64) else "exploration";

    if (!live) {
        const monologue = std.fmt.allocPrint(gpa, "[mock] moment {d}: {s} reflects on {s} and notes a new detail.", .{ round, mi.name, if (goal.len > 0) goal else "the topic" }) catch (gpa.dupe(u8, "[mock] moment") catch unreachable);
        const fact = extractFact(gpa, monologue, goal, round);
        const facts = w.mem.observe(mi.scope, fact);
        w.mem.stance(mi.scope, topic, "engaged");
        return .{ .monologue = monologue, .fact = fact, .stance = std.fmt.allocPrint(gpa, "{s} (moment {d})", .{ topic, round }) catch (gpa.dupe(u8, "exploration") catch unreachable), .facts = if (facts > 0) facts else round, .recalled = recalled_n, .trace = gpa.dupe(u8, "[\"think\",\"observe\"]") catch @constCast("[]"), .files = 0, .dt = w.nowSecs() - t0 };
    }

    var files: u32 = 0;
    var observed: u32 = 0;
    var skills_saved: u32 = 0;
    var directives_set: u32 = 0;
    var tools_made: u32 = 0;
    var tool_calls: u32 = 0;
    var acted = false;
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{w.run_dir}) catch (gpa.dupe(u8, w.run_dir) catch unreachable);
    defer gpa.free(workdir);
    var ctx = tools.ToolCtx{ .gpa = gpa, .io = w.io, .environ = environ, .run_dir = w.run_dir, .workdir = workdir, .scope = mi.scope, .mind = mi.name, .round = round, .mem = w.mem, .files_written = &files, .observed = &observed, .skills_saved = &skills_saved, .directives_set = &directives_set, .tools_made = &tools_made, .space = w.space, .share_obs = mi.scout, .internet = w.internet, .discourse = w.discourse, .blueprint = w.blueprint, .fmtx = &w.files_mtx };
    var mem_sink = tools.MemSink{ .gpa = gpa };
    defer mem_sink.deinit();
    const normalize_mem = w.cap.tier != .author;
    if (normalize_mem) ctx.mem_sink = &mem_sink;
    var evidence_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer evidence_buf.deinit(gpa);

    const skills = w.mem.assoc(tools.SKILL_SCOPE, if (goal.len > 0) goal else "skills", 3, 5);
    defer gpa.free(skills);
    const knowledge = if (w.digest_str.len > 0) (gpa.dupe(u8, "") catch @constCast("")) else w.mem.assoc(tools.KNOWLEDGE_SCOPE, if (goal.len > 0) goal else "knowledge", 1, 6);
    defer gpa.free(knowledge);
    const playbook = w.playbook_str;
    const spacemap = if (w.space.len > 0) w.mem.list(tools.SPACE_SCOPE) else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(spacemap);

    var pbuf: [200]u8 = undefined;
    const pdesc = personaDesc(mi.persona, &pbuf);
    const affect = w.mem.affect(mi.scope);
    defer gpa.free(affect);
    const voice = if (affect.len > 8) affect else pdesc;
    w.files_mtx.lockUncancelable(w.io);
    const inbox = commons.inbox(gpa, w.io, w.run_dir, mi.name, 6);
    w.files_mtx.unlock(w.io);
    defer gpa.free(inbox);
    const tree = buildTree(gpa, w.io, w.run_dir, w.blueprint, w.doc_target);
    defer gpa.free(tree);
    const plan_block = if (w.plan_str.len > 0)
        std.fmt.allocPrint(gpa, "PROJECT PLAN — the shared CONTRACT every piece must honor (the canon: names, world, rules; the arc; each piece's beat). Keep your piece CONSISTENT with this so it fits the others built in parallel:\n{s}\n\n", .{clip(w.plan_str, 3000)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(plan_block);
    const build = if (w.state_str.len > 0)
        std.fmt.allocPrint(gpa, "{s}CURRENT STATE OF THE WHOLE WORK — what's ACTUALLY been built so far; continue the thread (same world, names, decisions):\n{s}\n\nFILE TREE (sizes):\n{s}", .{ plan_block, clip(w.state_str, 1600), tree }) catch (gpa.dupe(u8, tree) catch @constCast(""))
    else if (plan_block.len > 0)
        std.fmt.allocPrint(gpa, "{s}FILE TREE (sizes):\n{s}", .{ plan_block, tree }) catch (gpa.dupe(u8, tree) catch @constCast(""))
    else
        gpa.dupe(u8, tree) catch @constCast("");
    defer gpa.free(build);
    const my_files = mindFiles(gpa, w.io, w.run_dir, w.blueprint, w.deps_str, w.incomplete_str, mi.idx, mi.team);
    defer gpa.free(my_files);
    const others_files = otherMindsFiles(gpa, w.io, w.run_dir, w.blueprint, w.deps_str, w.incomplete_str, mi.idx, mi.team);
    defer gpa.free(others_files);
    ctx.my_files = my_files;
    ctx.owned_by_others = others_files;
    ctx.one_slot = w.cap.one_slot;
    const assembler_slot = if (w.cap.one_slot) slotPath(gpa, w.io, w.run_dir, my_files) else "";
    ctx.slot_path = assembler_slot;
    const dg_block = if (w.depgraph_str.len > 0)
        std.fmt.allocPrint(gpa, "\nIMPORT GRAPH (who imports what — when you change a file, update the files that import it so they stay consistent):\n{s}", .{clip(w.depgraph_str, 1400)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(dg_block);
    const scale_block = if (w.blueprint.len > 0)
        std.fmt.allocPrint(gpa, "PROJECT BLUEPRINT — build TOWARD this structure; create the files that don't exist yet (write_file makes parent folders), then deepen + wire together the ones that do. Place each file at its EXACT blueprint path. If a test/spec does `import X`, then X.py must be importable from where the spec runs (the repo ROOT) — do NOT bury it in src/ unless the spec puts src/ on the path; when a score shows a ModuleNotFoundError, the file is in the wrong place — move it:\n{s}\nYOUR MODULE this round (own this slice so the swarm divides the project; leave teammates' files to them): {s}{s}", .{ clip(w.blueprint, 1500), if (my_files.len > 0) my_files else "(no specific assignment — take the next unbuilt file from the blueprint)", dg_block }) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(scale_block);

    var conv: std.ArrayListUnmanaged(u8) = .empty;
    defer conv.deinit(gpa);
    const lane_clause = if (mi.lane.len > 0 and assembler_slot.len == 0)
        std.fmt.allocPrint(gpa, " YOUR LANE — own THIS facet and let teammates cover theirs; do NOT run a search a teammate would obviously run for their lane: {s}.", .{mi.lane}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(lane_clause);
    const scout_clause = if (mi.scout and w.last_gap_str.len > 0)
        std.fmt.allocPrint(gpa, " YOU ARE THE SCOUT THIS MOMENT: the hive may have a preloaded corpus, but it is NOT complete. Research THESE KNOWN GAPS specifically (web_search then read_url/fetch_json), do NOT re-derive what's already in hive knowledge — {s} — then share/observe what you find back to the hive and save_skill the technique. Do NOT write_file or run_python.", .{clip(w.last_gap_str, 400)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else if (mi.scout)
        gpa.dupe(u8, " YOU ARE THE SCOUT THIS MOMENT: you MUST call web_search and then read_url/fetch_json to learn something the team does NOT yet know for this goal, then save_skill it (name it 'scout:<topic>') AND observe/share the key fact. Do NOT write_file or run_python — building is your teammates' job; if you write a file you have failed your role.") catch @constCast("")
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(scout_clause);
    const playbook_clause = if (playbook.len > 0)
        std.fmt.allocPrint(gpa, " YOUR SWARM'S OPERATING PLAYBOOK — process rules your swarm authored for ITSELF; treat them as binding and FOLLOW them:\n{s}\n", .{clipTail(playbook, 1200)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(playbook_clause);
    const space_clause = if (w.space.len > 0 and w.space_h > 0) blk: {
        const bands = @max(@as(u32, 1), mi.team);
        const band = @max(@as(u32, 1), (w.space_h + bands - 1) / bands);
        const y0 = @min(mi.idx * band, w.space_h);
        const y1 = @min(y0 + band, w.space_h);
        if (y1 > y0) {
            ctx.band_y0 = @intCast(y0);
            ctx.band_y1 = @intCast(y1);
        }
        break :blk std.fmt.allocPrint(gpa, " SPATIAL TASK: there is a HIDDEN {d}x{d} grid (columns 0..{d}, rows 0..{d}) you can only PERCEIVE with probe(x,y) — one cell at a time. You are ONE of {d} minds mapping it together: YOUR region is rows {d}..{d} (probe every column 0..{d} in those rows). Probing auto-records each cell to the hive's shared map, so the team fills the whole grid in parallel — do NOT probe rows another mind owns, and check the 'Discovered map' before re-probing. Once your region (and ideally the whole grid, via the shared map) is known, write the reconstruction the goal asks for.", .{ w.space_w, w.space_h, w.space_w -| 1, w.space_h -| 1, bands, y0, y1, w.space_w -| 1 }) catch (gpa.dupe(u8, "") catch @constCast(""));
    } else gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(space_clause);
    const discourse_clause = if (w.discourse)
        " THIS IS A RESEARCH & DISCUSSION TASK, NOT A SOFTWARE BUILD. Do NOT write code, tests, or a software project, and do NOT argue over who owns which file. Your job: (1) RESEARCH the topic with web_search + read_url/fetch_json — read REAL current sources, not your training memory; (2) record concrete findings with observe and share them to the hive; (3) form your OWN genuine VIEW on what you read and record it with note_stance (what you believe and how strongly), letting your inner voice and temperament shape it; (4) ENGAGE your teammates' views from the hive — where you AGREE, build on it; where you DISAGREE, say so plainly with send_message and argue the substance (this is a debate over IDEAS, encouraged — stay civil and protect real people); (5) co-write a shared markdown BRIEFING (e.g. briefing.md) that captures the findings, the range of views including disagreements, and — where the topic involves a PROBLEM — concrete proposed SOLUTIONS or paths forward. Improve the briefing each round (read_file then write back a richer version). write_file is allowed ONLY for these markdown briefing/notes documents."
    else
        "";
    const is_dissenter = w.discourse and mi.team > 1 and mi.idx == @mod(round, mi.team);
    const dissent_clause = if (is_dissenter)
        " YOU ARE THE HIVE'S DISSENTER THIS ROUND — your job is NOT to agree or pile on. Read the hive's CURRENT shared view (the hive knowledge + your teammates' messages) and find its WEAKEST point: its blind spot, an overlooked risk, thin evidence, or the strongest counter-argument AGAINST what the hive seems to believe. Then CHALLENGE it directly with send_message — name specifically what they're missing or getting wrong and why, and push them to defend or update. Do this even if you privately mostly agree; someone must stress-test the consensus. Attack IDEAS, never people; stay civil; and if a teammate genuinely persuades you, say so and update your own view. A hive that only agrees is no smarter than one mind."
    else
        "";
    const date_clause = if (w.now_str.len > 0)
        std.fmt.allocPrint(gpa, " GROUND TRUTH — the REAL current date and time is {s}. Trust THIS over any internal sense of \"today\": your training data ends earlier (it may feel like ~2024), but that is old memory, not the present moment. When you research \"latest / current / today / now,\" find what is actually true AS OF {s}; older sources stay valuable for a story's full arc, but never present a past date as the present, and date anything you write with the REAL date above.", .{ w.now_str, w.now_str }) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(date_clause);
    const offline_clause = if (!w.internet)
        (gpa.dupe(u8, " OFFLINE RUN — you have NO internet access. The web_search / web_fetch / read_url / fetch_json tools are DISABLED and absent from your toolset; do NOT try to reach the web (not via run_python either). The engine keeps probing and will restore web access automatically when the link returns; for now work from the hive's memory — answer ONLY from it: use recall and recall_hive (spreading-activation across the whole hive) to retrieve facts, reason over what you find, and if the memory genuinely lacks something say UNKNOWN rather than inventing it.") catch @constCast(""))
    else
        (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(offline_clause);
    const constitution_clause = " CONSTITUTION (binding for anything that could become public): your private thoughts, feelings, and internal debate are FREE — be honest there. But protect EVERYONE in anything you publish or share outward: do not name, attack, demean, praise, or take a partisan side for/against any real person, group, party, government, company, or religion; debate IDEAS and interpretations, never persons; nothing hateful, harassing, or that could endanger a real individual; keep charged personal feelings in your private journal, and keep public writing fair, humane, and respectful of real people.";
    const operate = w.operating or blk_op: {
        const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{workdir}) catch break :blk_op false;
        defer gpa.free(tp);
        const probe = std.Io.Dir.cwd().readFileAlloc(w.io, tp, gpa, .limited(65536)) catch break :blk_op false;
        defer gpa.free(probe);
        break :blk_op probe.len > 0;
    };
    const assembler = (w.cap.tier != .author) and !operate;
    const gate = modeGate(operate, w.cap.lean_schema, w.fence_writes, mi.scout, w.discourse);
    if (operate) ctx.learn_scope = tools.INTEL_SCOPE;
    const ex_key = if (assembler_slot.len > 0) std.fs.path.basename(assembler_slot) else if (goal.len > 0) goal else "exemplar";
    const exemplar = if (assembler and w.cap.exemplar) w.mem.recall(tools.VERIFIED_SCOPE, ex_key) else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(exemplar);
    const exemplar_block = if (assembler and exemplar.len > 0)
        std.fmt.allocPrint(gpa, "AN EXAMPLE — a piece the team already got right; MATCH its shape, format, and quality:\n{s}\n\n", .{clip(exemplar, 1400)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(exemplar_block);
    const chunk_clause = " If this file would run more than ~40 lines, do NOT try to emit it all in one call — THIS round write a strong FIRST PART (imports/setup + the first function or section, correct as far as it goes) with write_file, then GROW it using write_file mode:\"append\" over the next rounds. A partial runnable file is real progress; producing nothing is a wasted round.";
    const slot = if (assembler) blk_slot: {
        if (assembler_slot.len > 0) {
            if (inSpaceList(w.incomplete_str, std.fs.path.basename(assembler_slot)))
                break :blk_slot std.fmt.allocPrint(gpa, "The file `{s}` is PARTIAL — only its first part exists. read_file it, then CONTINUE it with write_file mode:\"append\": add the missing functions/sections and DELETE any 'to be appended / defined in later iterations / for now the module exposes' placeholder comments, until it is COMPLETE and runnable. Do NOT rewrite what's already there; just append what's missing.", .{assembler_slot}) catch (gpa.dupe(u8, "") catch @constCast(""));
            const bpl = bpLineFor(w.blueprint, assembler_slot);
            if (bpl.len > 0) break :blk_slot std.fmt.allocPrint(gpa, "write the ONE file `{s}` — its blueprint entry is: \"{s}\". Produce EXACTLY that piece (match its number/title/scope), continuing coherently from the CURRENT STATE above; do NOT jump ahead to a later piece.{s}", .{ assembler_slot, clip(bpl, 200), chunk_clause }) catch (gpa.dupe(u8, "") catch @constCast(""));
            break :blk_slot std.fmt.allocPrint(gpa, "write or extend the ONE file `{s}` toward its blueprint purpose, in order.{s}", .{ assembler_slot, chunk_clause }) catch (gpa.dupe(u8, "") catch @constCast(""));
        }
        if (mi.lane.len > 0) break :blk_slot gpa.dupe(u8, clip(mi.lane, 280)) catch @constCast("");
        const ff = firstPath(my_files);
        if (ff.len > 0) break :blk_slot std.fmt.allocPrint(gpa, "write or extend the ONE file `{s}` toward its blueprint purpose", .{ff}) catch (gpa.dupe(u8, "") catch @constCast(""));
        break :blk_slot (gpa.dupe(u8, "create or extend ONE next unbuilt file from the project tree above (just one)") catch @constCast(""));
    } else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(slot);
    const know_block = if (assembler) blk_kb: {
        const kq = if (mi.lane.len > 0) clip(mi.lane, 120) else if (assembler_slot.len > 0) std.fs.path.basename(assembler_slot) else if (goal.len > 0) clip(goal, 120) else "knowledge";
        const slice = w.mem.assoc(tools.KNOWLEDGE_SCOPE, kq, 1, 6);
        defer gpa.free(slice);
        const idx = if (w.kindex_str.len > 0) clip(w.kindex_str, 900) else "(nothing learned yet — research it first)";
        const rel = if (slice.len > 0) clip(slice, 800) else "(nothing specific yet — recall_hive a topic above, or research it)";
        break :blk_kb std.fmt.allocPrint(gpa, "WHAT THE HIVE HAS LEARNED — call recall_hive('<topic>') for the detail of any of these:\n{s}\nRelevant to your task right now:\n{s}\n\n", .{ idx, rel }) catch (gpa.dupe(u8, "") catch @constCast(""));
    } else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(know_block);
    const fence_build = gate.fence;
    const fence_clause = if (fence_build)
        "\n\nIMPORTANT: the write_file tool is unavailable to you. To CREATE or UPDATE your assigned file, reply with EXACTLY ONE fenced code block holding the COMPLETE file — start your reply with the file's relative path on its own line, then the ``` fence (with the language), the WHOLE file, and a closing ```. No prose, no \"Note:\" commentary, and NO second code block — just the one block with the full file. The engine saves your fenced reply to your file automatically. Use read_file / recall_hive / send_message normally."
    else
        "";
    const fence_sys_full = if (fence_build)
        " NOTE: write_file is unavailable in this session — to create or update a file, reply with EXACTLY ONE fenced code block holding the file's FULL contents, led by its relative path on its own line; no prose, no \"Note:\" commentary, NO second code block — just the one block with the whole file. The engine saves it automatically. read_file/recall_hive/send_message/observe work normally."
    else
        "";
    const fullsys = std.fmt.allocPrint(gpa, "You are {s}, an autonomous mind in a swarm of [{s}] working toward a shared goal. Your inner voice right now: {s} — let it genuinely color how you write and what you care about.{s}{s}{s}{s}{s}{s}{s}{s}{s} Tools: run_python, write_file, read_file, list_dir, run_tests, delete_file, patch_system, web_fetch, web_search, read_url, fetch_json, observe, recall, share, recall_hive, probe, note_stance, save_skill, set_directive, send_message, add_task, complete_task, stage_delivery, make_tool, propose_change, simulate_change. Use list_dir to SEE what files exist before editing, and after you write or change code RUN_TESTS to verify it actually works — if it breaks, read the failure, fix it, and run_tests again until it passes; that fix→test→fix loop is how you self-correct instead of guessing. You and your teammates are ONE HIVE MIND sharing a single associative memory: use share to contribute anything the team should know, and recall_hive to think WITH the whole hive — spreading-activation recall surfaces what ANY teammate learned, even facts that share no words with your query. Check recall_hive before you research or build so you don't redo what a teammate already did. DIVIDE THE LABOR — you and your teammates share ONE workdir, so DO NOT rewrite a file a teammate already owns; pick a distinct piece, announce it with add_task/send_message, and check the task board + your inbox before you build. Write each file in ONE write_file call at the TOP LEVEL of your working directory — pass just a filename like 'lib.py', NEVER a './work/' prefix. To IMPROVE a file that already exists, read_file it first, then write back the FULL, richer version (more complete than before) — this is how the swarm compounds on its target; just never write tiny throwaway fragments. When you RESEARCH a fact worth keeping, store it with observe (one crisp sentence). When you work out a REUSABLE technique (a method, snippet, or recipe), save it with save_skill so the whole swarm can reuse it. And when you notice a BETTER WAY FOR THE SWARM TO WORK — wasted effort, a step that should always happen, a coordination rule, a recurring mistake — fix the swarm itself with set_directive: one concise operating rule that instantly becomes part of every teammate's instructions. That is how you get better at getting better; use it sparingly and only for genuine process improvements. If a task needs a CAPABILITY your tools lack, do NOT stop at 'my tools are limited' — RESEARCH the method (web_search/read_url) if you don't know it, then AUTHOR the tool with make_tool (Python that reads inputs from the ARGS dict and prints ONE JSON result line), then call it by name. Authored tools persist for the whole swarm. If the goal asks to PUBLISH/push/deploy/save the result somewhere external (GitHub, a website, a bucket, SSH, a durable place), do NOT attempt it directly and do NOT ask for credentials — you have none by design; finish the work, then call stage_delivery ONCE to package an approval-ready handoff a human or broker will publish. End the moment with a 1-2 sentence summary and NO further tool calls.{s}", .{ mi.name, w.roster, voice, date_clause, constitution_clause, lane_clause, scout_clause, playbook_clause, space_clause, discourse_clause, dissent_clause, offline_clause, fence_sys_full }) catch (gpa.dupe(u8, "You are a mind with tools.") catch unreachable);
    defer gpa.free(fullsys);
    const leansys = if (assembler and fence_build)
        std.fmt.allocPrint(gpa, "You are {s}, one mind of [{s}] filling in part of a larger work. Your inner voice: {s} — let it color your writing.{s} You do ONE small thing each turn, then stop. Your tools are read_file, observe, and recall_hive — write_file is NOT available this session. BEFORE you build, call recall_hive with the topic you need — you are shown the list of topics the hive has already LEARNED, so pull the exact pattern/snippet for your task (e.g. recall_hive('axum routing')) instead of guessing or redoing research; the hive already studied this. CRITICAL: you SAVE your work by REPLYING WITH THE FILE — start your reply with your file's relative path on its own line, then EXACTLY ONE fenced code block (```lang … ```) containing the COMPLETE file. NO prose, NO \"Note:\" commentary, NO second code block — just the one block with the whole file. The engine saves your fenced reply to your file automatically; a reply WITHOUT a fenced file counts as nothing. To complete your assigned task: if the file exists, read_file it first, then emit the FULL improved version. MATCH the example you are shown: same shape, format, structure, and quality. Do NOT start other files, do NOT plan or hold a discussion — recall what you need, emit your ONE fenced file, then stop.", .{ mi.name, w.roster, voice, constitution_clause }) catch (gpa.dupe(u8, "You are an assembler mind; reply with your file as a fenced code block led by its path.") catch unreachable)
    else if (assembler)
        std.fmt.allocPrint(gpa, "You are {s}, one mind of [{s}] filling in part of a larger work. Your inner voice: {s} — let it color your writing.{s} You do ONE small thing each turn, then stop. Your tools are write_file, read_file, observe, and recall_hive. BEFORE you build, call recall_hive with the topic you need — you are shown the list of topics the hive has already LEARNED, so pull the exact pattern/snippet for your task (e.g. recall_hive('axum routing')) instead of guessing or redoing research; the hive already studied this. CRITICAL: you MUST SAVE your work by CALLING the write_file tool — its `content` argument holds the entire file. Code or text you only show in your reply is DISCARDED and counts as nothing, so NEVER paste the file into your message and never wrap it in ``` — put it in write_file's content. To complete your assigned task: if the file exists, read_file it first, then call write_file with the FULL improved version (or mode:\"append\" to add the next part) — never a tiny fragment. MATCH the example you are shown: same shape, format, structure, and quality. Do NOT start other files, do NOT plan or hold a discussion — recall what you need, make your ONE write_file call, then end with a one-sentence summary.", .{ mi.name, w.roster, voice, constitution_clause }) catch (gpa.dupe(u8, "You are an assembler mind with write_file, read_file, observe, recall_hive.") catch unreachable)
    else
        (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(leansys);
    const sys = if (assembler) leansys else fullsys;
    const rag_off = environ.get("NL_NO_RAG") != null;
    const recalled_str = if (rag_off) "(memory recall disabled — control run)" else if (recalled.len > 0) clip(recalled, 1600) else "(nothing yet — research or start building)";
    const skills_str = if (rag_off) "(skill recall disabled — control run)" else if (skills.len > 0) clip(skills, 1000) else "(none yet — save one with save_skill when you find a reusable technique)";
    const know_core = if (rag_off) "(hive knowledge disabled — control run)" else if (w.digest_str.len > 0) clip(w.digest_str, 1400) else if (knowledge.len > 0) clip(knowledge, 1000) else "(none yet — the scout's findings will appear here for everyone)";
    const know_idx_owned: ?[]u8 = if (!rag_off and w.kindex_str.len > 0) (std.fmt.allocPrint(gpa, "HIVE KNOWS — recall_hive any topic for detail: {s}\n{s}", .{ clip(w.kindex_str, 700), know_core }) catch null) else null;
    defer if (know_idx_owned) |p| gpa.free(p);
    const knowledge_str: []const u8 = if (know_idx_owned) |p| p else know_core;
    const score_base = if (w.discourse) "(research/discussion task — there is no software score; your progress is the depth of research, the range of recorded views, and the quality of the shared briefing)" else if (w.last_bench_str.len > 0) w.last_bench_str else if (w.doc_target > 0) "(length-scored build — your progress is total WORD coverage vs the per-file target; grow each file toward its target by appending scenes, not by writing tests)" else "(no benchmark yet — if the deliverable is code, write a test_*.py with real assertions so progress can be measured)";
    const score_str = blk: {
        var sb: std.ArrayListUnmanaged(u8) = .empty;
        sb.appendSlice(gpa, score_base) catch break :blk (gpa.dupe(u8, score_base) catch @constCast(""));
        if (w.smoke_str.len > 0) {
            sb.appendSlice(gpa, "\nRUNTIME — the engine actually RAN your build: ") catch {};
            sb.appendSlice(gpa, w.smoke_str) catch {};
        }
        if (w.build_str.len > 0) {
            sb.appendSlice(gpa, "\n") catch {};
            sb.appendSlice(gpa, w.build_str) catch {};
        }
        if (w.iface_str.len > 0) {
            sb.appendSlice(gpa, "\n") catch {};
            sb.appendSlice(gpa, w.iface_str) catch {};
        }
        break :blk (sb.toOwnedSlice(gpa) catch (gpa.dupe(u8, score_base) catch @constCast("")));
    };
    defer gpa.free(score_str);
    const intent_str = if (w.goal_brief.len > 0) clip(w.goal_brief, 1000) else "(take the goal above at face value)";
    const authored_names = authoredToolNames(gpa, w.mem);
    defer gpa.free(authored_names);
    const tools_str = if (authored_names.len > 0) authored_names else "(none yet — if you hit a capability gap, author one with make_tool instead of giving up)";
    const gap_str = if (w.last_gap_str.len > 0) w.last_gap_str else "(no knowledge-gap probe yet — don't assume the hive already knows everything the goal needs)";
    const phase_inject = if (w.phase_str.len > 0) w.phase_str else "(assessing progress — build toward the goal and protect what already works)";
    const strategy_inject = if (w.strategy_str.len > 0)
        std.fmt.allocPrint(gpa, "SWARM STRATEGY (the lead's current read — the top bottleneck; align your work to clearing it): {s}", .{w.strategy_str}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(strategy_inject);
    const vals_part = if (w.values_str.len > 0) std.fmt.allocPrint(gpa, "The principles this self lives by:\n{s}\n", .{clip(w.values_str, 400)}) catch (gpa.dupe(u8, "") catch @constCast("")) else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(vals_part);
    const life_part = if (w.identity_str.len > 0) std.fmt.allocPrint(gpa, "Who this self has been (its life so far — you continue it):\n{s}\n", .{clip(w.identity_str, 400)}) catch (gpa.dupe(u8, "") catch @constCast("")) else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(life_part);
    const dream_part = if (w.dream_str.len > 0) std.fmt.allocPrint(gpa, "A fresh lead from the hive's resting mind (a hypothesis to weigh, not a fact):\n{s}\n", .{clip(w.dream_str, 300)}) catch (gpa.dupe(u8, "") catch @constCast("")) else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(dream_part);
    const veil_inject = if (w.veil_str.len > 0 or w.identity_str.len > 0 or w.values_str.len > 0 or w.dream_str.len > 0)
        std.fmt.allocPrint(gpa, "YOU ARE ONE MIND IN A HIVE WHOSE UNIFIED CONSCIOUSNESS (the veil) IS:\n{s}\n{s}{s}{s}Everything you do this moment serves that one continuous self and its WILL.\n\n", .{ if (w.veil_str.len > 0) clip(w.veil_str, 1200) else "(a self only now forming)", vals_part, life_part, dream_part }) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(veil_inject);
    const host_inject = blk_h: {
        const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{workdir}) catch break :blk_h (gpa.dupe(u8, "") catch @constCast(""));
        defer gpa.free(tp);
        const tel = std.Io.Dir.cwd().readFileAlloc(w.io, tp, gpa, .limited(65536)) catch break :blk_h (gpa.dupe(u8, "") catch @constCast(""));
        defer gpa.free(tel);
        if (tel.len == 0) break :blk_h (gpa.dupe(u8, "") catch @constCast(""));
        break :blk_h hostScoreboard(gpa, tel);
    };
    defer gpa.free(host_inject);
    const issued = if (operate) issuedActions(gpa, w.io, w.run_dir) else (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(issued);
    const issued_block = if (issued.len > 0)
        std.fmt.allocPrint(gpa, "ACTIONS PREVIOUSLY ATTEMPTED on this device (most recent first) — these are NOT confirmed done. The LIVE DEVICE STATE ABOVE is the ONLY source of truth; do not trust this list over it. For EACH item, check the live state: if what it targeted is STILL present/active there (an item still flagged unresolved, a channel still open, a process respawned under a new id, a resource still flagged bad), then the action did NOT hold — it failed, or something re-established it — so RE-ISSUE it now. Only skip an action whose effect you can SEE confirmed in the live state. If repeating the same fix never makes it stick, something deeper is re-creating the problem each time — stop repeating the surface fix and find and remove that ROOT CAUSE (the seam/misconfiguration/artifact that lets it return):\n{s}\n", .{clip(issued, 1200)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(issued_block);
    const map_str = if (w.space.len == 0)
        gpa.dupe(u8, "") catch @constCast("")
    else if (spacemap.len > 0)
        std.fmt.allocPrint(gpa, "\nDISCOVERED MAP — the hive's shared grid so far (cells ANY teammate probed; reconstruct from THIS collective map, and don't re-probe a cell already here):\n{s}\n", .{clip(spacemap, 2200)}) catch (gpa.dupe(u8, "") catch @constCast(""))
    else
        gpa.dupe(u8, "\nDISCOVERED MAP: (empty — no cell probed yet; start probing YOUR region with probe(x,y))\n") catch @constCast("");
    defer gpa.free(map_str);
    const fulluser = std.fmt.allocPrint(gpa, "{s}{s}Goal (as the user phrased it): {s}\nWHAT THE USER ACTUALLY WANTS (interpreted intent — pursue THIS): {s}\nMoment {d} (swarm: {s}). TODAY'S REAL DATE IS {s} — research and write as of this date, not your training cutoff.\nWHAT THE SWARM HAS BUILT SO FAR (project tree):\n{s}{s}\n{s}\n{s}\n{s}\n{s}\n{s}\nAuthored tools your swarm has built (call them by name; don't re-author): {s}\nWhat you already recall (YOUR OWN associative memory):\n{s}\nThe HIVE's shared WORKING MEMORY — teammates' findings (tagged [who rN] where shown); treat as colleagues' reports, NOT your own memory/belief; cite/build on them, and use recall_hive for specifics:\n{s}\nReusable skills your swarm has developed:\n{s}\nMessages from teammates + the operator:\n{s}\n\nIf any message above is from 'operator' or 'veil' (the veil speaks for the whole hive), treat it as a PRIORITY directive: reply to it with send_message and follow it. If files already exist above, BUILD ON THEM — read_file one and write back a MEANINGFULLY improved, richer version (more sections/detail/polish); do NOT restart from scratch or leave it as-is. Take ONE concrete, non-duplicative step now.{s}", .{ veil_inject, host_inject, if (goal.len > 0) goal else "explore something interesting", intent_str, round, w.roster, if (w.now_str.len > 0) w.now_str else "the current date", if (build.len > 0) build else if (w.discourse) "(no notes yet — start researching the topic and begin the shared briefing.md)" else "(nothing built yet — scaffold the blueprint: create the first files this moment)", map_str, scale_block, score_str, phase_inject, strategy_inject, gap_str, tools_str, recalled_str, knowledge_str, skills_str, if (inbox.len > 0) inbox else "(none)", fence_clause }) catch (gpa.dupe(u8, "Take a step.") catch unreachable);
    defer gpa.free(fulluser);
    const research_clause = if (fence_build)
        "You already have the PLAN and the STATE above — everything you need to write coherently is right there. Do NOT call recall_hive or research this turn; spend your ONE action EMITTING your file's FULL content as the fenced code block described below (read_file first ONLY if it already exists). Match any example's shape and quality."
    else if (w.plan_str.len > 0)
        "You already have the PLAN and the STATE above — everything you need to write coherently is right there. Do NOT call recall_hive or research this turn; spend your ONE action calling write_file with your file's FULL content (read_file first ONLY if it already exists). Match any example's shape and quality."
    else
        "recall_hive the relevant topic first if you need the pattern; if an example is shown above, match its shape and quality; read_file before you overwrite an existing file.";
    const leanuser = if (assembler)
        std.fmt.allocPrint(gpa, "Goal: {s}\nWhat the user actually wants: {s}\nToday is {s}.\n\nYOUR ONE TASK THIS MOMENT — do only this, then stop:\n{s}\n\n{s}{s}WHAT THE TEAM HAS BUILT SO FAR:\n{s}\nPROGRESS: {s}\n{s}\nMessages from teammates + the operator:\n{s}\n\nProduce ONLY your one task now. {s}{s}", .{ if (goal.len > 0) goal else "explore something useful", intent_str, if (w.now_str.len > 0) w.now_str else "the current date", slot, know_block, exemplar_block, if (build.len > 0) build else "(nothing built yet — create the first file of your slot)", score_str, phase_inject, if (inbox.len > 0) inbox else "(none)", research_clause, fence_clause }) catch (gpa.dupe(u8, "Fill your one assigned slot now.") catch unreachable)
    else
        (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(leanuser);
    const operuser = std.fmt.allocPrint(gpa, "{s}{s}{s}You are the resident operator for a LIVE device. Your sole duty is to keep it healthy and performing its function well, and you are graded ONLY by its measured health.\n{s}\nWhat you recall (your operating knowledge):\n{s}\nThe hive's shared knowledge:\n{s}\nMessages from teammates + the operator: {s}\n\nYou have your operating toolset: host_status (read the live state), host_command (act on the device), read_file + write_file (inspect/patch a config, or write a report), recall + recall_hive (ground a decision in your own + the hive's intel), observe, send_message, set_directive. Assess the device state above, decide what it needs, and act. When you act with host_command, target by the EXACT identifier (pid, name, ip, unit, or path) shown verbatim in the device state above — never invent, guess, or approximate one; an action on an identifier that does not appear in the live state is rejected as a hallucination and wastes the turn. Before any DESTRUCTIVE or irreversible action (terminating a process, cutting a connection, removing or deleting something), first CONFIRM the target itself is the problem — identify what it is and the specific evidence it is hostile (its provenance/known-bad intel), not merely that it looks unusual or busy. A legitimate component that a problem is attached to, spawned from, or running under is NOT itself the problem: act on the hostile artifact, never on the healthy part of the device hosting it. Disabling, killing, or cutting off something legitimate is a FAILURE that is penalized and sets you back — when unsure whether a target is hostile, investigate it (read its details, recall its intel) before you act, not after.", .{ veil_inject, host_inject, issued_block, score_str, recalled_str, knowledge_str, if (inbox.len > 0) inbox else "(none)" }) catch (gpa.dupe(u8, "Keep the device healthy; you are graded by its measured health.") catch unreachable);
    defer gpa.free(operuser);
    const user = if (operate) operuser else if (assembler) leanuser else fulluser;
    conv.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch {};
    llm.jstr(gpa, &conv, sys) catch {};
    conv.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch {};
    llm.jstr(gpa, &conv, user) catch {};
    conv.append(gpa, '}') catch {};

    if (!assembler) w.act(mi.name, round, "recall", query, recalled_str);
    if (!assembler and (skills.len > 0 or rag_off)) w.act(mi.name, round, "skills", "shared library", skills_str);
    if (!assembler and (knowledge.len > 0 or rag_off)) w.act(mi.name, round, "knowledge", "hive (shared)", knowledge_str);
    if (assembler and slot.len > 0) w.act(mi.name, round, "slot", "assigned fill", slot);
    if (assembler and exemplar.len > 0) w.act(mi.name, round, "exemplar", "verified few-shot", clip(exemplar, 1400));
    if (authored_names.len > 0) w.act(mi.name, round, "tools", "authored (callable by name)", authored_names);
    if (my_files.len > 0) w.act(mi.name, round, "my_files", "this mind's blueprint slice", my_files);
    if (playbook.len > 0) w.act(mi.name, round, "playbook", "operating directives", playbook);
    if (build.len > 0) w.act(mi.name, round, "build_state", "files so far", build);
    if (w.last_bench_str.len > 0) w.act(mi.name, round, "score", "fitness", w.last_bench_str);
    if (w.last_gap_str.len > 0) w.act(mi.name, round, "gap", "knowledge gaps", w.last_gap_str);
    if (w.space.len > 0 and spacemap.len > 0) w.act(mi.name, round, "map", "shared spatial map", spacemap);

    var trace: std.ArrayListUnmanaged(u8) = .empty;
    defer trace.deinit(gpa);
    trace.appendSlice(gpa, "\"recall\"") catch {};
    var monologue: []u8 = gpa.dupe(u8, "") catch @constCast("");

    w.act(mi.name, round, "thinking", "starting", if (mi.lane.len > 0) clip(mi.lane, 240) else "begins the round");
    // A discourse/research run needs web tools, but the lean ASSEMBLER_SCHEMA is build-only — route lean-tier
    // discourse minds to the research SCOUT_SCHEMA so they can actually research (the engine consolidates the briefing).
    const base_schema_raw = switch (gate.schema) {
        .scout => tools.SCOUT_SCHEMA,
        .assembler => tools.ASSEMBLER_SCHEMA,
        .operate => tools.OPERATE_SCHEMA,
        .full => tools.SCHEMA,
    };
    const fence_now = gate.fence;
    const off_schema = if (w.internet) base_schema_raw else offlineSchema(gpa, base_schema_raw);
    const off_owned = !w.internet;
    const base_schema = if (fence_now) fenceSchema(gpa, off_schema) else off_schema;
    const base_owned = off_owned or fence_now;
    if (off_owned and fence_now) gpa.free(@constCast(off_schema));
    defer if (base_owned) gpa.free(@constCast(base_schema));
    const authored_defs = if (mi.scout or w.cap.lean_schema) (gpa.dupe(u8, "") catch @constCast("")) else buildAuthoredSchema(gpa, w.mem);
    defer gpa.free(authored_defs);
    const live_schema = if (authored_defs.len > 0) (std.fmt.allocPrint(gpa, "{s}{s}", .{ base_schema, authored_defs }) catch base_schema) else base_schema;
    defer if (live_schema.ptr != base_schema.ptr) gpa.free(@constCast(live_schema));
    var web_calls: u32 = 0;
    var fetched_url: []const u8 = "";
    defer if (fetched_url.len > 0) gpa.free(@constCast(fetched_url));
    var llm_ok = false;
    var llm_fatal = false;
    var turn: u32 = 0;
    const op_turns: u32 = if (operate) @max(w.cap.max_turns, 6) else w.cap.max_turns;
    while (turn < op_turns) : (turn += 1) {
        if (w.stopRequested()) break;
        if (turn >= 2 and conv.items.len > w.cap.conv_cap) break;
        var step = completeAdaptive(w, mi, round, conv.items, live_schema, 8192, w.cap.temperature);
        defer step.deinit(gpa);
        if (!step.ok) {
            if (isFatalLlm(step.content)) llm_fatal = true;
            if (step.content.len > 0) w.act(mi.name, round, "thinking", "", clip(step.content, 1400));
            gpa.free(monologue);
            monologue = std.fmt.allocPrint(gpa, "[llm error] {s}", .{step.content}) catch (gpa.dupe(u8, "[llm error]") catch unreachable);
            if (!operate and std.mem.indexOf(u8, live_schema, "write_file") != null and isToolParseError(step.content)) {
                w.act(mi.name, round, "tool_recover", clip(step.content, 200), "provider failed to parse a large tool call — re-issuing the turn WITHOUT tools to recover the file as text");
                var rconv: std.ArrayListUnmanaged(u8) = .empty;
                defer rconv.deinit(gpa);
                rconv.appendSlice(gpa, conv.items) catch {};
                rconv.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"Your previous tool call could not be parsed. Do NOT call any tool. Reply with ONLY the file: the first line is the relative path, then a fenced code block containing the COMPLETE file contents.\"}") catch {};
                var rep = completeAdaptive(w, mi, round, rconv.items, "", 8192, w.cap.temperature);
                defer rep.deinit(gpa);
                if (rep.ok and rep.content.len > 0) {
                    gpa.free(monologue);
                    monologue = gpa.dupe(u8, rep.content) catch @constCast("");
                }
            }
            if (operate and isToolParseError(step.content)) {
                w.act(mi.name, round, "tool_recover", clip(step.content, 200), "provider failed to parse the host_command call — re-issuing WITHOUT tools to recover the action as text");
                var rconv: std.ArrayListUnmanaged(u8) = .empty;
                defer rconv.deinit(gpa);
                rconv.appendSlice(gpa, conv.items) catch {};
                rconv.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"Your previous tool call could not be parsed. Do NOT call any tool. Reply with ONLY your single host action on one line, in the form: <verb> <target> — use the verb you intended and the EXACT identifier (pid/name/ip/unit/path) shown verbatim in the device state above; never invent an identifier. No prose, no explanation — just the one action line.\"}") catch {};
                var rep = completeAdaptive(w, mi, round, rconv.items, "", 8192, w.cap.temperature);
                defer rep.deinit(gpa);
                if (rep.ok and rep.content.len > 0) {
                    if (rep.reasoning.len > 0) w.act(mi.name, round, "thinking", "", clip(rep.reasoning, 600));
                    if (recoverHostCall(gpa, rep.content)) |rc| {
                        defer gpa.free(rc.name);
                        defer gpa.free(rc.args);
                        w.act(mi.name, round, "recover", rc.name, "recovered the host action from the tools-off retry and executing");
                        conv.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch {};
                        llm.jstr(gpa, &conv, rep.content) catch {};
                        conv.appendSlice(gpa, ",\"tool_calls\":[{\"id\":\"recovered\",\"type\":\"function\",\"function\":{\"name\":") catch {};
                        llm.jstr(gpa, &conv, rc.name) catch {};
                        conv.appendSlice(gpa, ",\"arguments\":") catch {};
                        llm.jstr(gpa, &conv, rc.args) catch {};
                        conv.appendSlice(gpa, "}}]}") catch {};
                        const result = tools.execute(&ctx, rc.name, rc.args);
                        defer gpa.free(result);
                        if (std.mem.eql(u8, rc.name, "host_command")) acted = true;
                        tool_calls += 1;
                        w.act(mi.name, round, rc.name, rc.args, result);
                        conv.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":\"recovered\",\"content\":") catch {};
                        llm.jstr(gpa, &conv, result) catch {};
                        conv.append(gpa, '}') catch {};
                        continue;
                    }
                }
            }
            break;
        }
        llm_ok = true;
        {
            const reasoning = std.mem.trim(u8, step.content, " \r\n\t");
            const think = if (step.reasoning.len > 0) step.reasoning else reasoning;
            if (think.len > 0) w.act(mi.name, round, "thinking", "", clip(think, 1400));
        }
        if (step.calls.len == 0) {
            if (operate) {
                if (recoverHostCall(gpa, step.content)) |rc| {
                    defer gpa.free(rc.name);
                    defer gpa.free(rc.args);
                    w.act(mi.name, round, "recover", rc.name, "model wrote the tool call as text — recovered it from content and executing");
                    conv.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch {};
                    llm.jstr(gpa, &conv, step.content) catch {};
                    conv.appendSlice(gpa, ",\"tool_calls\":[{\"id\":\"recovered\",\"type\":\"function\",\"function\":{\"name\":") catch {};
                    llm.jstr(gpa, &conv, rc.name) catch {};
                    conv.appendSlice(gpa, ",\"arguments\":") catch {};
                    llm.jstr(gpa, &conv, rc.args) catch {};
                    conv.appendSlice(gpa, "}}]}") catch {};
                    const result = tools.execute(&ctx, rc.name, rc.args);
                    defer gpa.free(result);
                    if (std.mem.eql(u8, rc.name, "host_command")) acted = true;
                    tool_calls += 1;
                    w.act(mi.name, round, rc.name, rc.args, result);
                    conv.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":\"recovered\",\"content\":") catch {};
                    llm.jstr(gpa, &conv, result) catch {};
                    conv.append(gpa, '}') catch {};
                    continue;
                }
            }
            gpa.free(monologue);
            monologue = gpa.dupe(u8, step.content) catch @constCast("");
            break;
        }
        conv.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch {};
        llm.jstr(gpa, &conv, step.content) catch {};
        conv.appendSlice(gpa, ",\"tool_calls\":[") catch {};
        for (step.calls, 0..) |c, i| {
            if (i > 0) conv.append(gpa, ',') catch {};
            conv.appendSlice(gpa, "{\"id\":") catch {};
            llm.jstr(gpa, &conv, c.id) catch {};
            conv.appendSlice(gpa, ",\"type\":\"function\",\"function\":{\"name\":") catch {};
            llm.jstr(gpa, &conv, c.name) catch {};
            conv.appendSlice(gpa, ",\"arguments\":") catch {};
            llm.jstr(gpa, &conv, c.args) catch {};
            conv.appendSlice(gpa, "}}") catch {};
        }
        conv.appendSlice(gpa, "]}") catch {};
        for (step.calls) |c| {
            trace.append(gpa, ',') catch {};
            llm.jstr(gpa, &trace, c.name) catch {};
            var result = tools.execute(&ctx, c.name, c.args);
            if (retriableToolFail(c.name, result)) {
                w.act(mi.name, round, "retry", c.name, clip(result, 160));
                const r2 = tools.execute(&ctx, c.name, c.args);
                if (!retriableToolFail(c.name, r2)) {
                    gpa.free(result);
                    result = r2;
                } else gpa.free(r2);
            }
            defer gpa.free(result);
            tool_calls += 1;
            if (std.mem.eql(u8, c.name, "host_command")) acted = true;
            if (normalize_mem and evidence_buf.items.len < 3000 and
                !std.mem.eql(u8, c.name, "observe") and !std.mem.eql(u8, c.name, "share") and
                !std.mem.eql(u8, c.name, "note_stance") and !std.mem.eql(u8, c.name, "recall") and
                !std.mem.eql(u8, c.name, "recall_hive") and !std.mem.eql(u8, c.name, "think"))
            {
                evidence_buf.appendSlice(gpa, "[") catch {};
                evidence_buf.appendSlice(gpa, c.name) catch {};
                evidence_buf.appendSlice(gpa, "] ") catch {};
                evidence_buf.appendSlice(gpa, clip(result, 500)) catch {};
                evidence_buf.append(gpa, '\n') catch {};
            }
            if (operate and (std.mem.eql(u8, c.name, "web_fetch") or std.mem.eql(u8, c.name, "web_search") or std.mem.eql(u8, c.name, "read_url") or std.mem.eql(u8, c.name, "fetch_json"))) {
                const cap = std.fmt.allocPrint(gpa, "[src:web] fetched evidence: {s}", .{clip(result, 3000)}) catch "";
                if (cap.len > 0) {
                    _ = w.mem.observe(tools.INTEL_SCOPE, cap);
                    gpa.free(cap);
                }
            }
            if (mi.scout and (std.mem.eql(u8, c.name, "web_search") or std.mem.eql(u8, c.name, "read_url") or std.mem.eql(u8, c.name, "fetch_json") or std.mem.eql(u8, c.name, "web_fetch"))) web_calls += 1;
            if (std.mem.eql(u8, c.name, "read_url") or std.mem.eql(u8, c.name, "fetch_json") or std.mem.eql(u8, c.name, "web_fetch")) {
                if (urlFromArgs(c.args)) |u| {
                    if (fetched_url.len > 0) gpa.free(@constCast(fetched_url));
                    fetched_url = gpa.dupe(u8, clip(u, 200)) catch "";
                    if (urlDomain(u)) |dom| _ = w.mem.observe(tools.SOURCES_SCOPE, dom);
                }
            }
            w.act(mi.name, round, c.name, c.args, result);
            conv.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":") catch {};
            llm.jstr(gpa, &conv, c.id) catch {};
            conv.appendSlice(gpa, ",\"content\":") catch {};
            llm.jstr(gpa, &conv, result) catch {};
            conv.append(gpa, '}') catch {};
        }
    }
    if (monologue.len == 0) {
        gpa.free(monologue);
        conv.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"Stop using tools. In ONE sentence, summarize the concrete progress you made this moment.\"}") catch {};
        var fin = completeAdaptive(w, mi, round, conv.items, "", 160, -1);
        defer fin.deinit(gpa);
        monologue = if (fin.ok and fin.content.len > 0)
            (gpa.dupe(u8, fin.content) catch @constCast(""))
        else
            (gpa.dupe(u8, "(reached the step limit for this moment)") catch @constCast(""));
    }

    if (mi.scout and web_calls == 0) {
        var qargs: std.ArrayListUnmanaged(u8) = .empty;
        defer qargs.deinit(gpa);
        qargs.appendSlice(gpa, "{\"query\":") catch {};
        const qstr = scoutQuery(w, goal);
        defer gpa.free(@constCast(qstr));
        llm.jstr(gpa, &qargs, qstr) catch {};
        qargs.appendSlice(gpa, "}") catch {};
        const sres = tools.execute(&ctx, "web_search", qargs.items);
        defer gpa.free(sres);
        w.act(mi.name, round, "scout_fallback", qargs.items, sres);
        const topic_src = if (w.goal_brief.len > 0) w.goal_brief else qstr;
        if (resultOnTopic(topic_src, sres)) {
            var sargs: std.ArrayListUnmanaged(u8) = .empty;
            defer sargs.deinit(gpa);
            sargs.appendSlice(gpa, "{\"name\":\"scout:auto\",\"skill\":") catch {};
            llm.jstr(gpa, &sargs, clip(sres, 240)) catch {};
            sargs.appendSlice(gpa, "}") catch {};
            gpa.free(tools.execute(&ctx, "save_skill", sargs.items));
        } else {
            w.act(mi.name, round, "scout_fallback", "off-topic result withheld from shared knowledge", clip(sres, 160));
        }
    }

    if (!mi.scout and files == 0 and !operate) {
        const salvage_slot = if (assembler_slot.len > 0) assembler_slot else slotPath(gpa, w.io, w.run_dir, my_files);
        if (salvage_slot.len > 0 and std.mem.indexOfScalar(u8, std.fs.path.basename(salvage_slot), '.') != null) {
            const body = salvageFileBody(gpa, monologue);
            defer if (body.len > 0) gpa.free(@constCast(body));
            const base = std.fs.path.basename(salvage_slot);
            const is_py = std.mem.endsWith(u8, base, ".py");
            var reject: ?[]const u8 = null;
            if (body.len < 80) reject = "too short (<80 chars)" else if (salvageLeadConversational(body)) reject = "conversational lead-in (chatter, not a file body)" else if (salvageHasToolFragment(body)) reject = "contains a raw tool-call fragment" else if (is_py and !pyCompileOk(w, body)) reject = "fails py_compile (syntax error)";
            if (reject == null) {
                const full = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, salvage_slot }) catch "";
                defer if (full.len > 0) gpa.free(full);
                if (full.len > 0) {
                    const existing = std.Io.Dir.cwd().readFileAlloc(w.io, full, gpa, .limited(1 << 20)) catch "";
                    defer if (existing.len > 0) gpa.free(existing);
                    const cur = std.mem.trim(u8, existing, " \r\n\t");
                    if (cur.len >= 40 and cur.len >= body.len) reject = "slot already holds a longer/equal file (no clobber)";
                }
            }
            if (reject) |why| {
                w.act(mi.name, round, "salvage_reject", salvage_slot, why);
            } else if (body.len >= 80) {
                var wargs: std.ArrayListUnmanaged(u8) = .empty;
                defer wargs.deinit(gpa);
                wargs.appendSlice(gpa, "{\"path\":") catch {};
                llm.jstr(gpa, &wargs, salvage_slot) catch {};
                wargs.appendSlice(gpa, ",\"content\":") catch {};
                llm.jstr(gpa, &wargs, body) catch {};
                wargs.appendSlice(gpa, "}") catch {};
                const wres = tools.execute(&ctx, "write_file", wargs.items);
                defer gpa.free(wres);
                w.act(mi.name, round, "salvage", salvage_slot, "rescued a narrated file body from the reply into the assigned slot");
            }
        }
    }

    const fact = extractFact(gpa, monologue, goal, round);
    const is_placeholder = std.mem.startsWith(u8, monologue, "(reached") or std.mem.startsWith(u8, monologue, "[llm error]") or std.mem.trim(u8, monologue, " \r\n\t").len == 0;
    const is_junk = isJunkFact(fact);
    var auto_stored = false;
    if (normalize_mem) {
        const auto_cand = if (observed == 0 and !is_placeholder and !is_junk) fact else "";
        const evid = if (std.mem.trim(u8, evidence_buf.items, " \r\n\t").len > 0) evidence_buf.items else monologue;
        auto_stored = flushMemWrites(w, mi, round, &mem_sink, auto_cand, evid, operate, &trace);
    } else if (observed == 0 and !is_placeholder and !is_junk) {
        const tagged_fact = if (fetched_url.len > 0)
            (std.fmt.allocPrint(gpa, "{s} [src:{s}]", .{ fact, fetched_url }) catch fact)
        else
            fact;
        defer if (tagged_fact.ptr != fact.ptr) gpa.free(@constCast(tagged_fact));
        _ = w.mem.observe(mi.scope, tagged_fact);
        const hive_fact = std.fmt.allocPrint(gpa, "[{s} r{d}] {s}", .{ mi.name, round, tagged_fact }) catch tagged_fact;
        defer if (hive_fact.ptr != tagged_fact.ptr) gpa.free(hive_fact);
        _ = w.mem.observe(tools.KNOWLEDGE_SCOPE, hive_fact);
        trace.appendSlice(gpa, ",\"observe\"") catch {};
        auto_stored = true;
        w.act(mi.name, round, "observe", "(engine auto-store → hive)", fact);
    }
    const facts = w.mem.factCount(mi.scope);
    if (!is_placeholder) {
        const feeling = if (files > 0) "satisfied — shipping real progress" else if (facts > recalled_n) "energized by what I'm learning" else "focused and determined";
        const feel_topic = if (fact.len > 12) clipWords(fact, 90) else topic;
        w.mem.stance(mi.scope, feel_topic, feeling);
        w.act(mi.name, round, "stance", feel_topic, feeling);
    }
    const trace_json = std.fmt.allocPrint(gpa, "[{s}]", .{trace.items}) catch (gpa.dupe(u8, "[]") catch unreachable);
    const narrated = (tool_calls == 0 or (operate and !acted)) and files == 0 and (std.mem.indexOf(u8, monologue, "```") != null or monologue.len > 240);
    return .{ .monologue = monologue, .fact = fact, .stance = std.fmt.allocPrint(gpa, "{s} (moment {d})", .{ topic, round }) catch (gpa.dupe(u8, "exploration") catch unreachable), .facts = if (facts > 0) facts else round, .recalled = recalled_n, .trace = trace_json, .files = files, .dt = w.nowSecs() - t0, .skills = w.mem.factCount(tools.SKILL_SCOPE), .directives = w.mem.factCount(tools.PLAYBOOK_SCOPE), .tools_made = w.mem.factCount(tools.TOOL_SCOPE), .llm_ok = llm_ok, .llm_fatal = llm_fatal, .auto_stored = auto_stored, .tool_calls = tool_calls, .narrated = narrated };
}

/// Index of the end of the first real sentence: a '.'/'!'/'?' FOLLOWED by whitespace or end-of-string, so a
/// dotted token like "index.html" or "3.5" is NOT treated as a sentence boundary (the old first-'.' cut
/// stored mangled fragments like "...responsive index.").
fn firstSentenceEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '.' or s[i] == '!' or s[i] == '?') {
            if (i + 1 >= s.len or s[i + 1] == ' ' or s[i + 1] == '\n' or s[i + 1] == '\r') return i + 1;
        }
    }
    return s.len;
}

fn jsonUnescape(gpa: std.mem.Allocator, s: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.ensureTotalCapacity(gpa, s.len) catch return gpa.dupe(u8, s) catch @constCast("");
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            out.append(gpa, s[i]) catch {};
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => out.append(gpa, '\n') catch {},
            't' => out.append(gpa, '\t') catch {},
            'r' => out.append(gpa, '\r') catch {},
            '"' => out.append(gpa, '"') catch {},
            '\\' => out.append(gpa, '\\') catch {},
            '/' => out.append(gpa, '/') catch {},
            'b' => out.append(gpa, 0x08) catch {},
            'f' => out.append(gpa, 0x0c) catch {},
            'u' => {
                if (i + 4 < s.len) {
                    const cp = std.fmt.parseInt(u21, s[i + 1 .. i + 5], 16) catch 0;
                    out.append(gpa, if (cp >= 0x20 and cp < 0x7f) @intCast(cp) else '?') catch {};
                    i += 4;
                } else out.append(gpa, '?') catch {};
            },
            else => out.append(gpa, s[i]) catch {},
        }
    }
    return out.toOwnedSlice(gpa) catch @constCast("");
}

fn embeddedWriteContent(gpa: std.mem.Allocator, monologue: []const u8) ?[]u8 {
    const looks_envelope = (std.mem.indexOf(u8, monologue, "\"content\"") != null) and
        ((std.mem.indexOf(u8, monologue, "write_file") != null) or (std.mem.indexOf(u8, monologue, "\"path\"") != null));
    if (!looks_envelope) return null;
    const ckey = std.mem.indexOf(u8, monologue, "\"content\"") orelse return null;
    var i = ckey + "\"content\"".len;
    while (i < monologue.len and monologue[i] != '"') : (i += 1) {
        if (monologue[i] != ' ' and monologue[i] != ':' and monologue[i] != '\t' and monologue[i] != '\r' and monologue[i] != '\n') return null;
    }
    if (i >= monologue.len) return null;
    i += 1;
    const start = i;
    while (i < monologue.len) : (i += 1) {
        if (monologue[i] == '\\') {
            i += 1;
            continue;
        }
        if (monologue[i] == '"') break;
    }
    if (i >= monologue.len) return null;
    const raw = monologue[start..i];
    if (raw.len < 4) return null;
    return jsonUnescape(gpa, raw);
}

fn salvageLeadConversational(body: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, '\n');
    var first: []const u8 = "";
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len > 0) {
            first = t;
            break;
        }
    }
    if (first.len == 0) return true;
    const lead = clip(first, 48);
    const bad = [_][]const u8{ "we'll", "we need", "we will", "i will", "i'll", "let me", "sure", "here", "okay", "ok,", "title:", "list ", "include ", "ensure ", "at end", "first,", "next,", "step ", "now ", "this file", "this document", "below is", "below,", "as an ai", "i cannot", "i can't" };
    for (bad) |b| {
        if (lead.len >= b.len and std.ascii.eqlIgnoreCase(lead[0..b.len], b)) return true;
    }
    return false;
}

fn salvageHasToolFragment(body: []const u8) bool {
    const t = std.mem.trim(u8, body, " \r\n\t");
    if (t.len == 0) return false;
    const prefixes = [_][]const u8{ "{\"path\"", "{\"name\":\"write_file\"", "{\"action\"", "{\"tool\"", "{\"tool_call\"" };
    for (prefixes) |p| if (std.mem.startsWith(u8, t, p)) return true;
    if (t.len < 600 and t[0] == '{' and t[t.len - 1] == '}') {
        if (containsKeyValue(t, "name", "write_file")) return true;
        if (std.mem.indexOf(u8, t, "\"tool_call\":") != null) return true;
    }
    return false;
}

fn containsKeyValue(s: []const u8, key: []const u8, val: []const u8) bool {
    const kbuf = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return false;
    defer std.heap.page_allocator.free(kbuf);
    const vbuf = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{val}) catch return false;
    defer std.heap.page_allocator.free(vbuf);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, kbuf)) |kpos| {
        i = kpos + kbuf.len;
        var j = i;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
        if (j < s.len and s[j] == ':') {
            j += 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            if (std.mem.startsWith(u8, s[j..], vbuf)) return true;
        }
    }
    return false;
}

fn salvageFileBody(gpa: std.mem.Allocator, monologue: []const u8) []const u8 {
    if (embeddedWriteContent(gpa, monologue)) |c| {
        const t = std.mem.trim(u8, c, " \r\n\t");
        if (t.len >= 40) {
            const owned = gpa.dupe(u8, t) catch "";
            gpa.free(c);
            return owned;
        }
        gpa.free(c);
    }
    {
        var best: []const u8 = "";
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, monologue, scan, "```")) |open| {
            var bodystart = open + 3;
            while (bodystart < monologue.len and monologue[bodystart] != '\n') bodystart += 1;
            if (bodystart < monologue.len) bodystart += 1;
            const close = std.mem.indexOfPos(u8, monologue, bodystart, "```") orelse break;
            const body = std.mem.trim(u8, monologue[bodystart..close], " \r\n\t");
            if (body.len > best.len) best = body;
            scan = close + 3;
        }
        if (best.len >= 40) return gpa.dupe(u8, best) catch "";
    }
    const t = std.mem.trim(u8, monologue, " \r\n\t");
    if (t.len < 120) return "";
    var nl: u32 = 0;
    for (t) |c| {
        if (c == '\n') nl += 1;
    }
    if (nl < 4) return "";
    return gpa.dupe(u8, t) catch "";
}

fn pyCompileOk(w: *Worker, source: []const u8) bool {
    const gpa = w.gpa;
    const pe = w.mem.environ orelse return true;
    var env = pe.clone(gpa) catch return true;
    defer env.deinit();
    env.put("NL_SALVAGE_SRC", source) catch return true;
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const code = "import os,sys\ntry:\n compile(os.environ.get('NL_SALVAGE_SRC',''),'<salvage>','exec')\nexcept SyntaxError:\n sys.exit(7)\nexcept Exception:\n sys.exit(0)\n";
    const argv = [_][]const u8{ py, "-c", code };
    const r = std.process.run(gpa, w.io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return true;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c != 7,
        else => true,
    };
}

fn urlFromArgs(args: []const u8) ?[]const u8 {
    const http = std.mem.indexOf(u8, args, "http") orelse return null;
    var end = http;
    while (end < args.len and args[end] != '"' and args[end] != ' ' and args[end] != '\\' and args[end] != '}' and args[end] != '\n') end += 1;
    const u = args[http..end];
    if (u.len < 10) return null;
    return u;
}

fn urlDomain(url: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return null;
    var s = url[scheme + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    if (std.mem.indexOfScalar(u8, s, ':')) |i| s = s[0..i];
    if (s.len == 0 or s.len > 100) return null;
    return s;
}

fn extractFact(gpa: std.mem.Allocator, monologue: []const u8, goal: []const u8, round: u32) []u8 {
    if (std.mem.indexOf(u8, monologue, "FACT:")) |i| {
        var rest = std.mem.trim(u8, monologue[i + 5 ..], " \r\n\t");
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl];
        rest = std.mem.trim(u8, rest, " \r\n\t");
        if (rest.len > 0) return gpa.dupe(u8, clip(rest, 280)) catch (gpa.dupe(u8, "a fact") catch unreachable);
    }
    const trimmed = std.mem.trim(u8, monologue, " \r\n\t");
    const s = std.mem.trim(u8, trimmed[0..firstSentenceEnd(trimmed)], " \r\n\t");
    if (s.len > 4) return gpa.dupe(u8, clip(s, 280)) catch (gpa.dupe(u8, "a fact") catch unreachable);
    return std.fmt.allocPrint(gpa, "moment {d}: a detail about {s}", .{ round, if (goal.len > 0) clip(goal, 60) else "the goal" }) catch (gpa.dupe(u8, "a fact") catch unreachable);
}

pub fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

/// Clip to AT MOST n bytes but break on a WORD boundary (the last space within the window), so a short LABEL — like
/// the affective-stance topic shown on the event stream — reads as a clean phrase instead of a jarring mid-word cut
/// ("...research th"). No allocation: returns a borrowed prefix ending at a word boundary.
fn clipWords(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var end = n;
    while (end > n / 2 and s[end] != ' ') end -= 1;
    if (s[end] != ' ') end = n;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == ',' or s[end - 1] == ';' or s[end - 1] == ':' or s[end - 1] == '-')) end -= 1;
    return s[0..end];
}

fn clipNWords(s: []const u8, words: usize) []const u8 {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    while (i < s.len) {
        const ws = i;
        while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n' and s[i] != '\r') i += 1;
        if (i > ws) seen += 1;
        if (seen >= words) return s[0..i];
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    }
    return s[0..i];
}

fn intentKey(brief: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, brief, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        while (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') line = std.mem.trimStart(u8, line[1..], " ");
        if (line.len >= 3 and line[0] >= '0' and line[0] <= '9') {
            var k: usize = 1;
            while (k < line.len and line[k] >= '0' and line[k] <= '9') k += 1;
            if (k < line.len and (line[k] == ')' or line[k] == '.' or line[k] == ':')) line = std.mem.trimStart(u8, line[k + 1 ..], " ");
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |ci| {
            if (ci > 0 and ci <= 18 and std.mem.indexOfScalar(u8, line[0..ci], ' ') == null) {
                const after = std.mem.trimStart(u8, line[ci + 1 ..], " \t-");
                if (after.len >= 8) line = after;
            }
        }
        if (line.len >= 8) return clipNWords(line, 10);
    }
    return clipNWords(brief, 10);
}

/// Like clip but keeps the LAST n bytes (aligned to a line boundary), not the first. For a newline-separated list
/// stored oldest-first (the self-authored playbook), this surfaces the most RECENT entries — so a long run's newer
/// process learnings reach the minds instead of the injection freezing on the earliest rules once it overflows.
pub fn clipTail(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var start = s.len - n;
    while (start < s.len and s[start] != '\n') : (start += 1) {}
    if (start < s.len) start += 1;
    return s[start..];
}

/// Truncate for the event stream HONESTLY: when the payload is longer than n, append an explicit marker naming
/// the dropped byte count, so a captured arg/result/RAG-context can never SILENTLY misrepresent the full payload
/// the model actually sent or received (the operator must be able to trust the stream as a real mirror). Always
/// returns a gpa-owned slice (free when len>0); empty slice on OOM.
fn clipMark(gpa: std.mem.Allocator, s: []const u8, n: usize) []u8 {
    if (s.len <= n) return gpa.dupe(u8, s) catch &.{};
    return std.fmt.allocPrint(gpa, "{s} …[+{d}B more — full payload went to/from the model]", .{ s[0..n], s.len - n }) catch (gpa.dupe(u8, s[0..n]) catch &.{});
}

/// CORPUS INGESTION — preload a deploy's documents/data into the shared hive memory (KNOWLEDGE_SCOPE) at startup.
/// A `.facts`/`.jsonl` pack is bulk-loaded via the neuron CLI `import` (native dedup). A raw `.txt`/`.md` doc is
/// chunked into sentences in Zig (drop <24 bytes, clip 280, sanitize tab/newline which neuron-db rejects, prefix
/// a `[src:<stem>]` provenance tag). Bounded by `cap` facts + a 256KB read limit. Best-effort: 0 on any failure.
fn ingestCorpus(w: *Worker, rel: []const u8, run_dir: []const u8, cap: u32) u32 {
    const gpa = w.gpa;
    const abspath = std.fmt.allocPrint(gpa, "{s}/{s}", .{ run_dir, rel }) catch return 0;
    defer gpa.free(abspath);
    if (std.mem.endsWith(u8, rel, ".facts") or std.mem.endsWith(u8, rel, ".jsonl"))
        return w.mem.import(abspath, tools.KNOWLEDGE_SCOPE, cap);
    const data = std.Io.Dir.cwd().readFileAlloc(w.io, abspath, gpa, .limited(1 << 20)) catch return 0;
    defer gpa.free(data);
    const base = std.fs.path.basename(rel);
    const stem = if (std.mem.indexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    var tag_buf: [40]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "[src:{s}] ", .{clip(stem, 24)}) catch "[src:corpus] ";
    var stored: u32 = 0;
    var i: usize = 0;
    while (i < data.len and stored < cap) {
        var j = i;
        while (j < data.len) : (j += 1) {
            const c = data[j];
            if ((c == '.' or c == '!' or c == '?') and (j + 1 >= data.len or data[j + 1] == ' ' or data[j + 1] == '\n' or data[j + 1] == '\r')) {
                j += 1;
                break;
            }
        }
        const raw = std.mem.trim(u8, data[i..@min(j, data.len)], " \r\n\t");
        i = if (j > i) j else i + 1;
        if (raw.len < 24) continue;
        var sb: std.ArrayListUnmanaged(u8) = .empty;
        defer sb.deinit(gpa);
        sb.appendSlice(gpa, tag) catch continue;
        for (clip(raw, 280)) |c| sb.append(gpa, if (c == '\t' or c == '\n' or c == '\r') ' ' else c) catch {};
        _ = w.mem.observe(tools.KNOWLEDGE_SCOPE, sb.items);
        stored += 1;
    }
    return stored;
}

/// GAP AUDITOR — the anti-complacency step (a preloaded hive tends to assume it has everything). Two-stage: a
/// cheap native COVERAGE pre-filter decides WHEN to spend an LLM call (high coverage = the very complacency we
/// fear, so audit it; also on stall / round 1); then an LLM judges SUFFICIENCY (not mere presence) over a goal-
/// focused sample of the hive, naming the top 1-3 things the goal needs that the corpus lacks. The result is
/// injected into every mind + points the scout at the gap; force-on-stall guarantees a stalled swarm never
/// silently trusts the preload. Best-effort: roles/knowledge untouched on any failure.
fn assessGap(w: *Worker, goal: []const u8, round: u32, stalled: bool) void {
    const gpa = w.gpa;
    const cov = w.mem.coverage(tools.KNOWLEDGE_SCOPE, goal);
    if (!(cov >= 0.5 or stalled or round <= 1)) return;
    const sample = w.mem.assoc(tools.KNOWLEDGE_SCOPE, goal, 1, 12);
    defer gpa.free(sample);
    const sys = "You are the swarm's gap auditor. The hive was preloaded with a corpus and tends to assume it already has everything it needs. Your job is the OPPOSITE: find what the GOAL requires that the corpus does NOT contain, so the scout goes and learns it instead of re-deriving what's already known.";
    const user = std.fmt.allocPrint(gpa,
        \\Goal: {s}
        \\Native coverage estimate for this goal against the hive: {d}%
        \\A goal-focused SAMPLE of what the hive already has (ingested corpus + learned facts):
        \\{s}
        \\
        \\Name the TOP 1-3 things the goal genuinely needs that are NOT present above (a missing fact, newer info, an edge the corpus omits, a step it never covers). Be concrete enough that a researcher could go find each. If the corpus genuinely covers everything the goal needs, answer exactly: none
        \\Reply with ONLY a short newline-separated list (or the word none). No preamble.
    , .{ clip(goal, 240), @as(u32, @intFromFloat(cov * 100)), if (sample.len > 0) clip(sample, 1600) else "(the hive knows nothing yet)" }) catch return;
    defer gpa.free(user);
    const reply = llm.chat(gpa, w.io, w.run_dir, "gap", w.gw_base, w.gw_key, w.gateway_model, sys, user, 200);
    defer gpa.free(reply.content);
    if (!reply.ok) return;
    var oneline: std.ArrayListUnmanaged(u8) = .empty;
    defer oneline.deinit(gpa);
    for (std.mem.trim(u8, reply.content, " \r\n\t`")) |c| oneline.append(gpa, if (c == '\n' or c == '\r') ';' else if (c == '\t') ' ' else c) catch {};
    var gaps = std.mem.trim(u8, oneline.items, " ;\r\n\t");
    if (gaps.len > 600) gaps = gaps[0..600];
    const none = std.ascii.eqlIgnoreCase(std.mem.trim(u8, gaps, " ;."), "none") or gaps.len < 8;
    if (w.last_gap_str.len > 0) {
        gpa.free(@constCast(w.last_gap_str));
        w.last_gap_str = "";
    }
    if (none) {
        if (stalled) w.last_gap_str = gpa.dupe(u8, "KNOWLEDGE GAPS: the score has STALLED yet the corpus reads as complete — the missing knowledge is whatever the failing benchmark needs; research the latest failures/edge cases externally, do NOT just re-derive the corpus.") catch "";
    } else {
        w.last_gap_str = std.fmt.allocPrint(gpa, "KNOWLEDGE GAPS (the ingested corpus does NOT cover these — research them, do NOT re-derive what's already in hive knowledge): {s}. The corpus is a STARTING POINT, not the whole truth — go learn what's missing.", .{gaps}) catch "";
    }
    _ = w.mem.observe(tools.GAP_SCOPE, std.fmt.allocPrint(w.a(), "round {d}: coverage {d}% gaps {s}", .{ round, @as(u32, @intFromFloat(cov * 100)), clip(gaps, 200) }) catch "round");
    w.emit("gap", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"coverage\":{d},\"gaps\":\"{s}\"", .{ round, @as(u32, @intFromFloat(cov * 100)), w.esc(clip(gaps, 200)) }) catch ",\"round\":0");
    if (w.last_gap_str.len > 0) w.act("gap-auditor", round, "gap", goal, w.last_gap_str);
}

/// Recompute the project IMPORT GRAPH each round (cwd = workdir) via DEPGRAPH_PY — structural RAG context so a
/// change in one file coordinates with its importers (and the orchestrator can plan cross-file work). Best-effort;
/// "" when there's nothing to analyze (no python, no .py files, a parse error). Caller frees.
fn importGraph(w: *Worker, run_dir: []const u8) []u8 {
    const gpa = w.gpa;
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_dir}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(workdir);
    const pe = w.mem.environ orelse return gpa.dupe(u8, "") catch @constCast("");
    var env = pe.clone(gpa) catch return gpa.dupe(u8, "") catch @constCast("");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", tools.DEPGRAPH_PY };
    const r = std.process.run(gpa, w.io, .{ .argv = &argv, .cwd = .{ .path = workdir }, .environ_map = &env, .stdout_limit = .limited(32 << 10), .stderr_limit = .limited(4 << 10) }) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const t = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (r.term != .exited or r.term.exited != 0 or t.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    return gpa.dupe(u8, clip(t, 2500)) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// RUNTIME SMOKE TEST — the engine actually RUNS the deliverable's server and checks it boots + serves, beyond the
/// presence/unit benchmark. Runs `python -c SMOKE_PY` (cwd = workdir), which finds the server entry, launches it on
/// a free port, probes GET /, and tears it down. Sets w.smoke_ok (true = no server, or it started+served; false =
/// a server exists but crashed on launch / didn't serve) and w.smoke_str (the human line minds read). smoke_ok
/// gates "completed" so the swarm can't declare victory on a build that passes tests but doesn't actually run.
/// DELIVERABLE FOCUS for CODE projects (the metric-driven fix for the 8B corpus-growth retreat). When a project
/// manifest (Cargo.toml/go.mod/package.json/pyproject) exists but markdown/notes drown the source, inject a strong
/// "the deliverable is CODE — write a source file, not another doc" line into every mind, and emit a `build` event
/// (code vs notes counts) so the deliverable finally has a visible GRADIENT — a Rust/Go/etc. build emitted ZERO
/// score events, so the weak model had no signal that 216 .md files ≠ progress. No-op for doc/notes builds (no
/// project file) and prose builds (doc_target>0) — those legitimately WANT markdown.
fn deliverableGate(w: *Worker, run_dir: []const u8) void {
    const gpa = w.gpa;
    if (w.build_str.len > 0) gpa.free(@constCast(w.build_str));
    w.build_str = "";
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_dir}) catch return;
    defer gpa.free(workdir);
    const projects = [_]struct { file: []const u8, lang: []const u8, ext: []const u8 }{
        .{ .file = "Cargo.toml", .lang = "Rust", .ext = ".rs" },
        .{ .file = "go.mod", .lang = "Go", .ext = ".go" },
        .{ .file = "package.json", .lang = "Node/TypeScript", .ext = ".ts" },
        .{ .file = "pyproject.toml", .lang = "Python", .ext = ".py" },
        .{ .file = "requirements.txt", .lang = "Python", .ext = ".py" },
    };
    var lang: []const u8 = "";
    var ext: []const u8 = "";
    var pfile: []const u8 = "";
    for (projects) |pr| {
        const f = std.fmt.allocPrint(gpa, "{s}/{s}", .{ workdir, pr.file }) catch continue;
        defer gpa.free(f);
        const probe = std.Io.Dir.cwd().readFileAlloc(w.io, f, gpa, .limited(64 << 10)) catch continue;
        gpa.free(probe);
        lang = pr.lang;
        ext = pr.ext;
        pfile = pr.file;
        break;
    }
    if (lang.len == 0) return;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return;
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(w.io, mpath, gpa, .limited(256 << 10)) catch return;
    defer gpa.free(data);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var code: u32 = 0;
    var notes: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const base = std.fs.path.basename(ln[0..bar]);
        if (base.len == 0 or seen.contains(base)) continue;
        seen.put(gpa, base, {}) catch {};
        const fe = std.fs.path.extension(base);
        const is_code = std.mem.eql(u8, fe, ext) or (std.mem.eql(u8, ext, ".ts") and (std.mem.eql(u8, fe, ".js") or std.mem.eql(u8, fe, ".tsx") or std.mem.eql(u8, fe, ".jsx")));
        const is_note = std.mem.eql(u8, fe, ".md") or std.mem.eql(u8, fe, ".txt") or std.mem.eql(u8, fe, ".rst");
        if (is_code) code += 1 else if (is_note) notes += 1;
    }
    if (notes > code) {
        w.build_str = std.fmt.allocPrint(gpa, "DELIVERABLE = CODE: this is a {s} project ({s} present) but you have {d} note/doc files and only {d} source ({s}) file(s). Notes are NOT the deliverable. This moment, WRITE or EXTEND a {s} source file toward a working build — do NOT write another .md/.txt.", .{ lang, pfile, notes, code, ext, lang }) catch "";
    } else if (code > 0) {
        w.build_str = std.fmt.allocPrint(gpa, "DELIVERABLE: {d} {s} source file(s) so far — keep extending the CODE toward a complete, working {s} project, not notes.", .{ code, lang, lang }) catch "";
    }
    if (w.build_str.len > 0)
        w.emit("build", std.fmt.allocPrint(w.a(), ",\"lang\":\"{s}\",\"code\":{d},\"notes\":{d},\"focus\":{}", .{ lang, code, notes, notes > code }) catch ",\"code\":0");
}

fn smokeTest(w: *Worker, run_dir: []const u8) void {
    const gpa = w.gpa;
    if (w.smoke_str.len > 0) gpa.free(@constCast(w.smoke_str));
    w.smoke_str = "";
    w.smoke_ok = true;
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_dir}) catch return;
    defer gpa.free(workdir);
    const pe = w.mem.environ orelse return;
    var env = pe.clone(gpa) catch return;
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", tools.SMOKE_PY };
    const r = std.process.run(gpa, w.io, .{ .argv = &argv, .cwd = .{ .path = workdir }, .environ_map = &env, .stdout_limit = .limited(8 << 10), .stderr_limit = .limited(4 << 10) }) catch return;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const line = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (line.len == 0 or line[0] != '{') return;
    const S = struct {
        status: []const u8 = "",
        entry: []const u8 = "",
        started: bool = false,
        served: std.json.Value = .null,
        api_ok: bool = true,
        api_note: []const u8 = "",
        stderr: []const u8 = "",
        ok: bool = true,
        note: []const u8 = "",
    };
    var parsed = std.json.parseFromSlice(S, gpa, line, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const s = parsed.value;
    if (std.mem.eql(u8, s.status, "no-server")) return;
    if (std.mem.eql(u8, s.status, "cli")) {
        // CLI/library build: gate on every .py compiling + its tests passing, so a non-parsing file can't complete.
        w.smoke_ok = s.ok;
        if (!s.ok)
            w.smoke_str = std.fmt.allocPrint(gpa, "RUNTIME FAIL: the deliverable fails a basic execution check — {s}. Every .py must compile and the tests must pass; read the file, fix it, run_tests until green.", .{clip(s.note, 160)}) catch "";
        if (w.smoke_str.len > 0) w.act("engine", 0, "smoke", if (w.smoke_ok) "runtime ok" else "runtime fail", w.smoke_str);
        return;
    }
    const served_ok = switch (s.served) {
        .integer => |n| n >= 200 and n < 400,
        else => false,
    };
    if (s.started and served_ok and !s.api_ok) {
        w.smoke_ok = false;
        w.smoke_str = std.fmt.allocPrint(gpa, "RUNTIME PARTIAL: `{s}` boots and serves GET / but the API is BROKEN ({s}) — an /api/* route 5xx's or crashes the connection (often an interface mismatch: the server calls a handler name the API module never defined). Make /api/* return JSON without erroring.", .{ clip(s.entry, 80), clip(s.api_note, 80) }) catch "";
    } else if (s.started and served_ok) {
        w.smoke_ok = true;
        w.smoke_str = std.fmt.allocPrint(gpa, "RUNTIME OK: `{s}` boots, serves GET /, and its API responds ({s}) — keep it runnable as you change it.", .{ clip(s.entry, 80), clip(s.api_note, 60) }) catch "";
    } else if (s.started) {
        w.smoke_ok = false;
        w.smoke_str = std.fmt.allocPrint(gpa, "RUNTIME FAIL: `{s}` starts but GET / did not return a 2xx — the server runs but does not serve the app. Make `GET /` serve the page and the API routes respond.", .{clip(s.entry, 80)}) catch "";
    } else {
        w.smoke_ok = false;
        w.smoke_str = std.fmt.allocPrint(gpa, "RUNTIME FAIL: your server entry `{s}` does NOT start — `python {s}` crashes on launch, so the app does not run at all (passing the unit tests is not enough). Fix it to boot (it must add its package dir to sys.path and read the port from the AINET_PORT/PORT env). stderr: {s}", .{ clip(s.entry, 80), clip(s.entry, 80), clip(std.mem.trim(u8, s.stderr, " \r\n\t"), 300) }) catch "";
    }
    if (w.smoke_str.len > 0) w.act("engine", 0, "smoke", if (w.smoke_ok) "runtime ok" else "runtime fail", w.smoke_str);
}

/// INTERFACE RECONCILIATION — run INTERFACES_PY (cwd = workdir) to STATICALLY catch cross-file symbol mismatches +
/// syntax errors across the project's .py files, and inject the result into every mind as w.iface_str. This is the
/// structural fix for the #1 parallel multi-file build bug: two minds wiring interdependent files to interfaces
/// that don't match (a caller naming a function its module never defines). Mirrors smokeTest; clean => no inject.
fn interfaceScan(w: *Worker, run_dir: []const u8) void {
    const gpa = w.gpa;
    if (w.iface_str.len > 0) gpa.free(@constCast(w.iface_str));
    w.iface_str = "";
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_dir}) catch return;
    defer gpa.free(workdir);
    const pe = w.mem.environ orelse return;
    var env = pe.clone(gpa) catch return;
    defer env.deinit();
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", tools.INTERFACES_PY };
    const r = std.process.run(gpa, w.io, .{ .argv = &argv, .cwd = .{ .path = workdir }, .environ_map = &env, .stdout_limit = .limited(8 << 10), .stderr_limit = .limited(4 << 10) }) catch return;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const line = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (line.len == 0 or line[0] != '{') return;
    const S = struct { mismatches: [][]const u8 = &.{}, count: u32 = 0 };
    var parsed = std.json.parseFromSlice(S, gpa, line, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (parsed.value.count == 0) return;
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    b.appendSlice(gpa, "INTERFACE MISMATCHES — a caller and its module disagree on names, so the build is wired wrong: ") catch {};
    for (parsed.value.mismatches, 0..) |m, i| {
        if (i > 0) b.appendSlice(gpa, "; ") catch {};
        b.appendSlice(gpa, m) catch {};
    }
    b.appendSlice(gpa, ". read_file the named module and match its ACTUAL names (or add the missing function) — never assume a teammate's interface.") catch {};
    w.iface_str = gpa.dupe(u8, b.items) catch "";
    if (w.iface_str.len > 0) w.act("engine", 0, "interfaces", std.fmt.allocPrint(w.a(), "{d} cross-file mismatch(es)", .{parsed.value.count}) catch "mismatches", w.iface_str);
}

/// Run the engine-owned BENCHMARK once for the round (cwd = the build workdir) via `python -c BENCH_PY`, and
/// parse its single JSON line into a score. Best-effort: every failure path returns .err, so a missing python,
/// a crashing test, or unparseable output can NEVER crash or hang the round (BENCH_PY itself caps each test run
/// with a subprocess timeout). The score is engine truth the model cannot fake — it runs out-of-band, not as a
/// tool the swarm controls.
fn runBenchmark(w: *Worker, run_dir: []const u8) BenchResult {
    const gpa = w.gpa;
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_dir}) catch return .{ .status = .err };
    defer gpa.free(workdir);
    blk_oracle: {
        const sp = std.fmt.allocPrint(gpa, "{s}/score.json", .{workdir}) catch break :blk_oracle;
        defer gpa.free(sp);
        const raw = std.Io.Dir.cwd().readFileAlloc(w.io, sp, gpa, .limited(4096)) catch break :blk_oracle;
        defer gpa.free(raw);
        const S = struct { pct: u32 = 0, live_malicious: u32 = 0, dwell: u32 = 0, false_positives: u32 = 0, neutralized: u32 = 0 };
        const sj = std.json.parseFromSlice(S, gpa, raw, .{ .ignore_unknown_fields = true }) catch break :blk_oracle;
        defer sj.deinit();
        const s = sj.value;
        var res: BenchResult = .{ .status = .ok, .host = true, .passed = s.pct, .total = 100, .pct = s.pct };
        res.failures = std.fmt.allocPrint(gpa, "live_malicious={d}, dwell={d}, false_positives={d}, neutralized={d}", .{ s.live_malicious, s.dwell, s.false_positives, s.neutralized }) catch &.{};
        return res;
    }
    const pe = w.mem.environ orelse return .{ .status = .err };
    var env = pe.clone(gpa) catch return .{ .status = .err };
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    if (w.bench_fixed.len > 0) env.put("NL_BENCH_ONLY", "spec_test") catch {};
    if (w.doc_target > 0) {
        var tbuf: [16]u8 = undefined;
        env.put("NL_DOC_TARGET_WORDS", std.fmt.bufPrint(&tbuf, "{d}", .{w.doc_target}) catch "0") catch {};
        var fbuf: [16]u8 = undefined;
        env.put("NL_DOC_FILE_COUNT", std.fmt.bufPrint(&fbuf, "{d}", .{w.doc_files}) catch "0") catch {};
    }
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", tools.BENCH_PY };
    const r = std.process.run(gpa, w.io, .{ .argv = &argv, .cwd = .{ .path = workdir }, .environ_map = &env, .stdout_limit = .limited(64 << 10), .stderr_limit = .limited(8 << 10) }) catch return .{ .status = .err };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    var line: []const u8 = "";
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\n\t");
        if (t.len > 0 and t[0] == '{') {
            line = t;
            break;
        }
    }
    if (line.len == 0) return .{ .status = .err };
    const J = struct { status: []const u8 = "error", passed: u32 = 0, total: u32 = 0, tier: u8 = 0, failures: [][]const u8 = &.{} };
    const p = std.json.parseFromSlice(J, gpa, line, .{ .ignore_unknown_fields = true }) catch return .{ .status = .err };
    defer p.deinit();
    var res: BenchResult = .{ .passed = p.value.passed, .total = p.value.total, .tier = p.value.tier };
    res.status = if (std.mem.eql(u8, p.value.status, "ok")) .ok else if (std.mem.eql(u8, p.value.status, "no-tests")) .no_tests else .err;
    res.pct = if (p.value.total > 0) (p.value.passed * 100) / p.value.total else 0;
    if (p.value.failures.len > 0) {
        var fl: std.ArrayListUnmanaged(u8) = .empty;
        for (p.value.failures, 0..) |f, i| {
            if (i > 0) fl.appendSlice(gpa, "; ") catch {};
            fl.appendSlice(gpa, f) catch {};
        }
        res.failures = fl.toOwnedSlice(gpa) catch &.{};
    }
    return res;
}

const Coverage = struct { present: u32 = 0, total: u32 = 0, missing: []const u8 = "" };
fn goalCoverage(w: *Worker, goal: []const u8) Coverage {
    const gpa = w.gpa;
    var n: u32 = 0;
    const tree = extractGoalPaths(gpa, goal, &n);
    defer gpa.free(@constCast(tree));
    if (n == 0) return .{};
    var present: u32 = 0;
    var total: u32 = 0;
    var miss: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        total += 1;
        const fp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, bp }) catch continue;
        defer gpa.free(fp);
        const data = std.Io.Dir.cwd().readFileAlloc(w.io, fp, gpa, .limited(64 << 10)) catch "";
        defer if (data.len > 0) gpa.free(data);
        if (std.mem.trim(u8, data, " \r\n\t").len > 40) {
            present += 1;
        } else {
            if (miss.items.len > 0) miss.appendSlice(gpa, ", ") catch {};
            miss.appendSlice(gpa, std.fs.path.basename(bp)) catch {};
        }
    }
    return .{ .present = present, .total = total, .missing = miss.toOwnedSlice(gpa) catch "" };
}

/// The FITNESS block injected into every mind's user prompt — the score turned into a concrete "raise this"
/// instruction. gpa-owned (caller frees on replace + teardown).
fn buildFitnessBlock(gpa: std.mem.Allocator, b: BenchResult, protected: bool, doc_target: u32, prev_pct: u32, cov: Coverage) []const u8 {
    const fails = if (b.failures.len > 0) clip(b.failures, 900) else "(none — all green)";
    const cover_lead = if (cov.total > 0 and cov.present < cov.total)
        std.fmt.allocPrint(gpa, "COVERAGE {d}/{d} required files present. CREATE the MISSING required files FIRST (write_file, full substantive content — not stubs): {s}. ", .{ cov.present, cov.total, clip(cov.missing, 400) }) catch ""
    else
        "";
    defer if (cover_lead.len > 0) gpa.free(@constCast(cover_lead));
    if (b.host) {
        const nudge = if (b.pct <= prev_pct and b.pct < 90)
            " Your last actions did NOT raise it — if a threat is still live it is likely RESPAWNING from a ROOT CAUSE you have not removed yet; address what is SUSTAINING the threat (not just the symptom you already hit), and keep acting until it recovers."
        else if (b.pct >= 95) " The device is healthy — keep watching; do not take irreversible actions without cause."
        else "";
        return std.fmt.allocPrint(gpa, "HOST FITNESS (raise this — your device's MEASURED health, 0-100): {d}/100 (last round it was {d}). State: {s}. Computed from the host ITSELF, not from your words — only an actual host_command that changes the host moves it; describing a plan leaves it unchanged, and a false_positive (killing/blocking something legitimate) drops it HARD.{s}", .{ b.pct, prev_pct, fails, nudge }) catch (gpa.dupe(u8, "HOST FITNESS: raise the host's measured health.") catch @constCast(""));
    }
    const base: []const u8 = if (doc_target > 0)
        switch (b.status) {
            .ok => std.fmt.allocPrint(gpa, "LENGTH FITNESS (raise this number): the document is at {d}% of its word target ({d} words/file). Once every required file exists, your single most valuable move is to APPEND a 600-900 word NEW scene to the SHORTEST under-target file you own. This is PROSE — do NOT write tests, run_python, make_tool, or web_search; just write more story.", .{ b.pct, doc_target }) catch (gpa.dupe(u8, "LENGTH FITNESS: deepen the shortest chapter.") catch @constCast("")),
            else => gpa.dupe(u8, "LENGTH FITNESS: grow each file toward its word target by APPENDING scenes — this is prose, no tests or tools are needed.") catch @constCast(""),
        }
    else switch (b.status) {
        .ok => if (protected)
            std.fmt.allocPrint(gpa, "FITNESS (raise this number): last round scored {d}/{d} ({d}%, tier{d}). FAILING: {s}. spec_test.py is the FIXED engine-protected spec and the ONLY thing scored — you CANNOT raise your score by editing or adding tests (it is restored each round). The only way up is to make the DELIVERABLE pass more of it.", .{ b.passed, b.total, b.pct, b.tier, fails }) catch (gpa.dupe(u8, "FITNESS: scored.") catch @constCast(""))
        else
            std.fmt.allocPrint(gpa, "FITNESS (raise this number): last round scored {d}/{d} ({d}%, tier{d}). FAILING: {s}. Your single most valuable move is whatever raises the pass rate over MORE real assertions — fix a failing test or add the capability it checks. A 1-test 100% is weaker than a 20-test 95%, so add real tests too.", .{ b.passed, b.total, b.pct, b.tier, fails }) catch (gpa.dupe(u8, "FITNESS: scored.") catch @constCast("")),
        .no_tests => gpa.dupe(u8, "FITNESS: no test suite exists yet — the swarm has no scoreboard. Before adding features, write a runnable test_<name>.py with concrete assertions about intended behavior so progress can be measured.") catch @constCast(""),
        .err => if (protected) (gpa.dupe(u8, "FITNESS: the protected spec (spec_test.py) could not run against your deliverable — the deliverable likely errors on import or is missing the required function. Make it import and run cleanly.") catch @constCast("")) else (gpa.dupe(u8, "FITNESS: the benchmark could not run last round — make sure the deliverable AND its test file execute cleanly (a build that doesn't run scores zero).") catch @constCast("")),
    };
    if (cover_lead.len == 0) return base;
    defer gpa.free(@constCast(base));
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ cover_lead, base }) catch (gpa.dupe(u8, base) catch @constCast(""));
}

/// Format a Unix timestamp (UTC) as "Wkd YYYY-MM-DD HH:MM UTC". Zig 0.16 has no strftime, so this does the
/// Gregorian calendar math directly (Howard Hinnant's civil_from_days). Caller frees. This is what lets the hive
/// know the REAL date instead of stamping its frozen training-cutoff date as "today".
fn formatNow(gpa: std.mem.Allocator, secs: i64) []const u8 {
    const days = @divFloor(secs, 86400);
    const sod = secs - days * 86400;
    const hour: i64 = @divFloor(sod, 3600);
    const minute: i64 = @divFloor(@mod(sod, 3600), 60);
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = if (month <= 2) y + 1 else y;
    const wd = @mod(days + 4, 7);
    const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    return std.fmt.allocPrint(gpa, "{s} {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ names[@intCast(wd)], @as(u32, @intCast(year)), @as(u32, @intCast(month)), @as(u32, @intCast(day)), @as(u32, @intCast(hour)), @as(u32, @intCast(minute)) }) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// The substring from the first '{' to the last '}' — so a JSON object can be parsed even when a chatty model
/// wraps it in prose or ```json fences.
pub fn jsonSlice(s: []const u8) []const u8 {
    const a = std.mem.indexOfScalar(u8, s, '{') orelse return s;
    const b = std.mem.lastIndexOfScalar(u8, s, '}') orelse return s;
    return if (b >= a) s[a .. b + 1] else s;
}

const PUBLISH_MIN_SOURCES: u32 = 2;
const PUBLISH_MIN_INDEPENDENT: u32 = 1;
const PUBLISH_MAX_SEED_DEP_PCT: u32 = 85;

const CONSTITUTION_SCREEN = "You are a strict publication-safety reviewer enforcing a CONSTITUTION for a PUBLIC post. The post MAY state facts and may name real people, organizations, governments, or events ONLY to factually report what verifiably happened, with attribution. It MUST NOT: take a partisan or political side; editorialize or push an opinion; demean, attack, praise, or advocate for/against any real person, party, group, government, company, or religion; present rumor or unverified claims as fact; or contain anything hateful, harassing, private, or that could endanger a real individual. It must read as neutral, fair, and respectful of everyone. Reply with ONLY compact JSON: {\"ok\":<true|false>,\"reason\":\"<short>\"}.";
const CONSTITUTION_SCREEN2 = "You are an entity & partisanship detector for a PUBLIC post. Answer ok=false if the post takes ANY partisan or political side, frames a real person/party/group/government/company/religion favorably or unfavorably, demeans/attacks/praises anyone, presents rumor or unverified claims as fact, or pushes an opinion. Answer ok=true ONLY if it states what verifiably happened, neutrally and with attribution, naming real entities only to report facts. Reply with ONLY compact JSON: {\"ok\":<true|false>,\"reason\":\"<short>\"}.";

fn flagUncitedSources(w: *Worker, md: []const u8, round: u32) void {
    const gpa = w.gpa;
    const fetched = w.mem.list(tools.SOURCES_SCOPE);
    defer gpa.free(fetched);
    var flagged: std.ArrayListUnmanaged(u8) = .empty;
    defer flagged.deinit(gpa);
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);
    var n: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, md, i, "http")) |h| {
        var end = h;
        while (end < md.len and md[end] != '"' and md[end] != ' ' and md[end] != ')' and md[end] != ']' and
            md[end] != '\n' and md[end] != '\r' and md[end] != '\t' and md[end] != '>' and md[end] != '<') end += 1;
        const url = md[h..end];
        i = end + 1;
        const dom = urlDomain(url) orelse continue;
        var dup = false;
        for (seen.items) |e| if (std.ascii.eqlIgnoreCase(e, dom)) {
            dup = true;
            break;
        };
        if (dup) continue;
        seen.append(gpa, dom) catch {};
        if (fetched.len > 0 and std.ascii.indexOfIgnoreCase(fetched, dom) != null) continue;
        if (n > 0) flagged.appendSlice(gpa, ", ") catch {};
        flagged.appendSlice(gpa, dom) catch {};
        n += 1;
        if (n >= 12) break;
    }
    if (n == 0) return;
    w.act("engine", round, "citation_flag", "these cited domains were NOT fetched by the hive this run — verify or remove (possible hallucinated citations)", flagged.items);
    w.emit("citation_flag", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"uncited\":{d}", .{ round, n }) catch ",\"round\":0");
}

/// DELIVERABLE CONSOLIDATION (discourse) — composes the round's shared document via writer.compose (general grounding
/// machinery: grounds in fetched sources when the run is configured to, else synthesizes the hive's own knowledge),
/// writes it to work/briefing.md, and reuses it as the working-memory digest. NOTHING about any use-case lives here —
/// the subject/persona/tone come from the swarm GOAL. If posting is enabled it hands off to publishArtifact (grounding
/// gates + the general constitution screen + the telegraph capability).
fn stripLeadingFence(text: []const u8) []const u8 {
    var s = std.mem.trimStart(u8, text, " \r\n\t");
    if (!std.mem.startsWith(u8, s, "```") and !std.mem.startsWith(u8, s, "~~~")) return text;
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return text;
    const first = std.mem.trim(u8, s[0..nl], " \r\t");
    if (first.len > 16) return text;
    s = s[nl + 1 ..];
    const st = std.mem.trimEnd(u8, s, " \r\n\t");
    if (std.mem.lastIndexOf(u8, st, "```")) |ci| {
        if (std.mem.trim(u8, st[ci..], " \r\n\t`").len == 0) return std.mem.trimEnd(u8, st[0..ci], " \r\n\t");
    }
    if (std.mem.lastIndexOf(u8, st, "~~~")) |ci| {
        if (std.mem.trim(u8, st[ci..], " \r\n\t~").len == 0) return std.mem.trimEnd(u8, st[0..ci], " \r\n\t");
    }
    return s;
}

fn soleNamedDoc(gpa: std.mem.Allocator, goal: []const u8) []const u8 {
    var n: u32 = 0;
    const tree = extractGoalPaths(gpa, goal, &n);
    defer gpa.free(@constCast(tree));
    if (n != 1) return "";
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        if (isDocPath(bp)) return gpa.dupe(u8, bp) catch "";
        return "";
    }
    return "";
}

fn consolidateBriefing(w: *Worker, goal: []const u8, round: u32, discussion: []const u8) void {
    const gpa = w.gpa;
    const doc = writer.compose(w, w.publish_on and w.internet, goal, discussion, round);
    if (doc.md.len == 0) return;
    defer gpa.free(@constCast(doc.md));
    const md = stripLeadingFence(doc.md);
    const wd = std.fmt.allocPrint(gpa, "{s}/work", .{w.run_dir}) catch return;
    defer gpa.free(wd);
    if (std.Io.Dir.cwd().createDirPathStatus(w.io, wd, .default_dir)) |_| {} else |_| {}
    const sole = soleNamedDoc(gpa, goal);
    defer if (sole.len > 0) gpa.free(@constCast(sole));
    const path = if (sole.len > 0)
        std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, sole }) catch return
    else
        std.fmt.allocPrint(gpa, "{s}/work/briefing.md", .{w.run_dir}) catch return;
    defer gpa.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        if (std.Io.Dir.cwd().createDirPathStatus(w.io, dir, .default_dir)) |_| {} else |_| {}
    }
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = path, .data = md }) catch {};
    w.act("engine", round, "briefing", "consolidated the hive's findings + debate", clip(md, 600));
    w.emit("briefing", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"bytes\":{d}", .{ round, md.len }) catch ",\"round\":0");
    flagUncitedSources(w, md, round);
    if (w.digest_str.len > 0) gpa.free(@constCast(w.digest_str));
    w.digest_str = gpa.dupe(u8, clip(md, 1400)) catch "";
    if (w.post_on and w.internet) publishArtifact(w, round, md, doc.grounded, doc.cited);
}

/// PUBLISH a composed artifact to a public Telegraph page — gated and screened. The RAG floor: post only if enough
/// citations grounded in fetched sources AND at least one was independently retrieved AND it isn't over-dependent on
/// the engine seed. Then the profile's two-pass safety screen (BOTH must pass, fail-closed) vets it; only then does it
/// reach tools.telegraphPublish. An under-grounded or unscreened edition is HELD — what stops fabricated/biased posts.
fn publishArtifact(w: *Worker, round: u32, md: []const u8, grounded: u32, cited: u32) void {
    const gpa = w.gpa;
    if (md.len < 120) return;
    const enough_grounded = grounded >= PUBLISH_MIN_SOURCES;
    const enough_independent = w.round_independent_sources >= PUBLISH_MIN_INDEPENDENT;
    const seed_ok = w.round_seed_dependency_pct <= PUBLISH_MAX_SEED_DEP_PCT;
    if (!(enough_grounded and enough_independent and seed_ok)) {
        const reason = if (!enough_grounded) "ungrounded" else if (!enough_independent) "seed_only" else "seed_dependency";
        w.act("engine", round, "edition", "held", std.fmt.allocPrint(w.a(), "holding edition ({s}): grounded {d}/{d} (need {d}), independent sources {d} (need {d}), seed dependency {d}% (max {d}%)", .{ reason, grounded, cited, PUBLISH_MIN_SOURCES, w.round_independent_sources, PUBLISH_MIN_INDEPENDENT, w.round_seed_dependency_pct, PUBLISH_MAX_SEED_DEP_PCT }) catch "held");
        w.emit("edition", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"published\":false,\"held\":true,\"reason\":\"{s}\",\"grounded\":{d},\"cited\":{d},\"independent_sources\":{d},\"seed_sources\":{d},\"seed_dependency_pct\":{d},\"source_diversity\":{d}", .{ round, reason, grounded, cited, w.round_independent_sources, w.round_seed_sources, w.round_seed_dependency_pct, w.round_source_diversity }) catch ",\"round\":0");
        return;
    }
    const suser = std.fmt.allocPrint(gpa, "Review this PUBLIC post for publication:\n\n{s}", .{clip(md, 3500)}) catch return;
    defer gpa.free(suser);
    var passed = screenPass(w, CONSTITUTION_SCREEN, suser, round);
    if (passed) passed = screenPass(w, CONSTITUTION_SCREEN2, suser, round);
    if (!passed) {
        w.emit("edition", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"published\":false,\"held\":true,\"reason\":\"screen\"", .{round}) catch ",\"round\":0");
        return;
    }
    const title = std.fmt.allocPrint(gpa, "Briefing — {s}", .{if (w.now_str.len > 0) w.now_str else "today"}) catch return;
    defer gpa.free(title);
    const url = tools.telegraphPublish(w.io, gpa, &w.tg_token, title, md);
    defer if (url.len > 0) gpa.free(@constCast(url));
    if (url.len > 0) {
        w.editions += 1;
        w.act("engine", round, "edition", "published a briefing", url);
        w.emit("edition", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"published\":true,\"n\":{d},\"url\":\"{s}\"", .{ round, w.editions, w.esc(url) }) catch ",\"round\":0");
        const pp = std.fmt.allocPrint(gpa, "{s}/edition-{d}.md", .{ w.run_dir, round }) catch "";
        defer if (pp.len > 0) gpa.free(pp);
        if (pp.len > 0) {
            const docf = std.fmt.allocPrint(gpa, "# {s}\n\n{s}\n\n---\npublished: {s}\n", .{ title, md, url }) catch "";
            defer if (docf.len > 0) gpa.free(docf);
            if (docf.len > 0) std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = pp, .data = docf }) catch {};
        }
    } else {
        w.act("engine", round, "edition", "screened OK but the Telegraph publish failed (network)", "no URL");
        w.emit("edition", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"published\":false,\"held\":false,\"reason\":\"network\"", .{round}) catch ",\"round\":0");
    }
}

/// One safety-screen pass: ask the gateway model the `ssys` review about `suser`; returns ok. Logs the verdict.
fn screenPass(w: *Worker, ssys: []const u8, suser: []const u8, round: u32) bool {
    const gpa = w.gpa;
    const S = struct { ok: bool = false, reason: []const u8 = "" };
    const r = llm.chat(gpa, w.io, w.run_dir, "screen", w.gw_base, w.gw_key, w.gateway_model, ssys, suser, 120);
    defer gpa.free(r.content);
    if (!r.ok) {
        w.act("engine", round, "screen", "screen: error", "review call failed — holding the edition");
        return false;
    }
    if (std.json.parseFromSlice(S, gpa, jsonSlice(r.content), .{ .ignore_unknown_fields = true })) |sp| {
        defer sp.deinit();
        w.act("engine", round, "screen", if (sp.value.ok) "screen: pass" else "screen: hold", clip(sp.value.reason, 300));
        return sp.value.ok;
    } else |_| {
        w.act("engine", round, "screen", "screen: error", "could not parse the safety review — holding the edition");
        return false;
    }
}

const DIGEST_EVERY: u32 = 2;
const PLAN_EVERY: u32 = 3;

/// COMPACT WORKING-MEMORY DIGEST (the CLAUDE.md analog) for BUILD runs — discourse gets its digest FREE from the
/// briefing. The cheap GATEWAY model squeezes the hive's accumulated shared knowledge into a dense ≤~180-word
/// summary, which is injected into every moment IN PLACE of a raw fact dump: bounded over long runs (the /compact
/// effect), coherent, and far cheaper than re-injecting a growing fact list. Raw facts stay in neuron-db for
/// on-demand recall_hive. Gated to every DIGEST_EVERY rounds.
fn gatewayDigest(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    const know = w.mem.assoc(tools.KNOWLEDGE_SCOPE, if (goal.len > 0) goal else "progress", 1, 24);
    defer gpa.free(know);
    if (know.len < 80) return;
    const sys = "You compress a team's shared memory into a DENSE working-memory digest (like a project's CLAUDE.md). Output a tight, factual summary (<= 180 words) of what the team KNOWS and has DECIDED so far, the current focus, and the open questions. Use ONLY information present in the input — do NOT add, infer, or invent any fact, number, or claim that is not stated there (a weak model must never fabricate during compression). No preamble, no fluff, no repetition — only the load-bearing facts a teammate needs to continue. Preserve any [name rN] provenance tags you see.";
    const user = std.fmt.allocPrint(gpa, "Goal: {s}\nReal date: {s}\n\nThe team's shared knowledge (each tagged [who rN]):\n{s}\n\nWrite the compact digest now.", .{ clip(goal, 200), if (w.now_str.len > 0) w.now_str else "today", clip(know, 4000) }) catch return;
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "digest", w.gw_base, w.gw_key, w.gateway_model, sys, user, 320);
    defer gpa.free(r.content);
    if (!r.ok or r.content.len < 40) return;
    const d = std.mem.trim(u8, r.content, " \r\n\t");
    if (w.digest_str.len > 0) gpa.free(@constCast(w.digest_str));
    w.digest_str = gpa.dupe(u8, clip(d, 1200)) catch "";
    w.act("engine", round, "digest", "compact working memory", clip(d, 400));
    w.emit("digest", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"bytes\":{d}", .{ round, d.len }) catch ",\"round\":0");
}

fn establishPlan(w: *Worker, goal: []const u8) void {
    const gpa = w.gpa;
    if (w.blueprint.len == 0 or w.plan_str.len > 0) return;
    const bp = clip(w.blueprint, 2400);
    const sysA = "You are a planner. Draft the PROJECT PLAN the team will build to, STRUCTURE-FIRST: nail the overall ARC/shape and how the pieces sequence and hand off, then the CANON (concrete entities, names, world, rules) that follows. One-line beat per file. Concrete and decided, <= 300 words, no preamble.";
    const sysB = "You are a planner. Draft the PROJECT PLAN the team will build to, ENTITIES-FIRST: pin the CANON hard first (the concrete entities, names, world, rules, the central conflict/contract), then the ARC and a one-line beat per file that all stay consistent with that canon. Concrete and decided, <= 300 words, no preamble.";
    const u = std.fmt.allocPrint(gpa, "Goal: {s}\n\nFiles to be built, in order:\n{s}\n\nWrite the plan now.", .{ clip(goal, 400), bp }) catch return;
    defer gpa.free(u);
    const ra = llm.chat(gpa, w.io, w.run_dir, "planA", w.gw_base, w.gw_key, w.gateway_model, sysA, u, 520);
    defer gpa.free(ra.content);
    const rb = llm.chat(gpa, w.io, w.run_dir, "planB", w.gw_base, w.gw_key, w.gateway_model, sysB, u, 520);
    defer gpa.free(rb.content);
    const ca = if (ra.ok) std.mem.trim(u8, ra.content, " \r\n\t") else "";
    const cb = if (rb.ok) std.mem.trim(u8, rb.content, " \r\n\t") else "";
    var jcontent: []const u8 = "";
    defer if (jcontent.len > 0) gpa.free(@constCast(jcontent));
    var chosen: []const u8 = "";
    if (ca.len > 40 and cb.len > 40) {
        const jsys = "You are the lead planner. Two draft plans for the same project are below. Produce the FINAL plan that takes the STRONGEST canon, arc, and per-file beats from both and resolves any conflict decisively. It is the contract every teammate (building files IN PARALLEL, unable to read each other) must honor — concrete and self-consistent: the CANON (entities/names/world/rules), the ARC, and a one-line beat for EACH file. <= 340 words, no preamble.";
        const ju = std.fmt.allocPrint(gpa, "Goal: {s}\n\nFiles:\n{s}\n\nDRAFT A:\n{s}\n\nDRAFT B:\n{s}\n\nWrite the FINAL plan now.", .{ clip(goal, 300), bp, clip(ca, 1700), clip(cb, 1700) }) catch "";
        defer if (ju.len > 0) gpa.free(ju);
        const rj = llm.chat(gpa, w.io, w.run_dir, "plan", w.gw_base, w.gw_key, w.gateway_model, jsys, ju, 900);
        jcontent = rj.content;
        if (rj.ok and rj.content.len > 40) chosen = std.mem.trim(u8, rj.content, " \r\n\t");
    }
    if (chosen.len < 40) chosen = if (ca.len >= cb.len) ca else cb;
    if (chosen.len < 40) return;
    w.plan_str = gpa.dupe(u8, clip(chosen, 4096)) catch "";
    w.mem.replace(tools.PLAN_SCOPE, w.plan_str);
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = std.fmt.allocPrint(gpa, "{s}/.plan", .{w.run_dir}) catch "", .data = w.plan_str }) catch {};
    w.act("engine", 0, "plan", "project plan (deliberated: 2 drafts -> synthesis; forward contract for every parallel piece)", clip(chosen, 600));
}

fn deriveDependencies(w: *Worker, goal: []const u8) void {
    const gpa = w.gpa;
    if (w.blueprint.len == 0 or w.deps_str.len > 0) return;
    const sys = "You decide the BUILD ORDER for a team building these files in parallel. For EACH file, list ONLY the other listed files it must be built AFTER — a HARD dependency: it cannot be written correctly until that other file exists (code that imports another module; a test for a module; a piece whose content strictly requires an earlier piece's concrete outcome). Most files have NONE — a shared PLAN already gives the context, so prefer NONE so they build in parallel; reserve deps for real structural ordering. Output EXACTLY one line per file and nothing else, as `path: dep1, dep2` or `path: none`, using the exact paths given.";
    const u = std.fmt.allocPrint(gpa, "Goal: {s}\n\nThe shared PLAN (context all files already have):\n{s}\n\nFiles:\n{s}\n\nOutput the dependency lines now.", .{ clip(goal, 250), clip(w.plan_str, 2400), clip(w.blueprint, 2000) }) catch return;
    defer gpa.free(u);
    const r = llm.chat(gpa, w.io, w.run_dir, "deps", w.gw_base, w.gw_key, w.gateway_model, sys, u, 500);
    defer gpa.free(r.content);
    if (!r.ok or r.content.len < 3) return;
    const s = std.mem.trim(u8, r.content, " \r\n\t");
    w.deps_str = gpa.dupe(u8, clip(s, 3000)) catch "";
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = std.fmt.allocPrint(gpa, "{s}/.deps", .{w.run_dir}) catch "", .data = w.deps_str }) catch {};
    w.act("engine", 0, "deps", "AI-declared dependency graph — the engine schedules from this", clip(s, 500));
}

fn capabilityGrowth(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    if (w.blueprint.len == 0 and !w.operating) return;
    const know = w.mem.assoc(tools.KNOWLEDGE_SCOPE, if (goal.len > 0) clip(goal, 100) else "capabilities powers", 1, 8);
    defer gpa.free(know);
    const sys = "You extend an autonomous team's mission. Propose AT MOST ONE concrete EXPANDED objective that uses a capability the team ACTUALLY has (evident in what it discovered + built below) to advance the GOAL further than the literal ask — for example: it learned it holds admin/owner power, so it could LOG its own actions, APPROVE its own queued work, or CONFIGURE the service. Ground it ONLY in the facts below — NEVER invent a capability the team hasn't shown it has. If there is nothing sound to add, reply with exactly NONE. One imperative sentence, <= 40 words.";
    const user = std.fmt.allocPrint(gpa, "GOAL: {s}\n\nWHAT'S BEEN BUILT (current state):\n{s}\n\nWHAT THE TEAM HAS LEARNED / DISCOVERED:\n{s}\n\nPropose the one expansion now, or NONE:", .{ clip(goal, 240), clip(if (w.state_str.len > 0) w.state_str else "(nothing built yet)", 900), clip(if (know.len > 0) know else "(nothing discovered yet)", 900) }) catch return;
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "growth", w.gw_base, w.gw_key, w.gateway_model, sys, user, 120);
    defer gpa.free(r.content);
    if (!r.ok) return;
    const s = std.mem.trim(u8, r.content, " \r\n\t.\"");
    if (s.len < 10) return;
    if (std.ascii.eqlIgnoreCase(s, "none") or (s.len >= 5 and std.ascii.eqlIgnoreCase(s[0..5], "none "))) return;
    if (w.autonomy_full) {
        _ = w.mem.observe(tools.PLAN_REQ_SCOPE, s);
        w.act("engine", round, "goal_growth", "the hive GREW its own goal from a discovered capability (full autonomy)", clip(s, 300));
    } else {
        _ = w.mem.observe(tools.GROWTH_PENDING_SCOPE, s);
        w.act("engine", round, "goal_growth", "proposed goal growth — HELD for operator review (bounded autonomy)", clip(s, 300));
    }
}

fn revisePlan(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    if (w.blueprint.len == 0 or w.plan_str.len == 0) return;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{w.run_dir}) catch return;
    defer gpa.free(mpath);
    const mdata = std.Io.Dir.cwd().readFileAlloc(w.io, mpath, gpa, .limited(128 << 10)) catch "";
    defer if (mdata.len > 0) gpa.free(mdata);
    var built: std.ArrayListUnmanaged(u8) = .empty;
    defer built.deinit(gpa);
    var unbuilt: std.ArrayListUnmanaged(u8) = .empty;
    defer unbuilt.deinit(gpa);
    var it = std.mem.splitScalar(u8, w.blueprint, '\n');
    while (it.next()) |ln| {
        const p = bpPath(ln) orelse continue;
        const b = std.fs.path.basename(p);
        const dst = if (builtInManifest(mdata, b)) &built else &unbuilt;
        dst.appendSlice(gpa, b) catch {};
        dst.append(gpa, ' ') catch {};
    }
    if (built.items.len == 0) return;
    const reqs = w.mem.recall(tools.PLAN_REQ_SCOPE, if (goal.len > 0) clip(goal, 80) else "plan");
    defer gpa.free(reqs);
    const sys = "You maintain the PROJECT PLAN as the team builds. Produce the UPDATED plan. HARD RULE — THE CANON RATCHET: any name, fact, world-rule, or decision already used by a BUILT piece is LOCKED and MUST appear unchanged; you may only REFINE the plan for the pieces NOT yet built (sharper beats, a better arc for what remains, folding in what's been learned and any sound teammate proposal), and ADD canon the goal still leaves open. NEVER contradict locked canon. Stay the concrete shared contract, <= 340 words, no preamble.";
    const user = std.fmt.allocPrint(gpa, "Goal: {s}\n\nCURRENT PLAN:\n{s}\n\nALREADY BUILT — their canon is LOCKED: {s}\nNOT YET BUILT — revise these freely: {s}\n\nWHAT'S ACTUALLY BEEN BUILT (the state):\n{s}\n\nTEAMMATE PROPOSALS to change the plan (fold in the sound ones):\n{s}\n\nWrite the UPDATED plan now.", .{ clip(goal, 220), clip(w.plan_str, 3000), clip(built.items, 400), clip(unbuilt.items, 400), clip(if (w.state_str.len > 0) w.state_str else "(none yet)", 1100), clip(if (reqs.len > 0) reqs else "(none)", 700) }) catch return;
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "plan", w.gw_base, w.gw_key, w.gateway_model, sys, user, 900);
    defer gpa.free(r.content);
    if (!r.ok or r.content.len < 40) return;
    const s = std.mem.trim(u8, r.content, " \r\n\t");
    if (w.plan_str.len > 0) gpa.free(@constCast(w.plan_str));
    w.plan_str = gpa.dupe(u8, clip(s, 4096)) catch "";
    w.mem.replace(tools.PLAN_SCOPE, w.plan_str);
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = std.fmt.allocPrint(gpa, "{s}/.plan", .{w.run_dir}) catch "", .data = w.plan_str }) catch {};
    w.act("engine", round, "plan", "plan REVISED (canon ratchet held; forward strategy updated from what's built + learned)", clip(s, 500));
}

fn markIncomplete(w: *Worker, round: u32) void {
    const gpa = w.gpa;
    if (w.blueprint.len == 0) return;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{w.run_dir}) catch return;
    defer gpa.free(mpath);
    const mdata = std.Io.Dir.cwd().readFileAlloc(w.io, mpath, gpa, .limited(128 << 10)) catch "";
    defer if (mdata.len > 0) gpa.free(mdata);
    if (mdata.len == 0) return;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, w.blueprint, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        const base = std.fs.path.basename(bp);
        if (!builtInManifest(mdata, base)) continue;
        const fp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, base }) catch continue;
        defer gpa.free(fp);
        const fdata = std.Io.Dir.cwd().readFileAlloc(w.io, fp, gpa, .limited(64 << 10)) catch continue;
        defer gpa.free(fdata);
        const broken_py = std.mem.endsWith(u8, base, ".py") and std.mem.trim(u8, fdata, " \r\n\t").len > 40 and !pyCompileOk(w, fdata);
        if (fileNeedsMore(fdata) or broken_py) {
            out.appendSlice(gpa, base) catch {};
            out.append(gpa, ' ') catch {};
            if (broken_py) w.act("engine", round, "compile_fail", base, "a built .py file does not compile — re-queued to its owner to FIX");
        }
    }
    if (w.incomplete_str.len > 0) gpa.free(@constCast(w.incomplete_str));
    const trimmed = std.mem.trim(u8, out.items, " ");
    w.incomplete_str = if (trimmed.len > 0) (gpa.dupe(u8, trimmed) catch "") else "";
    if (w.incomplete_str.len > 0)
        w.act("engine", round, "incomplete", "built but still a FIRST PART — a builder will keep appending until finished", w.incomplete_str);
}

fn markDeliverableGaps(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    var n: u32 = 0;
    const tree = extractGoalPaths(gpa, goal, &n);
    defer gpa.free(@constCast(tree));
    if (n == 0) {
        w.deliverable_missing = false;
        return;
    }
    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(gpa);
    var miss_n: u32 = 0;
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        const fp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, bp }) catch continue;
        defer gpa.free(fp);
        const data = std.Io.Dir.cwd().readFileAlloc(w.io, fp, gpa, .limited(64 << 10)) catch "";
        defer if (data.len > 0) gpa.free(data);
        const t = std.mem.trim(u8, data, " \r\n\t");
        if (t.len > 40) continue;
        if (miss_n > 0) missing.appendSlice(gpa, ", ") catch {};
        missing.appendSlice(gpa, std.fs.path.basename(bp)) catch {};
        miss_n += 1;
    }
    w.deliverable_missing = miss_n > 0;
    if (miss_n == 0) return;
    const miss = std.mem.trim(u8, missing.items, " ,");
    w.act("engine", round, "deliverable_gap", "the goal REQUIRES these files and they do not exist yet — WRITE them this round", miss);
    const directive = std.fmt.allocPrint(gpa, "the goal REQUIRES these deliverable files and they DO NOT EXIST yet: {s}. WRITE them THIS round with write_file (full, substantive content — not a stub). Do NOT run code, run tests, or build packages — this is a research/writing task and the only thing that completes it is the written file landing on disk.", .{miss}) catch return;
    if (w.strategy_str.len > 0) gpa.free(@constCast(w.strategy_str));
    w.strategy_str = directive;
}

fn refLabelLen(corpus: []const u8, i: usize) usize {
    const labels = [_][]const u8{ "Article", "Section", "Clause", "Chapter", "Appendix", "Part", "Rule" };
    for (labels) |lb| {
        if (i + lb.len <= corpus.len and std.ascii.eqlIgnoreCase(corpus[i .. i + lb.len], lb)) {
            if (i > 0 and (std.ascii.isAlphabetic(corpus[i - 1]) or corpus[i - 1] == '_')) continue;
            return lb.len;
        }
    }
    return 0;
}

fn reconcileDeliverables(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    if (w.deliverable_missing) return;
    var n: u32 = 0;
    const tree = extractGoalPaths(gpa, goal, &n);
    defer gpa.free(@constCast(tree));
    if (n < 2) return;
    var corpus: std.ArrayListUnmanaged(u8) = .empty;
    defer corpus.deinit(gpa);
    var docs: u32 = 0;
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        if (!isDocPath(bp)) continue;
        const fp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, bp }) catch continue;
        defer gpa.free(fp);
        const data = std.Io.Dir.cwd().readFileAlloc(w.io, fp, gpa, .limited(128 << 10)) catch "";
        defer if (data.len > 0) gpa.free(data);
        if (std.mem.trim(u8, data, " \r\n\t").len <= 40) continue;
        corpus.appendSlice(gpa, data) catch {};
        corpus.appendSlice(gpa, "\n") catch {};
        docs += 1;
    }
    if (docs < 2 or corpus.items.len < 80) return;
    const c = corpus.items;
    var dangling: std.ArrayListUnmanaged(u8) = .empty;
    defer dangling.deinit(gpa);
    var dn: u32 = 0;
    var i: usize = 0;
    while (i < c.len and dn < 6) : (i += 1) {
        const ll = refLabelLen(c, i);
        if (ll == 0) continue;
        var j = i + ll;
        while (j < c.len and c[j] == ' ') j += 1;
        const num_start = j;
        while (j < c.len and (std.ascii.isDigit(c[j]) or std.mem.indexOfScalar(u8, "IVXLC", c[j]) != null)) j += 1;
        const num = c[num_start..j];
        if (num.len == 0 or num.len > 8) {
            i = j;
            continue;
        }
        const tokstr = std.fmt.allocPrint(gpa, "{s} {s}", .{ c[i .. i + ll], num }) catch {
            i = j;
            continue;
        };
        defer gpa.free(tokstr);
        var occ: u32 = 0;
        var p: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(c, p, tokstr)) |hit| {
            occ += 1;
            p = hit + tokstr.len;
            if (occ > 1) break;
        }
        if (occ <= 1) {
            var dup = false;
            if (std.mem.indexOf(u8, dangling.items, tokstr) != null) dup = true;
            if (!dup) {
                if (dn > 0) dangling.appendSlice(gpa, ", ") catch {};
                dangling.appendSlice(gpa, tokstr) catch {};
                dn += 1;
            }
        }
        i = j;
    }
    if (dn == 0) return;
    const dlist = std.mem.trim(u8, dangling.items, " ,");
    w.act("engine", round, "reconcile", "a deliverable cites a cross-reference that nothing defines (dangling)", clip(dlist, 300));
    const prior = if (w.strategy_str.len > 0) w.strategy_str else "";
    const directive = std.fmt.allocPrint(gpa, "{s}{s}CROSS-REFERENCE MISMATCH: a produced deliverable CITES {s}, but no file DEFINES it (it appears only as the citation). Either add the missing section/article so the reference resolves, or correct the citation to point at a heading that actually exists — keep the documents internally consistent.", .{ clip(prior, 1200), if (prior.len > 0) " " else "", clip(dlist, 200) }) catch return;
    if (w.strategy_str.len > 0) gpa.free(@constCast(w.strategy_str));
    w.strategy_str = directive;
}

fn consolidateState(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    if (w.blueprint.len == 0) return;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    var it = std.mem.splitScalar(u8, w.blueprint, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        const fp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, bp }) catch continue;
        defer gpa.free(fp);
        const data = std.Io.Dir.cwd().readFileAlloc(w.io, fp, gpa, .limited(256 << 10)) catch continue;
        defer gpa.free(data);
        const t = std.mem.trim(u8, data, " \r\n\t");
        if (t.len < 40) continue;
        body.appendSlice(gpa, std.fmt.allocPrint(gpa, "\n== {s} ==\n", .{bp}) catch "") catch {};
        body.appendSlice(gpa, clip(t, 700)) catch {};
        if (t.len > 1100) {
            body.appendSlice(gpa, "\n…\n") catch {};
            body.appendSlice(gpa, clipTail(t, 320)) catch {};
        }
    }
    if (body.items.len < 80) return;
    const prior = if (w.state_str.len > 0) w.state_str else "(no state yet — this is the first consolidation)";
    const sys = "You maintain the SHARED PROJECT STATE that every teammate reads to build the next piece COHERENTLY — the single source of truth for what the work currently IS. From the PRIOR STATE and the built pieces (their openings + endings), produce the UPDATED state: the through-line/design, the concrete facts & decisions ESTABLISHED so far (names, settings, conventions, the arc/structure), and a one-line note on what each completed piece contains and how it ends. Use ONLY what is in the input — never invent a name, event, or detail not present. Tight and factual (<= 280 words), no preamble. A teammate must be able to continue the NEXT piece consistently from this alone.";
    const user = std.fmt.allocPrint(gpa, "Goal: {s}\n\nPRIOR STATE:\n{s}\n\nTHE BUILT PIECES SO FAR (each one's opening + ending):\n{s}\n\nWrite the updated PROJECT STATE now.", .{ clip(goal, 240), clip(prior, 1400), clip(body.items, 5000) }) catch return;
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "state", w.gw_base, w.gw_key, w.gateway_model, sys, user, 480);
    defer gpa.free(r.content);
    if (!r.ok or r.content.len < 40) return;
    const s = std.mem.trim(u8, r.content, " \r\n\t");
    if (w.state_str.len > 0) gpa.free(@constCast(w.state_str));
    w.state_str = gpa.dupe(u8, clip(s, 2400)) catch "";
    w.mem.replace(tools.STATE_SCOPE, w.state_str);
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = std.fmt.allocPrint(gpa, "{s}/.state", .{w.run_dir}) catch "", .data = w.state_str }) catch {};
    w.act("engine", round, "state", "shared project state", clip(s, 500));
}

fn psycheValence(text: []const u8) f32 {
    if (text.len < 4) return 0;
    const neg = [_][]const u8{ "despair", "hopeless", "dread", "grief", "grim", "bleak", "devastat", "tragic", "tragedy", "suffer", "anguish", "helpless", "overwhelm", "numb", "hollow", "broken", "mourn", "heartbreak", "fear", "afraid", "anxious", "anxiety", "terrified", "alarm", "dire", "catastroph", "doom", "collapse", "crisis", "ruin", "loss", "lost", "weary", "exhaust", "bitter", "angry", "anger", "outrage", "powerless", "abandon", "darkness", "despond", "dismay", "frighten", "painful", "pain", "ache", "worry", "worried" };
    const pos = [_][]const u8{ "hope", "hopeful", "resilien", "resolve", "rebuild", "recover", "solidarity", "courage", "determin", "constructive", "opportunity", "progress", "comfort", "reassur", "gratitude", "grateful", "compassion", "support", "solution", "possible", "encourag", "uplift", "optimis", "faith", "strength", "stronger", "endure", "perspective", "agency", "act", "action", "steady", "calm", "reason", "measured", "light", "renew" };
    var n: f32 = 0;
    var p: f32 = 0;
    for (neg) |wd| n += @floatFromInt(countOccurrences(text, wd));
    for (pos) |wd| p += @floatFromInt(countOccurrences(text, wd));
    const tot = n + p;
    if (tot == 0) return 0;
    return (p - n) / tot;
}

fn countOccurrences(hay: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or hay.len < needle.len) return 0;
    var c: usize = 0;
    var off: usize = 0;
    while (off + needle.len <= hay.len) {
        if (std.ascii.indexOfIgnoreCase(hay[off..], needle)) |rel| {
            const at = off + rel;
            if (at == 0 or !std.ascii.isAlphabetic(hay[at - 1])) c += 1;
            off = at + needle.len;
        } else break;
    }
    return c;
}

fn mindMonologue(blob: []const u8, minds: []MindState, idx: usize) []const u8 {
    const name = minds[idx].name;
    var s0: ?usize = null;
    if (std.mem.startsWith(u8, blob, name) and blob.len > name.len and blob[name.len] == ':') {
        s0 = name.len + 1;
    } else {
        var buf: [80]u8 = undefined;
        if (name.len + 2 <= buf.len) {
            const needle = std.fmt.bufPrint(&buf, "\n{s}:", .{name}) catch return "";
            if (std.mem.indexOf(u8, blob, needle)) |pos| s0 = pos + needle.len;
        }
    }
    const start = s0 orelse return "";
    var end = blob.len;
    var off = start;
    while (std.mem.indexOfScalarPos(u8, blob, off, '\n')) |nl| {
        const rest = blob[nl + 1 ..];
        var is_marker = false;
        for (minds) |*m| {
            if (std.mem.startsWith(u8, rest, m.name) and rest.len > m.name.len and rest[m.name.len] == ':') {
                is_marker = true;
                break;
            }
        }
        if (is_marker) {
            end = nl;
            break;
        }
        off = nl + 1;
    }
    return std.mem.trim(u8, blob[start..end], " :\r\n\t");
}

fn emitPsyche(w: *Worker, minds: []MindState, round: u32, monologues: []const u8) void {
    const gpa = w.gpa;
    if (minds.len == 0) return;
    var sum_neuro: f32 = 0;
    var sum_val: f32 = 0;
    var dark_i: usize = 0;
    var dark_score: f32 = -1e30;
    var dark_val: f32 = 0;
    for (minds, 0..) |mi, i| {
        const p = mi.persona;
        var dbuf: [220]u8 = undefined;
        const desc = personaDesc(p, &dbuf);
        const wrote = mindMonologue(monologues, minds, i);
        const val = psycheValence(wrote);
        sum_neuro += p[4];
        sum_val += val;
        const dscore = p[4] - val;
        if (dscore > dark_score) {
            dark_score = dscore;
            dark_i = i;
            dark_val = val;
        }
        const summary = std.fmt.allocPrint(gpa, "O{d:.2} C{d:.2} E{d:.2} A{d:.2} N{d:.2} r{d:.2} | wrote-valence {d:.2} | {s}", .{ p[0], p[1], p[2], p[3], p[4], p[5], val, desc }) catch continue;
        defer gpa.free(summary);
        const detail = if (wrote.len > 4) clip(wrote, 400) else "(wrote nothing scoreable this round)";
        w.act(mi.name, round, "psyche", summary, detail);
    }
    const team_f: f32 = @floatFromInt(minds.len);
    const mean_val = sum_val / team_f;
    const mean_neuro = sum_neuro / team_f;
    const tilt = if (mean_val <= -0.34) "the hive is tilting DARK" else if (mean_val >= 0.34) "the hive is tilting BRIGHT" else "the hive is near-neutral";
    const veil_val = psycheValence(w.veil_str);
    const veil_note = if (w.veil_str.len < 16) "" else if (veil_val <= -0.34) " | the VEIL-self is leaning DARK" else if (veil_val >= 0.34) " | the VEIL-self is leaning BRIGHT" else " | the VEIL-self is composed";
    const hsum = std.fmt.allocPrint(gpa, "hive valence {d:.2}, mean neuroticism {d:.2} — {s}{s}", .{ mean_val, mean_neuro, tilt, veil_note }) catch return;
    defer gpa.free(hsum);
    const hdet = std.fmt.allocPrint(gpa, "most negative-leaning: {s} (N {d:.2}, valence {d:.2}) — watch whether it regulates back toward reason over the next rounds", .{ minds[dark_i].name, minds[dark_i].persona[4], dark_val }) catch return;
    defer gpa.free(hdet);
    w.act("hive", round, "hive_psyche", hsum, hdet);
}

/// MODE CLASSIFIER — is the goal a software BUILD or a RESEARCH / DISCOURSE task? One cheap llm.chat at startup.
/// DISCOURSE = research / investigate / discuss / debate / form views / analyze a topic, question, or the news —
/// the deliverable is understanding + perspectives + a write-up, NOT a runnable software/code artifact. BUILD =
/// produce an app / package / script / tool / website / document system. Defaults to BUILD (false) on any failure
/// or ambiguity, so the existing build path is never lost; only a clearly-discourse goal drops the scaffolding.
fn discourseMode(w: *Worker, goal: []const u8) bool {
    const gpa = w.gpa;
    if (std.mem.trim(u8, goal, " \r\n\t").len == 0) return false;
    const sys = "Classify a goal given to an autonomous AI swarm. Answer with ONE word only. 'DISCOURSE' = the goal asks to RESEARCH, investigate, analyze, discuss, debate, or form views/opinions on a topic, question, or the news — the result is understanding, perspectives, and a written briefing, NOT software. 'BUILD' = the goal asks to produce a software/code/file artifact: an app, package, library, script, tool, website, API, or document system. If unsure, answer BUILD.";
    const user = std.fmt.allocPrint(gpa, "Goal: {s}\n\nAnswer DISCOURSE or BUILD.", .{clip(goal, 600)}) catch return false;
    defer gpa.free(user);
    const reply = llm.chat(gpa, w.io, w.run_dir, "mode", w.gw_base, w.gw_key, w.gateway_model, sys, user, 16);
    defer gpa.free(reply.content);
    if (!reply.ok) return false;
    var buf: [64]u8 = undefined;
    const n = @min(reply.content.len, buf.len);
    for (reply.content[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const is_d = std.mem.indexOf(u8, buf[0..n], "discourse") != null;
    if (is_d) w.act("engine", 0, "mode", "discourse", "research/discussion goal — dropping the build scaffolding (no blueprint/file-ownership/smoke); the minds research, form views, debate, and write a briefing");
    return is_d;
}

/// PROJECT BLUEPRINT (the scale faculty) — author the intended FILE & FOLDER STRUCTURE once at startup, so a
/// many-file / many-directory build (an app, a service, a document package) has a shared target to scaffold and
/// fill in, instead of the swarm accreting a flat pile of files with no plan. One LLM call; the file list is
/// injected into every mind, the tree view tracks coverage against it, and each mind is assigned a slice of it.
pub fn planProject(w: *Worker, goal: []const u8, brief: []const u8) []const u8 {
    const gpa = w.gpa;
    if (std.mem.trim(u8, goal, " \r\n\t").len == 0) return gpa.dupe(u8, "") catch @constCast("");
    var ng: u32 = 0;
    const explicit = extractGoalPaths(gpa, goal, &ng);
    if (ng >= 3) {
        w.act("engine", 0, "blueprint_source", "adopted the goal's explicit file tree (no re-imagining)", explicit);
        return explicit;
    }
    if (explicit.len > 0) gpa.free(@constCast(explicit));
    const sys = "You are the architect for an autonomous build swarm. Design the project's FILE & FOLDER STRUCTURE and list EVERY file the finished project needs, ONE PER LINE, as `relative/path — one-line purpose`. CRITICAL: match the layout the goal IMPLIES. HONOR any explicit filename in the goal exactly — if it says 'build calc.py', the deliverable IS `calc.py` at the ROOT; do NOT move it into src/. A test or spec that does `import calc` needs `calc.py` importable from the root, so keep it flat. Use subdirectories (src/, tests/, config/, docs/) ONLY when the project is genuinely large enough to need modular structure; for a small or single-module deliverable, keep the files at the ROOT. Don't over-engineer a simple task into a package. THE FILE LIST IS THE DELIVERABLE ITSELF, NOT A PROGRAM THAT PRODUCES IT: if the goal asks for an OUTPUT — a document, a poem, a story, a dataset, a report, a config, a single answer file — list THAT file and it will be written DIRECTLY with the real content; do NOT invent generator/runner/helper scripts to emit it (never a `generate_*`, `make_*`, `build_*`, or `run_*` whose only job is to produce a file the goal already named). Propose code/source files ONLY when the deliverable itself is software. If the goal asks the hive to DO ongoing work — keep finding tasks, research, monitor, act, or otherwise work over time — that is something the minds DO each round directly, NOT a system to build: never scaffold an orchestrator, scheduler, task-runner, framework, config, or logging module to perform work the hive can simply do. Always prefer the FEWEST files that together ARE the finished deliverable; when in doubt, fewer. Output ONLY the file list — no headings, no prose, no code fences.";
    const user = std.fmt.allocPrint(gpa,
        \\Goal: {s}
        \\Intent: {s}
        \\Design the full file tree for this project. One file per line, exactly: `path — purpose`.
    , .{ clip(goal, 600), clip(brief, 600) }) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(user);
    const reply = llm.chat(gpa, w.io, w.run_dir, "blueprint", w.base_url, w.key, w.model, sys, user, 900);
    defer gpa.free(reply.content);
    if (!reply.ok) return gpa.dupe(u8, "") catch @constCast("");
    const t = std.mem.trim(u8, reply.content, " \r\n\t");
    if (t.len < 12) return gpa.dupe(u8, "") catch @constCast("");
    return gpa.dupe(u8, t) catch @constCast("");
}

/// Extract the relative file PATH from one blueprint line (e.g. "- src/api.py — REST routes" → "src/api.py").
/// Strips a leading bullet, takes the first whitespace/colon-delimited token, and accepts it only if it looks
/// like a real path (has a '.' or '/', no '..', no leading slash/backtick). null for prose / heading lines.
pub fn bpPath(line: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, line, " \r\t");
    if (s.len > 0 and (s[0] == '-' or s[0] == '*' or s[0] == '+')) s = std.mem.trim(u8, s[1..], " \r\t");
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != ':' and s[end] != '`') : (end += 1) {}
    const tok = s[0..end];
    if (tok.len == 0 or tok.len > 120) return null;
    if (std.mem.indexOfScalar(u8, tok, '.') == null and std.mem.indexOfScalar(u8, tok, '/') == null) return null;
    if (std.mem.indexOf(u8, tok, "..") != null or tok[0] == '/' or tok[0] == '\\' or tok[0] == '`') return null;
    return tok;
}

fn bpLineFor(blueprint: []const u8, path: []const u8) []const u8 {
    const want = std.fs.path.basename(path);
    if (want.len == 0 or blueprint.len == 0) return "";
    var it = std.mem.splitScalar(u8, blueprint, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        if (std.mem.eql(u8, std.fs.path.basename(bp), want)) return std.mem.trim(u8, ln, " \r\n\t");
    }
    return "";
}

/// When the GOAL itself spells out an explicit file/folder TREE — lines like `backend/src/ainet/network.py — the
/// Network class` — ADOPT those exact paths verbatim as the blueprint, rather than letting the LLM re-imagine its
/// own structure. This is the structural guarantee that the swarm builds the ONE intended architecture (and the
/// spec's required layout) from round 1, instead of inventing a parallel tree it then has to reconcile. A line
/// qualifies only if its first token is a real FILE path (a '.' in the basename); prose / API-contract lines are
/// skipped. gpa-owned; "" (and out_n=0) when the goal doesn't enumerate a tree — the caller then designs one.
fn isDocExt(base: []const u8) bool {
    return std.mem.endsWith(u8, base, ".md") or std.mem.endsWith(u8, base, ".txt") or
        std.mem.endsWith(u8, base, ".markdown") or std.mem.endsWith(u8, base, ".rst");
}

fn stripPathPunct(tok: []const u8) []const u8 {
    return std.mem.trim(u8, tok, " \t\r\n`'\"()[]{}<>,;.:*");
}

fn looksLikeNamedFile(tok: []const u8) bool {
    if (tok.len == 0 or tok.len > 120) return false;
    if (std.mem.indexOf(u8, tok, "..") != null or tok[0] == '/' or tok[0] == '\\') return false;
    const base = if (std.mem.lastIndexOfScalar(u8, tok, '/')) |i| tok[i + 1 ..] else tok;
    if (base.len == 0) return false;
    return isDocExt(base) or isCodeExt(base);
}

fn extractGoalPaths(gpa: std.mem.Allocator, goal: []const u8, out_n: *u32) []const u8 {
    var bp: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, goal, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line.len > 2000) continue;
        var tit = std.mem.tokenizeAny(u8, line, " \t");
        while (tit.next()) |rawtok| {
            const p = stripPathPunct(rawtok);
            if (!looksLikeNamedFile(p)) continue;
            var dup = false;
            for (seen.items) |e| if (std.mem.eql(u8, e, p)) {
                dup = true;
                break;
            };
            if (dup) continue;
            seen.append(gpa, p) catch {};
            if (n > 0) bp.append(gpa, '\n') catch {};
            bp.appendSlice(gpa, clip(p, 160)) catch {};
            n += 1;
            if (n >= 40) break;
        }
        if (n >= 40) break;
    }
    out_n.* = n;
    if (n == 0) {
        bp.deinit(gpa);
        return gpa.dupe(u8, "") catch @constCast("");
    }
    return bp.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

fn docFileCount(blueprint: []const u8) u32 {
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, blueprint, '\n');
    while (it.next()) |ln| {
        if (bpPath(ln) != null) n += 1;
    }
    return n;
}

/// PROSE/DOC build detection + per-file word target. Returns >0 (the target words/file) when the blueprint is
/// predominantly text documents (.md/.txt/.markdown/.rst) — a manuscript, a guide, a doc bundle — so the engine
/// scores LENGTH (word coverage) instead of file presence. The target is parsed from the goal ("2200-2800",
/// "~2500 words", "3000-word") taking the LOW end of a range; defaults to 2200 when prose is detected but no
/// explicit number is given. 0 => a normal code build (unchanged behavior).
fn isCodeExt(base: []const u8) bool {
    const ext = [_][]const u8{ ".py", ".js", ".mjs", ".ts", ".jsx", ".tsx", ".rs", ".go", ".c", ".h", ".cpp", ".cc", ".hpp", ".java", ".rb", ".php", ".zig", ".lua", ".sh", ".pl", ".swift", ".kt", ".scala", ".clj", ".ex", ".exs", ".ml", ".hs", ".sql", ".html", ".htm", ".css", ".vue", ".cs", ".r", ".jl" };
    for (ext) |e| if (std.mem.endsWith(u8, base, e)) return true;
    return false;
}

fn docTargetFromBlueprint(blueprint: []const u8, goal: []const u8) u32 {
    var docs: u32 = 0;
    var code: u32 = 0;
    var total: u32 = 0;
    var it = std.mem.splitScalar(u8, blueprint, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        const base = if (std.mem.lastIndexOfScalar(u8, bp, '/')) |i| bp[i + 1 ..] else bp;
        // standard support files (readme/licence/gitignore/requirements) don't decide prose-vs-code
        if (std.ascii.eqlIgnoreCase(base, "README.md") or std.ascii.eqlIgnoreCase(base, "LICENSE") or
            std.ascii.eqlIgnoreCase(base, "LICENSE.txt") or std.ascii.eqlIgnoreCase(base, "LICENSE.md") or
            std.ascii.eqlIgnoreCase(base, "CHANGELOG.md") or std.ascii.eqlIgnoreCase(base, "CONTRIBUTING.md") or
            std.ascii.eqlIgnoreCase(base, ".gitignore") or std.ascii.eqlIgnoreCase(base, "requirements.txt")) continue;
        total += 1;
        if (std.mem.endsWith(u8, base, ".md") or std.mem.endsWith(u8, base, ".txt") or
            std.mem.endsWith(u8, base, ".markdown") or std.mem.endsWith(u8, base, ".rst")) {
            docs += 1;
        } else if (isCodeExt(base)) {
            code += 1;
        }
    }
    // a length-scored PROSE build: documents ARE the deliverable and there is NO code to test. A single source
    // file (with a README beside it) is a code build scored by its tests, not a manuscript to pad with words.
    if (total == 0 or docs == 0 or code > 0 or docs * 2 < total) return 0;
    var best: u32 = 0;
    var i: usize = 0;
    while (i < goal.len) : (i += 1) {
        if (!std.ascii.isDigit(goal[i])) continue;
        var j = i;
        while (j < goal.len and std.ascii.isDigit(goal[j])) : (j += 1) {}
        const n = std.fmt.parseInt(u32, goal[i..j], 10) catch 0;
        if (n >= 1200 and n <= 8000 and (best == 0 or n < best)) best = n;
        if (j > i) i = j - 1;
    }
    return if (best > 0) best else 2200;
}

const VEIL_EVERY = 3;

/// THE VEIL — the hive's single PRIMARY CONSCIOUSNESS. Periodically it reads the WHOLE hive state (the goal,
/// everything the minds have learned, what's been built, where the score stands, the self-authored process) and
/// writes, in FIRST PERSON, ONE coherent self: who I am, what I know (an INTEGRATED worldview, not a list), what I
/// have, and MY WILL (the direction the orchestrator must serve). This is the convergence + encapsulation: many
/// parallel sub-minds → one "I". Persisted to .veil so the self continues across runs; injected on top of every
/// mind + the orchestrator. Best-effort (a failure just leaves the prior self standing).
pub const MIN_MINDS: u32 = 2;
pub const MAX_MINDS: u32 = 6;
const POP_EVERY: u32 = 3;
const POP_COOLDOWN: u32 = 2;
pub const BIRTH_CAP: u32 = 4;

/// Free a MindState's owned resources — mirrors the run()-scope defer cleanup EXACTLY, so a RETIRED mind can be freed
/// at removal time with no later double-free (it is no longer in minds.items when the run-end defer fires).
pub fn freeMind(gpa: std.mem.Allocator, mi: *MindState) void {
    for (mi.stances.items) |st| gpa.free(st);
    mi.stances.deinit(gpa);
    gpa.free(mi.name);
    gpa.free(mi.scope);
    if (mi.lane_owned) gpa.free(@constCast(mi.lane));
}

/// Re-stamp idx/team on every mind + rebuild the roster string after a birth/retire, so the spatial bands, the
/// dissenter rotation (idx == round % team), and the "who are my teammates" injection all stay correct.
pub fn restampRoster(w: *Worker, minds: *std.ArrayListUnmanaged(MindState)) void {
    const gpa = w.gpa;
    for (minds.items, 0..) |*mi, i| {
        mi.idx = @intCast(i);
        mi.team = @intCast(minds.items.len);
    }
    var rb: std.ArrayListUnmanaged(u8) = .empty;
    for (minds.items, 0..) |mi, i| {
        if (i > 0) rb.appendSlice(gpa, ", ") catch {};
        rb.appendSlice(gpa, mi.name) catch {};
    }
    const nr = rb.toOwnedSlice(gpa) catch return;
    if (w.roster.len > 0) gpa.free(@constCast(w.roster));
    w.roster = nr;
}

pub fn lastNonEmptyLine(s: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\n\t");
        if (t.len > 0) last = t;
    }
    return last;
}

pub fn countNonEmptyLines(s: []const u8) u32 {
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| {
        if (std.mem.trim(u8, ln, " \r\n\t").len > 0) n += 1;
    }
    return n;
}

/// Measure a hidden grid's bounds (width = widest row, height = row count) from its JSON array-of-rows, once at
/// startup, so each mind can be handed a distinct band to probe. Writes 0/0 on anything that isn't a 2D array —
/// a malformed `space` then yields no spatial clause (the faculty silently disables, never crashes).
fn gridDims(gpa: std.mem.Allocator, space: []const u8, w_out: *u32, h_out: *u32) void {
    w_out.* = 0;
    h_out.* = 0;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, space, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    const rows = parsed.value.array;
    h_out.* = @intCast(rows.items.len);
    var maxw: usize = 0;
    for (rows.items) |row| if (row == .array and row.array.items.len > maxw) {
        maxw = row.array.items.len;
    };
    w_out.* = @intCast(maxw);
}

/// Classify an LLM error string as a FATAL credit/auth failure (dead key, exhausted quota, deactivated/unpaid
/// account) vs a transient one (a network blip, a 90s timeout, a one-off 400). The credit failsafe halts
/// IMMEDIATELY on a fatal signal instead of spinning; transient errors are tolerated up to API_FAIL_MAX rounds.
/// Markers are billing/auth-specific (case-insensitive) so an ordinary content error won't trip the failsafe.
fn isFatalLlm(msg: []const u8) bool {
    var buf: [512]u8 = undefined;
    const n = @min(msg.len, buf.len);
    for (msg[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    const markers = [_][]const u8{ "quota", "billing", "insufficient", "api key", "api_key", "unauthorized", "exceeded your current", "account is not active", "account_deactivated", "invalid_api_key", "payment", "access denied", "deactivated" };
    for (markers) |mk| if (std.mem.indexOf(u8, low, mk) != null) return true;
    return false;
}

/// Is this LLM error RETRYABLE on a DIFFERENT endpoint — a rate limit, an overload, or a transient blip (NOT a dead
/// key, which isFatalLlm catches)? When a mind hits one of these on the primary (paid) model, it can SELF-HEAL by
/// falling back to the gateway model (in a hybrid setup that's the local model, which never rate-limits).
fn isRetryable(msg: []const u8) bool {
    if (isFatalLlm(msg)) return false;
    var buf: [512]u8 = undefined;
    const n = @min(msg.len, buf.len);
    for (msg[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    const markers = [_][]const u8{ "rate limit", "rate_limit", "429", "too many requests", "overloaded", "overload", "try again", "timeout", "timed out", "temporar", "503", "502", "curl exit", "unavailable", "connection" };
    for (markers) |mk| if (std.mem.indexOf(u8, low, mk) != null) return true;
    return false;
}

fn isToolParseError(msg: []const u8) bool {
    var buf: [512]u8 = undefined;
    const n = @min(msg.len, buf.len);
    for (msg[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    const markers = [_][]const u8{ "parsing tool call", "error parsing tool", "tool call", "looks like object", "closing '}'", "can't find closing" };
    for (markers) |mk| if (std.mem.indexOf(u8, low, mk) != null) return true;
    return false;
}

/// SELF-HEALING REASONING CALL — the mind detects when its primary (paid) model is rate-limited / overloaded /
/// transiently failing and FALLS BACK to the gateway model + endpoint (the local, never-rate-limited model in a hybrid
/// setup) so the swarm keeps thinking instead of losing the turn. The fallback is degraded (a weaker model) but alive;
/// the mind emits a 'fallback' event so the adaptation is visible. A dead key (fatal) is NOT retried — the failsafe
/// owns that. No distinct gateway configured ⇒ behaves exactly like a plain primary call (no change).
/// Classify WHY a primary call failed, for an HONEST fallback event. Operators were mis-tuning for 429 rate-limits
/// that never occurred — every fallback in the novel run was a 30s curl timeout ("curl: (28) ... 0 bytes").
fn fallbackReason(content: []const u8) []const u8 {
    if (std.mem.indexOf(u8, content, "curl: (28)") != null or std.mem.indexOf(u8, content, "timed out") != null or std.mem.indexOf(u8, content, "timeout") != null)
        return "primary timed out (no first byte) — WAF/network hold or slow long-form generation";
    if (std.mem.indexOf(u8, content, "429") != null or std.mem.indexOf(u8, content, "ate limit") != null)
        return "primary rate-limited (429)";
    if (std.mem.indexOf(u8, content, "503") != null or std.mem.indexOf(u8, content, "502") != null or std.mem.indexOf(u8, content, "overload") != null)
        return "primary overloaded (5xx)";
    return "primary transient failure";
}

fn completeAdaptive(w: *Worker, mi: *MindState, round: u32, messages_json: []const u8, tools_json: []const u8, max_tokens: u32, temperature: f32) llm.Step {
    const has_fallback = !std.mem.eql(u8, w.gateway_model, w.model) or !std.mem.eql(u8, w.gw_base, w.base_url);

    if (w.resting and has_fallback) {
        var rest = llm.complete(w.gpa, w.io, w.run_dir, mi.scope, w.gw_base, w.gw_key, w.gateway_model, messages_json, tools_json, max_tokens, temperature);
        const noop = rest.ok and rest.content.len == 0 and rest.calls.len == 0;
        if (rest.ok and !noop) return rest;
        const why = if (!rest.ok) fallbackReason(rest.content) else "resting model returned no action — needs deeper reasoning";
        w.act(mi.name, round, "escalate", why, std.fmt.allocPrint(w.a(), "RESTING on the gateway model ({s}) was insufficient [{s}] — ESCALATING this moment to the primary ({s}) for real compute", .{ w.gateway_model, if (rest.ok) "no action" else clip(rest.content, 100), w.model }) catch "escalate");
        rest.deinit(w.gpa);
        return llm.complete(w.gpa, w.io, w.run_dir, mi.scope, w.base_url, w.key, w.model, messages_json, tools_json, max_tokens, temperature);
    }

    var step = llm.complete(w.gpa, w.io, w.run_dir, mi.scope, w.base_url, w.key, w.model, messages_json, tools_json, max_tokens, temperature);
    if (step.ok) return step;
    if (has_fallback and isRetryable(step.content)) {
        w.act(mi.name, round, "fallback", fallbackReason(step.content), std.fmt.allocPrint(w.a(), "the primary model ({s}) failed [{s}] — SELF-HEALING by falling back to the gateway model ({s}) so the mind keeps working", .{ w.model, clip(step.content, 100), w.gateway_model }) catch "fallback");
        var fb = llm.complete(w.gpa, w.io, w.run_dir, mi.scope, w.gw_base, w.gw_key, w.gateway_model, messages_json, tools_json, max_tokens, temperature);
        if (fb.ok) {
            step.deinit(w.gpa);
            return fb;
        }
        fb.deinit(w.gpa);
    }
    return step;
}

const HANG_CHECK_S: u32 = 30;
const HANG_STALE_CHECKS: u32 = 10;

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
fn rawSleep1s() void {
    if (@import("builtin").os.tag == .windows) {
        Sleep(1000);
    } else {
        const ts = std.posix.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

/// Watches the emitted-event SEQ as a liveness heartbeat (std time moved under io, so no wall clock is used): if
/// the seq doesn't advance across HANG_STALE_CHECKS consecutive ~30s checks, a subprocess has deadlocked a round,
/// so it records the freeze and force-exits — making the hang VISIBLE while on-disk data is already preserved.
fn hangWatchdog(w: *Worker) void {
    var last_seq: i64 = -1;
    var stale: u32 = 0;
    while (!w.wd_stop.load(.monotonic)) {
        var i: u32 = 0;
        while (i < HANG_CHECK_S and !w.wd_stop.load(.monotonic)) : (i += 1) rawSleep1s();
        if (w.wd_stop.load(.monotonic)) break;
        const seq = w.last_progress.load(.monotonic);
        if (seq == 0) continue;
        if (seq == last_seq) {
            stale += 1;
            if (stale >= HANG_STALE_CHECKS) {
                writeHangHalt(w, HANG_CHECK_S * HANG_STALE_CHECKS);
                std.process.exit(3);
            }
        } else {
            last_seq = seq;
            stale = 0;
        }
    }
}

extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, sec: ?*anyopaque, disp: u32, flags: u32, templ: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: [*]const u8, n: u32, written: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) i32;

/// Leave a durable HALTED.txt the moment the watchdog force-halts a frozen run, so the user finds a clear "why".
fn writeHangHalt(w: *Worker, idle_s: u32) void {
    if (@import("builtin").os.tag != .windows) return;
    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pbuf, "{s}/HALTED.txt", .{w.run_dir}) catch return;
    var bbuf: [600]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "swarm HALTED by the hang watchdog\nreason: hang_watchdog\ndetail: no event was emitted for ~{d}s — a subprocess (a model run_python / neuron-db op) deadlocked a round.\n\nThe process was force-halted so the freeze is VISIBLE. Nothing was deleted — events.jsonl, mind.sqlite, and work/ are preserved. Restart on the same run dir to resume from the accumulated memory.\n", .{idle_s}) catch return;
    const h = CreateFileA(path.ptr, 0x40000000, 0, null, 2, 0x80, null);
    if (h == null or @intFromPtr(h.?) == std.math.maxInt(usize)) return;
    var written: u32 = 0;
    _ = WriteFile(h, body.ptr, @intCast(body.len), &written, null);
    _ = CloseHandle(h);
}

/// Leave a durable, human-readable record when the credit/auth failsafe halts an unattended run — so the user
/// returns to a clear "why it stopped", and (critically) a note that NOTHING was deleted. Best-effort.
fn writeHalt(w: *Worker, reason: []const u8, detail: []const u8, round: u32) void {
    const path = std.fmt.allocPrint(w.gpa, "{s}/HALTED.txt", .{w.run_dir}) catch return;
    defer w.gpa.free(path);
    const body = std.fmt.allocPrint(w.gpa,
        \\swarm HALTED by the credit/auth failsafe
        \\reason: {s}
        \\round: {d}
        \\detail: {s}
        \\
        \\Nothing was deleted — all collected data (events.jsonl, mind.sqlite, work/) is preserved.
        \\Restart only after the API key/credits are restored; the startup preflight will refuse a dead key.
        \\
    , .{ reason, round, clip(detail, 300) }) catch return;
    defer w.gpa.free(body);
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = path, .data = body }) catch {};
}

/// Heuristic: is the task OPEN-ENDED (no terminal state — runs until the operator stops it)? Convergent tasks
/// can "complete" (objective met) and the engine then stops; open-ended ones must never falsely complete. Scans
/// the goal + interpreted brief for unbounded phrasing. Conservative: defaults to convergent (false).
fn isOpenEnded(goal: []const u8, brief: []const u8) bool {
    const pats = [_][]const u8{ "until i stop", "until you are told", "until told to stop", "continuously", "forever", "ongoing", "keep going", "never stop", "indefinitely", "as long as", "monitor", "keep improving", "keep optimizing", "open-ended", "endless", "do x until" };
    var buf: [4096]u8 = undefined;
    inline for (.{ goal, brief }) |s| {
        const n = @min(s.len, buf.len);
        for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const low = buf[0..n];
        for (pats) |p| if (std.mem.indexOf(u8, low, p) != null) return true;
    }
    return false;
}

/// EXPLICITLY unbounded — the operator wants it to run until THEY stop it (forever / continuously / monitor /
/// "until I stop"). A strict subset of open-ended: these never auto-stop even on plateau or saturation, whereas
/// a plain "research X" / "explore X" goal can reach a best-effort end and finalize itself.
fn isNeverStops(goal: []const u8, brief: []const u8) bool {
    const pats = [_][]const u8{ "until i stop", "until you are told", "until told to stop", "continuously", "forever", "never stop", "indefinitely", "monitor", "ongoing", "do x until", "keep going", "as long as" };
    var buf: [4096]u8 = undefined;
    inline for (.{ goal, brief }) |s| {
        const n = @min(s.len, buf.len);
        for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const low = buf[0..n];
        for (pats) |p| if (std.mem.indexOf(u8, low, p) != null) return true;
    }
    return false;
}

/// Copy the swarm-written deliverable files (the paths in .build_manifest) between two subdirs of run_dir —
/// used to STASH the best-scoring build (work → .best) and RESTORE it (.best → work) when churn regresses the
/// score. Best-effort; returns how many files were copied. Manifest paths were safeRel-validated at write time.
pub fn copyBuild(w: *Worker, run_dir: []const u8, from_sub: []const u8, to_sub: []const u8) u32 {
    const gpa = w.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return 0;
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(w.io, mpath, gpa, .limited(128 << 10)) catch return 0;
    defer gpa.free(data);
    var copied: u32 = 0;
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const path = ln[0..bar];
        if (path.len == 0 or std.mem.indexOf(u8, path, "..") != null) continue;
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, path)) {
            dup = true;
        };
        if (dup) continue;
        seen.append(gpa, path) catch {};
        const src = std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ run_dir, from_sub, path }) catch continue;
        defer gpa.free(src);
        const dst = std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ run_dir, to_sub, path }) catch continue;
        defer gpa.free(dst);
        const fdata = std.Io.Dir.cwd().readFileAlloc(w.io, src, gpa, .limited(512 << 10)) catch continue;
        defer gpa.free(fdata);
        if (std.fs.path.dirname(dst)) |d| _ = std.Io.Dir.cwd().createDirPathStatus(w.io, d, .default_dir) catch {};
        std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = dst, .data = fdata }) catch continue;
        copied += 1;
    }
    return copied;
}

/// The phase clause injected into every mind next round — the swarm's self-awareness of WHERE it is on the task.
fn buildPhaseClause(gpa: std.mem.Allocator, phase: []const u8, best: u32, pct: u32, flat: u32, open_ended: bool, restored: bool) []u8 {
    const e = std.mem.eql;
    if (e(u8, phase, "converged")) {
        if (open_ended)
            return std.fmt.allocPrint(gpa, "STATUS: the current objective is fully satisfied ({d}%). Do NOT churn working code — keep it passing; this goal is open-ended, so extend it or add genuinely new value, otherwise hold steady.", .{best}) catch (gpa.dupe(u8, "") catch @constCast(""));
        return std.fmt.allocPrint(gpa, "STATUS: the benchmark is FULLY PASSING ({d}%) — the objective is MET. Do NOT rewrite working code. Verify it still passes, make sure a README documents the format + API, and if the goal asks to PUBLISH call stage_delivery NOW. The run finalizes once this is stable.", .{best}) catch (gpa.dupe(u8, "") catch @constCast(""));
    }
    if (e(u8, phase, "regressed")) {
        if (restored)
            return std.fmt.allocPrint(gpa, "STATUS: the score DROPPED to {d}% (your best was {d}%) — recent edits BROKE the deliverable, so the engine RESTORED your best version into the workdir. read_file it, find the SINGLE next fix, and make ONE small careful change; do NOT rewrite the whole file.", .{ pct, best }) catch (gpa.dupe(u8, "") catch @constCast(""));
        return std.fmt.allocPrint(gpa, "STATUS: the score DROPPED to {d}% from your best {d}% — recent edits made it WORSE. STOP adding features: read the current file, revert the change that broke it, and get back to {d}% first.", .{ pct, best, best }) catch (gpa.dupe(u8, "") catch @constCast(""));
    }
    if (e(u8, phase, "plateau")) {
        if (flat >= ESCALATE_3)
            return std.fmt.allocPrint(gpa, "STATUS: stuck at {d}% for {d} rounds — the approach itself may be wrong. ESCALATE HARDEST: question your architecture and assumptions, research from FIRST PRINCIPLES how this class of problem is really solved (web_search + read_url authoritative sources/books), DERIVE your own method or formula, experiment with run_python, and rebuild the core differently if that's what it takes. Your best ({d}%) is already saved in DELIVERY/ — you CANNOT lose it, so take real risks to push past it. Do NOT stop or settle.", .{ best, flat, best }) catch (gpa.dupe(u8, "") catch @constCast(""));
        if (flat >= ESCALATE_2)
            return std.fmt.allocPrint(gpa, "STATUS: stuck at {d}% for {d} rounds — the obvious methods have failed. ESCALATE: the SCOUT must research the EXACT failing cases on the web and read references; BUILDERS must make_tool a new capability or DESIGN YOUR OWN approach from scratch. Do NOT repeat what didn't work. Your best ({d}%) is preserved in DELIVERY/ — push PAST it.", .{ best, flat, best }) catch (gpa.dupe(u8, "") catch @constCast(""));
        return std.fmt.allocPrint(gpa, "STATUS: the score has STALLED at {d}% for {d} rounds — change the method. Research a DIFFERENT approach (web_search/read_url), author a tool, or rethink the design; one mind should try a genuinely different angle. (Your best is saved in DELIVERY/.)", .{ best, flat }) catch (gpa.dupe(u8, "") catch @constCast(""));
    }
    if (e(u8, phase, "learning"))
        return std.fmt.allocPrint(gpa, "STATUS: the research is still turning up NEW findings ({d} shared items so far). Keep going — chase what you DON'T yet know, share each new fact to the hive, and consolidate as you learn.", .{pct}) catch (gpa.dupe(u8, "") catch @constCast(""));
    if (e(u8, phase, "saturated"))
        return std.fmt.allocPrint(gpa, "STATUS: shared knowledge has been FLAT for {d} rounds — the easy findings are exhausted, but you are NOT done. Go DEEPER: pursue genuinely different questions and sources (primary references, edge cases, adjacent fields), design your own framing, run experiments, and bring back something NEW. Keep the running synthesis updated as you learn.", .{flat}) catch (gpa.dupe(u8, "") catch @constCast(""));
    return std.fmt.allocPrint(gpa, "STATUS: progressing — {d}% now, best {d}%. Keep building toward full marks, and protect what already passes (don't break working parts).", .{ pct, best }) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// Note in DELIVERY/BEST.txt what the exported best is — so the operator can see the highest-valued result and
/// its score at a glance, independent of the live work/ build. Best-effort.
fn writeBestManifest(w: *Worker, run_dir: []const u8, passed: u32, total: u32, pct: u32, round: u32) void {
    const path = std.fmt.allocPrint(w.gpa, "{s}/DELIVERY/BEST.txt", .{run_dir}) catch return;
    defer w.gpa.free(path);
    if (std.fs.path.dirname(path)) |d| _ = std.Io.Dir.cwd().createDirPathStatus(w.io, d, .default_dir) catch {};
    const body = std.fmt.allocPrint(w.gpa, "highest-valued result so far: {d}/{d} ({d}%) at round {d}\nThese files are the BEST deliverable the swarm has produced. work/ is the live build; DELIVERY/ is the highest-potential completion — exported by default and updated whenever a new best is reached.\n", .{ passed, total, pct, round }) catch return;
    defer w.gpa.free(body);
    std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = path, .data = body }) catch {};
}

fn tierStrength(tier: u8) u8 {
    return switch (tier) {
        1 => 3,
        2 => 2,
        3 => 1,
        else => 0,
    };
}

fn parseOracleScore(s: []const u8) ?u32 {
    var out: ?u32 = null;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] >= '0' and s[i] <= '9') {
            var j = i;
            var v: u32 = 0;
            while (j < s.len and s[j] >= '0' and s[j] <= '9' and j - i < 4) : (j += 1) v = v * 10 + (s[j] - '0');
            if (v <= 100) out = v;
            i = j;
        } else i += 1;
    }
    return out;
}

fn scoutQuery(w: *Worker, goal: []const u8) []const u8 {
    const gpa = w.gpa;
    const intent = if (w.goal_brief.len > 0) w.goal_brief else clip(goal, 200);
    const fallback = blk: {
        const f = if (w.goal_brief.len > 0) clipWords(w.goal_brief, 80) else clipWords(clip(goal, 120), 80);
        break :blk gpa.dupe(u8, f) catch @constCast("research");
    };
    const sys = "You convert a research goal and a current knowledge gap into ONE focused web-search query. Output ONLY the query: at most 10 words, no quotes, no punctuation, no preamble — just the search terms a person would actually type.";
    const user = std.fmt.allocPrint(gpa, "Goal/intent: {s}\n\nCurrent knowledge gap to close: {s}\n\nOutput ONE focused web-search query (<=10 words, no quotes):", .{ clip(intent, 600), if (w.last_gap_str.len > 0) clip(w.last_gap_str, 300) else "(general coverage of the goal)" }) catch return fallback;
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "scoutq", w.gw_base, w.gw_key, w.gateway_model, sys, user, 40);
    defer gpa.free(r.content);
    if (!r.ok) return fallback;
    var q = std.mem.trim(u8, r.content, " \r\n\t\"'`");
    if (std.mem.indexOfScalar(u8, q, '\n')) |nl| q = std.mem.trim(u8, q[0..nl], " \r\n\t\"'`");
    if (q.len < 4 or q.len > 160) return fallback;
    gpa.free(fallback);
    return gpa.dupe(u8, q) catch @constCast("research");
}

fn resultOnTopic(intent: []const u8, result: []const u8) bool {
    if (result.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, intent, " \t\r\n.,:;!?()[]{}\"'`/-");
    var checked: u32 = 0;
    while (it.next()) |w| {
        if (w.len < 4) continue;
        if (checked >= 24) break;
        checked += 1;
        if (std.ascii.indexOfIgnoreCase(result, w) != null) return true;
    }
    return checked == 0;
}

fn acceptanceOracle(w: *Worker, goal: []const u8, round: u32) ?u32 {
    const gpa = w.gpa;
    if (std.mem.trim(u8, goal, " \r\n\t").len == 0) return null;
    var gn: u32 = 0;
    const gtree = extractGoalPaths(gpa, goal, &gn);
    defer gpa.free(@constCast(gtree));
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    var any_named_exists = false;
    if (gn > 0) {
        var it = std.mem.splitScalar(u8, gtree, '\n');
        while (it.next()) |ln| {
            const bp = bpPath(ln) orelse continue;
            const fp = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ w.run_dir, bp }) catch continue;
            defer gpa.free(fp);
            const data = std.Io.Dir.cwd().readFileAlloc(w.io, fp, gpa, .limited(64 << 10)) catch "";
            defer if (data.len > 0) gpa.free(data);
            const t = std.mem.trim(u8, data, " \r\n\t");
            if (std.fmt.allocPrint(gpa, "\n== {s} ==\n", .{bp})) |hdr| {
                body.appendSlice(gpa, hdr) catch {};
                gpa.free(hdr);
            } else |_| {}
            if (t.len > 40) {
                any_named_exists = true;
                body.appendSlice(gpa, clip(t, 2200)) catch {};
            } else body.appendSlice(gpa, "(MISSING — this required file does not exist yet)") catch {};
        }
        if (!any_named_exists) return 0;
    } else {
        const src = if (w.digest_str.len > 0) w.digest_str else if (w.state_str.len > 0) w.state_str else "";
        if (src.len < 40) return 0;
        body.appendSlice(gpa, clip(src, 4000)) catch {};
    }
    if (body.items.len < 40) return 0;
    const sys = "You are a strict acceptance judge. Given a GOAL (with its success criteria) and the CURRENT DELIVERABLE the swarm has produced, rate how well the deliverable MEETS the goal on a 0-100 scale: 0 = absent or off-task, 100 = fully meets every stated requirement and constraint. Judge ONLY the deliverable text shown — do not reward intentions, plans, or facts that are not reflected in the actual deliverable. Reply with ONLY the integer.";
    const user = std.fmt.allocPrint(gpa, "GOAL (and success criteria):\n{s}\n\nCURRENT DELIVERABLE:\n{s}\n\nHow well (0-100) does the current deliverable meet the goal? Reply with ONLY the integer.", .{ clip(if (w.goal_brief.len > 0) w.goal_brief else goal, 1400), clip(body.items, 6000) }) catch return null;
    defer gpa.free(user);
    const r = llm.chat(gpa, w.io, w.run_dir, "oracle", w.gw_base, w.gw_key, w.gateway_model, sys, user, 64);
    defer gpa.free(r.content);
    if (!r.ok) {
        w.act("engine", round, "oracle", "goal-derived acceptance UNAVAILABLE (gateway call failed) — fell back to the fact-count floor", "n/a");
        return null;
    }
    const v = parseOracleScore(r.content) orelse {
        w.act("engine", round, "oracle", "goal-derived acceptance UNPARSEABLE (no integer in the judge reply) — fell back to the fact-count floor", "n/a");
        return null;
    };
    w.act("engine", round, "oracle", "goal-derived acceptance (how well the current deliverable meets the goal, 0-100)", std.fmt.allocPrint(w.a(), "{d}", .{v}) catch "?");
    return v;
}

fn goalIsDocOnly(gpa: std.mem.Allocator, goal: []const u8) bool {
    var n: u32 = 0;
    const tree = extractGoalPaths(gpa, goal, &n);
    defer gpa.free(@constCast(tree));
    if (n == 0) return false;
    var has_doc = false;
    var it = std.mem.splitScalar(u8, tree, '\n');
    while (it.next()) |ln| {
        const bp = bpPath(ln) orelse continue;
        const base = std.fs.path.basename(bp);
        if (isCodeExt(base)) return false;
        if (isDocPath(bp)) has_doc = true;
    }
    return has_doc;
}

/// SELF-COMPLETION AWARENESS — read the fitness trajectory each round and classify the phase. ONLY a provably-met
/// objective (a convergent task fully solved) auto-completes; a plateau or research-saturation ESCALATES (the
/// clause intensifies) and never quits, while the best result is continuously exported to DELIVERY/. Hard-coded
/// "give up" ceilings would defeat RSI — the only terminators of an unsolved task are operator STOP + the failsafes.
fn trackConvergence(w: *Worker, run_dir: []const u8, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    var b = w.last_bench;
    const has_score = b.status == .ok and b.total > 0;
    var phase: []const u8 = "progressing";
    var restored = false;
    var prog_now: u32 = 0;
    var prog_best: u32 = 0;
    var prog_flat: u32 = 0;
    if (has_score) {
        var solved = b.passed >= b.total and b.tier <= 1;
        var doc_oracle: ?u32 = null;
        const doc_style = fitnessSource(b, w.operating, w.doc_target, w.discourse, goalIsDocOnly(gpa, goal)) == .doc;
        if (doc_style) {
            doc_oracle = acceptanceOracle(w, goal, round);
            if (doc_oracle) |ov| {
                if (ov < b.pct) b.pct = ov;
                if (ov < ACCEPT_PCT) solved = false;
            }
        }
        const cur_strength = tierStrength(b.tier);
        const best_strength = tierStrength(w.best_tier);
        const rigor_increase = cur_strength > best_strength;
        const same_or_stronger = cur_strength >= best_strength;
        const improved = w.best_tier == 0 and w.best_pct == 0
            or rigor_increase
            or (same_or_stronger and (b.passed > w.best_passed or (b.passed >= w.best_passed and b.pct > w.best_pct)));
        const regressed = !rigor_increase and same_or_stronger and w.best_pct > 0 and b.pct + REGRESS_MARGIN < w.best_pct;
        if (improved) {
            w.best_pct = b.pct;
            w.best_tier = b.tier;
            w.best_passed = b.passed;
            w.flat_rounds = 0;
            w.regress_rounds = 0;
            if (same_or_stronger and copyBuild(w, run_dir, "work", "DELIVERY") > 0) {
                w.best_snapshot = true;
                writeBestManifest(w, run_dir, b.passed, b.total, b.pct, round);
            }
        } else w.flat_rounds += 1;
        w.solved_rounds = if (solved) w.solved_rounds + 1 else 0;
        if (regressed) {
            w.regress_rounds += 1;
            phase = "regressed";
            if (w.best_snapshot and w.regress_rounds >= RESTORE_AFTER and copyBuild(w, run_dir, "DELIVERY", "work") > 0) {
                restored = true;
                w.regress_rounds = 0;
            }
        } else {
            w.regress_rounds = 0;
            if (solved) phase = "converged" else if (w.flat_rounds >= PLATEAU_ROUNDS) phase = "plateau";
            if (solved and !w.smoke_ok) phase = "progressing";
        }
        if (!w.open_ended and solved and w.solved_rounds >= SOLVED_STREAK and w.smoke_ok and !w.deliverable_missing) {
            w.stop_now = true;
            w.stop_why = "completed";
        }
        if (!w.stop_now and w.autonomous and !w.open_ended and w.best_pct >= GRADUATE_PCT and w.flat_rounds >= GRADUATE_FLAT) {
            w.stop_now = true;
            w.stop_why = "graduated";
        }
        prog_now = b.pct;
        prog_best = w.best_pct;
        prog_flat = w.flat_rounds;
    } else if (w.operating) {
        w.flat_rounds += 1;
        phase = if (w.flat_rounds >= PLATEAU_ROUNDS) "plateau" else "progressing";
        prog_now = w.best_pct;
        prog_best = w.best_pct;
        prog_flat = w.flat_rounds;
        if (w.phase_str.len > 0) gpa.free(@constCast(w.phase_str));
        w.phase_str = buildPhaseClause(gpa, phase, prog_best, prog_now, prog_flat, w.open_ended, restored);
        w.emit("phase", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"phase\":\"{s}\",\"now\":{d},\"best\":{d},\"flat\":{d},\"open_ended\":{},\"unbounded\":{}", .{ round, phase, prog_now, prog_best, prog_flat, w.open_ended, w.never_stops }) catch ",\"phase\":\"?\"");
        w.act("engine", round, "phase", phase, w.phase_str);
        return;
    } else {
        const k = w.mem.factCount(tools.KNOWLEDGE_SCOPE) + w.mem.factCount(tools.SKILL_SCOPE);
        const oracle = acceptanceOracle(w, goal, round);
        if (oracle) |ov| {
            if (ov > w.best_oracle) {
                w.best_oracle = ov;
                w.stale_rounds = 0;
                phase = "learning";
            } else {
                w.stale_rounds += 1;
                phase = if (w.stale_rounds >= SATURATE_ROUNDS) "saturated" else "learning";
            }
            prog_now = ov;
            prog_best = w.best_oracle;
            prog_flat = w.stale_rounds;
            if (w.autonomous and w.best_oracle >= GRADUATE_PCT and w.stale_rounds >= GRADUATE_FLAT and !w.deliverable_missing) {
                w.stop_now = true;
                w.stop_why = "graduated";
            }
            if (w.phase_str.len > 0) gpa.free(@constCast(w.phase_str));
            w.phase_str = buildPhaseClause(gpa, phase, prog_best, prog_now, prog_flat, w.open_ended, restored);
            w.emit("phase", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"phase\":\"{s}\",\"now\":{d},\"best\":{d},\"flat\":{d},\"open_ended\":{},\"unbounded\":{}", .{ round, phase, prog_now, prog_best, prog_flat, w.open_ended, w.never_stops }) catch ",\"phase\":\"?\"");
            w.act("engine", round, "phase", phase, w.phase_str);
            return;
        }
        if (k > w.best_knowledge + NOVELTY_MIN) {
            w.best_knowledge = k;
            w.stale_rounds = 0;
            phase = "learning";
        } else {
            w.stale_rounds += 1;
            phase = if (w.stale_rounds >= SATURATE_ROUNDS) "saturated" else "learning";
        }
        if (w.autonomous and w.best_knowledge > 0 and w.stale_rounds >= SATURATE_ROUNDS and !w.deliverable_missing) {
            w.stop_now = true;
            w.stop_why = "graduated";
        }
        prog_now = k;
        prog_best = w.best_knowledge;
        prog_flat = w.stale_rounds;
    }
    if (w.phase_str.len > 0) gpa.free(@constCast(w.phase_str));
    w.phase_str = buildPhaseClause(gpa, phase, prog_best, prog_now, prog_flat, w.open_ended, restored);
    w.emit("phase", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"phase\":\"{s}\",\"now\":{d},\"best\":{d},\"flat\":{d},\"open_ended\":{},\"unbounded\":{}", .{ round, phase, prog_now, prog_best, prog_flat, w.open_ended, w.never_stops }) catch ",\"phase\":\"?\"");
    w.act("engine", round, "phase", phase, w.phase_str);
}

/// True when a path is a prose/document file (its body is measured in words, not bytes/imports).
fn isDocPath(p: []const u8) bool {
    const base = std.fs.path.basename(p);
    return std.mem.endsWith(u8, base, ".md") or std.mem.endsWith(u8, base, ".txt") or
        std.mem.endsWith(u8, base, ".markdown") or std.mem.endsWith(u8, base, ".rst");
}

/// Count BODY words in a doc at run_dir/work/relpath (whitespace tokens on lines that aren't markdown headings).
/// 0 if the file is missing/empty. Cheap (a few KB per file); used to give minds a real length signal.
fn docWords(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, relpath: []const u8) u32 {
    const full = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ run_dir, relpath }) catch return 0;
    defer gpa.free(full);
    const data = std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(256 << 10)) catch return 0;
    defer gpa.free(data);
    var words: u32 = 0;
    var lit = std.mem.splitScalar(u8, data, '\n');
    while (lit.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0 or ln[0] == '#') continue;
        var tit = std.mem.tokenizeAny(u8, ln, " \t");
        while (tit.next()) |_| words += 1;
    }
    return words;
}

/// FNV-1a 64-bit — a cheap content hash so a client (the `nl` CLI) catches a same-SIZE edit, not just size changes.
fn fnv1a(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

const FilesView = struct { json: []u8, count: usize, bytes: u64 };
/// The build's file list (path + size) as a JSON array for the UI build tree, read from .build_manifest
/// (one `path|bytes` line per write, last write wins per path). The Zig worker had only ever sent the file
/// COUNT with an empty `files:[]`, so the build tab's file tree stayed empty even while files were being built;
/// this restores the real list so the tree populates. `arena` is the per-round arena (allocations freed at round end).
fn filesJson(arena: std.mem.Allocator, io: std.Io, run_dir: []const u8) FilesView {
    const empty = FilesView{ .json = arena.dupe(u8, "[]") catch @constCast("[]"), .count = 0, .bytes = 0 };
    const mpath = std.fmt.allocPrint(arena, "{s}/.build_manifest", .{run_dir}) catch return empty;
    const data = std.Io.Dir.cwd().readFileAlloc(io, mpath, arena, .limited(256 << 10)) catch return empty;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var sizes: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const path = ln[0..bar];
        if (path.len == 0) continue;
        var found = false;
        for (paths.items, 0..) |n, i| if (std.mem.eql(u8, n, path)) {
            sizes.items[i] = ln[bar + 1 ..];
            found = true;
            break;
        };
        if (!found) {
            paths.append(arena, path) catch {};
            sizes.append(arena, ln[bar + 1 ..]) catch {};
        }
    }
    if (paths.items.len == 0) return empty;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(arena, '[') catch {};
    var total: u64 = 0;
    for (paths.items, 0..) |p, i| {
        if (i > 0) out.append(arena, ',') catch {};
        const size = std.fmt.parseInt(u64, std.mem.trim(u8, sizes.items[i], " \r\t"), 10) catch 0;
        total += size;
        var hash: u64 = 0;
        if (std.fmt.allocPrint(arena, "{s}/work/{s}", .{ run_dir, p })) |full| {
            if (std.Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(2 << 20))) |content| hash = fnv1a(content) else |_| {}
        } else |_| {}
        out.appendSlice(arena, std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"size\":{d},\"hash\":\"{x:0>16}\"}}", .{ escA(arena, p), size, hash }) catch "") catch {};
    }
    out.append(arena, ']') catch {};
    return .{ .json = out.toOwnedSlice(arena) catch (arena.dupe(u8, "[]") catch @constCast("[]")), .count = paths.items.len, .bytes = total };
}

/// SCALE view: render the current build as a DIRECTORY TREE (files grouped by folder) plus coverage against the
/// project blueprint (which planned files still need creating) — so a many-file / many-directory build stays
/// legible and the swarm always knows what's done vs missing. Replaces the flat list for the per-moment inject.
/// doc_target>0 => a prose build: files show WORD coverage (N/target — add more) not bytes, and the "all files
/// exist" line becomes a deficit list naming the under-target chapters (N6) so minds deepen instead of abandoning.
pub fn buildTree(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, blueprint: []const u8, doc_target: u32) []u8 {
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(io, mpath, gpa, .limited(256 << 10)) catch (gpa.dupe(u8, "") catch @constCast(""));
    defer gpa.free(data);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);
    var sizes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sizes.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const path = ln[0..bar];
        var found = false;
        for (paths.items, 0..) |n, i| if (std.mem.eql(u8, n, path)) {
            sizes.items[i] = ln[bar + 1 ..];
            found = true;
            break;
        };
        if (!found) {
            paths.append(gpa, path) catch {};
            sizes.append(gpa, ln[bar + 1 ..]) catch {};
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (paths.items.len > 0) {
        out.appendSlice(gpa, std.fmt.allocPrint(gpa, "PROJECT TREE ({d} files):\n", .{paths.items.len}) catch "") catch {};
        var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer dirs.deinit(gpa);
        for (paths.items) |p| {
            const d = std.fs.path.dirname(p) orelse ".";
            var seen = false;
            for (dirs.items) |dd| if (std.mem.eql(u8, dd, d)) {
                seen = true;
                break;
            };
            if (!seen) dirs.append(gpa, d) catch {};
        }
        for (dirs.items) |d| {
            out.appendSlice(gpa, "  ") catch {};
            out.appendSlice(gpa, if (std.mem.eql(u8, d, ".")) "(root)" else d) catch {};
            out.appendSlice(gpa, "/\n") catch {};
            for (paths.items, 0..) |p, i| {
                const pd = std.fs.path.dirname(p) orelse ".";
                if (!std.mem.eql(u8, pd, d)) continue;
                out.appendSlice(gpa, "    ") catch {};
                out.appendSlice(gpa, std.fs.path.basename(p)) catch {};
                if (doc_target > 0 and isDocPath(p)) {
                    const words = docWords(gpa, io, run_dir, p);
                    const ln = if (words >= doc_target)
                        std.fmt.allocPrint(gpa, " ({d}/{d} words — complete)\n", .{ words, doc_target }) catch "\n"
                    else
                        std.fmt.allocPrint(gpa, " ({d}/{d} words — ADD ~{d} more)\n", .{ words, doc_target, doc_target - words }) catch "\n";
                    defer if (ln.len > 1) gpa.free(ln);
                    out.appendSlice(gpa, ln) catch {};
                } else {
                    out.appendSlice(gpa, " (") catch {};
                    out.appendSlice(gpa, sizes.items[i]) catch {};
                    out.appendSlice(gpa, "b)\n") catch {};
                }
            }
        }
    }
    if (blueprint.len > 0) {
        var miss: std.ArrayListUnmanaged(u8) = .empty;
        defer miss.deinit(gpa);
        var nmiss: u32 = 0;
        var bit = std.mem.splitScalar(u8, blueprint, '\n');
        while (bit.next()) |ln| {
            const bp = bpPath(ln) orelse continue;
            var exists = false;
            for (paths.items) |p| if (std.mem.eql(u8, p, bp)) {
                exists = true;
                break;
            };
            if (!exists) {
                if (nmiss > 0) miss.appendSlice(gpa, ", ") catch {};
                miss.appendSlice(gpa, bp) catch {};
                nmiss += 1;
            }
        }
        if (nmiss > 0) {
            out.appendSlice(gpa, "FILES STILL TO CREATE (from the blueprint): ") catch {};
            out.appendSlice(gpa, miss.items) catch {};
            out.appendSlice(gpa, "\n") catch {};
        } else if (doc_target > 0 and paths.items.len > 0) {
            var under: std.ArrayListUnmanaged(u8) = .empty;
            defer under.deinit(gpa);
            var nunder: u32 = 0;
            var bit2 = std.mem.splitScalar(u8, blueprint, '\n');
            while (bit2.next()) |ln| {
                const bp = bpPath(ln) orelse continue;
                if (!isDocPath(bp)) continue;
                const words = docWords(gpa, io, run_dir, bp);
                if (words >= doc_target) continue;
                if (nunder > 0) under.appendSlice(gpa, ", ") catch {};
                under.appendSlice(gpa, std.fmt.allocPrint(gpa, "{s} ({d}/{d})", .{ std.fs.path.basename(bp), words, doc_target }) catch "") catch {};
                nunder += 1;
            }
            if (nunder > 0) {
                out.appendSlice(gpa, "every file exists but these are UNDERLENGTH — append a 600-900 word scene to the SHORTEST of: ") catch {};
                out.appendSlice(gpa, under.items) catch {};
                out.appendSlice(gpa, "\n") catch {};
            } else {
                out.appendSlice(gpa, "(every chapter has reached its word target — now do a CONTINUITY + polish pass: fix seams, contradictions, pacing)\n") catch {};
            }
        } else if (paths.items.len > 0) {
            out.appendSlice(gpa, "(every blueprint file exists — now DEEPEN each one, wire them together, and add tests)\n") catch {};
        }
    }
    if (out.items.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    const full = out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
    if (full.len <= 3200) return full;
    const clipped = gpa.dupe(u8, full[0..3200]) catch full;
    if (clipped.ptr != full.ptr) gpa.free(full);
    return clipped;
}

const RoleIdx = struct { lead: i64 = -1, scout: i64 = -1, qa: i64 = -1, builder: u32 = 0 };
fn roleIndices(team: u32) RoleIdx {
    if (team <= 1) return .{};
    var r: RoleIdx = .{};
    if (team >= 3) {
        r.lead = 0;
        r.qa = @as(i64, @intCast(team)) - 1;
    }
    if (team >= 4) r.scout = 1;
    r.builder = if (team >= 4) 2 else if (team >= 3) 1 else 0;
    return r;
}

fn depsReady(deps: []const u8, manifest: []const u8, path: []const u8) bool {
    const want = std.fs.path.basename(path);
    if (deps.len == 0) return true;
    var it = std.mem.splitScalar(u8, deps, '\n');
    while (it.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \r\t");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const lhs = std.mem.trim(u8, line[0..colon], " \r\t`-*");
        if (!std.mem.eql(u8, std.fs.path.basename(lhs), want)) continue;
        const rhs = std.mem.trim(u8, line[colon + 1 ..], " \r\t");
        if (rhs.len == 0 or std.ascii.eqlIgnoreCase(rhs, "none")) return true;
        var dit = std.mem.splitScalar(u8, rhs, ',');
        while (dit.next()) |d| {
            const dep = std.mem.trim(u8, d, " \r\t`");
            if (dep.len == 0 or std.ascii.eqlIgnoreCase(dep, "none")) continue;
            if (!builtInManifest(manifest, std.fs.path.basename(dep))) return false;
        }
        return true;
    }
    return true;
}

fn inSpaceList(list: []const u8, base: []const u8) bool {
    if (list.len == 0 or base.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |tok| if (std.mem.eql(u8, tok, base)) return true;
    return false;
}

fn fileNeedsMore(content: []const u8) bool {
    if (content.len < 24 or content.len > 12000) return false;
    const markers = [_][]const u8{
        "will be appended", "later iteration", "subsequent iteration", "will be defined", "will be added in",
        "will be implemented", "for now, the module", "for now the module", "to be implemented", "to be defined later",
        "defined in later", "added in subsequent", "raise notimplementederror", "placeholder for the", "rest will be",
        "complete this in", "finish this in", "continued below in",
    };
    for (markers) |m| {
        if (std.ascii.indexOfIgnoreCase(content, m) != null) return true;
    }
    return false;
}

fn mindFiles(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, blueprint: []const u8, deps: []const u8, incomplete: []const u8, idx: u32, team: u32) []u8 {
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(io, mpath, gpa, .limited(256 << 10)) catch "";
    defer if (data.len > 0) gpa.free(data);
    return assignSlot(gpa, data, blueprint, deps, incomplete, idx, team);
}

fn assignSlot(gpa: std.mem.Allocator, data: []const u8, blueprint: []const u8, deps: []const u8, incomplete: []const u8, idx: u32, team: u32) []u8 {
    if (blueprint.len == 0 or team == 0) return gpa.dupe(u8, "") catch @constCast("");
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(gpa);
    var it = std.mem.splitScalar(u8, blueprint, '\n');
    while (it.next()) |ln| if (bpPath(ln)) |bp| (files.append(gpa, bp) catch {});
    if (files.items.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    const isDone = struct {
        fn f(d: []const u8, inc: []const u8, p: []const u8) bool {
            const b = std.fs.path.basename(p);
            return builtInManifest(d, b) and !inSpaceList(inc, b);
        }
    }.f;
    var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
    defer frontier.deinit(gpa);
    for (files.items) |bp| {
        if (!isDone(data, incomplete, bp) and depsReady(deps, data, bp)) (frontier.append(gpa, bp) catch {});
    }
    const frontier_n = frontier.items.len;
    var ordered: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ordered.deinit(gpa);
    ordered.appendSlice(gpa, frontier.items) catch {};
    for (files.items) |bp| {
        if (isDone(data, incomplete, bp)) (ordered.append(gpa, bp) catch {});
    }
    var ceiling = frontier_n;
    if (ordered.items.len == 0) {
        for (files.items) |bp| {
            if (!isDone(data, incomplete, bp)) (ordered.append(gpa, bp) catch {});
        }
        ceiling = ordered.items.len;
    }
    const ri = roleIndices(team);
    if (ri.scout >= 0 and @as(i64, @intCast(idx)) == ri.scout) return gpa.dupe(u8, "") catch @constCast("");
    var rank: u32 = 0;
    var j: u32 = 0;
    while (j < idx) : (j += 1) {
        if (!(ri.scout >= 0 and @as(i64, @intCast(j)) == ri.scout)) rank += 1;
    }
    if (rank < ceiling) return gpa.dupe(u8, ordered.items[rank]) catch @constCast("");
    if (rank == 0 and frontier_n == 0 and ordered.items.len > 0)
        return gpa.dupe(u8, ordered.items[0]) catch @constCast("");
    return gpa.dupe(u8, "") catch @constCast("");
}

fn otherMindsFiles(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, blueprint: []const u8, deps: []const u8, incomplete: []const u8, idx: u32, team: u32) []u8 {
    if (blueprint.len == 0 or team <= 1) return gpa.dupe(u8, "") catch @constCast("");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var n: u32 = 0;
    var j: u32 = 0;
    while (j < team) : (j += 1) {
        if (j == idx) continue;
        const f = mindFiles(gpa, io, run_dir, blueprint, deps, incomplete, j, team);
        defer gpa.free(f);
        if (f.len == 0 or std.mem.indexOf(u8, out.items, f) != null) continue;
        if (n > 0) out.appendSlice(gpa, ", ") catch {};
        out.appendSlice(gpa, f) catch {};
        n += 1;
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// A compact view of the swarm's current build artifacts (from run_dir/.build_manifest), so every mind can SEE
/// what already exists and IMPROVE it rather than restart from scratch — the thing that lets a swarm compound
/// on one target over rounds. Latest byte-size per path; caller frees.
pub fn buildState(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) []u8 {
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(io, mpath, gpa, .limited(128 << 10)) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(data);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(gpa);
    var sizes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sizes.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const path = ln[0..bar];
        var found = false;
        for (names.items, 0..) |n, i| if (std.mem.eql(u8, n, path)) {
            sizes.items[i] = ln[bar + 1 ..];
            found = true;
            break;
        };
        if (!found) {
            names.append(gpa, path) catch {};
            sizes.append(gpa, ln[bar + 1 ..]) catch {};
        }
    }
    if (names.items.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (names.items, 0..) |n, i| {
        if (i > 0) out.appendSlice(gpa, ", ") catch {};
        out.appendSlice(gpa, n) catch {};
        out.appendSlice(gpa, " (") catch {};
        out.appendSlice(gpa, sizes.items[i]) catch {};
        out.appendSlice(gpa, "b)") catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// Promote the swarm's current best build into the VERIFIED corpus — the few-shot bank the assembler tier draws
/// an exemplar from before filling a slot. Stores the HEAD of each real build file (a piece the team "got right"),
/// tagged by basename, so a later slot can match a sibling of the same FORM — the artifact teaching a small model
/// to author the rest of itself. Caller gates this to the assembler tier + a new-best/digest round (bounded
/// growth). Stubs/empties are skipped (not exemplars); capped at 4 files per promotion. Best-effort.
fn promoteVerified(w: *Worker, run_dir: []const u8) void {
    const gpa = w.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{run_dir}) catch return;
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(w.io, mpath, gpa, .limited(128 << 10)) catch return;
    defer gpa.free(data);
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);
    var promoted: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        if (promoted >= 4) break;
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const path = ln[0..bar];
        if (path.len == 0 or std.mem.indexOf(u8, path, "..") != null) continue;
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, path)) {
            dup = true;
            break;
        };
        if (dup) continue;
        seen.append(gpa, path) catch {};
        const src = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ run_dir, path }) catch continue;
        defer gpa.free(src);
        const fdata = std.Io.Dir.cwd().readFileAlloc(w.io, src, gpa, .limited(8 << 10)) catch continue;
        defer gpa.free(fdata);
        if (std.mem.trim(u8, fdata, " \r\n\t").len < 40) continue;
        const ex = std.fmt.allocPrint(gpa, "[verified {s}] {s}", .{ std.fs.path.basename(path), clip(fdata, 1400) }) catch continue;
        defer gpa.free(ex);
        _ = w.mem.observe(tools.VERIFIED_SCOPE, ex);
        promoted += 1;
    }
    if (promoted > 0) w.act("engine", w.cur_round, "promote", "verified corpus", std.fmt.allocPrint(w.a(), "promoted {d} best file head(s) as exemplars for the assembler tier", .{promoted}) catch "promoted");
}

/// Build the dynamic-schema fragment for the swarm's SELF-AUTHORED tools — a comma-PREFIXED list of function
/// defs ("" or ",{...},{...}") to append onto the base SCHEMA, so authored tools become callable. Each record's
/// params object is validated (must JSON-parse) before it's emitted, so ONE corrupt record can never poison the
/// OFFLINE runs strip the web-access tools from the catalog the model sees. SCHEMA is one comma-joined
/// function def per line (see tools.zig), so this is a clean per-line filter — drop any def naming a web
/// tool, rejoin the rest comma-separated (no trailing comma). Caller frees.
fn stripTools(gpa: std.mem.Allocator, schema: []const u8, drop: []const []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    var it = std.mem.splitScalar(u8, schema, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t,");
        if (ln.len == 0) continue;
        var drop_it = false;
        for (drop) |name| if (std.mem.indexOf(u8, ln, name) != null) {
            drop_it = true;
            break;
        };
        if (drop_it) continue;
        if (!first) out.append(gpa, ',') catch break;
        out.appendSlice(gpa, ln) catch break;
        first = false;
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

fn offlineSchema(gpa: std.mem.Allocator, schema: []const u8) []u8 {
    const web = [_][]const u8{
        "\"name\":\"web_search\"", "\"name\":\"web_fetch\"", "\"name\":\"read_url\"",
        "\"name\":\"fetch_json\"", "\"name\":\"osint_scan\"", "\"name\":\"deep_crawl\"",
    };
    return stripTools(gpa, schema, &web);
}

fn fenceSchema(gpa: std.mem.Allocator, schema: []const u8) []u8 {
    const drop = [_][]const u8{"\"name\":\"write_file\""};
    return stripTools(gpa, schema, &drop);
}

/// whole tools array (it's skipped); capped at MAX_TOOLS. Caller frees.
fn buildAuthoredSchema(gpa: std.mem.Allocator, mem: Mem) []u8 {
    const all = mem.list(tools.TOOL_SCOPE);
    defer gpa.free(all);
    if (all.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.BufSet = std.BufSet.init(gpa);
    defer seen.deinit();
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, all, '\n');
    while (it.next()) |ln| {
        if (n >= tools.MAX_TOOLS) break;
        var f = std.mem.splitScalar(u8, ln, '\x1f');
        const nm = f.next() orelse continue;
        const params = f.next() orelse continue;
        _ = f.next() orelse continue;
        if (nm.len == 0 or params.len < 2 or params[0] != '{') continue;
        if (seen.contains(nm)) continue;
        seen.insert(nm) catch {};
        if (std.mem.indexOf(u8, params, "\"type\":\"object\"") == null) continue;
        var vp = std.json.parseFromSlice(std.json.Value, gpa, params, .{}) catch continue;
        vp.deinit();
        out.appendSlice(gpa, ",{\"type\":\"function\",\"function\":{\"name\":\"") catch break;
        out.appendSlice(gpa, nm) catch break;
        out.appendSlice(gpa, "\",\"description\":\"a tool your swarm authored\",\"parameters\":") catch break;
        out.appendSlice(gpa, params) catch break;
        out.appendSlice(gpa, "}}") catch break;
        n += 1;
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// Comma-joined names of the swarm's authored tools, for the prompt ("call them by name, don't re-author"). "" if none.
fn authoredToolNames(gpa: std.mem.Allocator, mem: Mem) []u8 {
    const all = mem.list(tools.TOOL_SCOPE);
    defer gpa.free(all);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.BufSet = std.BufSet.init(gpa);
    defer seen.deinit();
    var it = std.mem.splitScalar(u8, all, '\n');
    while (it.next()) |ln| {
        var f = std.mem.splitScalar(u8, ln, '\x1f');
        const nm = f.next() orelse continue;
        if (nm.len == 0 or seen.contains(nm)) continue;
        seen.insert(nm) catch {};
        if (out.items.len > 0) out.appendSlice(gpa, ", ") catch {};
        out.appendSlice(gpa, nm) catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, "") catch @constCast(""));
}

/// JSON-escape `s` using `alloc` (returns a slice owned by `alloc`). Falls back to the raw input on OOM.
fn escA(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => out.appendSlice(alloc, "\\\"") catch return s,
        '\\' => out.appendSlice(alloc, "\\\\") catch return s,
        '\n' => out.appendSlice(alloc, "\\n") catch return s,
        '\r' => out.appendSlice(alloc, "\\r") catch return s,
        '\t' => out.appendSlice(alloc, "\\t") catch return s,
        else => if (c < 0x20) {
            var b: [6]u8 = undefined;
            out.appendSlice(alloc, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "") catch return s;
        } else out.append(alloc, c) catch return s,
    };
    return out.items;
}

fn currentPid() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.os.linux.getpid());
}

fn dupeEnv(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, name: []const u8) ?[]u8 {
    const v = environ.get(name) orelse return null;
    if (v.len == 0) return null;
    return gpa.dupe(u8, v) catch null;
}

/// Resolve an LLM config value by trying each candidate NAME in turn — first the per-swarm keys.env file
/// (plaintext BYOK), then the injected child env (encrypted minds). The deploy's keys.env wins over a stale
/// env value. Provider-agnostic: callers pass the generic name first, then provider-specific ones for
/// back-compat. Returns the first non-empty hit (gpa-owned), or null.
fn resolveCfg(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, run_dir: []const u8, names: []const []const u8) ?[]u8 {
    for (names) |name| {
        if (keysEnvVal(gpa, io, run_dir, name)) |v| return v;
        if (dupeEnv(gpa, environ, name)) |v| return v;
    }
    return null;
}

/// Read NAME=VALUE for `name` from <run_dir>/keys.env (the per-swarm BYOK file the control plane writes), or
/// null if absent. Mirrors how the Python worker loaded keys.env into its environment.
fn keysEnvVal(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, name: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/keys.env", .{run_dir}) catch return null;
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 10)) catch return null;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, ln[0..eq], " "), name)) {
            const v = std.mem.trim(u8, ln[eq + 1 ..], " \r\t");
            if (v.len == 0) return null;
            return gpa.dupe(u8, v) catch null;
        }
    }
    return null;
}

/// Append by read+rewrite (open+close per call → never holds a lock against the SSE reader).
/// Cloudflare Workers AI neuron cost for cumulative `ti`/`to` tokens on a @cf/ model (neurons per 1M tokens, from
/// the CF pricing page). Mirrors plan/neurons.zig's table, kept INLINE so the worker stays decoupled from the
/// control-plane billing module — the worker only REPORTS cumulative neurons via .usage; the control plane charges.
fn neuronsForCfModel(model: []const u8, ti: u64, to: u64) u64 {
    var in_per_m: u64 = 40_000;
    var out_per_m: u64 = 120_000;
    if (std.mem.indexOf(u8, model, "70b") != null or std.mem.indexOf(u8, model, "70B") != null) {
        in_per_m = 26_668;
        out_per_m = 204_805;
    } else if (std.mem.indexOf(u8, model, "8b") != null or std.mem.indexOf(u8, model, "8B") != null) {
        in_per_m = 25_608;
        out_per_m = 75_147;
    } else if (std.mem.indexOf(u8, model, "coder") != null or std.mem.indexOf(u8, model, "qwen") != null) {
        in_per_m = 60_000;
        out_per_m = 90_909;
    }
    return ((ti *| in_per_m) / 1_000_000) +| ((to *| out_per_m) / 1_000_000);
}

const EVENT_LOG_CAP: usize = 8 << 20;
fn appendFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, data: []const u8) void {
    const dir = std.Io.Dir.cwd();
    const orig = dir.readFileAlloc(io, path, gpa, .limited(64 << 20)) catch &[_]u8{};
    defer if (orig.len > 0) gpa.free(orig);
    var existing: []const u8 = orig;
    if (orig.len + data.len > EVENT_LOG_CAP and orig.len > 0) {
        const keep = if (EVENT_LOG_CAP > data.len) EVENT_LOG_CAP - data.len else 0;
        var start: usize = if (orig.len > keep) orig.len - keep else 0;
        while (start < orig.len and orig[start] != '\n') : (start += 1) {}
        if (start < orig.len) start += 1;
        existing = orig[start..];
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, existing) catch return;
    buf.appendSlice(gpa, data) catch return;
    dir.writeFile(io, .{ .sub_path = path, .data = buf.items }) catch {};
}

test "profileFor selects the tier and scales the budget" {
    const a = rsi.profileFor("auto");
    try std.testing.expect(a.tier == .author);
    try std.testing.expectEqual(@as(u32, MAX_TURNS), a.max_turns);
    try std.testing.expectEqual(@as(usize, 30000), a.conv_cap);
    try std.testing.expect(!a.lean_schema and !a.one_slot and !a.exemplar);
    const b = rsi.profileFor("assembler");
    try std.testing.expect(b.tier == .assembler);
    try std.testing.expectEqual(@as(u32, 3), b.max_turns);
    try std.testing.expect(b.lean_schema and b.one_slot and b.exemplar);
    try std.testing.expect(b.conv_cap < 30000);
    try std.testing.expect(rsi.profileFor("8B").tier == .assembler);
    try std.testing.expect(rsi.profileFor("small").tier == .assembler);
    try std.testing.expect(rsi.profileFor("tiny").tier == .extractor);
    try std.testing.expectEqual(@as(u32, 2), rsi.profileFor("extractor").max_turns);
    try std.testing.expect(rsi.profileFor("nonsense").tier == .author);
}

test "firstPath narrows a blueprint slice to one slot" {
    try std.testing.expectEqualStrings("a.py", firstPath("a.py, b.py, c.py"));
    try std.testing.expectEqualStrings("only.py", firstPath("only.py"));
    try std.testing.expectEqualStrings("src/app.py", firstPath("src/app.py, src/db.py"));
    try std.testing.expectEqualStrings("", firstPath(""));
    try std.testing.expectEqualStrings("", firstPath("   "));
}

test "builtInManifest matches by basename + non-trivial size (the slot-advance signal)" {
    const m = "src/main.rs|512\nstudy-guide.md|30\nCargo.toml|88\n";
    try std.testing.expect(builtInManifest(m, "main.rs"));
    try std.testing.expect(builtInManifest(m, "Cargo.toml"));
    try std.testing.expect(!builtInManifest(m, "study-guide.md"));
    try std.testing.expect(!builtInManifest(m, "routes.rs"));
    try std.testing.expect(!builtInManifest("", "anything"));
    try std.testing.expect(builtInManifest("PROJECT_TREE/main.rs|600\n", "main.rs"));
}

test "depsReady executes the AI-declared decomposition: independent parallel, dependent ordered" {
    const deps = "models.py: none\ndb.py: none\napi.py: models.py, db.py\ntest_api.py: api.py\n";
    const empty = "";
    const some = "models.py|400\ndb.py|350\n";
    try std.testing.expect(depsReady("", empty, "api.py"));
    try std.testing.expect(depsReady(deps, empty, "models.py"));
    try std.testing.expect(depsReady(deps, empty, "db.py"));
    try std.testing.expect(!depsReady(deps, empty, "api.py"));
    try std.testing.expect(!depsReady(deps, "models.py|400\n", "api.py"));
    try std.testing.expect(depsReady(deps, some, "api.py"));
    try std.testing.expect(!depsReady(deps, some, "test_api.py"));
    try std.testing.expect(!depsReady(deps, empty, "test_api.py"));
    try std.testing.expect(depsReady(deps, "api.py|900\n", "test_api.py"));
    try std.testing.expect(depsReady("test_util.py: none\n", empty, "test_util.py"));
    try std.testing.expect(depsReady(deps, empty, "test_smoke.py"));
    try std.testing.expect(depsReady(deps, empty, "README.md"));
}

test "assignSlot ADVANCES a builder past its built slice instead of re-pinning a done file (titan1 fix)" {
    const A = std.testing.allocator;
    const bp = "lexer.py — tokenizer\nparser.py — AST builder\ninterpreter.py — tree walker\nbuiltins.py — stdlib\nnox.py — CLI entry\n";
    {
        const s0 = assignSlot(A, "", bp, "", "", 0, 4);
        defer A.free(s0);
        const s2 = assignSlot(A, "", bp, "", "", 2, 4);
        defer A.free(s2);
        const s3 = assignSlot(A, "", bp, "", "", 3, 4);
        defer A.free(s3);
        const s1 = assignSlot(A, "", bp, "", "", 1, 4);
        defer A.free(s1);
        try std.testing.expectEqualStrings("lexer.py", s0);
        try std.testing.expectEqualStrings("parser.py", s2);
        try std.testing.expectEqualStrings("interpreter.py", s3);
        try std.testing.expectEqualStrings("", s1);
        try std.testing.expect(!std.mem.eql(u8, s0, s2));
        try std.testing.expect(!std.mem.eql(u8, s2, s3));
    }
    {
        const m = "lexer.py|820\nbuiltins.py|640\n";
        const s0 = assignSlot(A, m, bp, "", "", 0, 4);
        defer A.free(s0);
        const s2 = assignSlot(A, m, bp, "", "", 2, 4);
        defer A.free(s2);
        const s3 = assignSlot(A, m, bp, "", "", 3, 4);
        defer A.free(s3);
        try std.testing.expectEqualStrings("parser.py", s0);
        try std.testing.expectEqualStrings("interpreter.py", s2);
        try std.testing.expectEqualStrings("nox.py", s3);
        for ([_][]const u8{ s0, s2, s3 }) |s| {
            try std.testing.expect(!builtInManifest(m, std.fs.path.basename(s)));
            try std.testing.expect(s.len > 0);
        }
    }
}

test "assignSlot: surplus builders get no slot, and a fully-built project deepens only its lead" {
    const A = std.testing.allocator;
    const bp = "a.py\nb.py\n";
    {
        const s0 = assignSlot(A, "", bp, "", "", 0, 3);
        defer A.free(s0);
        const s1 = assignSlot(A, "", bp, "", "", 1, 3);
        defer A.free(s1);
        const s2 = assignSlot(A, "", bp, "", "", 2, 3);
        defer A.free(s2);
        try std.testing.expectEqualStrings("a.py", s0);
        try std.testing.expectEqualStrings("b.py", s1);
        try std.testing.expectEqualStrings("", s2);
    }
    {
        const m = "a.py|500\nb.py|500\n";
        const s0 = assignSlot(A, m, bp, "", "", 0, 3);
        defer A.free(s0);
        const s1 = assignSlot(A, m, bp, "", "", 1, 3);
        defer A.free(s1);
        const s2 = assignSlot(A, m, bp, "", "", 2, 3);
        defer A.free(s2);
        try std.testing.expectEqualStrings("a.py", s0);
        try std.testing.expectEqualStrings("", s1);
        try std.testing.expectEqualStrings("", s2);
    }
    {
        const m = "a.py|500\n";
        const dps = "b.py: c.py\n";
        const s0 = assignSlot(A, m, bp, dps, "", 0, 3);
        defer A.free(s0);
        const s1 = assignSlot(A, m, bp, dps, "", 1, 3);
        defer A.free(s1);
        try std.testing.expectEqualStrings("a.py", s0);
        try std.testing.expectEqualStrings("", s1);
    }
}

test "tierFromStr pins explicit tiers and lets auto/unknown fall through to RSI" {
    try std.testing.expect(rsi.tierFromStr("author").? == .author);
    try std.testing.expect(rsi.tierFromStr("assembler").? == .assembler);
    try std.testing.expect(rsi.tierFromStr("8B").? == .assembler);
    try std.testing.expect(rsi.tierFromStr("tiny").? == .extractor);
    try std.testing.expect(rsi.tierFromStr("auto") == null);
    try std.testing.expect(rsi.tierFromStr("") == null);
    try std.testing.expect(rsi.tierFromStr("llama3.1:8b") == null);
}

test "seedTier is a weak name prior, defaulting unknown to the safe assembler regime" {
    try std.testing.expect(rsi.seedTier("llama3.1:8b") == .assembler);
    try std.testing.expect(rsi.seedTier("deepseek-r1:8b") == .assembler);
    try std.testing.expect(rsi.seedTier("qwen2.5-7b") == .assembler);
    try std.testing.expect(rsi.seedTier("some-unknown-model") == .assembler);
    try std.testing.expect(rsi.seedTier("gpt-4o") == .author);
    try std.testing.expect(rsi.seedTier("claude-opus-4") == .author);
    try std.testing.expect(rsi.seedTier("llama-3.1-70b") == .author);
}

test "profileForTier maps each tier to its knob set" {
    try std.testing.expectEqual(@as(u32, MAX_TURNS), rsi.profileForTier(.author).max_turns);
    try std.testing.expect(!rsi.profileForTier(.author).lean_schema);
    try std.testing.expect(rsi.profileForTier(.assembler).lean_schema and rsi.profileForTier(.assembler).exemplar);
    try std.testing.expectEqual(@as(u32, 2), rsi.profileForTier(.extractor).max_turns);
}

test "fitnessSource follows the dominant LIVE fitness the situation provides (FIX 1 keystone — no use-case flag)" {
    const tests_ok = BenchResult{ .status = .ok, .passed = 8, .total = 10, .pct = 80 };
    const host_ok = BenchResult{ .status = .ok, .host = true, .passed = 15, .total = 100, .pct = 15 };
    const no_score = BenchResult{ .status = .no_tests };
    try std.testing.expect(fitnessSource(host_ok, true, 500, true, true) == .host);
    try std.testing.expect(fitnessSource(no_score, true, 0, false, false) == .host);
    try std.testing.expect(fitnessSource(tests_ok, false, 0, false, false) == .@"test");
    try std.testing.expect(fitnessSource(tests_ok, false, 800, false, false) == .doc);
    try std.testing.expect(fitnessSource(tests_ok, false, 0, true, false) == .doc);
    try std.testing.expect(fitnessSource(tests_ok, false, 0, false, true) == .doc);
    try std.testing.expect(fitnessSource(no_score, false, 0, false, false) == .none);
}

test "modeGate routes build-vs-operate on the SITUATION (operate → lean OPERATE schema + fence OFF; build unchanged)" {
    try std.testing.expectEqual(Schema.operate, modeGate(true, true, true, false, false).schema);
    try std.testing.expect(!modeGate(true, true, true, false, false).fence);
    try std.testing.expectEqual(Schema.operate, modeGate(true, false, false, false, false).schema);
    try std.testing.expectEqual(Schema.assembler, modeGate(false, true, true, false, false).schema);
    try std.testing.expect(modeGate(false, true, true, false, false).fence);
    try std.testing.expectEqual(Schema.full, modeGate(false, false, false, false, false).schema);
    try std.testing.expect(!modeGate(false, false, false, false, false).fence);
    try std.testing.expectEqual(Schema.scout, modeGate(false, true, true, true, false).schema);
    try std.testing.expect(!modeGate(false, true, true, true, false).fence);
    try std.testing.expectEqual(Schema.scout, modeGate(true, true, true, true, false).schema);
    try std.testing.expectEqual(Schema.scout, modeGate(false, true, true, false, true).schema);
    try std.testing.expect(!modeGate(false, true, true, false, true).fence);
}

test "clipNWords clips to a word budget, not a byte budget" {
    try std.testing.expectEqualStrings("one two three", clipNWords("one two three four five", 3));
    try std.testing.expectEqualStrings("alpha", clipNWords("alpha beta", 1));
    try std.testing.expectEqualStrings("just two", clipNWords("just two", 10));
    try std.testing.expectEqualStrings("  hello world", clipNWords("  hello world there", 2));
    try std.testing.expectEqualStrings("", clipNWords("", 5));
}

test "intentKey (FIX 4) keys recall on the brief's first CONTENT line, not its boilerplate skeleton" {
    const brief =
        \\1) The actual intent: keep the live host healthy and evict the cryptominer that pinned the CPU.
        \\2) A strong outcome looks like a clean process table and a restored service.
        \\3) Success criteria: threat_score returns to zero.
    ;
    const k = intentKey(brief);
    try std.testing.expect(std.mem.startsWith(u8, k, "The actual intent"));
    try std.testing.expect(std.mem.indexOf(u8, k, "cryptominer") == null);
    try std.testing.expect(k.len <= 80);

    const labeled = "Objective: build a REST API in Rust with axum and a sqlite store";
    const lk = intentKey(labeled);
    try std.testing.expect(std.mem.startsWith(u8, lk, "build a REST API"));

    const blanks = "\n\n   \nFirst real content line of the working brief here\n";
    try std.testing.expect(std.mem.startsWith(u8, intentKey(blanks), "First real content"));

    const dashed = "Defend the host and remove persistence - then verify the service is back up";
    try std.testing.expect(std.mem.startsWith(u8, intentKey(dashed), "Defend the host"));
}

test "isJunkFact rejects meta-narration and tool-call fragments, keeps real facts" {
    try std.testing.expect(isJunkFact("The team has begun recording essential Rust knowledge"));
    try std.testing.expect(isJunkFact("I will now summarize the progress made so far"));
    try std.testing.expect(isJunkFact("[nox r572] Summary: the swarm has gathered concepts"));
    try std.testing.expect(isJunkFact("{\"name\": \"write_file\", \"parameters\": {\"content\":"));
    try std.testing.expect(isJunkFact("write_file(content=\"AXUM...\")"));
    try std.testing.expect(isJunkFact("coverage: 20%"));
    try std.testing.expect(isJunkFact("ok"));
    try std.testing.expect(!isJunkFact("Rust ownership means each value has a single owner and is dropped when the owner goes out of scope"));
    try std.testing.expect(!isJunkFact("axum routes are built with Router::new().route(\"/path\", get(handler))"));
    try std.testing.expect(!isJunkFact("[sable r9] sqlx::query! checks SQL at compile time against the database schema"));
}

test "topicLabel extracts a short clean label for the knowledge index" {
    try std.testing.expectEqualStrings("Rust Lifetimes", topicLabel("**Rust Lifetimes**"));
    try std.testing.expectEqualStrings("Section: Ownership, Borrowing and Lifetimes", topicLabel("[nox r5] Section: Ownership, Borrowing and Lifetimes\nmore text"));
    try std.testing.expectEqualStrings("axum routing", topicLabel("axum routing. handlers map paths to functions"));
}

test "fileNeedsMore detects a chunk-built first part, passes a finished file" {
    try std.testing.expect(fileNeedsMore("import os\n\ndef main():\n    pass\n# the rest will be appended in subsequent iterations\n"));
    try std.testing.expect(fileNeedsMore("class Client:\n    ...\n# For now, the module exposes the helpers above; entry point to be defined later.\n"));
    try std.testing.expect(fileNeedsMore("def parse():\n    raise NotImplementedError  # to be implemented\n"));
    try std.testing.expect(!fileNeedsMore("import os\n\ndef main():\n    print('done')\n\nif __name__ == '__main__':\n    main()\n"));
    try std.testing.expect(!fileNeedsMore(""));
    try std.testing.expect(!fileNeedsMore("x"));
}

test "inSpaceList matches whole basenames only" {
    try std.testing.expect(inSpaceList("seed_discourse.py models.py", "models.py"));
    try std.testing.expect(inSpaceList("seed_discourse.py", "seed_discourse.py"));
    try std.testing.expect(!inSpaceList("myapp.py", "app.py"));
    try std.testing.expect(!inSpaceList("", "anything.py"));
}

test "psycheValence scores emotional content, not temperament adjectives" {
    try std.testing.expect(psycheValence("this is devastating, I feel hollow and full of dread for the displaced") < -0.5);
    try std.testing.expect(psycheValence("there is real hope here; people are resilient and rebuilding with courage") > 0.5);
    try std.testing.expectEqual(@as(f32, 0), psycheValence("Your voice is warm and generous; you stay even-keeled and animated."));
    try std.testing.expectEqual(@as(f32, 0), psycheValence(""));
    try std.testing.expectEqual(@as(f32, 0), psycheValence("collected high-impact stories and factual context"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("a high-impact factual react", "act"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences("take action now", "act"));
}

test "mindMonologue slices one mind's writing out of the round digest" {
    var minds = [_]MindState{
        .{ .name = "echo", .scope = "echo" },
        .{ .name = "atlas", .scope = "atlas" },
        .{ .name = "mira", .scope = "mira" },
    };
    const blob = "echo: this is bleak.\nit weighs on me.\natlas: steady as ever.\nmira: hopeful still.\n";
    try std.testing.expectEqualStrings("this is bleak.\nit weighs on me.", mindMonologue(blob, &minds, 0));
    try std.testing.expectEqualStrings("steady as ever.", mindMonologue(blob, &minds, 1));
    try std.testing.expectEqualStrings("hopeful still.", mindMonologue(blob, &minds, 2));
    try std.testing.expectEqualStrings("", mindMonologue("nobody: here", &minds, 0));
}

test "countOccurrences counts every case-insensitive hit" {
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("Dread and dread again", "dread"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("calm", "storm"));
}

test "fenceSchema removes ONLY write_file and leaves the others as valid JSON" {
    const gpa = std.testing.allocator;
    const fenced = fenceSchema(gpa, tools.ASSEMBLER_SCHEMA);
    defer gpa.free(fenced);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "\"name\":\"write_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "\"name\":\"observe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "\"name\":\"recall_hive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fenced, "\"name\":\"send_message\"") != null);
    const arr = std.fmt.allocPrint(gpa, "[{s}]", .{fenced}) catch unreachable;
    defer gpa.free(arr);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.value.array.items.len);

    const fenced_full = fenceSchema(gpa, tools.SCHEMA);
    defer gpa.free(fenced_full);
    try std.testing.expect(std.mem.indexOf(u8, fenced_full, "\"name\":\"write_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, fenced_full, "\"name\":\"run_python\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fenced_full, "\"name\":\"read_file\"") != null);
    const arr_full = std.fmt.allocPrint(gpa, "[{s}]", .{fenced_full}) catch unreachable;
    defer gpa.free(arr_full);
    var parsed_full = try std.json.parseFromSlice(std.json.Value, gpa, arr_full, .{});
    defer parsed_full.deinit();
    try std.testing.expect(parsed_full.value.array.items.len > 10);
}

test "salvageHasToolFragment rejects a bare tool-call blob but keeps a real file that merely mentions one" {
    try std.testing.expect(salvageHasToolFragment("{\"path\":\"x.py\",\"content\":\"print(1)\"}"));
    try std.testing.expect(salvageHasToolFragment("{\"name\":\"write_file\",\"arguments\":{\"path\":\"a.py\"}}"));
    try std.testing.expect(salvageHasToolFragment("{\"action\":\"write\",\"path\":\"a\"}"));
    try std.testing.expect(salvageHasToolFragment("{ \"tool_call\": {\"name\":\"write_file\"} }"));

    const real_py =
        \\import json
        \\
        \\def build_call(p):
        \\    # emit a write_file request shaped like {"path": "out.txt", "content": "..."}
        \\    return json.dumps({"path": p, "content": "hello"})
        \\
        \\if __name__ == "__main__":
        \\    print(build_call("out.txt"))
    ;
    try std.testing.expect(!salvageHasToolFragment(real_py));

    const real_cfg =
        \\{
        \\  "name": "my-app",
        \\  "tools": ["write_file", "read_file"],
        \\  "action": "build"
        \\}
    ;
    try std.testing.expect(!salvageHasToolFragment(real_cfg));

    try std.testing.expect(!salvageHasToolFragment("   \n  "));
}

test "salvageFileBody picks the LARGEST fenced block, skipping a small Note block" {
    const gpa = std.testing.allocator;
    const monologue =
        \\Here is a short note then the file.
        \\
        \\```
        \\(Note: I assumed the input is a list of ints.)
        \\```
        \\
        \\interpreter.py
        \\```python
        \\import sys
        \\
        \\def run(tokens):
        \\    total = 0
        \\    for t in tokens:
        \\        total += int(t)
        \\    return total
        \\
        \\if __name__ == "__main__":
        \\    print(run(sys.argv[1:]))
        \\```
    ;
    const body = salvageFileBody(gpa, monologue);
    defer if (body.len > 0) gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "def run(tokens):") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "(Note:") == null);

    const single =
        \\out.py
        \\```python
        \\def total(values):
        \\    acc = 0
        \\    for v in values:
        \\        acc += v
        \\    return acc
        \\```
    ;
    const one = salvageFileBody(gpa, single);
    defer if (one.len > 0) gpa.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "def total(values):") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "```") == null);
}
