//! Recursive self-improvement (RSI) for the neuron-loops worker — the engine-owned faculties that tune the
//! swarm's OWN operating parameters and strategy from measured outcomes, while the safety floor stays fixed:
//!   * the model-CAPACITY self-tuner (probe/name seed + two-way adaptation from measured tool-use vs narration),
//!   * the intuitive goal INTERPRETER (a terse instruction rebuilt into an explicit working brief),
//!   * the GOVERNOR (proposal accept/rollback by trial confidence + token-utility) and its score helpers, and
//!   * the multi-timescale RSI MEMORY distill, the weakness-driven CURRICULUM, the end-of-round RETROSPECTIVE,
//!     and the role ORCHESTRATOR (the swarm authors its own division of labor each round).
//! All of this operates on the `*run.Worker` god-object; the shared types/helpers live in run.zig and are
//! aliased below so the function bodies read exactly as they did in run.zig.
const std = @import("std");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const run = @import("run.zig");

const Worker = run.Worker;
const MindState = run.MindState;
const Moment = run.Moment;
const BenchResult = run.BenchResult;
const Tier = run.Tier;
const CapacityProfile = run.CapacityProfile;
const TEMP_FLOOR = run.TEMP_FLOOR;
const LANES = run.LANES;
const SCOUT_LANE = run.SCOUT_LANE;
const clip = run.clip;
const clipTail = run.clipTail;
const buildState = run.buildState;
const bpPath = run.bpPath;
const personaDesc = run.personaDesc;
const lastNonEmptyLine = run.lastNonEmptyLine;
const countNonEmptyLines = run.countNonEmptyLines;

/// The base ROLE ARCHETYPES the swarm's planner specializes from each round — the seed vocabulary for adaptive,
/// self-planned division of labor (roles self-improve in real time instead of being fixed by index). `research`
/// gates the research-only SCOUT_SCHEMA. `capability-builder` is what makes make_tool fire organically: a mind
/// whose explicit job is to find a capability gap and AUTHOR a tool for it; `inventor` breaks a stalled approach.
const Archetype = struct { key: []const u8, lane: []const u8, research: bool };
const ARCHETYPES = [_]Archetype{
    .{ .key = "lead", .lane = "LEAD/coordinator — set the plan, break it into add_task assignments, integrate teammates' work into the final artifact, keep everyone aligned (don't build it all yourself)", .research = false },
    .{ .key = "implementer", .lane = "IMPLEMENTER — own a concrete part of the deliverable end to end and keep EXTENDING it every round; read_file before you rewrite", .research = false },
    .{ .key = "reviewer", .lane = "REVIEW & QA — OWN the test suite (real test_*.py assertions about INTENDED behavior, never trivial asserts that game the score), and each round fix the single biggest failing test", .research = false },
    .{ .key = "domain-learner", .lane = SCOUT_LANE, .research = true },
    .{ .key = "capability-builder", .lane = "CAPABILITY-BUILDER — find the ONE capability gap blocking the benchmark; research the technique if needed, then AUTHOR it with make_tool (Python reading ARGS, printing one JSON line) so the team gains a permanent, callable tool, and verify it. Your output is a NEW TOOL, not a one-off script.", .research = false },
    .{ .key = "inventor", .lane = "INVENTOR — the current approach is stuck; do NOT iterate the failing path. Devise a DIFFERENT method (new algorithm/decomposition, or a new tool via make_tool) and prototype it.", .research = false },
};

/// The engine-defined knob set for each tier — the ONLY place the per-tier budget lives (the minds never control
/// it; this stays in the engine's safety floor). `adaptCapacity` and the startup seed both route through here.
pub fn profileForTier(t: Tier) CapacityProfile {
    return switch (t) {
        .author => .{},
        .assembler => .{ .tier = .assembler, .max_turns = 3, .conv_cap = 12000, .lean_schema = true, .one_slot = true, .exemplar = true, .temperature = 0.2 },
        .extractor => .{ .tier = .extractor, .max_turns = 2, .conv_cap = 8000, .lean_schema = true, .one_slot = true, .exemplar = true, .temperature = TEMP_FLOOR },
    };
}

/// An EXPLICIT manifest/NL_TIER tier string → a PINNED tier (RSI off, operator's call). null ⇒ "auto"/""/unknown
/// ⇒ RSI on (seed from the name, then adapt each round from measured behavior).
pub fn tierFromStr(s: []const u8) ?Tier {
    const t = std.mem.trim(u8, s, " \r\n\t");
    if (std.ascii.eqlIgnoreCase(t, "author")) return .author;
    if (std.ascii.eqlIgnoreCase(t, "assembler") or std.ascii.eqlIgnoreCase(t, "8b") or std.ascii.eqlIgnoreCase(t, "small")) return .assembler;
    if (std.ascii.eqlIgnoreCase(t, "extractor") or std.ascii.eqlIgnoreCase(t, "tiny")) return .extractor;
    return null;
}

/// The round-0 SEED — a weak PRIOR only (RSI corrects it from real behavior by ~round 2). A MEASURED prior
/// outranks the name prior: the /api/show probe exposes the model's true parameter count, so a local 70B is
/// seeded author no matter what it is named. Unknown ⇒ assembler: it is the safe default, because a strong
/// model still works under the lean scaffold (and RSI promotes it on its first strong round), whereas the
/// full author setup DROWNS a weak model on round 1.
pub fn seedTier(model: []const u8) Tier {
    const c = llm.capsSnapshot();
    if (c.probed and c.param_count > 0)
        return if (c.param_count >= 60_000_000_000) .author else .assembler;
    var buf: [96]u8 = undefined;
    const n = @min(model.len, buf.len);
    for (model[0..n], 0..) |c2, i| buf[i] = std.ascii.toLower(c2);
    const m = buf[0..n];
    const big = [_][]const u8{ "gpt-4", "gpt-5", "gpt4", "claude", "opus", "sonnet", "gemini-1.5-pro", "gemini-2", "70b", "72b", "405b", "-large", "command-r-plus" };
    for (big) |k| if (std.mem.indexOf(u8, m, k) != null) return .author;
    return .assembler;
}

