//! dataset.zig — TRAINING-SET CAPTURE. "Build dataset" records everything the veil does while it is
//! on, in a shape a fine-tuning run can consume without a conversion script.
//!
//! WHERE IT CAPTURES, AND WHY THERE. The single honest place to record a training example is the LLM
//! BOUNDARY: the exact request the engine sent (system doctrine + full conversation + tool RESULTS +
//! the tools array) and the exact assistant output (visible content, hidden reasoning, structured
//! tool_calls). That pair IS a supervised example — prompt and completion — with nothing inferred and
//! nothing reconstructed. Capturing higher up (the conversation log) loses the tool wire format and
//! the reasoning channel; capturing lower (the HTTP body) loses which role/model served it. So
//! worker/llm.zig calls recordCall() at each of its four completion paths, and worker/tools.zig calls
//! recordTool() at its one dispatcher — together those cover how the model REASONS (reasoning field),
//! how it CALLS tools (tool_calls + the tool's own args/result/ok/ms), and how it BUILDS (every
//! write_file / edit_file / run_* execution, with what came back).
//!
//! WHAT A SET LOOKS LIKE ({data}/sets/<id>/, NL_SETS_DIR overrides the root):
//!   meta.json            what this set is: label, when, counts, and every (model, provider) seen
//!   README.md            the format, written INTO the set so it travels with the data
//!   sft.jsonl            TRAINING-READY. One JSON object per line, OpenAI messages format:
//!                        {"messages":[…,{"role":"assistant","content":…,"reasoning_content":…,
//!                        "tool_calls":[…]}],"tools":[…],"model":…,"provider":…,"source":…}
//!                        — the shape TRL / axolotl / unsloth / llama-factory all read directly.
//!   by-model/<slug>.jsonl  the same records SHARDED by the model that produced them, so "train on
//!                        only what the-veil-12b generated" (or only what Opus generated) is one file.
//!   raw.jsonl            FULL FIDELITY, nothing dropped: the verbatim request body and the parsed
//!                        response beside it, plus timing, token counts, provider host and role label.
//!                        sft.jsonl is derived from this; raw is what you re-derive a different
//!                        format from later.
//!   tools.jsonl          every tool EXECUTION: name, verbatim args, the result the model saw, ok, ms.
//!
//! ROLLING PARTS. No file that is still being written grows past PART_MAX. The append that would cross it first
//! renames the live file to <name>.<UTC stamp>.jsonl (a rename, no copy) and starts a fresh <name>.jsonl, and an
//! archived part is never written again. WHY: Windows Defender's real-time protection rescans a file in full every
//! time it is modified and closed. Measured 2026-10-11 on a set recording since 2026-08-20: raw.jsonl 511 MB,
//! sft.jsonl 526 MB and by-model/ 526 MB took a few dozen KB per model call, and Defender answered every append by
//! re-reading them — bursts of 0.9-1.3 GB/s, about 45 bursts of ~1 GB in 150 s around one prompt, enough to take
//! the whole machine down whenever RAM was tight. Records are untouched: the same bytes, never split across parts.
//! A reader that wants one stream concatenates <name>.*.jsonl in name order and then <name>.jsonl — the parts'
//! UTC stamps sort before the live file's "jsonl" — and gets exactly the bytes a single file would have held.
//!
//! ON/OFF IS A FILE, DELIBERATELY. `<root>/RECORDING` holds the active set id. Swarm minds are
//! separate PROCESSES (the supervisor injects NL_SETS_DIR), and a marker file is the one switch every
//! process can read with no IPC and no restart — flip it in the server and the next call a worker
//! makes is already being captured. Each process re-stats it at most every RECHECK_S, so the
//! per-call cost of "am I recording?" is an atomic load.
//!
//! FAIL-QUIET, ALWAYS. Every path here is best-effort: a full disk or a permission error must never
//! break the turn the user is having. Every write is `catch {}` and every reader treats absence as
//! "not recording".

const std = @import("std");
const vthread = @import("../threads.zig"); // every thread: small Windows stack commit + a name (see threads.zig)

/// The marker file's name inside the sets root; its contents are the active set id.
pub const MARKER = "RECORDING";
/// How long a process may trust its cached view of the marker before re-stat'ing it.
const RECHECK_S: i64 = 2;
/// A single captured record is capped so one pathological 8MB tool result cannot make a set
/// unreadable line-by-line. The cap is per FIELD (see clip) — the record itself is never truncated
/// mid-JSON, which would poison the whole file for a line-oriented reader.
const FIELD_CAP: usize = 256 * 1024;

const log = std.log.scoped(.dataset);

const St = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io = undefined,
    gpa: std.mem.Allocator = undefined,
    configured: bool = false,
    /// Fast path for the hooks: a relaxed load decides whether to do any work at all.
    armed: std.atomic.Value(bool) = .init(false),
    root: [512]u8 = @splat(0),
    root_len: u16 = 0,
    id: [64]u8 = @splat(0),
    id_len: u8 = 0,
    last_check_s: i64 = 0,
    // live counters for the status row (this process's view; meta.json is recomputed on stop)
    calls: u64 = 0,
    examples: u64 = 0,
    tools: u64 = 0,
};
var st: St = .{};

fn lock() void {
    st.mutex.lockUncancelable(st.io);
}
fn unlock() void {
    st.mutex.unlock(st.io);
}

fn nowS() i64 {
    return @intCast(std.Io.Timestamp.now(st.io, .real).toSeconds());
}

/// Resolve the sets root and adopt any recording already in progress (a server restart mid-capture
/// keeps appending to the same set). `data` is the server data root; NL_SETS_DIR overrides, and is
/// what the supervisor injects into worker processes so a swarm mind records into the same set.
pub fn configure(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, data: []const u8) void {
    st.io = io;
    lock();
    defer unlock();
    st.gpa = gpa;
    st.configured = true;
    var buf: [512]u8 = undefined;
    const root: []const u8 = blk: {
        if (environ.get("NL_SETS_DIR")) |d| {
            const t = std.mem.trim(u8, d, " \r\n\t");
            if (t.len > 0 and t.len <= buf.len) break :blk t;
        }
        // No env override and no data root (a worker process the supervisor did not point at a set):
        // stay UNCONFIGURED rather than deriving "/sets" and writing into the filesystem root.
        if (data.len == 0) {
            st.configured = false;
            return;
        }
        break :blk std.fmt.bufPrint(&buf, "{s}/sets", .{data}) catch return;
    };
    st.root_len = @intCast(@min(root.len, st.root.len));
    @memcpy(st.root[0..st.root_len], root[0..st.root_len]);
    st.last_check_s = 0; // force a marker read on the first check
    refreshLocked();
}

/// The sets root — the supervisor passes this to workers as NL_SETS_DIR. Empty before configure().
pub fn setsDir() []const u8 {
    if (!st.configured) return "";
    lock();
    defer unlock();
    return st.root[0..st.root_len];
}

/// Re-read the marker when the cached view is stale. Caller holds the lock.
fn refreshLocked() void {
    const now = nowS();
    if (now - st.last_check_s < RECHECK_S) return;
    st.last_check_s = now;
    st.id_len = 0;
    var pbuf: [600]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/" ++ MARKER, .{st.root[0..st.root_len]}) catch {
        st.armed.store(false, .release);
        return;
    };
    const f = std.Io.Dir.cwd().openFile(st.io, p, .{}) catch {
        st.armed.store(false, .release);
        return;
    };
    defer f.close(st.io);
    var idbuf: [80]u8 = undefined;
    const n = f.readPositionalAll(st.io, &idbuf, 0) catch 0;
    const id = std.mem.trim(u8, idbuf[0..n], " \r\n\t");
    // a set id is a path segment we build ourselves — refuse anything that could escape the root
    if (id.len == 0 or id.len > st.id.len or std.mem.indexOfAny(u8, id, "/\\.\"") != null) {
        st.armed.store(false, .release);
        return;
    }
    @memcpy(st.id[0..id.len], id);
    st.id_len = @intCast(id.len);
    st.armed.store(true, .release);
}

/// The active set id, or empty. Cheap: an atomic load, then a stat at most every RECHECK_S.
fn activeId(buf: []u8) []const u8 {
    if (!st.configured) return "";
    lock();
    defer unlock();
    refreshLocked();
    if (st.id_len == 0 or st.id_len > buf.len) return "";
    @memcpy(buf[0..st.id_len], st.id[0..st.id_len]);
    return buf[0..st.id_len];
}

pub const Status = struct {
    configured: bool,
    recording: bool,
    id: []const u8, // fixed storage; valid until the next start/stop
    root: []const u8,
    calls: u64,
    examples: u64,
    tools: u64,
};

pub fn status() Status {
    if (!st.configured) return .{ .configured = false, .recording = false, .id = "", .root = "", .calls = 0, .examples = 0, .tools = 0 };
    lock();
    defer unlock();
    refreshLocked();
    return .{
        .configured = true,
        .recording = st.id_len > 0,
        .id = st.id[0..st.id_len],
        .root = st.root[0..st.root_len],
        .calls = st.calls,
        .examples = st.examples,
        .tools = st.tools,
    };
}

// ---- start / stop -------------------------------------------------------------------------------

/// Mint a set id from the wall clock: sortable, human-readable, and a safe path segment by
/// construction (digits and one dash only). Collisions inside one second are broken by the counter.
var mint_seq: std.atomic.Value(u32) = .init(0);

fn mintId(buf: []u8) []const u8 {
    const secs = nowS();
    const d = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yd = d.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = d.getDaySeconds();
    const seq = mint_seq.fetchAdd(1, .monotonic) % 1000;
    return std.fmt.bufPrint(buf, "set-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d:0>3}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        seq,
    }) catch "set-unnamed";
}

/// Begin recording. Creates the set directory, writes meta.json + README.md, then raises the marker
/// (last, so no process can see a set id whose directory is not there yet). Returns the set id.
pub fn start(label: []const u8) ![]const u8 {
    if (!st.configured) return error.NotConfigured;
    lock();
    defer unlock();
    refreshLocked();
    if (st.id_len > 0) return error.AlreadyRecording;

    var idbuf: [64]u8 = undefined;
    const id = mintId(&idbuf);
    const root = st.root[0..st.root_len];
    _ = std.Io.Dir.cwd().createDirPathStatus(st.io, root, .default_dir) catch {};
    var dbuf: [640]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ root, id }) catch return error.PathTooLong;
    _ = std.Io.Dir.cwd().createDirPathStatus(st.io, dir, .default_dir) catch return error.CreateFailed;
    var mbuf: [700]u8 = undefined;
    const mdir = std.fmt.bufPrint(&mbuf, "{s}/by-model", .{dir}) catch return error.PathTooLong;
    _ = std.Io.Dir.cwd().createDirPathStatus(st.io, mdir, .default_dir) catch {};

    writeMeta(dir, id, label, nowS(), 0, false);
    writeReadme(dir, id, label);

    st.calls = 0;
    st.examples = 0;
    st.tools = 0;

    // the marker LAST: its presence is what turns every process on
    var pbuf: [700]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/" ++ MARKER, .{root}) catch return error.PathTooLong;
    std.Io.Dir.cwd().writeFile(st.io, .{ .sub_path = p, .data = id }) catch return error.CreateFailed;

    @memcpy(st.id[0..id.len], id);
    st.id_len = @intCast(id.len);
    st.armed.store(true, .release);
    st.last_check_s = nowS();
    log.info("recording dataset {s} -> {s}", .{ id, dir });
    return st.id[0..st.id_len];
}

/// Stop recording and finalize the set: drop the marker first (so no further call is captured mid
/// finalize), then rewrite meta.json with the observed counts.
pub fn stop() !void {
    if (!st.configured) return error.NotConfigured;
    lock();
    defer unlock();
    refreshLocked();
    if (st.id_len == 0) return error.NotRecording;
    const root = st.root[0..st.root_len];
    var pbuf: [700]u8 = undefined;
    if (std.fmt.bufPrint(&pbuf, "{s}/" ++ MARKER, .{root})) |p| {
        std.Io.Dir.cwd().deleteFile(st.io, p) catch {};
    } else |_| {}
    st.armed.store(false, .release);

    var dbuf: [640]u8 = undefined;
    if (std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ root, st.id[0..st.id_len] })) |dir| {
        const started = readMetaStarted(dir);
        writeMeta(dir, st.id[0..st.id_len], readMetaLabel(dir), started, nowS(), true);
        log.info("dataset {s} finalized ({d} examples, {d} calls, {d} tool runs)", .{ st.id[0..st.id_len], st.examples, st.calls, st.tools });
    } else |_| {}
    st.id_len = 0;
    st.last_check_s = nowS();
}

fn writeMeta(dir: []const u8, id: []const u8, label: []const u8, started_s: i64, ended_s: i64, closed: bool) void {
    const gpa = st.gpa;
    var j: std.ArrayListUnmanaged(u8) = .empty;
    defer j.deinit(gpa);
    j.appendSlice(gpa, "{\"v\":1,\"id\":") catch return;
    jstr(&j, id) catch return;
    j.appendSlice(gpa, ",\"label\":") catch return;
    jstr(&j, label) catch return;
    j.print(gpa, ",\"started_s\":{d},\"ended_s\":{d},\"closed\":{s}", .{ started_s, ended_s, if (closed) "true" else "false" }) catch return;
    j.print(gpa, ",\"calls\":{d},\"examples\":{d},\"tool_runs\":{d}", .{ st.calls, st.examples, st.tools }) catch return;
    j.appendSlice(gpa, ",\"format\":\"openai-messages-sft\",\"files\":{\"training\":\"sft.jsonl\",\"raw\":\"raw.jsonl\",\"tools\":\"tools.jsonl\",\"by_model\":\"by-model/\"},\"parts\":\"every file rolls at 16 MiB into <name>.<UTC stamp>.jsonl; concatenate <name>.*.jsonl in name order, then <name>.jsonl\"}\n") catch return;
    var pbuf: [700]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/meta.json", .{dir}) catch return;
    std.Io.Dir.cwd().writeFile(st.io, .{ .sub_path = p, .data = j.items }) catch {};
}

/// One field out of the set's own meta.json (start time / label survive a restart).
fn readMetaStarted(dir: []const u8) i64 {
    var pbuf: [700]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/meta.json", .{dir}) catch return 0;
    var buf: [2048]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(st.io, p, .{}) catch return 0;
    defer f.close(st.io);
    const n = f.readPositionalAll(st.io, &buf, 0) catch return 0;
    const P = struct { started_s: i64 = 0 };
    const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, buf[0..n], .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    return parsed.value.started_s;
}

var label_scratch: [128]u8 = @splat(0);
fn readMetaLabel(dir: []const u8) []const u8 {
    var pbuf: [700]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/meta.json", .{dir}) catch return "";
    var buf: [2048]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(st.io, p, .{}) catch return "";
    defer f.close(st.io);
    const n = f.readPositionalAll(st.io, &buf, 0) catch return "";
    const P = struct { label: []const u8 = "" };
    const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, buf[0..n], .{ .ignore_unknown_fields = true }) catch return "";
    defer parsed.deinit();
    const l = parsed.value.label;
    const k = @min(l.len, label_scratch.len);
    @memcpy(label_scratch[0..k], l[0..k]);
    return label_scratch[0..k];
}

fn writeReadme(dir: []const u8, id: []const u8, label: []const u8) void {
    const gpa = st.gpa;
    const body = std.fmt.allocPrint(gpa,
        \\# veil dataset `{s}`
        \\
        \\{s}
        \\
        \\Captured at the LLM boundary: each record is the exact request the engine sent and the exact
        \\response it got back — system doctrine, full conversation, tool results, the tools array, the
        \\assistant's visible content, its hidden reasoning, and its structured tool calls.
        \\
        \\## Files
        \\
        \\| file | what it is |
        \\|---|---|
        \\| `sft.jsonl` | **train on this.** One example per line in OpenAI messages format: `{{"messages":[…],"tools":[…]}}`. The final message is the assistant turn being learned, carrying `content`, `reasoning_content` when the model reasoned, and `tool_calls` when it called tools. Read directly by TRL, axolotl, unsloth and llama-factory. |
        \\| `by-model/<model>.jsonl` | the same records, sharded by the model that produced them — train on one model's behaviour, or compare them. |
        \\| `raw.jsonl` | full fidelity: verbatim request body, parsed response, timing, token counts, provider host, role label. Re-derive any other format from here. |
        \\| `tools.jsonl` | every tool execution: name, verbatim arguments, the result text the model saw, ok, and duration. |
        \\| `meta.json` | label, window, counts. |
        \\
        \\Every `.jsonl` file rolls at 16 MiB: the full file is renamed to `<name>.<UTC stamp>.jsonl` and a fresh
        \\`<name>.jsonl` continues (Windows Defender rescans a modified file in full, so a file that keeps growing
        \\makes every write cost a rescan of all of it). For one stream, concatenate `<name>.*.jsonl` in name order,
        \\then `<name>.jsonl` — for example `cat sft.*.jsonl sft.jsonl > all-sft.jsonl`. Records never span parts.
        \\
        \\## Fields on an sft record
        \\
        \\- `messages` — the full prompt trajectory, including prior `role:"tool"` results.
        \\- `tools` — the tool schemas that were on the belt for this call (train tool selection, not just prose).
        \\- `model`, `provider`, `base_url` — who produced the completion and where it came from.
        \\- `source` — `chat`, `swarm`, or `task`: which surface generated it.
        \\- `role_label` — the engine's own name for the call (`chat`, `plan`, `loop`, `compact`, …), so a
        \\  trainer can keep the agentic step and the summarizer apart.
        \\- `finish_reason` — `tool_calls`, `stop`, or `length`. Read this before training; see below.
        \\
        \\## Filtering
        \\
        \\Records are appended as they happen, so a failed or refused call is here too — that is deliberate
        \\(a set with no failures teaches a model that failure never happens). `ok:false` marks them; drop
        \\them with `jq 'select(.ok)'` if your run wants only clean turns.
        \\
        \\**Drop `finish_reason:"length"` before you train.** Those completions were cut off mid-generation
        \\when the token budget ran out — the text ends mid-word and there is no answer and no tool call,
        \\only a truncated reasoning trace. They look like empty replies and they teach exactly that. On the
        \\first real capture they were 13% of the set. `jq 'select(.finish_reason != "length")'`.
        \\
        \\**A `stop` record with an empty completion is usually CORRECT, not broken.** The memory-extraction
        \\role emits nothing when a turn holds no durable fact ("Nothing qualifies. Output empty."). That is
        \\right for that role and poison for general chat, so split on `role_label` rather than deleting it.
        \\
        \\**Decontaminate against your eval before training.** These are real turns, so anything you also
        \\use as a held-out drill will be in here. Match on the normalised user turn, not just byte equality.
        \\
    , .{ id, if (label.len > 0) label else "(no label)" }) catch return;
    defer gpa.free(body);
    var pbuf: [700]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/README.md", .{dir}) catch return;
    std.Io.Dir.cwd().writeFile(st.io, .{ .sub_path = p, .data = body }) catch {};
}