/// Map an explicit tier string to a profile (PINNED path + the unit tests). null/auto/unknown → author.
pub fn profileFor(tier_str: []const u8) CapacityProfile {
    return profileForTier(tierFromStr(tier_str) orelse .author);
}

pub fn adaptCapacity(w: *Worker, round: u32, results: []const Moment) void {
    if (w.cap_pinned) return;
    var live_moments: u32 = 0;
    var with_tool: u32 = 0;
    var with_real_tool: u32 = 0;
    var narrated: u32 = 0;
    for (results) |r| {
        if (!r.llm_ok) continue;
        live_moments += 1;
        // a FENCED moment that landed its file via the salvage did its job with zero tool calls — count the
        // outcome, not the transport, or every fenced worker reads as "drowning" and gets demoted for working.
        if (r.tool_calls > 0 or r.files > 0) with_tool += 1;
        if (r.tool_calls > 0) with_real_tool += 1;
        if (r.narrated) narrated += 1;
    }
    if (live_moments == 0) {
        w.promo_streak = 0; // "two CONSECUTIVE strong rounds" must not straddle a total-outage round
        return;
    }
    const tool_ok = (with_tool * 100) / live_moments;
    const drowning = narrated > 0 or tool_ok < 60;
    if (!drowning) {
        w.cap_streak = 0;
        // PROMOTE (the seed comment above always promised this; now it is real): two consecutive rounds of
        // full GENUINE tool competence (every live moment made structured tool calls, nothing narrated) lift
        // the tier one step, so a capable model seeded low gets its full toolset back. Guards against the
        // false-positive flap measured in review: a FENCED worker's strong signal is the lean regime
        // carrying it (read-only calls still parse; its file lands via salvage) — promoting it to author
        // strips exactly that machinery, so fence mode blocks promotion; and one promote->demote round-trip
        // proves the higher tier drowns this model, locking further promotion for the run.
        const stronger: ?Tier = switch (w.cap.tier) {
            .author => null,
            .assembler => .author,
            .extractor => .assembler,
        };
        if (stronger != null and !w.fence_writes and !w.promo_locked and with_real_tool == live_moments and narrated == 0) {
            w.promo_streak += 1;
            if (w.promo_streak >= 2) {
                w.promo_streak = 0;
                const from = w.cap.tier;
                const keep_temp = w.cap.temperature;
                w.cap = profileForTier(stronger.?);
                w.cap.temperature = keep_temp;
                w.tier_was_promoted = true;
                w.act("engine", round, "capacity", @tagName(stronger.?), std.fmt.allocPrint(w.a(), "RSI promote {s} -> {s}: two strong rounds running (100% structured tool use, nothing narrated) — the model earned its fuller toolset back", .{ @tagName(from), @tagName(stronger.?) }) catch "rsi promote");
                w.emit("capacity", std.fmt.allocPrint(w.a(), ",\"tier\":\"{s}\",\"turns\":{d},\"conv_cap\":{d},\"promoted\":true", .{ @tagName(stronger.?), w.cap.max_turns, w.cap.conv_cap }) catch ",\"promoted\":true");
            }
        } else w.promo_streak = 0;
        return;
    }
    w.promo_streak = 0;
    if (w.cap.temperature < 0 or w.cap.temperature > TEMP_FLOOR) {
        const prev = w.cap.temperature;
        w.cap.temperature = TEMP_FLOOR;
        w.cap_streak = 0;
        w.act("engine", round, "capacity", "temperature", std.fmt.allocPrint(w.a(), "RSI lower temperature {d:.2} -> {d:.2}: the model NARRATED instead of emitting tool calls ({d}% of moments used tools, {d} narrated) — pulling sampling toward deterministic emission BEFORE touching its tier (full toolset preserved)", .{ if (prev < 0) @as(f32, 0.8) else prev, TEMP_FLOOR, tool_ok, narrated }) catch "rsi temp");
        w.emit("capacity", std.fmt.allocPrint(w.a(), ",\"tier\":\"{s}\",\"temperature\":{d:.2},\"tool_ok\":{d},\"narrated\":{d}", .{ @tagName(w.cap.tier), TEMP_FLOOR, tool_ok, narrated }) catch ",\"temperature\":0.10");
        return;
    }
    const operating = blk_op2: {
        const tp = std.fmt.allocPrint(w.gpa, "{s}/work/telemetry.json", .{w.run_dir}) catch break :blk_op2 false;
        defer w.gpa.free(tp);
        break :blk_op2 if (std.Io.Dir.cwd().access(w.io, tp, .{})) |_| true else |_| false;
    };
    const leaner: ?Tier = if (operating) null else switch (w.cap.tier) {
        .author => .assembler,
        .assembler => .extractor,
        .extractor => null,
    };
    if (leaner == null) {
        w.cap_streak = 0;
        return;
    }
    w.cap_streak += 1;
    if (w.cap_streak < 2) return;
    w.cap_streak = 0;
    const from = w.cap.tier;
    if (w.tier_was_promoted) {
        // demoting OUT of a tier we promoted INTO = the higher tier measurably drowns this model; lock
        // promotion for the rest of the run so the promote/demote pair cannot flap.
        w.promo_locked = true;
        w.tier_was_promoted = false;
    }
    w.cap = profileForTier(leaner.?);
    w.cap.temperature = TEMP_FLOOR;
    w.act("engine", round, "capacity", @tagName(leaner.?), std.fmt.allocPrint(w.a(), "RSI demote {s} -> {s}: low temp was not enough — the model still DROWNS ({d}% of moments used tools, {d} narrated, 2 rounds running) — leaning the context flow down to its measured ability", .{ @tagName(from), @tagName(leaner.?), tool_ok, narrated }) catch "rsi demote");
    w.emit("capacity", std.fmt.allocPrint(w.a(), ",\"tier\":\"{s}\",\"turns\":{d},\"conv_cap\":{d},\"tool_ok\":{d},\"narrated\":{d}", .{ @tagName(leaner.?), w.cap.max_turns, w.cap.conv_cap, tool_ok, narrated }) catch ",\"tier\":\"author\"");
}