// ---- the capture hooks --------------------------------------------------------------------------

/// Which surface produced a record. The engine knows; the dataset should not have to guess.
pub const Source = enum { chat, swarm, task, other };

/// The surface THIS PROCESS serves: the server sets `.chat` at boot, a spawned swarm worker sets
/// `.swarm`. Process-wide because it is a property of the binary's role, not of any one call — and
/// it is the field that answers "where did this response come from" at training time.
var proc_source: Source = .other;

pub fn setSource(s: Source) void {
    proc_source = s;
}

/// The fast gate every hook checks first: an atomic load, no lock, no syscall. False means the
/// capture path costs a single relaxed read per LLM call and per tool run.
pub fn armed() bool {
    return st.armed.load(.acquire);
}

/// One completed LLM call, as the engine saw it.
pub const Call = struct {
    source: Source = .other,
    /// The engine's own label for this call: chat / plan / loop / compact / lesson / …
    role_label: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    /// The VERBATIM request body the transport sent (JSON). messages/tools are lifted out of it, so
    /// what the trainer sees is byte-identical to what the model saw.
    request_body: []const u8 = "",
    /// The assistant's visible text.
    content: []const u8 = "",
    /// The hidden reasoning channel, when the model produced one.
    reasoning: []const u8 = "",
    /// The assistant's tool calls as a JSON ARRAY BODY (no brackets), already in OpenAI shape:
    /// `{"id":…,"type":"function","function":{"name":…,"arguments":"…"}}, …`
    tool_calls: []const u8 = "",
    finish_reason: []const u8 = "",
    ok: bool = true,
    ms: u64 = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    /// A pre-rendered prompt instead of a messages array (the raw wire-format path). Such a call has
    /// no OpenAI-shaped example, so it lands in raw.jsonl only.
    raw_prompt: bool = false,
};

/// Record one LLM call. No-op unless recording. Never throws — a capture failure must not disturb
/// the turn that produced it.
pub fn recordCall(c_in: Call) void {
    if (!st.armed.load(.acquire)) return;
    var idbuf: [64]u8 = undefined;
    const id = activeId(&idbuf);
    if (id.len == 0) return;
    const gpa = st.gpa;
    var c = c_in;
    // The transport does not know which SURFACE it is serving — the process does. An explicit
    // source on the call still wins; `.other` means "ask the process", which is how a chat record
    // gets tagged `chat` and a swarm mind's gets `swarm`.
    if (c.source == .other) c.source = proc_source;

    var dbuf: [700]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ setsDirRaw(), id }) catch return;

    // ---- raw.jsonl: everything, request body spliced verbatim ----
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(gpa);
    raw.print(gpa, "{{\"v\":1,\"kind\":\"call\",\"ts\":{d},\"source\":\"{s}\"", .{ nowS(), @tagName(c.source) }) catch return;
    kv(&raw, "role_label", c.role_label) catch return;
    kv(&raw, "model", c.model) catch return;
    kv(&raw, "base_url", c.base_url) catch return;
    kv(&raw, "provider", hostOf(c.base_url)) catch return;
    raw.print(gpa, ",\"ok\":{s},\"ms\":{d},\"tokens_in\":{d},\"tokens_out\":{d}", .{ if (c.ok) "true" else "false", c.ms, c.tokens_in, c.tokens_out }) catch return;
    kv(&raw, "finish_reason", c.finish_reason) catch return;
    raw.appendSlice(gpa, ",\"request\":") catch return;
    if (c.request_body.len > 0 and c.request_body.len <= FIELD_CAP) {
        appendOneLine(&raw, c.request_body) catch return; // already JSON — splice, never re-escape
    } else {
        // oversized (or absent): keep the record valid and say so rather than embedding a truncated object
        raw.print(gpa, "{{\"omitted\":\"body {d} bytes\"}}", .{c.request_body.len}) catch return;
    }
    raw.appendSlice(gpa, ",\"response\":{\"content\":") catch return;
    jstr(&raw, clip(c.content)) catch return;
    if (c.reasoning.len > 0) {
        raw.appendSlice(gpa, ",\"reasoning\":") catch return;
        jstr(&raw, clip(c.reasoning)) catch return;
    }
    if (c.tool_calls.len > 0) {
        raw.appendSlice(gpa, ",\"tool_calls\":[") catch return;
        raw.appendSlice(gpa, c.tool_calls) catch return;
        raw.append(gpa, ']') catch return;
    }
    raw.appendSlice(gpa, "}}\n") catch return;
    appendTo(dir, "raw.jsonl", raw.items);

    // ---- sft.jsonl: the trainer-ready projection ----
    // Only a messages-shaped request yields an OpenAI example; a pre-rendered prompt has no message
    // structure to teach, so it stays in raw.jsonl rather than being faked into one.
    var made_example = false;
    if (!c.raw_prompt) {
        if (jsonArrayInner(c.request_body, "messages")) |msgs| {
            var sft: std.ArrayListUnmanaged(u8) = .empty;
            defer sft.deinit(gpa);
            sft.appendSlice(gpa, "{\"messages\":[") catch return;
            appendOneLine(&sft, msgs) catch return;
            // the completion being learned
            sft.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch return;
            jstr(&sft, clip(c.content)) catch return;
            if (c.reasoning.len > 0) {
                sft.appendSlice(gpa, ",\"reasoning_content\":") catch return;
                jstr(&sft, clip(c.reasoning)) catch return;
            }
            if (c.tool_calls.len > 0) {
                sft.appendSlice(gpa, ",\"tool_calls\":[") catch return;
                sft.appendSlice(gpa, c.tool_calls) catch return;
                sft.append(gpa, ']') catch return;
            }
            sft.appendSlice(gpa, "}]") catch return;
            if (jsonArrayInner(c.request_body, "tools")) |tls| {
                if (tls.len > 0) {
                    sft.appendSlice(gpa, ",\"tools\":[") catch return;
                    appendOneLine(&sft, tls) catch return;
                    sft.append(gpa, ']') catch return;
                }
            }
            kv(&sft, "model", c.model) catch return;
            kv(&sft, "provider", hostOf(c.base_url)) catch return;
            kv(&sft, "base_url", c.base_url) catch return;
            kv(&sft, "source", @tagName(c.source)) catch return;
            kv(&sft, "role_label", c.role_label) catch return;
            // finish_reason belongs in the TRAINING file, not only in raw.jsonl. A record that stopped
            // on `length` is a truncated generation: the model was still mid-thought when the token
            // budget ran out, so its completion ends mid-word and there is no answer or tool call at
            // all. Measured on set-20260801-173947-000: 36 of 287 records (13%) — reasoning tails like
            // "...Today is 202" and "...The goal is \"Deep-research DISTRIB". Training on those teaches
            // a model to stop mid-thought, which is exactly the empty-reply defect that cost gary-v1
            // seven drills. Without this field a trainer reading sft.jsonl cannot tell them from a
            // complete record without cross-referencing raw.jsonl by timestamp, so the honest thing is
            // to carry the flag where the filtering happens.
            kv(&sft, "finish_reason", c.finish_reason) catch return;
            sft.print(gpa, ",\"ok\":{s},\"ts\":{d}}}\n", .{ if (c.ok) "true" else "false", nowS() }) catch return;
            appendTo(dir, "sft.jsonl", sft.items);
            // and the per-model shard: "train on only what THIS model produced"
            var shard: [160]u8 = undefined;
            if (std.fmt.bufPrint(&shard, "by-model/{s}.jsonl", .{slug(c.model)})) |rel| {
                appendTo(dir, rel, sft.items);
            } else |_| {}
            made_example = true;
        }
    }

    lock();
    defer unlock();
    st.calls += 1;
    if (made_example) st.examples += 1;
}

/// One tool execution, as the dispatcher saw it: what the model asked for, and what came back.
pub const ToolRun = struct {
    source: Source = .other,
    mind: []const u8 = "",
    round: u32 = 0,
    name: []const u8 = "",
    /// Verbatim arguments JSON as the model emitted it.
    args_json: []const u8 = "",
    /// The result text handed back to the model.
    result: []const u8 = "",
    ok: bool = true,
    ms: u64 = 0,
};

pub fn recordTool(t_in: ToolRun) void {
    if (!st.armed.load(.acquire)) return;
    var idbuf: [64]u8 = undefined;
    const id = activeId(&idbuf);
    if (id.len == 0) return;
    const gpa = st.gpa;
    var t = t_in;
    if (t.source == .other) t.source = proc_source;
    var dbuf: [700]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ setsDirRaw(), id }) catch return;

    var j: std.ArrayListUnmanaged(u8) = .empty;
    defer j.deinit(gpa);
    j.print(gpa, "{{\"v\":1,\"kind\":\"tool\",\"ts\":{d},\"source\":\"{s}\"", .{ nowS(), @tagName(t.source) }) catch return;
    kv(&j, "tool", t.name) catch return;
    if (t.mind.len > 0) kv(&j, "mind", t.mind) catch return;
    j.print(gpa, ",\"round\":{d},\"ok\":{s},\"ms\":{d},\"args\":", .{ t.round, if (t.ok) "true" else "false", t.ms }) catch return;
    // args are JSON when the model emitted an object; anything else rides as a string so the record
    // stays parseable either way
    const a = std.mem.trim(u8, t.args_json, " \r\n\t");
    if (a.len > 0 and a.len <= FIELD_CAP and (a[0] == '{' or a[0] == '[')) {
        appendOneLine(&j, a) catch return; // a model may emit pretty-printed args — still one line
    } else {
        jstr(&j, clip(a)) catch return;
    }
    j.appendSlice(gpa, ",\"result\":") catch return;
    jstr(&j, clip(t.result)) catch return;
    j.appendSlice(gpa, "}\n") catch return;
    appendTo(dir, "tools.jsonl", j.items);

    lock();
    defer unlock();
    st.tools += 1;
}

/// Every captured set as a JSON ARRAY BODY (no brackets), newest first — each element is that set's
/// own meta.json, spliced verbatim. The meta file IS the record, so a listing cannot drift from what
/// the set says about itself. Best-effort: an unreadable set is skipped, never a failed listing.
pub fn listInto(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) void {
    if (!st.configured) return;
    const root = setsDirRaw();
    if (root.len == 0) return;
    var d = std.Io.Dir.cwd().openDir(st.io, root, .{ .iterate = true }) catch return;
    defer d.close(st.io);
    // ids are minted sortable (set-YYYYMMDD-HHMMSS-NNN), so collecting then reversing gives newest first
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(st.io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (!std.mem.startsWith(u8, e.name, "set-")) continue;
        names.append(arena, arena.dupe(u8, e.name) catch continue) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, b, a); // descending
        }
    }.lt);
    var n: usize = 0;
    for (names.items) |name| {
        var pbuf: [700]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}/meta.json", .{ root, name }) catch continue;
        const body = std.Io.Dir.cwd().readFileAlloc(st.io, p, arena, .limited(64 << 10)) catch continue;
        const t = std.mem.trim(u8, body, " \r\n\t");
        if (t.len == 0 or t[0] != '{') continue;
        if (n > 0) out.append(arena, ',') catch return;
        out.appendSlice(arena, t) catch return;
        n += 1;
    }
}

// ---- helpers ------------------------------------------------------------------------------------

/// The root WITHOUT taking the lock — callers here already hold it or are on the fast path. Safe:
/// the root is written once at configure and never mutated after.
fn setsDirRaw() []const u8 {
    return st.root[0..st.root_len];
}

/// Opening of the system block holding the user's durable credential store. Everything from here to
/// the end of that JSON string is dropped: the block's own header calls its contents "keys, logins,
/// preferences", so there is nothing in it worth training on and a great deal worth leaking.
const MEM_MARKER = "YOUR MEMORY (durable facts";

/// Credential prefixes masked wherever they appear. Deliberately few — a prefix that also occurs in
/// ordinary prose would blank real training signal, so only unambiguous ones are listed.
const TOKEN_PREFIXES = [_][]const u8{ "hf_", "sk-", "ghp_", "gho_", "github_pat_", "vcp_", "xoxb-", "xoxp-", "AKIA", "AIza" };

fn isTokenChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

/// End of the JSON string containing `from`: the next UNESCAPED quote.
fn jsonStrEnd(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i;
    }
    return s.len;
}

/// Scrub credentials out of a record before it is ever written.
///
/// Why this is here rather than left to whoever trains on the set. A captured set is the one artefact
/// of this server MEANT to travel — uploaded to a training run, shared, published beside a model. The
/// capture point is the LLM boundary, and the request body there carries the whole system prompt,
/// which includes the user's durable memory store. Measured on the first real set
/// (set-20260801-171249-000, 90 records): a live third-party API key, a login, and the operator's
/// email address 46 times, present in sft.jsonl AND raw.jsonl AND by-model/. A training set is the
/// worst possible place to discover that late, because by then it has been copied somewhere else.
///
/// Conservative on purpose: it masks what is unambiguously a credential and leaves the rest alone.
/// Bare 32-hex is NOT masked — tool-call ids and content hashes look identical, and blanking those
/// would corrupt the very structure the set exists to teach. Returns null when nothing matched, so
/// the ordinary path allocates nothing.
fn redact(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var changed = false;
    var i: usize = 0;
    while (i < data.len) {
        // 1. durable-memory block: drop from the marker to the end of its JSON string
        if (std.mem.startsWith(u8, data[i..], MEM_MARKER)) {
            out.appendSlice(gpa, "[memory block redacted at capture]") catch {
                out.deinit(gpa);
                return null;
            };
            i = jsonStrEnd(data, i);
            changed = true;
            continue;
        }
        // 2. prefixed credentials (hf_…, ghp_…, AKIA…)
        var hit = false;
        for (TOKEN_PREFIXES) |pfx| {
            if (!std.mem.startsWith(u8, data[i..], pfx)) continue;
            var j = i + pfx.len;
            while (j < data.len and isTokenChar(data[j])) j += 1;
            if (j - i < pfx.len + 12) break; // too short to be a real key — leave the prose alone
            out.appendSlice(gpa, "[redacted-token]") catch {
                out.deinit(gpa);
                return null;
            };
            i = j;
            changed = true;
            hit = true;
            break;
        }
        if (hit) continue;
        // 3. email addresses
        if (data[i] == '@') {
            var s = i;
            while (s > 0 and (isTokenChar(data[s - 1]) or data[s - 1] == '.' or data[s - 1] == '%' or data[s - 1] == '+')) s -= 1;
            // NEVER WALK INTO A JSON ESCAPE. This operates on already-encoded JSON, where a newline is
            // the two bytes `\` `n`. `n` is a token char, so the left-walk happily ate it and left a
            // bare `\` in front of the placeholder — an invalid escape that made the whole record
            // unparseable. It happened for real: a captured Python snippet containing
            //     ...```python\n@app.route(\"/...\")
            // became ...```python\[redacted-email](\"... and broke line 586 of a 880-line set, in
            // sft.jsonl, raw.jsonl and tools.jsonl alike. One corrupt line is worse than the leak it
            // was fixing, because a line-oriented reader loses the record entirely.
            if (s > 0 and data[s - 1] == '\\') s += 1;
            var e = i + 1;
            var dot = false;
            while (e < data.len and (isTokenChar(data[e]) or data[e] == '.')) : (e += 1) {
                if (data[e] == '.') dot = true;
            }
            // A decorator or attribute access is not an email: `@app.route(` has a dotted "domain" and
            // reads exactly like one. Requiring that it is not immediately called keeps Python and JS
            // source — which this set is FULL of, it being a coding assistant's traffic — intact.
            const called = e < data.len and data[e] == '(';
            // needs a local part, a dotted domain and a plausible length — otherwise it is prose
            if (s < i and dot and !called and e > i + 3 and e - i <= 64 and (i - s) <= out.items.len) {
                out.shrinkRetainingCapacity(out.items.len - (i - s));
                out.appendSlice(gpa, "[redacted-email]") catch {
                    out.deinit(gpa);
                    return null;
                };
                i = e;
                changed = true;
                continue;
            }
        }
        out.append(gpa, data[i]) catch {
            out.deinit(gpa);
            return null;
        };
        i += 1;
    }
    if (!changed) {
        out.deinit(gpa);
        return null;
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

/// The size a file that is still being written may reach before its next append rolls it (see ROLLING PARTS at the
/// top of this file). 16 MiB: a Defender rescan of that is milliseconds, and a long-running set still makes only a
/// few hundred parts. A var only so the tests can roll on a few hundred bytes.
pub const PART_MAX: u64 = 16 << 20;
var part_max: u64 = PART_MAX;

/// Serializes appendTo across this process's threads: a roll (stat, rename, fresh file) must not interleave with
/// another thread's stat-then-write, and two appends must not land at the same offset. An io-free spin-and-yield
/// lock rather than std.Io.Mutex, because the callers are plain threads (chat turns, httpz workers, swarm minds)
/// and a contended runtime mutex parks on the thread's alert — the primitive behind the 2026-09-02 desk freeze
/// (desk/src/nap.zig). A waiter yields its timeslice instead; a hold is one small append to a small file.
var append_held = std.atomic.Value(bool).init(false);

fn appendLock() void {
    while (append_held.swap(true, .acquire)) std.Thread.yield() catch {};
}

fn appendUnlock() void {
    append_held.store(false, .release);
}

fn appendTo(dir: []const u8, rel: []const u8, data_in: []const u8) void {
    // EVERY output file is written through here — that is why the scrub lives here rather than at the
    // four call sites, so a fifth output cannot be added and silently skip it.
    const scrubbed = redact(st.gpa, data_in);
    defer if (scrubbed) |s| st.gpa.free(s);
    const data = scrubbed orelse data_in;
    var pbuf: [900]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, rel }) catch return;
    appendLock();
    defer appendUnlock();
    const d = std.Io.Dir.cwd();
    const size: u64 = if (d.statFile(st.io, p, .{})) |s| s.size else |e| switch (e) {
        error.FileNotFound => 0,
        else => return, // never collapse an unknown stat error to offset 0 — that clobbers the log
    };
    // ROLL before an append that would carry a non-empty file past part_max. A failed rename (another process holds
    // the file without delete sharing) keeps appending to the big file: slower for Defender, never lost data.
    if (size > 0 and size + data.len > part_max) _ = rollPart(p);
    const f = d.createFile(st.io, p, .{ .truncate = false }) catch return;
    defer f.close(st.io);
    // The offset is read AFTER opening, from the path (a fresh handle reports length 0 on this Io — see
    // http.appendFile): between the stat above and this open, another PROCESS appending to the same set may have
    // grown the file (writing at the old offset would clobber its record) or rolled it (writing at the old offset
    // into the fresh part would leave a gap of zeros). The lock above covers this process's threads only.
    const end: u64 = if (d.statFile(st.io, p, .{})) |s| s.size else |e| switch (e) {
        error.FileNotFound => 0,
        else => return,
    };
    f.writePositionalAll(st.io, data, end) catch {};
}