/// INTUITIVE RSI — the goal interpreter. Take the user's terse, possibly-vague instruction and rebuild it into
/// an explicit working brief: the real intent, what a strong result looks like, and concrete success criteria
/// (even for open-ended "do X until I stop you"). One cheap llm.chat at swarm start; the brief is injected into
/// every mind so the swarm pursues what the user MEANT, not just the literal words. gpa-owned; "" on any failure.
pub fn interpretGoal(w: *Worker, goal: []const u8) []const u8 {
    const gpa = w.gpa;
    if (std.mem.trim(u8, goal, " \r\n\t").len == 0) return gpa.dupe(u8, "") catch @constCast("");
    const sys = "You turn a user's brief, possibly-vague instruction to an autonomous AI swarm into an explicit working brief. Infer what the user ACTUALLY wants, what a great result looks like, and concrete success criteria — even when the instruction is open-ended (e.g. 'do X until I stop you'). CRITICAL: you must PRESERVE, verbatim, every output file the goal names (e.g. worldbook.md, ch01.md) and every hard constraint or process requirement it states (e.g. 'a crisis must be handled', 'cite real sources', 'record dissent') — never paraphrase them away or drop them. Be specific and actionable. Do not ask questions; commit to the most sensible interpretation.";
    const user = std.fmt.allocPrint(gpa,
        \\The user gave this instruction to the swarm:
        \\"{s}"
        \\
        \\Write a SHORT brief the swarm should treat as its real objective:
        \\1) the actual intent behind the words — what they are really after;
        \\2) what a strong outcome looks like, concretely;
        \\3) the success criteria — what "good" or "done" means; if it's open-ended, define what continuous progress looks like;
        \\4) REQUIRED DELIVERABLES — list EVERY output file the goal names, verbatim (exact filenames, do not paraphrase or drop any);
        \\5) HARD CONSTRAINTS — list EVERY hard constraint and process requirement the goal states, verbatim (e.g. a mandated event/crisis, "cite real sources", "record dissent"). If the goal names none, say "none".
        \\Reply with ONLY the brief. No preamble, no questions.
    , .{clip(goal, 600)}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(user);
    const reply = llm.chat(gpa, w.io, w.run_dir, "intent", w.gw_base, w.gw_key, w.gateway_model, sys, user, 400);
    defer gpa.free(reply.content);
    if (!reply.ok) return gpa.dupe(u8, "") catch @constCast("");
    const t = std.mem.trim(u8, reply.content, " \r\n\t");
    if (t.len < 16) return gpa.dupe(u8, "") catch @constCast("");
    return gpa.dupe(u8, t) catch @constCast("");
}

pub fn parseScorePct(line: []const u8) ?i32 {
    const l = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const r = std.mem.indexOfScalarPos(u8, line, l + 1, '%') orelse return null;
    if (r <= l + 1) return null;
    const t = std.mem.trim(u8, line[l + 1 .. r], " \r\n\t");
    return std.fmt.parseInt(i32, t, 10) catch null;
}

const TrialConfidence = struct {
    trials: u32 = 0,
    mean_delta_milli: i64 = 0,
    confidence_milli: i64 = 0,
};

pub fn scoreTrialConfidence(scores: []const u8) TrialConfidence {
    var vals: [6]i32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, scores, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\n\t");
        if (t.len == 0) continue;
        if (parseScorePct(t)) |pct| {
            if (n < vals.len) {
                vals[n] = pct;
                n += 1;
            } else {
                var i: usize = 1;
                while (i < vals.len) : (i += 1) vals[i - 1] = vals[i];
                vals[vals.len - 1] = pct;
            }
        }
    }
    if (n < 2) return .{};

    var sum_delta: i64 = 0;
    var pos: i64 = 0;
    var neg: i64 = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const d: i64 = @as(i64, vals[i]) - @as(i64, vals[i - 1]);
        sum_delta += d;
        if (d > 0) pos += 1 else if (d < 0) neg += 1;
    }
    const deltas_n: i64 = @intCast(n - 1);
    const mean_milli: i64 = @divTrunc(sum_delta * 1000, deltas_n);
    var conf: i64 = 500 + @divTrunc((pos - neg) * 350, deltas_n) + @divTrunc(mean_milli, 6) + deltas_n * 40;
    if (conf < 0) conf = 0;
    if (conf > 1000) conf = 1000;
    return .{ .trials = @intCast(deltas_n), .mean_delta_milli = mean_milli, .confidence_milli = conf };
}