/// Rolls this process has made, so two in the same millisecond still get distinct, ordered names.
var roll_seq: std.atomic.Value(u32) = .init(0);

/// Rename the live file `p` (…/raw.jsonl) to its archived part …/raw.<YYYYMMDD-HHMMSS.mmm>-<seq>-t<thread>.jsonl,
/// stamped in UTC. The stamp (then the zero-padded sequence) sorts parts oldest-first and before the live file; the
/// thread id keeps two processes that roll in the same millisecond apart. A name that already exists is never
/// renamed onto (a rename may replace its target): the roll is skipped and the next append tries again. True when
/// the live path is free for a fresh part.
fn rollPart(p: []const u8) bool {
    const stem = if (std.mem.endsWith(u8, p, ".jsonl")) p[0 .. p.len - ".jsonl".len] else p;
    const ms = std.Io.Timestamp.now(st.io, .real).toMilliseconds();
    if (ms <= 0) return false;
    const secs: u64 = @intCast(@divTrunc(ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var nb: [960]u8 = undefined;
    const archive = std.fmt.bufPrint(&nb, "{s}.{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.{d:0>3}-{d:0>6}-t{d}.jsonl", .{
        stem,                             yd.year,                   md.month.numeric(),        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),             ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(), @as(u64, @intCast(@mod(ms, 1000))),
        roll_seq.fetchAdd(1, .monotonic), std.Thread.getCurrentId(),
    }) catch return false;
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(st.io, archive, .{})) |_| return false else |_| {}
    cwd.rename(p, cwd, archive, st.io) catch return false;
    return true;
}

fn clip(s: []const u8) []const u8 {
    if (s.len <= FIELD_CAP) return s;
    // cut on a UTF-8 boundary so the escaper never emits half a codepoint
    var n = FIELD_CAP;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Splice already-valid JSON into a JSONL record, GUARANTEEING one physical line.
///
/// The engine's request bodies are pretty-printed in places — `TURN_TOOLS` joins its ~20 tool
/// schemas with real newlines, so a verbatim splice put ONE record across 20 lines and every
/// line-oriented reader (jq, HuggingFace `load_dataset("json")`, a plain `for line in f`) choked on
/// it. Found by reading back a real captured turn, not by a unit test — the fixtures were all
/// single-line. Control bytes get one of two treatments, because JSON gives them two meanings:
///
///   * BETWEEN tokens a control byte is layout, never value, and `\u00XX` is not even legal there —
///     so every byte under 0x20 folds to the one whitespace that cannot split a line, a space.
///   * INSIDE a string it is value, and a raw one is illegal JSON. "already-valid" does not hold on
///     the `recordTool` path: `ToolRun.args_json` is verbatim model output, so a model that emits a
///     literal newline or a stray 0x01 inside an argument string used to be copied through here
///     byte-for-byte — malformed JSON, and for a newline a record split across two lines, which a
///     fine-tuning loader rejects or skips silently. `\u00XX` is the only encoding that keeps the
///     byte AND the line, and it matches every other escaper in the tree (gateway/http.zig `jstr`,
///     cli.zig `jstr`, plug/plugins.zig, and `jstr` below).
fn appendOneLine(list: *std.ArrayListUnmanaged(u8), json: []const u8) !void {
    const gpa = st.gpa;
    var in_str = false;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (in_str) {
            if (ch == '\\' and i + 1 < json.len) {
                try list.append(gpa, ch);
                i += 1;
                try list.append(gpa, json[i]); // an escaped byte can never close the string
            } else if (ch < 0x20) {
                try list.print(gpa, "\\u{x:0>4}", .{ch}); // value preserved, line preserved
            } else {
                try list.append(gpa, ch);
                if (ch == '"') in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => {
                in_str = true;
                try list.append(gpa, ch);
            },
            '\n', '\r', '\t' => try list.append(gpa, ' '),
            else => try list.append(gpa, if (ch < 0x20) ' ' else ch), // any other C0: layout too
        }
    }
}

/// `,"key":"value"` with the value escaped. Skips entirely when the value is empty.
fn kv(list: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try list.appendSlice(st.gpa, ",\"");
    try list.appendSlice(st.gpa, key);
    try list.appendSlice(st.gpa, "\":");
    try jstr(list, value);
}

/// JSON string escaper (the gateway's, kept local so the worker side has no gateway dependency).
fn jstr(list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const gpa = st.gpa;
    try list.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => {
            if (ch < 0x20 or ch == 0x7f) {
                try list.print(gpa, "\\u{x:0>4}", .{ch});
            } else try list.append(gpa, ch);
        },
    };
    try list.append(gpa, '"');
}

/// Host component of a base URL — the "where did this come from" field.
pub fn hostOf(url: []const u8) []const u8 {
    var s = std.mem.trim(u8, url, " \r\n\t");
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfAny(u8, s, "/?#")) |i| s = s[0..i];
    return s;
}

var slug_buf: [96]u8 = @splat(0);
/// A model id as a safe file-name segment: everything outside [A-Za-z0-9._-] becomes '_'. Empty
/// reads as "unknown" so a shard always has a name.
pub fn slug(model: []const u8) []const u8 {
    if (model.len == 0) return "unknown";
    const n = @min(model.len, slug_buf.len);
    for (model[0..n], 0..) |ch, i| {
        slug_buf[i] = switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '-', '_' => ch,
            else => '_',
        };
    }
    return slug_buf[0..n];
}

/// The RAW inner text of a top-level `"key": [ … ]` array — brackets excluded — or null. String-aware
/// bracket matching, so a message whose content contains `]` or `{` cannot end the scan early. The
/// returned slice ALIASES `body`: splicing the caller's exact bytes is the whole point (key order and
/// number spelling stay byte-identical to what the model was sent).
pub fn jsonArrayInner(body: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 2 > kbuf.len) return null;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, needle)) |at| {
        from = at + 1;
        var i = at + needle.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) i += 1;
        if (i >= body.len or body[i] != ':') continue;
        i += 1;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) i += 1;
        if (i >= body.len or body[i] != '[') continue;
        var depth: usize = 0;
        var in_str = false;
        var j = i;
        while (j < body.len) : (j += 1) {
            const ch = body[j];
            if (in_str) {
                if (ch == '\\') j += 1 else if (ch == '"') in_str = false;
                continue;
            }
            switch (ch) {
                '"' => in_str = true,
                '[', '{' => depth += 1,
                ']', '}' => {
                    depth -= 1;
                    if (depth == 0) return body[i + 1 .. j];
                },
                else => {},
            }
        }
        return null; // unterminated
    }
    return null;
}

// ---- tests --------------------------------------------------------------------------------------

test "jsonArrayInner lifts the caller's exact bytes: nesting, brackets inside strings, absent keys" {
    const body = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"a ] tricky [ one\"},{\"x\":[1,2]}],\"tools\":[]}";
    try std.testing.expectEqualStrings("{\"role\":\"user\",\"content\":\"a ] tricky [ one\"},{\"x\":[1,2]}", jsonArrayInner(body, "messages").?);
    try std.testing.expectEqualStrings("", jsonArrayInner(body, "tools").?);
    try std.testing.expect(jsonArrayInner(body, "nope") == null);
    // a key whose value is not an array must not match, and escaped quotes must not derail the scan
    try std.testing.expect(jsonArrayInner("{\"messages\":\"not-an-array\"}", "messages") == null);
    const esc = "{\"messages\":[{\"content\":\"say \\\"hi]\\\" now\"}]}";
    try std.testing.expectEqualStrings("{\"content\":\"say \\\"hi]\\\" now\"}", jsonArrayInner(esc, "messages").?);
}

test "slug and hostOf: file-safe model names, provider identity from the base url" {
    try std.testing.expectEqualStrings("the-veil-12b", slug("the-veil-12b"));
    try std.testing.expectEqualStrings("qwen2.5-coder_7b", slug("qwen2.5-coder:7b"));
    try std.testing.expectEqualStrings("xentriom_gemma-4-12B", slug("xentriom/gemma-4-12B"));
    try std.testing.expectEqualStrings("unknown", slug(""));
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com/v1"));
    try std.testing.expectEqualStrings("127.0.0.1:8788", hostOf("http://127.0.0.1:8788/builtin/v1"));
    try std.testing.expectEqualStrings("", hostOf(""));
}

test "a set records a full turn: sft example carries messages, tools, reasoning and tool_calls" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-dataset-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("NL_SETS_DIR", root ++ "/sets");
    configure(gpa, io, &env, root);
    defer {
        stop() catch {};
        st.configured = false;
        st.armed.store(false, .release);
    }

    // nothing is captured before start()
    recordCall(.{ .model = "m", .content = "ignored", .request_body = "{\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" });
    try std.testing.expect(!status().recording);

    const id = try start("unit test");
    try std.testing.expect(std.mem.startsWith(u8, id, "set-"));
    try std.testing.expect(status().recording);

    recordCall(.{
        .source = .chat,
        .role_label = "chat",
        .model = "the-veil-12b",
        .base_url = "http://127.0.0.1:8788/builtin/v1",
        .request_body =
        \\{"model":"the-veil-12b","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"write a.txt"}],"tools":[{"type":"function","function":{"name":"write_file"}}]}
        ,
        .content = "on it",
        .reasoning = "plan it",
        .tool_calls =
        \\{"id":"tc1","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"a.txt\"}"}}
        ,
        .finish_reason = "tool_calls",
        .ms = 120,
        .tokens_in = 30,
        .tokens_out = 7,
    });
    recordTool(.{ .source = .chat, .name = "write_file", .args_json = "{\"path\":\"a.txt\",\"content\":\"hi\"}", .result = "wrote a.txt", .ok = true, .ms = 3 });

    var pbuf: [256]u8 = undefined;
    const sft_path = try std.fmt.bufPrint(&pbuf, "{s}/sets/{s}/sft.jsonl", .{ root, id });
    const sft = try std.Io.Dir.cwd().readFileAlloc(io, sft_path, gpa, .limited(1 << 20));
    defer gpa.free(sft);

    // it must parse as JSON — a trainer reads this line-by-line and a malformed line poisons the file
    const p = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trim(u8, sft, " \r\n"), .{});
    defer p.deinit();
    const msgs = p.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len); // system + user + the learned assistant turn
    try std.testing.expectEqualStrings("system", msgs[0].object.get("role").?.string);
    const last = msgs[2].object;
    try std.testing.expectEqualStrings("assistant", last.get("role").?.string);
    try std.testing.expectEqualStrings("on it", last.get("content").?.string);
    try std.testing.expectEqualStrings("plan it", last.get("reasoning_content").?.string);
    const tc = last.get("tool_calls").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tc.len);
    try std.testing.expectEqualStrings("write_file", tc[0].object.get("function").?.object.get("name").?.string);
    // the tools array rides along, so tool SELECTION is trainable and not just prose
    try std.testing.expectEqual(@as(usize, 1), p.value.object.get("tools").?.array.items.len);
    // finish_reason must reach the TRAINING file, not raw.jsonl alone. A `length` record is a
    // truncated generation — no answer, no tool call, just a reasoning trace cut off mid-word — and a
    // trainer reading sft.jsonl has to be able to drop it without cross-referencing raw by timestamp.
    // 13% of the first real capture (set-20260801-173947-000) were exactly that.
    try std.testing.expectEqualStrings("tool_calls", p.value.object.get("finish_reason").?.string);
    try std.testing.expectEqualStrings("the-veil-12b", p.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("127.0.0.1:8788", p.value.object.get("provider").?.string);

    // the per-model shard holds the same example
    var sbuf: [256]u8 = undefined;
    const shard_path = try std.fmt.bufPrint(&sbuf, "{s}/sets/{s}/by-model/the-veil-12b.jsonl", .{ root, id });
    const shard = try std.Io.Dir.cwd().readFileAlloc(io, shard_path, gpa, .limited(1 << 20));
    defer gpa.free(shard);
    try std.testing.expectEqualStrings(std.mem.trim(u8, sft, " \r\n"), std.mem.trim(u8, shard, " \r\n"));

    // raw.jsonl keeps the verbatim request + the timing/token facts sft drops
    var rbuf: [256]u8 = undefined;
    const raw_path = try std.fmt.bufPrint(&rbuf, "{s}/sets/{s}/raw.jsonl", .{ root, id });
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, raw_path, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    const rp = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trim(u8, raw, " \r\n"), .{});
    defer rp.deinit();
    try std.testing.expectEqual(@as(i64, 120), rp.value.object.get("ms").?.integer);
    try std.testing.expectEqual(@as(i64, 30), rp.value.object.get("tokens_in").?.integer);
    try std.testing.expectEqualStrings("chat", rp.value.object.get("role_label").?.string);
    try std.testing.expect(rp.value.object.get("request").?.object.get("messages") != null);

    // tools.jsonl carries the execution with its arguments as real JSON, not a string
    var tbuf: [256]u8 = undefined;
    const tool_path = try std.fmt.bufPrint(&tbuf, "{s}/sets/{s}/tools.jsonl", .{ root, id });
    const tools_txt = try std.Io.Dir.cwd().readFileAlloc(io, tool_path, gpa, .limited(1 << 20));
    defer gpa.free(tools_txt);
    const tp = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trim(u8, tools_txt, " \r\n"), .{});
    defer tp.deinit();
    try std.testing.expectEqualStrings("write_file", tp.value.object.get("tool").?.string);
    try std.testing.expectEqualStrings("a.txt", tp.value.object.get("args").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("wrote a.txt", tp.value.object.get("result").?.string);

    const s = status();
    try std.testing.expectEqual(@as(u64, 1), s.calls);
    try std.testing.expectEqual(@as(u64, 1), s.examples);
    try std.testing.expectEqual(@as(u64, 1), s.tools);
}