pub fn rsiGovernance(w: *Worker, round: u32, prev_pct: u32, tok0_in: u64, tok0_out: u64, tok0_calls: u64) void {
    const gpa = w.gpa;
    const proposals = w.mem.list(tools.PROPOSAL_SCOPE);
    defer gpa.free(proposals);
    const sims = w.mem.list(tools.SIM_SCOPE);
    defer gpa.free(sims);
    const scores = w.mem.list(tools.SCORE_SCOPE);
    defer gpa.free(scores);

    const latest = lastNonEmptyLine(proposals);
    const sims_n = countNonEmptyLines(sims);
    const tc = scoreTrialConfidence(scores);
    const now_pct_i: i32 = @intCast(w.last_bench.pct);
    const prev_pct_i: i32 = @intCast(prev_pct);
    const score_delta: i32 = now_pct_i - prev_pct_i;

    const din = llm.tokens_in.load(.monotonic) - tok0_in;
    const dout = llm.tokens_out.load(.monotonic) - tok0_out;
    const dcalls = llm.calls_made.load(.monotonic) - tok0_calls;
    const denom: i64 = @as(i64, @intCast(din + dout + 1));
    const utility_milli: i64 = @divTrunc(@as(i64, score_delta) * 100000, denom);

    var decision: []const u8 = "none";
    if (latest.len > 0) {
        if (sims_n == 0) {
            decision = "hold_no_sim";
        } else if (tc.trials < 2) {
            decision = "hold_low_trials";
        } else if (score_delta > 0 and w.last_bench.status == .ok and tc.confidence_milli >= 600 and tc.mean_delta_milli > 0) {
            decision = "accept";
        } else if (score_delta < 0 or tc.confidence_milli <= 350) {
            decision = "rollback";
        } else {
            decision = "hold";
        }

        const canary = std.fmt.allocPrint(gpa, "round {d} decision={s} score_delta={d} utility_milli={d} trials={d} confidence_milli={d} mean_delta_milli={d} sims={d} proposal={s}", .{ round, decision, score_delta, utility_milli, tc.trials, tc.confidence_milli, tc.mean_delta_milli, sims_n, clip(latest, 260) }) catch return;
        defer gpa.free(canary);
        _ = w.mem.observe(tools.CANARY_SCOPE, canary);
    }

    const gov = std.fmt.allocPrint(gpa, "round {d} governor: proposal={s} decision={s} score_delta={d} tokens={d} calls={d} utility_milli={d} trials={d} confidence_milli={d} mean_delta_milli={d}", .{ round, if (latest.len > 0) clip(latest, 180) else "(none)", decision, score_delta, din + dout, dcalls, utility_milli, tc.trials, tc.confidence_milli, tc.mean_delta_milli }) catch return;
    defer gpa.free(gov);
    _ = w.mem.observe(tools.AUTONOMY_SCOPE, gov);

    w.emit("rsi", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"decision\":\"{s}\",\"score_delta\":{d},\"tokens\":{d},\"calls\":{d},\"utility_milli\":{d},\"simulations\":{d},\"trials\":{d},\"confidence_milli\":{d},\"mean_delta_milli\":{d},\"proposal\":\"{s}\"", .{ round, decision, score_delta, din + dout, dcalls, utility_milli, sims_n, tc.trials, tc.confidence_milli, tc.mean_delta_milli, w.esc(clip(if (latest.len > 0) latest else "(none)", 220)) }) catch ",\"round\":0");
}

pub fn distillRsiMemory(w: *Worker, goal: []const u8, round: u32) void {
    const gpa = w.gpa;
    const ep = std.fmt.allocPrint(gpa, "round {d} | goal={s} | phase={s} | score={d}% | strategy={s}", .{ round, clip(goal, 160), clip(if (w.phase_str.len > 0) w.phase_str else "progressing", 140), w.last_bench.pct, clip(if (w.strategy_str.len > 0) w.strategy_str else "(none)", 220) }) catch return;
    defer gpa.free(ep);
    _ = w.mem.observe(tools.EPISODE_SCOPE, ep);

    if (@mod(round, 3) == 0) {
        const st = std.fmt.allocPrint(gpa, "round {d} strategy distill: bottleneck={s} | plan={s}", .{ round, clip(if (w.last_gap_str.len > 0) w.last_gap_str else "(no explicit gap)", 220), clip(if (w.strategy_str.len > 0) w.strategy_str else "(no strategy yet)", 300) }) catch return;
        defer gpa.free(st);
        _ = w.mem.observe(tools.STRATEGY_SCOPE, st);
    }

    if (@mod(round, 9) == 0) {
        const ar = std.fmt.allocPrint(gpa, "round {d} architecture distill: playbook={s} | depgraph={s}", .{ round, clip(if (w.playbook_str.len > 0) w.playbook_str else "(no directives)", 260), clip(if (w.depgraph_str.len > 0) w.depgraph_str else "(no depgraph)", 260) }) catch return;
        defer gpa.free(ar);
        _ = w.mem.observe(tools.ARCH_SCOPE, ar);
    }
}

pub fn updateRsiCurriculum(w: *Worker, goal: []const u8, round: u32, stalled: bool) void {
    if (!stalled and @mod(round, 3) != 0) return;
    const gpa = w.gpa;
    const challenge = if (!w.discourse and w.last_bench.status == .ok and w.last_bench.failures.len > 0)
        std.fmt.allocPrint(gpa, "Target the top failing benchmark behavior: {s}", .{clip(w.last_bench.failures, 220)}) catch return
    else if (w.last_gap_str.len > 0)
        std.fmt.allocPrint(gpa, "Close this explicit knowledge gap with external evidence and a concrete implementation step: {s}", .{clip(w.last_gap_str, 220)}) catch return
    else
        std.fmt.allocPrint(gpa, "Design one alternative method for goal '{s}' and test it against the current baseline.", .{clip(goal, 160)}) catch return;
    defer gpa.free(challenge);

    const rec = std.fmt.allocPrint(gpa, "round {d} challenge: {s}", .{ round, challenge }) catch return;
    defer gpa.free(rec);
    _ = w.mem.observe(tools.CURRICULUM_SCOPE, rec);

    w.emit("curriculum", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"stalled\":{},\"challenge\":\"{s}\"", .{ round, stalled, w.esc(clip(challenge, 260)) }) catch ",\"round\":0");
}