test "every record is ONE physical line even when the request body is pretty-printed" {
    // THE JSONL CONTRACT, and a real defect this pins: the engine's tools array joins its schemas
    // with real newlines, so a verbatim splice wrote one record across twenty lines and every
    // line-oriented reader broke. Caught by reading back a captured turn — the fixtures were all
    // single-line, so no unit test could have seen it.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-dataset-oneline-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("NL_SETS_DIR", root ++ "/sets");
    configure(gpa, io, &env, root);
    defer {
        stop() catch {};
        st.configured = false;
        st.armed.store(false, .release);
    }
    setSource(.chat);
    defer setSource(.other);
    const id = try start("oneline");

    // a body shaped like the real one: newlines BETWEEN tokens, and a newline INSIDE a string that
    // is already escaped (the system prompt) — the first must fold, the second must survive intact
    recordCall(.{
        .model = "m",
        .request_body =
        \\{"model":"m",
        \\ "messages":[{"role":"system","content":"line one\nline two"},
        \\   {"role":"user","content":"hi"}],
        \\ "tools":[{"type":"function","function":{"name":"a"}},
        \\   {"type":"function","function":{"name":"b"}}]}
        ,
        .content = "ok",
    });

    var pbuf: [256]u8 = undefined;
    const sft_path = try std.fmt.bufPrint(&pbuf, "{s}/sets/{s}/sft.jsonl", .{ root, id });
    const sft = try std.Io.Dir.cwd().readFileAlloc(io, sft_path, gpa, .limited(1 << 20));
    defer gpa.free(sft);
    // exactly one line: one trailing newline, none inside
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sft, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, sft, "\n"));
    const p = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trim(u8, sft, " \r\n"), .{});
    defer p.deinit();
    const msgs = p.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    // the ESCAPED newline inside the system prompt is content, not layout — it must survive
    try std.testing.expectEqualStrings("line one\nline two", msgs[0].object.get("content").?.string);
    try std.testing.expectEqual(@as(usize, 2), p.value.object.get("tools").?.array.items.len);
    // and the process source tagged the record without the caller passing one
    try std.testing.expectEqualStrings("chat", p.value.object.get("source").?.string);

    // raw.jsonl holds the same guarantee
    var rbuf: [256]u8 = undefined;
    const raw_path = try std.fmt.bufPrint(&rbuf, "{s}/sets/{s}/raw.jsonl", .{ root, id });
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, raw_path, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "\n"));
    const rp = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trim(u8, raw, " \r\n"), .{});
    defer rp.deinit();
    try std.testing.expect(rp.value.object.get("request").?.object.get("messages") != null);
}

test "a tool arg carrying literal control bytes still writes one valid JSON line" {
    // `ToolRun.args_json` is VERBATIM model output, not the engine's own JSON, so appendOneLine's
    // "already-valid" precondition does not hold on this path. A model that emits a literal newline,
    // tab or 0x01 inside an argument string used to have those bytes spliced straight through: bytes
    // under 0x20 are illegal inside a JSON string, and a raw newline additionally splits the record
    // in two. Either way the fine-tuning loader rejects the line or skips it silently.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-dataset-ctlbytes-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("NL_SETS_DIR", root ++ "/sets");
    configure(gpa, io, &env, root);
    defer {
        stop() catch {};
        st.configured = false;
        st.armed.store(false, .release);
    }
    const id = try start("ctlbytes");

    // literal 0x0a / 0x09 / 0x01 INSIDE the argument string (not the two-char JSON escapes), and a
    // newline BETWEEN tokens, which is layout and must still fold to a space
    recordTool(.{
        .name = "shell",
        .args_json = "{\"cmd\":\"echo a\nb\tc\x01d\",\n \"n\":1}",
        .result = "out\nerr\x01done", // the same bytes down the jstr path
    });

    var pbuf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/sets/{s}/tools.jsonl", .{ root, id });
    const rec = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(rec);
    const line = std.mem.trim(u8, rec, " \r\n");

    // ONE physical line: the raw newline inside the argument did not split the record
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rec, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, rec, "\n"));
    // and not one bare control byte reached the file
    for (line) |ch| try std.testing.expect(ch >= 0x20);
    try std.testing.expect(std.mem.indexOf(u8, line, "\\u0001") != null); // written as \u00XX

    // it parses, and the argument bytes come back EXACTLY as the model emitted them — an escaper
    // that dropped or mangled them would quietly corrupt what the set exists to teach
    const p = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer p.deinit();
    const args = p.value.object.get("args").?.object;
    try std.testing.expectEqualStrings("echo a\nb\tc\x01d", args.get("cmd").?.string);
    try std.testing.expectEqual(@as(i64, 1), args.get("n").?.integer); // the folded newline kept it JSON
    try std.testing.expectEqualStrings("out\nerr\x01done", p.value.object.get("result").?.string);
}

test "a pre-rendered prompt call is kept in raw but never faked into an sft example" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-dataset-rawform-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("NL_SETS_DIR", root ++ "/sets");
    configure(gpa, io, &env, root);
    defer {
        stop() catch {};
        st.configured = false;
        st.armed.store(false, .release);
    }
    const id = try start("");

    recordCall(.{
        .source = .swarm,
        .role_label = "chat",
        .model = "the-veil-12b",
        .request_body = "{\"model\":\"the-veil-12b\",\"prompt\":\"<bos>hi\",\"raw\":true}",
        .content = "hello",
        .raw_prompt = true,
    });

    var pbuf: [256]u8 = undefined;
    const raw_path = try std.fmt.bufPrint(&pbuf, "{s}/sets/{s}/raw.jsonl", .{ root, id });
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, raw_path, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"prompt\"") != null);

    // no sft.jsonl at all: there was no message structure to learn from
    var sbuf: [256]u8 = undefined;
    const sft_path = try std.fmt.bufPrint(&sbuf, "{s}/sets/{s}/sft.jsonl", .{ root, id });
    try std.testing.expect(std.Io.Dir.cwd().statFile(io, sft_path, .{}) == error.FileNotFound);
    try std.testing.expectEqual(@as(u64, 0), status().examples);
    try std.testing.expectEqual(@as(u64, 1), status().calls);
}

test "the marker is the switch: stop finalizes and no further call is captured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-dataset-marker-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("NL_SETS_DIR", root ++ "/sets");
    configure(gpa, io, &env, root);
    defer {
        st.configured = false;
        st.armed.store(false, .release);
    }

    const id = try start("marker");
    // a second start while one runs is refused — two writers into one set id would interleave
    try std.testing.expectError(error.AlreadyRecording, start("again"));
    var mbuf: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&mbuf, "{s}/sets/" ++ MARKER, .{root});
    const held = try std.Io.Dir.cwd().readFileAlloc(io, marker, gpa, .limited(256));
    defer gpa.free(held);
    try std.testing.expectEqualStrings(id, std.mem.trim(u8, held, " \r\n"));

    try stop();
    try std.testing.expect(!status().recording);
    try std.testing.expect(std.Io.Dir.cwd().statFile(io, marker, .{}) == error.FileNotFound);
    try std.testing.expectError(error.NotRecording, stop());

    // meta.json is closed out with the counts
    var pbuf: [256]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&pbuf, "{s}/sets/{s}/meta.json", .{ root, id });
    const meta = try std.Io.Dir.cwd().readFileAlloc(io, meta_path, gpa, .limited(1 << 16));
    defer gpa.free(meta);
    const mp = try std.json.parseFromSlice(std.json.Value, gpa, meta, .{});
    defer mp.deinit();
    try std.testing.expect(mp.value.object.get("closed").?.bool);
    try std.testing.expectEqualStrings("marker", mp.value.object.get("label").?.string);
    try std.testing.expectEqualStrings("openai-messages-sft", mp.value.object.get("format").?.string);

    // and with the marker gone, a call after stop writes nothing
    recordCall(.{ .model = "m", .content = "after", .request_body = "{\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" });
    var sbuf: [256]u8 = undefined;
    const sft_path = try std.fmt.bufPrint(&sbuf, "{s}/sets/{s}/sft.jsonl", .{ root, id });
    try std.testing.expect(std.Io.Dir.cwd().statFile(io, sft_path, .{}) == error.FileNotFound);
}