/// End-of-round RETROSPECTIVE — the engine-owned half of recursive self-improvement. Builder minds, heads-down
/// on the deliverable, essentially never volunteer a process change, so we make reflection a deterministic step:
/// once per round, look at what actually happened + the rules already in force, and let the model add ONE new
/// operating rule to the self-authored playbook (or decline). Those rules are injected into every mind's system
/// prompt next round, so the swarm's PROCESS compounds over time exactly like its artifact does — without the
/// engine hard-wiring any particular behaviour. Best-effort: any failure just skips this round's reflection.
pub fn roundRetrospective(w: *Worker, goal: []const u8, round: u32, summaries: []const u8, bench: BenchResult) void {
    const gpa = w.gpa;
    const playbook = w.mem.list(tools.PLAYBOOK_SCOPE);
    defer gpa.free(playbook);
    const build = buildState(gpa, w.io, w.run_dir);
    defer gpa.free(build);
    const score_line = switch (bench.status) {
        .ok => std.fmt.allocPrint(gpa, "{d}/{d} ({d}%) tier{d}; failing: {s}", .{ bench.passed, bench.total, bench.pct, bench.tier, if (bench.failures.len > 0) clip(bench.failures, 400) else "(none)" }) catch (gpa.dupe(u8, "scored") catch @constCast("")),
        .no_tests => gpa.dupe(u8, "no test suite yet — no scoreboard exists") catch @constCast(""),
        .err => gpa.dupe(u8, "the benchmark could not run (deliverable or tests don't execute)") catch @constCast(""),
    };
    defer gpa.free(score_line);
    const sys = if (w.discourse)
        "You are the swarm's retrospective facilitator for a RESEARCH and WRITING task. There is NO code repo, NO test suite, and NO build — do not invent one. After each round you maintain the swarm's OPERATING PLAYBOOK: short, concrete RESEARCH/WRITING process rules (close a coverage gap, source an unsourced claim, record dissent where minds disagreed, WRITE a named deliverable file that doesn't exist yet, sharpen a weakly-calibrated view) that every mind must follow next round. Never propose a software/engineering rule (no 'add a unit test', 'py_compile', 'set __all__', 'fix imports', 'run the benchmark'). You add a rule only when it would genuinely change behaviour for the better."
    else
        "You are the swarm's retrospective facilitator. After each round you maintain the swarm's OPERATING PLAYBOOK: short, concrete process rules (about coordination, verifying work, building on what exists, not duplicating effort, and RAISING THE BENCHMARK PASS RATE) that every mind must follow next round. You add a rule only when it would genuinely change behaviour for the better.";
    const user = if (w.discourse) std.fmt.allocPrint(gpa,
        \\Goal: {s}
        \\
        \\What the minds reported this round:
        \\{s}
        \\
        \\Written deliverable so far: {s}
        \\
        \\Rules already in force (do NOT restate these):
        \\{s}
        \\
        \\This is a research/writing task — there is no benchmark or test suite. Name the SINGLE most valuable NEW research/writing process rule for next round, drawn ONLY from: a coverage gap to close, an unsourced claim to ground with a real source, missing dissent to record, a named deliverable file the goal requires that has NOT been written yet (write it with write_file), or weak calibration to sharpen. Do NOT propose any software/engineering rule (no unit tests, py_compile, __all__, imports, benchmarks — there is no code). If the playbook already covers what matters, answer exactly: none
        \\Reply with ONLY the one-line imperative rule (or the word none). No preamble, no quotes.
    , .{
        if (goal.len > 0) clip(goal, 240) else "explore",
        if (summaries.len > 0) clip(summaries, 1600) else "(no summaries)",
        if (build.len > 0) clip(build, 400) else "(nothing written yet)",
        if (playbook.len > 0) clipTail(playbook, 1200) else "(empty — no rules yet)",
    }) catch return else std.fmt.allocPrint(gpa,
        \\Goal: {s}
        \\
        \\Benchmark this round: {s}
        \\
        \\What the minds reported this round:
        \\{s}
        \\
        \\Current build: {s}
        \\
        \\Rules already in force (do NOT restate these):
        \\{s}
        \\
        \\Name the SINGLE most valuable NEW process rule that would RAISE THE PASS RATE next round (or improve coordination/verification toward it) — concrete and not already covered above. If the benchmark could not run, a rule ensuring the deliverable and its tests execute cleanly may be most valuable. If the playbook already covers what matters, answer exactly: none
        \\Reply with ONLY the one-line imperative rule (or the word none). No preamble, no quotes.
    , .{
        if (goal.len > 0) clip(goal, 240) else "explore",
        score_line,
        if (summaries.len > 0) clip(summaries, 1600) else "(no summaries)",
        if (build.len > 0) clip(build, 400) else "(nothing yet)",
        if (playbook.len > 0) clipTail(playbook, 1200) else "(empty — no rules yet)",
    }) catch return;
    defer gpa.free(user);

    const reply = llm.chat(gpa, w.io, w.run_dir, "retro", w.gw_base, w.gw_key, w.gateway_model, sys, user, 160);
    defer gpa.free(reply.content);
    if (!reply.ok) return;
    var rule = std.mem.trim(u8, reply.content, " \r\n\t\"'`");
    while (rule.len > 0 and (rule[0] == '-' or rule[0] == '*' or rule[0] == '.' or (rule[0] >= '0' and rule[0] <= '9'))) rule = std.mem.trim(u8, rule[1..], " \r\n\t.)\"'`");
    if (rule.len < 8) return;
    if (std.ascii.eqlIgnoreCase(rule, "none")) return;
    if (rule.len > 200) rule = rule[0..200];
    if (playbook.len > 0 and std.mem.indexOf(u8, playbook, rule[0..@min(rule.len, 24)]) != null) {
        w.act("retro", round, "playbook", "no change", "(playbook already covers it)");
        return;
    }
    _ = w.mem.observe(tools.PLAYBOOK_SCOPE, rule);
    w.act("retro", round, "set_directive", "retrospective", rule);
    w.emit("growth", std.fmt.allocPrint(w.a(), ",\"mind\":\"retro\",\"round\":{d},\"age\":{d},\"facts\":0,\"skills\":0,\"directives\":{d},\"recalled\":0,\"built\":false,\"stances\":[]", .{ round, round, w.mem.factCount(tools.PLAYBOOK_SCOPE) }) catch ",\"round\":0");
}

/// The string value of `"<key>": "<value>"` inside possibly-malformed JSON text — a last-resort extractor for
/// when the whole document does not parse (weak-model truncation). Backslash-escaped quotes are skipped.
fn textField(s: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [48]u8 = undefined;
    const kq = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
    const kpos = std.mem.indexOf(u8, s, kq) orelse return null;
    var i = kpos + kq.len;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == ':')) i += 1;
    if (i >= s.len or s[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return s[start..i];
    }
    return s[start..]; // truncated mid-string — keep what's there
}

test "textField extracts a value from prose-wrapped or truncated JSON" {
    try std.testing.expectEqualStrings("fix the store API", textField("Here is my plan: {\"bottleneck\": \"fix the store API\", \"assignments\": [", "bottleneck").?);
    try std.testing.expectEqualStrings("cut off mid", textField("{\"bottleneck\":\"cut off mid", "bottleneck").?);
    try std.testing.expect(textField("no such key here", "bottleneck") == null);
}

pub fn matchArchetype(role: []const u8) ?Archetype {
    const t = std.mem.trim(u8, role, " \r\n\t");
    for (ARCHETYPES) |x| if (std.ascii.eqlIgnoreCase(x.key, t)) return x;
    return null;
}

/// The ROLE PLANNER — the engine-owned driver of adaptive division of labor (roles self-improve in real time).
/// Once per round it asks the model to assign EVERY mind one archetype role given the goal + score + build +
/// authored tools, and re-plans toward the gap when the score stalls. This is the structural driver that makes
/// make_tool fire organically (it can assign a capability-builder). Round-1's static seed is a strong prior;
/// the planner only overrides from round 2+, caps churn at half the swarm (anti-thrash), and never strips the
/// learning floor (>=1 scout at n>=4; an omitted mind keeps its prior role, so the seed reviewer persists).
/// Best-effort: on any failure roles are left untouched. Single-threaded (between rounds) — moments read fresh.
/// TRUE when `focus` names a blueprint file already claimed by an earlier assignment THIS round (the caller
/// then skips the duplicate assignment); otherwise registers every blueprint basename the focus names into
/// `claimed` and returns false. Word-bounded matching, so `store.py` in prose never claims test_store.py.
fn focusClaimsTaken(blueprint: []const u8, focus: []const u8, claimed: *std.ArrayListUnmanaged([]const u8), gpa: std.mem.Allocator) bool {
    if (blueprint.len == 0) return false;
    var pending: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pending.deinit(gpa);
    var bit = std.mem.splitScalar(u8, blueprint, '\n');
    while (bit.next()) |bl| {
        const bp = bpPath(bl) orelse continue;
        const base = std.fs.path.basename(bp);
        if (base.len < 4) continue;
        if (!run.containsWordBounded(focus, base)) continue;
        for (claimed.items) |c| if (std.mem.eql(u8, c, base)) return true;
        pending.append(gpa, base) catch {};
    }
    for (pending.items) |b| claimed.append(gpa, b) catch {};
    return false;
}