test "redact strips the memory block, keys and emails before anything is written" {
    const gpa = std.testing.allocator;
    // Shaped like a real record: the durable-memory system block spliced into a JSON messages array.
    // Measured on set-20260801-171249-000 this block carried a live third-party API key, a login and
    // the operator's email 46 times, into sft.jsonl, raw.jsonl and by-model/ alike.
    const rec =
        "{\"messages\":[{\"role\":\"system\",\"content\":\"YOUR MEMORY (durable facts this user asked you " ++
        "to keep) - [key] Discourse API key: 9f8e7d6c5b4a39281706\"},{\"role\":\"user\",\"content\":\"mail me at " ++
        "someone@example.com with hf_AbCdEfGhIjKlMnOpQrStUvWx\"}],\"model\":\"m\"}";
    const got = redact(gpa, rec) orelse return error.NothingRedacted;
    defer gpa.free(got);

    // the three secrets are gone
    try std.testing.expect(std.mem.indexOf(u8, got, "Discourse API key") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "9f8e7d6c5b4a39281706") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "someone@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "hf_AbCdEfGhIjKlMnOpQrStUvWx") == null);
    // and their placeholders are there instead
    try std.testing.expect(std.mem.indexOf(u8, got, "[memory block redacted at capture]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "[redacted-email]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "[redacted-token]") != null);
    // the record is still parseable JSON — a scrub that corrupts the line destroys the whole set for a
    // line-oriented reader, which is worse than the leak it was fixing
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, got, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("m", parsed.value.object.get("model").?.string);

    // TRAINING SIGNAL SURVIVES: a record with no secrets is returned untouched (null = no copy), and
    // things that merely look secret-ish are left alone — a scrub that eats tool-call ids or ordinary
    // prose would quietly destroy what the set exists to teach.
    const clean = "{\"messages\":[{\"role\":\"assistant\",\"content\":\"call id tc0b0e53f0cc6f0353 ok\"}]}";
    try std.testing.expect(redact(gpa, clean) == null);
    const hexy = "{\"id\":\"36a7f6a6f5a9448496de641cf64bd375\",\"sk-\":\"short\"}"; // hash + too-short prefix
    try std.testing.expect(redact(gpa, hexy) == null);

    // THE ESCAPE-BOUNDARY REGRESSION. This exact shape corrupted line 586 of a real 880-line set:
    // a Python snippet whose JSON encoding puts `\` `n` immediately before an `@`. `n` is a token
    // char, so the left-walk ate it, left a bare `\` in front of the placeholder, and made the
    // record unparseable in sft.jsonl, raw.jsonl and tools.jsonl at once. A decorator is also not
    // an email. Both must survive byte-for-byte.
    const code = "{\"messages\":[{\"role\":\"assistant\",\"content\":\"```python\\n@app.route(\\\"/health\\\")\\ndef h(): pass\"}]}";
    try std.testing.expect(redact(gpa, code) == null); // nothing to scrub -> returned untouched
    { // and the input really was valid JSON, so "unchanged" means "still valid"
        const pc = try std.json.parseFromSlice(std.json.Value, gpa, code, .{});
        defer pc.deinit();
    }

    // A REAL email still goes, even sitting right after an escape-heavy run.
    const mixed = "{\"c\":\"line\\nreach me: real.person@example.com\\n@app.get(\\\"/x\\\")\"}";
    const fixed = redact(gpa, mixed) orelse return error.EmailNotRedacted;
    defer gpa.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "real.person@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "[redacted-email]") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@app.get(") != null); // decorator survived
    const pf = try std.json.parseFromSlice(std.json.Value, gpa, fixed, .{}); // still parseable
    defer pf.deinit();
}

// ---- rolling parts --------------------------------------------------------------------------------------------------

/// A scratch recorder state for the rolling tests: configured on its own root, no set started (appendTo writes to
/// whatever dir it is given), part_max shrunk so a roll happens every few records.
const RollFixture = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    root: []const u8,

    fn init(f: *RollFixture, root: []const u8, max: u64) !std.Io {
        const gpa = std.testing.allocator;
        f.threaded = std.Io.Threaded.init(gpa, .{});
        const io = f.threaded.io();
        f.root = root;
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir);
        f.env = std.process.Environ.Map.init(gpa);
        var sb: [256]u8 = undefined;
        try f.env.put("NL_SETS_DIR", try std.fmt.bufPrint(&sb, "{s}/sets", .{root}));
        configure(gpa, io, &f.env, root);
        part_max = max;
        return io;
    }

    fn deinit(f: *RollFixture) void {
        part_max = PART_MAX;
        st.configured = false;
        st.armed.store(false, .release);
        std.Io.Dir.cwd().deleteTree(f.threaded.io(), f.root) catch {};
        f.env.deinit();
        f.threaded.deinit();
    }
};

/// Every file in `dir` whose name is `stem` + ".jsonl" or a part of it, in the order a reader concatenates them
/// (parts by name, then the live file), joined. Also reports how many parts there were and the largest file.
fn rollReadAll(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, stem: []const u8, parts_out: *usize, largest_out: *u64) ![]u8 {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var live = false;
    while (try it.next(io)) |ent| {
        if (ent.kind != .file or !std.mem.startsWith(u8, ent.name, stem) or !std.mem.endsWith(u8, ent.name, ".jsonl")) continue;
        const mid = ent.name[stem.len .. ent.name.len - ".jsonl".len];
        if (mid.len == 0) {
            live = true;
            continue;
        }
        if (mid[0] != '.') continue;
        try names.append(gpa, try gpa.dupe(u8, ent.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    parts_out.* = names.items.len;
    largest_out.* = 0;
    var all: std.ArrayListUnmanaged(u8) = .empty;
    errdefer all.deinit(gpa);
    var pb: [600]u8 = undefined;
    for (names.items) |n| {
        const body = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, n }), gpa, .limited(1 << 22));
        defer gpa.free(body);
        largest_out.* = @max(largest_out.*, body.len);
        try all.appendSlice(gpa, body);
    }
    if (live) {
        const body = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.bufPrint(&pb, "{s}/{s}.jsonl", .{ dir, stem }), gpa, .limited(1 << 22));
        defer gpa.free(body);
        largest_out.* = @max(largest_out.*, body.len);
        try all.appendSlice(gpa, body);
    }
    return all.toOwnedSlice(gpa);
}

test "rolling parts: no file outgrows part_max, records never split, and the parts concatenate to exactly what was written" {
    const gpa = std.testing.allocator;
    var fx: RollFixture = undefined;
    const io = try fx.init("zig-dataset-roll-tmp", 300);
    defer fx.deinit();
    const dir = "zig-dataset-roll-tmp/set";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);

    var want: std.ArrayListUnmanaged(u8) = .empty;
    defer want.deinit(gpa);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        var lb: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&lb, "{{\"n\":{d},\"pad\":\"abcdefghijklmnopqrstuvwxyz\"}}\n", .{i});
        appendTo(dir, "raw.jsonl", line);
        try want.appendSlice(gpa, line);
    }
    var parts: usize = 0;
    var largest: u64 = 0;
    const got = try rollReadAll(gpa, io, dir, "raw", &parts, &largest);
    defer gpa.free(got);
    try std.testing.expect(parts >= 8); // ~3 KB of records through a 300-byte cap
    try std.testing.expect(largest <= 300); // nothing that was still being written ever passed the cap
    try std.testing.expectEqualStrings(want.items, got); // byte-identical, in order, nothing lost or duplicated
    // every part ends on a record boundary: each file's last byte is a newline (checked through the whole stream)
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, got, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |ln| : (n += 1) {
        const p = try std.json.parseFromSlice(std.json.Value, gpa, ln, .{});
        p.deinit();
    }
    try std.testing.expectEqual(@as(usize, 60), n);
}

test "rolling parts: a record bigger than part_max still lands whole, in a part of its own" {
    const gpa = std.testing.allocator;
    var fx: RollFixture = undefined;
    const io = try fx.init("zig-dataset-roll-big-tmp", 100);
    defer fx.deinit();
    const dir = "zig-dataset-roll-big-tmp/set";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    appendTo(dir, "sft.jsonl", "{\"small\":1}\n");
    var big: [251]u8 = undefined;
    @memset(big[0..249], 'x');
    big[0] = '"';
    big[248] = '"';
    big[249] = '\n';
    appendTo(dir, "sft.jsonl", big[0..250]);
    var parts: usize = 0;
    var largest: u64 = 0;
    const got = try rollReadAll(gpa, io, dir, "sft", &parts, &largest);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 1), parts); // the small record was rolled away first
    try std.testing.expectEqual(@as(u64, 250), largest); // the big one was never split
    try std.testing.expect(std.mem.startsWith(u8, got, "{\"small\":1}\n\""));
}

test "rolling parts: parallel writers through the roll lose nothing, duplicate nothing, and leave no zero-filled gaps" {
    const gpa = std.testing.allocator;
    var fx: RollFixture = undefined;
    const io = try fx.init("zig-dataset-roll-par-tmp", 400);
    defer fx.deinit();
    const dir = "zig-dataset-roll-par-tmp/set";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    const W = struct {
        fn run(w: usize) void {
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                var lb: [96]u8 = undefined;
                const line = std.fmt.bufPrint(&lb, "{{\"w\":{d},\"i\":{d},\"pad\":\"0123456789\"}}\n", .{ w, i }) catch return;
                appendTo("zig-dataset-roll-par-tmp/set", "tools.jsonl", line);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, w| t.* = try vthread.spawn("test-dataset", W.run, .{w});
    for (threads) |t| t.join();
    var parts: usize = 0;
    var largest: u64 = 0;
    const got = try rollReadAll(gpa, io, dir, "tools", &parts, &largest);
    defer gpa.free(got);
    try std.testing.expect(parts >= 4);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 0) == null); // no gap written at a stale offset
    var seen = [_][40]bool{[_]bool{false} ** 40} ** 4;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, got, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |ln| : (n += 1) {
        const R = struct { w: usize, i: usize, pad: []const u8 };
        const p = try std.json.parseFromSlice(R, gpa, ln, .{});
        defer p.deinit();
        try std.testing.expect(!seen[p.value.w][p.value.i]); // never twice
        seen[p.value.w][p.value.i] = true;
    }
    try std.testing.expectEqual(@as(usize, 160), n); // never lost
}