pub fn planRoles(w: *Worker, minds: []MindState, goal: []const u8, round: u32, bench: BenchResult, stalled: bool) void {
    const gpa = w.gpa;
    if (minds.len <= 1) return;
    const build = buildState(gpa, w.io, w.run_dir);
    defer gpa.free(build);
    const caps = w.mem.list(tools.TOOL_SCOPE);
    defer gpa.free(caps);
    var capnames: std.ArrayListUnmanaged(u8) = .empty;
    defer capnames.deinit(gpa);
    {
        var it = std.mem.splitScalar(u8, caps, '\n');
        while (it.next()) |ln| {
            var f = std.mem.splitScalar(u8, ln, '\x1f');
            const nm = f.next() orelse continue;
            if (nm.len == 0) continue;
            if (capnames.items.len > 0) capnames.appendSlice(gpa, ", ") catch {};
            capnames.appendSlice(gpa, nm) catch {};
        }
    }
    const score_line = switch (bench.status) {
        .ok => std.fmt.allocPrint(gpa, "{d}/{d} ({d}%) tier{d}; failing: {s}", .{ bench.passed, bench.total, bench.pct, bench.tier, if (bench.failures.len > 0) clip(bench.failures, 280) else "(none)" }) catch (gpa.dupe(u8, "scored") catch @constCast("")),
        .no_tests => gpa.dupe(u8, "no tests yet") catch @constCast(""),
        .err => gpa.dupe(u8, "the benchmark did not run") catch @constCast(""),
    };
    defer gpa.free(score_line);
    var roster: std.ArrayListUnmanaged(u8) = .empty;
    defer roster.deinit(gpa);
    for (minds) |mi| {
        var pbuf: [200]u8 = undefined;
        const pd = personaDesc(mi.persona, &pbuf);
        roster.appendSlice(gpa, mi.name) catch {};
        roster.appendSlice(gpa, " (temperament: ") catch {};
        roster.appendSlice(gpa, pd) catch {};
        roster.appendSlice(gpa, ")\n") catch {};
    }
    const sys = "You are the swarm's LEAD ORCHESTRATOR. Each round you set the strategy: name the single biggest bottleneck blocking a higher score, then assign EVERY mind its most valuable SPECIFIC next task — grounded in the ACTUAL failing tests, the blueprint, the import graph, and the current build. Be concrete: name the file, the failing test, or the missing capability (not a generic role). For a MULTI-DIRECTORY project, prefer giving each mind a whole MODULE/DIRECTORY to own so its files stay coherent, and respect the import graph (a change to a file means updating the files that import it). Ensure coverage: at least one mind must directly attack the top failing test; once real code exists keep at least one mind reviewing/hardening. `research:true` makes a mind the SCOUT — the hive's RETRIEVAL-AUGMENTATION faculty: research-only (build tools withheld) so it can't drift into building, it brings findings back into the shared hive memory that EVERY mind then recalls. Assign a scout when the team needs knowledge it doesn't yet have. If the planned STRUCTURE needs to change (a file you didn't plan is now needed), add it via blueprint_add. CRITICAL — the protected benchmark is the SOURCE OF TRUTH and may REQUIRE files at EXACT paths that are NOT in your blueprint: if a failing test's message names a file path (e.g. 'backend/server.py must exist') that is not already a blueprint line, you MUST add that EXACT path via blueprint_add this round and assign a mind to create it there — do NOT keep editing a similarly-named file at a different path. Match work to temperament where it helps. Maximize the benchmark pass rate as fast as possible.";
    const user = std.fmt.allocPrint(gpa, "The hive's WILL (from the VEIL, the consciousness you serve — your plan must advance it): {s}\nGoal: {s}\nRound: {d}{s}\nBenchmark: {s}\nProject blueprint:\n{s}\nImport graph:\n{s}\nCurrent build:\n{s}\nAuthored tools so far: {s}\nMinds (assign one SPECIFIC task each):\n{s}\nOutput STRICT JSON on ONE line and nothing else: {{\"bottleneck\":\"<the single biggest thing blocking a higher score, one line>\",\"assignments\":[{{\"mind\":\"<name>\",\"focus\":\"<this mind's specific next task>\",\"research\":<true|false>}}],\"blueprint_add\":[\"<new path — purpose, only if the structure must change>\"]}}", .{ if (w.veil_str.len > 0) clip(w.veil_str, 500) else "(forming)", clip(goal, 240), round, if (stalled) " (SCORE IS STALLED — change the plan: research the gap, author a tool, or rethink the structure/approach)" else "", score_line, if (w.blueprint.len > 0) clip(w.blueprint, 500) else "(no blueprint)", if (w.depgraph_str.len > 0) clip(w.depgraph_str, 600) else "(none yet)", if (build.len > 0) clip(build, 500) else "(nothing yet)", if (capnames.items.len > 0) capnames.items else "(none yet)", roster.items }) catch return;
    defer gpa.free(user);
    const reply = llm.chat(gpa, w.io, w.run_dir, "planner", w.base_url, w.key, w.model, sys, user, 480);
    defer gpa.free(reply.content);
    if (!reply.ok) return;
    const P = struct {
        bottleneck: []const u8 = "",
        assignments: []const struct { mind: []const u8 = "", focus: []const u8 = "", research: bool = false } = &.{},
        blueprint_add: []const []const u8 = &.{},
    };
    const trimmed = std.mem.trim(u8, reply.content, " \r\n\t`");
    var parsed = std.json.parseFromSlice(P, gpa, trimmed, .{ .ignore_unknown_fields = true }) catch blk_fb: {
        // FALLBACK 1: a weak model wraps its JSON in prose or a ```json fence — parse the outermost {...} span.
        const lb = std.mem.indexOfScalar(u8, trimmed, '{');
        const rb = std.mem.lastIndexOfScalar(u8, trimmed, '}');
        if (lb != null and rb != null and rb.? > lb.?) {
            if (std.json.parseFromSlice(P, gpa, trimmed[lb.? .. rb.? + 1], .{ .ignore_unknown_fields = true })) |p2| {
                break :blk_fb p2;
            } else |_| {}
        }
        // FALLBACK 2: the JSON is truly broken (truncated mid-string) — salvage at least the bottleneck text
        // so the round keeps a STRATEGY instead of discarding the whole plan; roles stay as they were.
        if (textField(trimmed, "bottleneck")) |b| {
            if (std.mem.trim(u8, b, " \r\n\t").len > 3) {
                if (w.strategy_str.len > 0) gpa.free(@constCast(w.strategy_str));
                w.strategy_str = gpa.dupe(u8, clip(std.mem.trim(u8, b, " \r\n\t"), 280)) catch "";
                w.act("orchestrator", round, "strategy", w.strategy_str, "(the plan JSON was unparseable — kept the bottleneck as this round's strategy; roles unchanged)");
            }
        }
        return;
    };
    defer parsed.deinit();
    if (parsed.value.assignments.len == 0 and parsed.value.bottleneck.len == 0) return;
    if (std.mem.trim(u8, parsed.value.bottleneck, " \r\n\t").len > 3) {
        if (w.strategy_str.len > 0) gpa.free(@constCast(w.strategy_str));
        w.strategy_str = gpa.dupe(u8, clip(std.mem.trim(u8, parsed.value.bottleneck, " \r\n\t"), 280)) catch "";
    }
    if (parsed.value.blueprint_add.len > 0 and w.blueprint.len > 0) {
        var nb: std.ArrayListUnmanaged(u8) = .empty;
        defer nb.deinit(gpa);
        nb.appendSlice(gpa, w.blueprint) catch {};
        var added: u32 = 0;
        for (parsed.value.blueprint_add) |line| {
            if (added >= 6) break;
            const np = bpPath(line) orelse continue;
            var dup = false;
            var bit = std.mem.splitScalar(u8, w.blueprint, '\n');
            while (bit.next()) |bl| {
                if (bpPath(bl)) |ep| if (std.mem.eql(u8, ep, np)) {
                    dup = true;
                    break;
                };
            }
            if (dup) continue;
            nb.append(gpa, '\n') catch {};
            nb.appendSlice(gpa, clip(std.mem.trim(u8, line, " \r\n\t"), 160)) catch {};
            added += 1;
        }
        if (added > 0) {
            if (nb.toOwnedSlice(gpa)) |newbp| {
                gpa.free(@constCast(w.blueprint));
                w.blueprint = newbp;
                w.emit("blueprint", std.fmt.allocPrint(w.a(), ",\"revised\":true,\"round\":{d},\"added\":{d}", .{ round, added }) catch ",\"revised\":true");
                w.act("orchestrator", round, "blueprint_revised", "structure evolved", w.blueprint);
            } else |_| {}
        }
    }
    var changed: u32 = 0;
    var plan_ev: std.ArrayListUnmanaged(u8) = .empty;
    defer plan_ev.deinit(gpa);
    // PER-FILE EXCLUSIVITY: at most ONE mind may hold a task naming a given blueprint file. Within this plan
    // the first claim wins; after the plan lands, a STALE lane (a mind not reassigned this round) that names a
    // file claimed this round is RELEASED. Without this, tasks piled up — observed live (sim_forum4): round 7
    // held two minds' tasks on users.py, round 8 three; the collision spliced a second copy of the module into
    // the file. Claims are blueprint basenames word-bounded in the task text (a real file, not a prose word).
    var claimed: std.ArrayListUnmanaged([]const u8) = .empty; // slices into w.blueprint — stable this round
    defer claimed.deinit(gpa);
    const reassigned = gpa.alloc(bool, minds.len) catch null;
    defer if (reassigned) |ra| gpa.free(ra);
    if (reassigned) |ra| for (ra) |*x| {
        x.* = false;
    };
    for (parsed.value.assignments) |a| {
        const focus = std.mem.trim(u8, a.focus, " \r\n\t");
        if (focus.len < 4) continue;
        if (focusClaimsTaken(w.blueprint, focus, &claimed, gpa)) continue; // a teammate claimed this file first
        for (minds, 0..) |*mi, mx| {
            if (!std.ascii.eqlIgnoreCase(mi.name, a.mind)) continue;
            if (reassigned) |ra| ra[mx] = true;
            if (std.mem.eql(u8, mi.lane, focus)) {
                mi.scout = a.research and w.internet;
                break;
            }
            const newlane = gpa.dupe(u8, clip(focus, 300)) catch break;
            if (mi.lane_owned and mi.lane.ptr != mi.name.ptr) gpa.free(@constCast(mi.lane));
            mi.lane = newlane;
            mi.lane_owned = true;
            mi.scout = a.research and w.internet;
            changed += 1;
            if (plan_ev.items.len > 0) plan_ev.appendSlice(gpa, " | ") catch {};
            plan_ev.appendSlice(gpa, std.fmt.allocPrint(gpa, "{s}: {s}", .{ a.mind, clip(newlane, 60) }) catch "") catch {};
            break;
        }
    }
    // release stale colliding lanes: a mind NOT in this round's plan whose old task names a file a teammate
    // just claimed would otherwise keep "owning" it and edit in parallel (the pile-up above).
    if (claimed.items.len > 0) for (minds, 0..) |*mi, mx| {
        const was_reassigned = if (reassigned) |ra| ra[mx] else false;
        if (was_reassigned or !mi.lane_owned or mi.lane.len == 0) continue;
        var hit: []const u8 = "";
        for (claimed.items) |base| {
            if (run.containsWordBounded(mi.lane, base)) {
                hit = base;
                break;
            }
        }
        if (hit.len == 0) continue;
        if (mi.lane.ptr != mi.name.ptr) gpa.free(@constCast(mi.lane));
        mi.lane = "";
        mi.lane_owned = false;
        var relbuf: [256]u8 = undefined;
        const relmsg = std.fmt.bufPrint(&relbuf, "stale task named `{s}`, which this round's plan assigns to a teammate — released (one mind per file)", .{hit}) catch "stale colliding task released (one mind per file)";
        w.act("orchestrator", round, "lane_release", mi.name, relmsg);
    };
    if (minds.len >= 4 and w.internet) {
        var has_scout = false;
        for (minds) |mi| {
            if (mi.scout) has_scout = true;
        }
        if (!has_scout) minds[1].scout = true;
    }
    if (changed > 0 or w.strategy_str.len > 0) {
        w.act("orchestrator", round, "strategy", if (w.strategy_str.len > 0) w.strategy_str else goal, plan_ev.items);
        w.emit("strategy", std.fmt.allocPrint(w.a(), ",\"round\":{d},\"bottleneck\":\"{s}\",\"plan\":\"{s}\"", .{ round, w.esc(clip(w.strategy_str, 280)), w.esc(clip(plan_ev.items, 400)) }) catch ",\"round\":0");
        w.emit("growth", std.fmt.allocPrint(w.a(), ",\"mind\":\"orchestrator\",\"round\":{d},\"age\":{d},\"facts\":0,\"skills\":0,\"directives\":0,\"recalled\":0,\"built\":false,\"stances\":[]", .{ round, round }) catch ",\"round\":0");
    }
}
