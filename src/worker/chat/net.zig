//! GARY'S 4TOPE — the conversation's working span as a dependency graph, and the continuation as its unfolding.
//!
//! Named by Gary Stimpson, who framed it (2026-10-10): a conversation is a higher-dimensional object the model can
//! only read one-dimensionally, the way a 4-polytope can only be seen through its net — cells joined along shared
//! faces, cut along a spanning tree and laid flat. The question is which tree to cut along. The answer, from the
//! pages he pointed at, is the shortest-path tree from where the work stands, and the part that must never be cut
//! away is the longest path back from it. Same family as the tool tree (belt.zig): both are bounded views of a
//! structure too big to show whole, walked from the frontier, with the engine holding the map.
//!
//! Compaction and continuation used to be a writing problem: when the span grew past its budget a model was asked
//! to paraphrase the older part, and when a turn crossed its spend ceiling a model was asked to write a ~180-word
//! CONTINUATION STATE from the head and tail of the log. Both paraphrases are lossy, both cost a model call, and
//! the second one is what the user watched scroll past four times in one task and read, correctly, as the harness
//! losing the thread. Both are retrieval problems, and retrieval has algorithms.
//!
//! Three results carry the whole design, each from the page Gary pointed at:
//!
//!   * LONGEST PATH is NP-hard on a general graph and LINEAR on a DAG: order the vertices topologically and take,
//!     for each, one more than the best of its predecessors (the critical path method is this on a schedule). A
//!     working span is a DAG by construction — every dependency points at something older — and its vertices are
//!     already in topological order. The longest weighted path backward from the frontier is the CRITICAL CHAIN:
//!     the results the current step transitively rests on. That chain replaces "keep the newest 32 KB" as the
//!     thing a prune must never stub (`criticalChain`, `protectedIds`).
//!   * A NET is a polyhedron cut along a spanning tree and laid flat so adjacent faces stay adjacent; a shortest
//!     path on the surface becomes a straight line on a suitable net. The prompt is a net of the conversation,
//!     and the spanning tree to cut along is the SHORTEST-PATH TREE from the source — the frontier. Laid out in
//!     that tree's order, every node appears exactly once (a tree has no overlap) and every derivation chain from
//!     the frontier is one contiguous span of text (`unfold`).
//!   * The SHORTEST-PATH TREE is what Dijkstra builds; with a byte budget it is also the selection rule: nodes are
//!     taken in distance order from the frontier until the budget is spent, so what rides is what the frontier is
//!     closest to, not what is newest.
//!
//! Edges are recorded at write time from what is actually in the span, never inferred by a model: a result depends
//! on the step that issued it (by tool_call_id); a step depends STRONGLY on a previous-round result whose
//! distinctive tokens its own words or arguments reuse (it demonstrably read it), and weakly on the rest of that
//! round; a step depends on the step before it (the model's own thread). An identical call, or a later write, edit
//! or delete of the same file that landed, SUPERSEDES the earlier result; a later READ supersedes an earlier read
//! only when it demonstrably shows all of it (reading another region of a file is more evidence, not a
//! replacement); a result that reads as an error is a DEAD END, except a read that shows the file's own lines,
//! whatever they say. Superseded results are stale and are neither protected nor carried; dead ends are carried
//! under RULED OUT, which is the negative knowledge a paraphrase forgets and a retrieval must be told about.
//!
//! The rendering keeps the four labels the next segment already reads (ESTABLISHED / ON DISK / RULED OUT / NEXT)
//! so nothing downstream changes, but every line is verbatim bytes from the span: NEXT is the frontier's own last
//! words, ON DISK is the engine's file ledger, RULED OUT the failed calls, ESTABLISHED the chain in net order.
//! Zero model calls. The same bytes are banked into neuron-db as the chat runs (engine.zig, step boundary), so the
//! carry is a layout of what is already remembered, not the only copy of it.

const std = @import("std");

pub const Kind = enum(u8) { user, step, note, result, engine };

pub const Dep = struct { to: u32, w: u8 };

/// One message of the span. Excerpts and ids live in the graph's arena, so the graph outlives the buffer it was
/// read from (the caller rewrites that buffer right after).
pub const Node = struct {
    kind: Kind,
    /// a result's tool_call_id; "" otherwise
    id: []const u8 = "",
    /// a result's tool name and (unescaped, clipped) arguments; "" otherwise
    name: []const u8 = "",
    args: []const u8 = "",
    /// the message content, unescaped, one line, clipped to EXCERPT_MAX
    text: []const u8 = "",
    /// the round (step index) this message belongs to
    round: u32 = 0,
    deps: std.ArrayListUnmanaged(Dep) = .empty,
    superseded: bool = false,
    dead: bool = false,
    /// bytes this message occupies in the span (for the budget)
    bytes: usize = 0,
    /// a read_file result's line window, read from its arguments; the whole file for every other node
    lines: Lines = .{},
};

/// The line window a read_file call asked for, resolved the way tools.zig `readFile` resolves it: start_line (or
/// its `offset` alias) through end_line (or offset+limit-1), 1-indexed and inclusive, a missing bound being the
/// file's edge, so a call with no window at all is the whole file. `windowed` is readFile's own test: a windowed
/// read answers with a `[lines A-B of N]` header line and then the lines, an unwindowed one with the file's head.
/// Each bound is read as readFile's own std.json parse reads its `usize` field, so `"start_line":"1230"` and
/// `1230.0` are line 1230 there as here. `known` is false when the arguments could not be read in full (their
/// excerpt was clipped, or a bound is one std.json refuses, which readFile answers with "bad args"): such a window
/// is contained only by a whole-file one and contains nothing.
pub const Lines = struct {
    first: u64 = 1,
    last: u64 = std.math.maxInt(u64),
    windowed: bool = false,
    known: bool = true,

    /// The window in a read_file call's unescaped arguments (a Node's `args`).
    pub fn of(args: []const u8) Lines {
        const unknown: Lines = .{ .windowed = true, .known = false };
        // an args excerpt longer than its cap ends in "..." rather than the object's own '}', and may have lost
        // the very bound that narrows the window
        if (args.len == 0 or args[args.len - 1] != '}') return unknown;
        const sl = jsonUint(args, "start_line") orelse return unknown;
        const el = jsonUint(args, "end_line") orelse return unknown;
        const off = jsonUint(args, "offset") orelse return unknown;
        const lim = jsonUint(args, "limit") orelse return unknown;
        // readFile: `start_line = start_line or offset`, `end_line = end_line or start+limit-1 (only with a start)`
        const start = if (sl > 0) sl else off;
        const end = if (el > 0) el else if (lim > 0 and start > 0) start +| (lim - 1) else 0;
        return .{
            .first = if (start == 0) 1 else start,
            .last = if (end == 0) std.math.maxInt(u64) else end,
            .windowed = start > 0 or end > 0,
        };
    }

    /// Every line `inner` asked for lies inside `outer` (a whole-file window holds any window, known or not).
    pub fn contains(outer: Lines, inner: Lines) bool {
        if (!outer.known) return false;
        if (outer.first <= 1 and outer.last == std.math.maxInt(u64)) return true;
        if (!inner.known) return false;
        return outer.first <= inner.first and inner.last <= outer.last;
    }
};

/// How much of one message the net carries. Enough for a path and the line that matters; a 10 KB file read is a
/// stub pointing at a file the next segment can read again.
pub const EXCERPT_MAX: usize = 240;
/// ...and of the frontier's last words, which are the one thing worth more room.
pub const NEXT_MAX: usize = 700;
/// How many wordless assistant messages back NEXT looks for the model's last stated intention (nearestWords).
const NEXT_WORDS_LOOKBACK: usize = 4;
/// How much of the frontier's own calls NEXT shows beside its words (a `run_python` body is not a plan).
const NEXT_CALLS_MAX: usize = 240;
/// Edge weights for the critical chain: a result the step demonstrably read, the step that issued a result, the
/// model's own thread, and a previous-round result nothing points at.
const W_USED: u8 = 2;
const W_ISSUED: u8 = 1;
const W_THREAD: u8 = 1;
const W_WEAK: u8 = 0;
/// Costs for the shortest-path tree (lower is nearer the frontier).
const C_USED: u32 = 1;
const C_ISSUED: u32 = 1;
const C_THREAD: u32 = 1;
const C_WEAK: u32 = 3;
const C_SUPERSEDED: u32 = 4;
const C_DEAD: u32 = 1;

pub const Graph = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// every call the steps issued, so a result finds its issuer by id
    calls: std.ArrayListUnmanaged(Call) = .empty,
    /// the newest step (or note), the source of the unfolding; NONE when the span has no assistant message
    frontier: u32 = NONE,

    pub const NONE: u32 = std.math.maxInt(u32);
    const Call = struct { id: []const u8, name: []const u8, args: []const u8, step: u32 };

    pub fn deinit(g: *Graph) void {
        for (g.nodes.items) |*n| n.deps.deinit(g.gpa);
        g.nodes.deinit(g.gpa);
        g.calls.deinit(g.gpa);
        g.arena.deinit();
    }

    /// Read a working span — comma-joined `{"role":...}` objects as conv_buf holds them — into the graph.
    pub fn fromSpan(gpa: std.mem.Allocator, span: []const u8) !Graph {
        var g: Graph = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer g.deinit();
        const a = g.arena.allocator();
        // each node's content as the span holds it (results only; "" otherwise), one per node: supersession needs
        // the bytes a read really showed, which the clipped excerpt does not keep. Slices into `span`, so they
        // live only for this call.
        var raws: std.ArrayListUnmanaged([]const u8) = .empty;
        defer raws.deinit(gpa);
        // pass 1: the nodes, in order (which is a topological order: every edge points at an older node)
        var round: u32 = 0;
        var at: usize = 0;
        const marker = "{\"role\":\"";
        while (std.mem.indexOfPos(u8, span, at, marker)) |start| {
            const next = std.mem.indexOfPos(u8, span, start + marker.len, "," ++ marker) orelse span.len;
            const obj = span[start..next];
            at = next;
            const role = jsonStr(obj, "role");
            var n: Node = .{ .kind = .engine, .bytes = obj.len };
            var n_raw: []const u8 = "";
            if (std.mem.eql(u8, role, "user")) {
                n.kind = .user;
                n.text = try excerpt(a, jsonStr(obj, "content"), EXCERPT_MAX);
            } else if (std.mem.eql(u8, role, "assistant")) {
                const calls = std.mem.indexOf(u8, obj, "\"tool_calls\":[") != null;
                if (calls) round += 1;
                n.kind = if (calls) .step else .note;
                n.text = try excerpt(a, jsonStr(obj, "content"), NEXT_MAX);
                n.round = round;
                try g.nodes.append(gpa, n);
                try raws.append(gpa, n_raw);
                const step_idx: u32 = @intCast(g.nodes.items.len - 1);
                g.frontier = step_idx;
                // the step's calls become result PLACEHOLDERS only when their results arrive (below); here we
                // remember them on the step so a result can find its issuer by id
                try g.addCalls(a, step_idx, obj);
                continue;
            } else if (std.mem.eql(u8, role, "tool")) {
                n.kind = .result;
                n.id = try a.dupe(u8, jsonStr(obj, "tool_call_id"));
                const raw = jsonStr(obj, "content");
                n.text = try excerpt(a, raw, EXCERPT_MAX);
                n.dead = looksDead(n.text);
                n.round = round;
                // name/args from the issuing step's call list
                if (g.callOf(n.id)) |c| {
                    n.name = c.name;
                    n.args = c.args;
                    if (std.mem.eql(u8, c.name, "read_file")) {
                        n.lines = Lines.of(c.args);
                        // looksDead judges the excerpt, and a read's excerpt is the FILE's opening lines: a bug-site
                        // window whose first line raises `KeyError(name + ' not found')` read as a failed call, was
                        // carried under RULED OUT, and gave way to any later read of the path, another region
                        // included. A view that shows the file's own lines did not fail, whatever they say.
                        if (n.dead and showsFileLines(raw)) n.dead = false;
                    }
                    try n.deps.append(gpa, .{ .to = c.step, .w = W_ISSUED });
                }
                n_raw = raw;
            } else {
                n.kind = .engine;
                n.text = try excerpt(a, jsonStr(obj, "content"), EXCERPT_MAX);
                n.round = round;
            }
            try g.nodes.append(gpa, n); // the graph owns n.deps from here, so the append below cannot leak them
            try raws.append(gpa, n_raw);
        }
        if (g.nodes.items.len == 0) return g;
        // pass 2: what each step READ (previous-round results whose distinctive tokens it reuses), the thread, and
        // supersession between results
        var prev_step: u32 = NONE;
        for (g.nodes.items, 0..) |*n, i| {
            if (n.kind != .step and n.kind != .note) continue;
            const idx: u32 = @intCast(i);
            if (prev_step != NONE) try n.deps.append(gpa, .{ .to = prev_step, .w = W_THREAD });
            // tokens the step reused: its own words plus the arguments of the calls it then made
            var toks_buf: [32][]const u8 = undefined;
            var ntok = distinctiveTokens(n.text, &toks_buf);
            for (g.calls.items) |c| if (c.step == idx) {
                ntok += distinctiveTokens(c.args, toks_buf[ntok..]);
            };
            const toks = toks_buf[0..ntok];
            // the previous round's results: everything between prev_step and this step
            var j: usize = if (prev_step == NONE) 0 else prev_step + 1;
            while (j < i) : (j += 1) {
                const r = &g.nodes.items[j];
                if (r.kind != .result) continue;
                var used = false;
                for (toks) |t| if (std.ascii.indexOfIgnoreCase(r.text, t) != null) {
                    used = true;
                    break;
                };
                try n.deps.append(gpa, .{ .to = @intCast(j), .w = if (used) W_USED else W_WEAK });
            }
            prev_step = idx;
        }
        g.markSuperseded(raws.items);
        return g;
    }

    fn addCalls(g: *Graph, a: std.mem.Allocator, step: u32, obj: []const u8) !void {
        const key = "\"tool_calls\":[";
        const start = std.mem.indexOf(u8, obj, key) orelse return;
        var at = start + key.len;
        while (std.mem.indexOfPos(u8, obj, at, "{\"id\":\"")) |cs| {
            const ce = std.mem.indexOfPos(u8, obj, cs, "}}") orelse obj.len;
            const call = obj[cs..@min(obj.len, ce + 2)];
            at = @max(cs + 1, ce);
            const id = jsonStr(call, "id");
            if (id.len == 0) continue;
            const args_raw = jsonStr(call, "arguments");
            try g.calls.append(g.gpa, .{
                .id = try a.dupe(u8, id),
                .name = try a.dupe(u8, jsonStr(call, "name")),
                .args = try excerpt(a, args_raw, 160),
                .step = step,
            });
        }
    }

    fn callOf(g: *const Graph, id: []const u8) ?Call {
        if (id.len == 0) return null;
        for (g.calls.items) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    /// What makes an earlier result stale:
    ///   * an IDENTICAL later call: the newer answer to the same question is the current one;
    ///   * a later write, edit or delete of the same path that LANDED (`mutationLanded`): every earlier view of the
    ///     file, and every earlier change record of it, describes a file that is no longer that way. One that was
    ///     refused changed nothing, so it stales nothing: an edit the tag guard rejected (SymPy's edit #24 in the
    ///     same baseline) used to stale every earlier read of the file as surely as a landed one;
    ///   * a later READ of the path only when it shows everything the earlier read showed (`readCovers`), and a
    ///     later listing of a directory an earlier listing of it.
    /// Reading another region of a file is gathering more evidence, not replacing it. While ANY later call on a path
    /// superseded every earlier result on it, a read of lines 820-845 staled the read of the bug site at 1230-1290
    /// of the same file: the prune was free to stub it, the carry dropped it, and the segment after the spend
    /// ceiling re-derived the bug from scratch and first reached for the wrong fix (a SWE-bench Lite baseline run).
    /// `raws` is each node's content as the span held it, for readCovers.
    fn markSuperseded(g: *Graph, raws: []const []const u8) void {
        const items = g.nodes.items;
        for (items, 0..) |*older, i| {
            if (older.kind != .result or older.name.len == 0) continue;
            const path = jsonStr(older.args, "path");
            var j = i + 1;
            while (j < items.len) : (j += 1) {
                const newer = items[j];
                if (newer.kind != .result or newer.name.len == 0) continue;
                if (std.mem.eql(u8, newer.name, older.name) and std.mem.eql(u8, newer.args, older.args)) {
                    older.superseded = true;
                    break;
                }
                if (path.len == 0 or !isFileTool(newer.name) or !std.mem.eql(u8, jsonStr(newer.args, "path"), path)) continue;
                const stale = if (isFileMutation(newer.name))
                    mutationLanded(newer.name, raws[j])
                else if (std.mem.eql(u8, newer.name, "read_file") and std.mem.eql(u8, older.name, "read_file"))
                    readCovers(newer, older.*, raws[j], raws[i])
                else
                    std.mem.eql(u8, newer.name, "list_dir") and std.mem.eql(u8, older.name, "list_dir");
                if (stale) {
                    older.superseded = true;
                    break;
                }
            }
        }
    }

    /// THE CRITICAL CHAIN: the longest weighted dependency path from the frontier back through the span (the DAG
    /// recurrence, one pass over the nodes in order). Returned frontier-first. Empty when there is no frontier.
    pub fn criticalChain(g: *const Graph, gpa: std.mem.Allocator) ![]u32 {
        var out: std.ArrayListUnmanaged(u32) = .empty;
        errdefer out.deinit(gpa);
        if (g.frontier == NONE) return out.toOwnedSlice(gpa);
        const n = g.nodes.items.len;
        // dist[v] = longest path STARTING at v and walking back along deps; nodes are in topological order
        // (edges point to lower indices), so oldest-first is the order that has every dependency ready.
        const dist = try gpa.alloc(u32, n);
        defer gpa.free(dist);
        const via = try gpa.alloc(u32, n);
        defer gpa.free(via);
        for (g.nodes.items, 0..) |node, i| {
            dist[i] = 0;
            via[i] = NONE;
            for (node.deps.items) |d| {
                const cand = dist[d.to] + d.w;
                // ties go to the NEWER dependency (a larger index): the frontier's recent reads over its old ones
                if (cand > dist[i] or (cand == dist[i] and via[i] != NONE and d.to > via[i])) {
                    dist[i] = cand;
                    via[i] = d.to;
                }
            }
        }
        var at: u32 = g.frontier;
        while (at != NONE) : (at = via[at]) try out.append(gpa, at);
        return out.toOwnedSlice(gpa);
    }

    /// The tool_call_ids a prune must leave alone: every live (not superseded) result on the critical chain.
    /// Slices point into the graph's arena; the returned list is gpa-owned.
    pub fn protectedIds(g: *const Graph, gpa: std.mem.Allocator) ![]const []const u8 {
        const chain = try g.criticalChain(gpa);
        defer gpa.free(chain);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (chain) |i| {
            const node = g.nodes.items[i];
            if (node.kind == .result and !node.superseded and node.id.len > 0) try out.append(gpa, node.id);
        }
        return out.toOwnedSlice(gpa);
    }

    /// THE SOURCE UNFOLDING: Dijkstra from the frontier over the dependency graph (both directions, weighted so
    /// what the frontier read is nearer than what it merely saw, and stale or failed results are farther), taking
    /// nodes in distance order until `budget` bytes are spoken for, then laid out in shortest-path-tree order so
    /// each derivation chain is one contiguous run and no node appears twice. `ground` is the engine's own file
    /// ledger (verbatim, clipped) for ON DISK. Empty when the span has nothing to carry. gpa-owned.
    pub fn unfold(g: *Graph, gpa: std.mem.Allocator, budget: usize, ground: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        if (g.frontier == NONE or budget < 200) return out.toOwnedSlice(gpa);
        const n = g.nodes.items.len;
        // undirected adjacency with costs
        const dist = try gpa.alloc(u32, n);
        defer gpa.free(dist);
        const parent = try gpa.alloc(u32, n);
        defer gpa.free(parent);
        const done = try gpa.alloc(bool, n);
        defer gpa.free(done);
        @memset(dist, std.math.maxInt(u32));
        @memset(parent, NONE);
        @memset(done, false);
        dist[g.frontier] = 0;
        // O(V^2) Dijkstra: spans hold a few hundred messages at most, and this runs once per cut
        var left: usize = n;
        while (left > 0) : (left -= 1) {
            var u: u32 = NONE;
            for (dist, 0..) |d, i| if (!done[i] and d != std.math.maxInt(u32) and (u == NONE or d < dist[u])) {
                u = @intCast(i);
            };
            if (u == NONE) break;
            done[u] = true;
            // edges out of u (its deps) and into u (nodes that depend on it)
            for (g.nodes.items[u].deps.items) |d| g.relax(dist, parent, u, d.to, d.w);
            for (g.nodes.items, 0..) |node, i| for (node.deps.items) |d| if (d.to == u) g.relax(dist, parent, u, @intCast(i), d.w);
        }
        // SELECT in distance order under the budget: NEXT and ON DISK are reserved first (NEXT gets at most a
        // third, ON DISK a quarter, and the section headers their room)
        const words = g.nearestWords();
        const next_text = clipWords(words.text, @max(80, budget / 3));
        // the frontier's own calls ride beside borrowed words (see nearestWords), clipped and counted
        const frontier_calls: ?[]const u8 = if (words.at != g.frontier) g.lastCallsOf(g.frontier) else null;
        var spent: usize = next_text.len + 64 + @min(ground.len, budget / 4) + 200;
        if (frontier_calls) |c| spent += @min(c.len, NEXT_CALLS_MAX) + 24;
        const chosen = try gpa.alloc(bool, n);
        defer gpa.free(chosen);
        @memset(chosen, false);
        const order = try gpa.alloc(u32, n);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, dist, struct {
            fn lt(dd: []u32, x: u32, y: u32) bool {
                if (dd[x] != dd[y]) return dd[x] < dd[y];
                return x > y; // nearer ties: newer first
            }
        }.lt);
        for (order) |i| {
            if (dist[i] == std.math.maxInt(u32)) break;
            const node = g.nodes.items[i];
            // steps are the model's narration — their decisions show in what they then called, and the
            // frontier's own words are NEXT; a note rides only when it is a distillation (a fold note)
            if (i == g.frontier or node.kind == .user or node.kind == .engine or node.kind == .step or node.superseded) continue;
            if (node.kind == .note and !isDistillation(node.text)) continue;
            if (node.kind == .result and node.text.len == 0) continue;
            const cost = node.text.len + node.name.len + node.args.len + 24;
            if (spent + cost > budget) continue;
            spent += cost;
            chosen[i] = true;
        }
        // LAY OUT: NEXT (the frontier's own words), ON DISK, RULED OUT (dead ends, nearest first), then
        // ESTABLISHED in shortest-path-tree order — a depth-first walk from the frontier, children by distance
        try out.appendSlice(gpa, "NEXT (the frontier, in its own last words): ");
        if (next_text.len > 0) {
            try out.appendSlice(gpa, next_text);
            if (frontier_calls) |calls| {
                try out.appendSlice(gpa, " — it had then called ");
                try out.appendSlice(gpa, clip(calls, NEXT_CALLS_MAX));
            }
        } else if (g.lastCallsOf(g.frontier)) |calls| {
            try out.appendSlice(gpa, "it had just called ");
            try out.appendSlice(gpa, clip(calls, NEXT_CALLS_MAX));
        } else {
            try out.appendSlice(gpa, "(no words; see the results below)");
        }
        try out.append(gpa, '\n');
        if (ground.len > 0) {
            try out.appendSlice(gpa, "ON DISK: ");
            try out.appendSlice(gpa, std.mem.trim(u8, clip(ground, budget / 4), " \r\n\t"));
            try out.append(gpa, '\n');
        }
        var any_dead = false;
        for (order) |i| if (chosen[i] and g.nodes.items[i].dead) {
            if (!any_dead) try out.appendSlice(gpa, "RULED OUT (calls that failed; do not repeat them as they were):\n");
            any_dead = true;
            try g.line(gpa, &out, i);
        };
        var any_est = false;
        var stack: std.ArrayListUnmanaged(u32) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, g.frontier);
        const visited = try gpa.alloc(bool, n);
        defer gpa.free(visited);
        @memset(visited, false);
        while (stack.items.len > 0) {
            const u = stack.pop().?;
            if (visited[u]) continue;
            visited[u] = true;
            if (chosen[u] and !g.nodes.items[u].dead) {
                if (!any_est) try out.appendSlice(gpa, "ESTABLISHED (what the frontier rests on, nearest first, each derivation contiguous):\n");
                any_est = true;
                try g.line(gpa, &out, u);
            }
            // children in the SPT: nodes whose parent is u; push farthest first so the nearest is walked first
            var kids: [64]u32 = undefined;
            var nk: usize = 0;
            for (parent, 0..) |p, i| if (p == u and nk < kids.len) {
                kids[nk] = @intCast(i);
                nk += 1;
            };
            std.mem.sort(u32, kids[0..nk], dist, struct {
                fn farFirst(dd: []u32, x: u32, y: u32) bool {
                    return dd[x] > dd[y];
                }
            }.farFirst);
            for (kids[0..nk]) |k| try stack.append(gpa, k);
        }
        return out.toOwnedSlice(gpa);
    }

    fn relax(g: *const Graph, dist: []u32, parent: []u32, from: u32, to: u32, w: u8) void {
        const target = g.nodes.items[to];
        // issued and thread edges share a weight, so this is a ladder rather than a switch
        var c: u32 = if (w == W_USED) C_USED else if (w == W_WEAK) C_WEAK else C_ISSUED;
        comptime std.debug.assert(C_ISSUED == C_THREAD);
        if (target.superseded) c += C_SUPERSEDED;
        if (target.dead) c += C_DEAD;
        if (dist[from] != std.math.maxInt(u32) and dist[from] + c < dist[to]) {
            dist[to] = dist[from] + c;
            parent[to] = from;
        }
    }

    fn line(g: *const Graph, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), i: u32) !void {
        const node = g.nodes.items[i];
        switch (node.kind) {
            .result => {
                try out.print(gpa, "- r{d} {s}", .{ node.round, if (node.name.len > 0) node.name else "tool" });
                if (node.args.len > 0) try out.print(gpa, " {s}", .{node.args});
                try out.appendSlice(gpa, if (node.dead) " -> " else ": ");
                try out.appendSlice(gpa, node.text);
                try out.append(gpa, '\n');
            },
            .step, .note => {
                try out.print(gpa, "- r{d} note: {s}\n", .{ node.round, node.text });
            },
            else => {},
        }
    }

    /// THE WORDS NEXT CARRIES: the frontier's own, or — when its last message was a bare tool call — the newest
    /// earlier assistant message that said anything, within NEXT_WORDS_LOOKBACK assistant messages. A step's
    /// words are its stated intention, and a frontier that only called a tool has not retracted the sentence
    /// before it. Measured on a cut SWE-bench Lite turn (pytest-7220, arm D, 2026-10-14): the model had written
    /// "The fix works. Now add a regression test. Let me check existing tests for a similar style:" one round
    /// earlier, its frontier was a wordless `run_python` call, and NEXT carried that call's truncated arguments —
    /// so the next segment re-derived the fix's state instead of writing the test. A fold note (a distillation)
    /// is the engine's summary, never the model's intention, and is skipped. `at` is the node the words came
    /// from, NONE when nothing within reach said anything.
    fn nearestWords(g: *const Graph) struct { text: []const u8, at: u32 } {
        if (g.frontier == NONE) return .{ .text = "", .at = NONE };
        var i: u32 = g.frontier;
        var seen: usize = 0;
        while (true) {
            const node = g.nodes.items[i];
            if (node.kind == .step or (node.kind == .note and !isDistillation(node.text))) {
                if (node.text.len > 0) return .{ .text = node.text, .at = i };
                seen += 1;
                if (seen > NEXT_WORDS_LOOKBACK) break;
            }
            if (i == 0) break;
            i -= 1;
        }
        return .{ .text = "", .at = NONE };
    }

    /// "name args, name args" for the calls a step issued, or null.
    fn lastCallsOf(g: *Graph, step: u32) ?[]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const a = g.arena.allocator();
        for (g.calls.items) |c| if (c.step == step) {
            if (buf.items.len > 0) buf.appendSlice(a, ", ") catch return null;
            buf.appendSlice(a, c.name) catch return null;
            if (c.args.len > 0) {
                buf.append(a, ' ') catch return null;
                buf.appendSlice(a, c.args) catch return null;
            }
        };
        if (buf.items.len == 0) return null;
        return buf.items;
    }
};

fn isFileTool(name: []const u8) bool {
    const names = [_][]const u8{ "read_file", "write_file", "edit_file", "delete_file", "list_dir" };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The file tools that change the file, rather than look at it.
fn isFileMutation(name: []const u8) bool {
    const names = [_][]const u8{ "write_file", "edit_file", "delete_file" };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// How engine.zig's PRUNED_RESULT_NOTE opens (pinned there by a test): the one-line stub a prune leaves in place of
/// a result.
pub const PRUNED_STUB = "[tool result pruned";

/// Did a write, edit or delete change the file, by its own answer (`raw`, as the span holds it)? The success answers
/// are tools.zig's, the shapes engine.zig parseFileMutation records in the file ledger (a test there pins the two
/// together): write_file and edit_file open with "wrote ", "appended to ", "rewrote " or "edited " and always carry
/// "file is now "; delete_file opens with "deleted ". Any other answer is a refusal that left the file as it was (a
/// stale anchor, tags in the replacement text, a syntax-gate rejection, a missing file, an engine refusal). A result
/// the prune stubbed no longer says which it was, so it is taken to have landed, as every mutation used to be: a
/// pre-edit view wrongly kept live is a file carried as it no longer is, the worse of the two mistakes.
pub fn mutationLanded(name: []const u8, raw: []const u8) bool {
    if (std.mem.startsWith(u8, raw, PRUNED_STUB)) return true;
    if (std.mem.eql(u8, name, "delete_file")) return std.mem.startsWith(u8, raw, "deleted ");
    for ([_][]const u8{ "wrote ", "appended to ", "rewrote ", "edited " }) |p| {
        if (std.mem.startsWith(u8, raw, p)) return std.mem.indexOf(u8, raw, "file is now ") != null;
    }
    return false;
}

/// Does the newer read show everything the older read showed? Both are read_file results on one path; the raws
/// are their contents as the span holds them (still escaped).
fn readCovers(newer: Node, older: Node, raw_new: []const u8, raw_old: []const u8) bool {
    // a failed read showed no file, so the first later read that worked is the news; a failed one shows nothing
    // (`dead` on a read is fromSpan's: a view that shows the file's own lines is never a failed read)
    if (older.dead) return !newer.dead;
    if (newer.dead) return false;
    // the same whole-file request twice: the newer view is the current one
    if (older.lines.known and newer.lines.known and !older.lines.windowed and !newer.lines.windowed) return true;
    if (!newer.lines.contains(older.lines)) return false;
    // The window says it should; the view must say it did. A covering range can still show LESS than the read it
    // would replace: a whole-file view stops at its head (readFile's 8000-byte cap), a window at
    // hashline.WINDOW_MAX_BYTES, the engine elides the middle of any result past 10 KB, and a prune leaves a
    // one-line stub. The hashline tags say which lines each view shows, by NUMBER, and they are absolute, so a
    // window and a whole-file view name a line alike. Numbers, not bytes: a file changed between the two reads by a
    // tool the net does not count as a write (run_python, a shell sed) is still shown again, line for line, by the
    // newer view, and that view is the current one. A byte check kept the pre-change view live beside it, both
    // protected and carried, two contradictory views of the same lines told apart only by their round labels.
    if (tagsCover(raw_new, raw_old)) |covered| return covered;
    // An untagged view (a roamed read outside the workdir, a binary-ish file) has no numbers to read, so only its
    // bytes can show it: the older read's text inside the newer result. That cannot see through a change made
    // between the two reads, and then keeps both views: one view too many is the safer way to be wrong.
    return std.mem.indexOf(u8, raw_new, shownText(raw_old, older.lines)) != null;
}

/// The file text a read result shows, as the span holds it (still escaped): a windowed read's view minus its
/// `[lines A-B of N]` header line, an unwindowed one's view whole. A windowed answer with no line break in it has
/// no file text at all (a past-the-end notice, a refusal, a pruned stub), so it shows "". A window whose arguments
/// could not be read may have been either kind; its own header says which.
fn shownText(raw: []const u8, lines: Lines) []const u8 {
    if (!lines.windowed or (!lines.known and !std.mem.startsWith(u8, raw, "[lines "))) return raw;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 1) {
        if (raw[i] != '\\') continue;
        if (raw[i + 1] == 'n') return raw[i + 2 ..];
        i += 1; // any other escape: step over its second byte so an escaped backslash cannot pose as `\n`
    }
    return "";
}

/// Does a read result show the file's own lines? By its tags, or by readFile's `[lines A-B of N]` header with lines
/// under it (an untagged window). An untagged whole-file view carries no such mark, so this cannot say for one.
fn showsFileLines(raw: []const u8) bool {
    var it: TagRuns = .{ .raw = raw, .whole = false };
    if (it.next() != null) return true;
    return std.mem.startsWith(u8, raw, "[lines ") and shownText(raw, .{ .windowed = true }).len > 0;
}

/// hashline.HASH_LEN: the letters in each half of a line tag (engine.zig's test of real read views pins it).
const TAG_HASH_LEN = 3;

/// A run of consecutive line numbers a read view shows.
const Run = struct { first: u64, last: u64 };

/// The runs of line numbers a read result shows, read off the hashline tags its lines open with (`42:abc:def→`,
/// which readFile puts on every chat read inside the workdir), in the result as the span holds it (still escaped).
/// With `whole`, a line the view cut short is left out: readFile clips a whole-file view at its byte cap and the
/// engine elides the middle of a big result, both mid-line, and each says so on the line right after the cut
/// (`[...view clipped`, `...[N bytes elided`). A window clipped at WINDOW_MAX_BYTES ends on a whole line before its
/// `[...window clipped` notice, which costs that line here too; counting one line too few is the safe side.
const TagRuns = struct {
    raw: []const u8,
    whole: bool,
    at: usize = 0,
    /// the run being read; any line that does not open with the next tag ends it
    cur: ?Run = null,

    fn next(it: *TagRuns) ?Run {
        while (it.at <= it.raw.len) {
            // one line: up to the next escaped line break, stepping over every other escape whole
            const start = it.at;
            var end = it.raw.len;
            var i = start;
            while (i + 1 < it.raw.len) : (i += 1) {
                if (it.raw[i] != '\\') continue;
                if (it.raw[i + 1] == 'n') {
                    end = i;
                    break;
                }
                i += 1;
            }
            it.at = if (end < it.raw.len) end + 2 else it.raw.len + 1;
            const line = it.raw[start..end];
            if (tagLine(line)) |n| {
                if (it.cur) |*c| if (n == c.last + 1) {
                    c.last = n;
                    continue;
                };
                const done = it.cur;
                it.cur = .{ .first = n, .last = n };
                if (done) |d| return d;
                continue;
            }
            var r = it.cur orelse continue;
            it.cur = null;
            if (it.whole and (std.mem.startsWith(u8, line, "[...") or std.mem.startsWith(u8, line, "...["))) {
                if (r.first == r.last) continue;
                r.last -= 1;
            }
            return r;
        }
        const tail = it.cur;
        it.cur = null;
        return tail;
    }
};

/// The line number a read view's line opens with, when it opens with a hashline tag (`42:abc:def→`, the arrow as
/// UTF-8, which http.jstr keeps, or escaped as `→`); null for any other line.
fn tagLine(line: []const u8) ?u64 {
    var i: usize = 0;
    var n: u64 = 0;
    while (i < line.len and i < 12 and std.ascii.isDigit(line[i])) : (i += 1) n = n * 10 + (line[i] - '0');
    if (i == 0 or n == 0) return null;
    for (0..2) |_| {
        if (i >= line.len or line[i] != ':') return null;
        i += 1;
        for (0..TAG_HASH_LEN) |_| {
            if (i >= line.len or line[i] < 'a' or line[i] > 'z') return null;
            i += 1;
        }
    }
    const rest = line[i..];
    if (std.mem.startsWith(u8, rest, "\u{2192}") or std.ascii.startsWithIgnoreCase(rest, "\\u2192")) return n;
    return null;
}

/// Does the newer view show, whole, every line the older view shows? Read off both views' tags. null when the older
/// view carries none (an untagged view, or one that shows no file at all), for the caller to judge another way.
fn tagsCover(raw_new: []const u8, raw_old: []const u8) ?bool {
    var held: [8]Run = undefined; // a view is one run, or a head and a tail around an elision
    var nh: usize = 0;
    var nw: TagRuns = .{ .raw = raw_new, .whole = true };
    while (nw.next()) |r| {
        if (nh == held.len) break; // a view in more pieces than that is not counted past them
        held[nh] = r;
        nh += 1;
    }
    var ow: TagRuns = .{ .raw = raw_old, .whole = false };
    var any = false;
    while (ow.next()) |r| {
        any = true;
        // walk the older run through the newer runs that hold it
        var at = r.first;
        while (at <= r.last) {
            const h = for (held[0..nh]) |run| {
                if (run.first <= at and at <= run.last) break run;
            } else return false;
            at = h.last + 1;
        }
    }
    return if (any) true else null;
}

/// The value of `key` in a flat JSON object as readFile's std.json parse reads a `usize` field: a number, or a string
/// holding one, integral floats included. 0 when the key is absent (the field's default), null when it is present
/// but std.json refuses it (a fraction, a negative, a word), which readFile answers with "bad args".
fn jsonUint(obj: []const u8, key: []const u8) ?u64 {
    const at = valueAt(obj, key) orelse return 0;
    // the value's own token: a string through its closing quote, anything else up to the next delimiter
    var end = at;
    if (end < obj.len and obj[end] == '"') {
        end += 1;
        while (end < obj.len and obj[end] != '"') : (end += 1) {
            if (obj[end] == '\\') end += 1;
        }
        end += 1;
        if (end > obj.len) return null;
    } else {
        while (end < obj.len and obj[end] != ',' and obj[end] != '}' and obj[end] != ' ' and obj[end] != '\t') end += 1;
    }
    // the parse readFile runs, on that token alone; a bound's string never needs the room an unescape could take
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = std.json.parseFromSliceLeaky(usize, fba.allocator(), obj[at..end], .{}) catch return null;
    return v;
}

/// A compaction note or a FACTS carrier is worth carrying; the model's own narration is not (its decisions show
/// in what it then called).
fn isDistillation(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "FACTS LEDGER") or std.mem.startsWith(u8, text, "PROGRESS") or std.mem.indexOf(u8, text[0..@min(text.len, 80)], "PROGRESS") != null;
}

/// Does a result read as a failure? Judged on its opening, where every executor in this codebase puts it.
pub fn looksDead(text: []const u8) bool {
    const head = text[0..@min(text.len, 400)];
    const starts = [_][]const u8{ "ERROR", "Error:", "error:", "(NOT executed", "(no ", "(failed", "FAIL", "Traceback" };
    for (starts) |s| if (std.mem.startsWith(u8, head, s)) return true;
    const within = [_][]const u8{ "Traceback (most recent", "No such file", "not found", "command not found", "timed out", "refused", "exit code 1", "exit code 2" };
    for (within) |s| if (std.mem.indexOf(u8, head, s) != null) return true;
    return false;
}

/// Tokens a later step could only have got from THIS text: 5+ characters, carrying a letter, not a common word.
/// Paths and identifiers keep their punctuation. Fills `out`, returns how many.
pub fn distinctiveTokens(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        while (i < text.len and !tokenChar(text[i])) i += 1;
        const start = i;
        while (i < text.len and tokenChar(text[i])) i += 1;
        const tok = std.mem.trim(u8, text[start..i], "./-_");
        if (tok.len < 5 or tok.len > 64) continue;
        var has_letter = false;
        for (tok) |c| if (std.ascii.isAlphabetic(c)) {
            has_letter = true;
            break;
        };
        if (!has_letter or isCommon(tok)) continue;
        var seen = false;
        for (out[0..n]) |t| if (std.ascii.eqlIgnoreCase(t, tok)) {
            seen = true;
            break;
        };
        if (seen) continue;
        out[n] = tok;
        n += 1;
    }
    return n;
}

fn tokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-';
}

fn isCommon(tok: []const u8) bool {
    const common = [_][]const u8{
        "which",  "there",   "their", "about",  "would",     "should", "could",   "these",    "those",    "where",   "after",
        "before", "while",   "using", "based",  "first",     "other",  "where",   "because",  "return",   "returns", "content",
        "result", "results", "value", "values", "string",    "number", "false",   "error",    "function", "const",   "then",
        "write",  "read",    "file",  "files",  "check",     "tool",   "tools",   "model",    "please",   "thanks",  "found",
        "output", "input",   "lines", "bytes",  "assistant", "system", "message", "messages", "status",   "working", "being",
    };
    for (common) |c| if (std.ascii.eqlIgnoreCase(c, tok)) return true;
    return false;
}

/// The string value of `key` in a flat JSON object, RAW (still escaped), or "".
pub fn jsonStr(obj: []const u8, key: []const u8) []const u8 {
    var i = valueAt(obj, key) orelse return "";
    if (i >= obj.len or obj[i] != '"') return "";
    i += 1;
    const start = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '\\') {
            i += 1;
            continue;
        }
        if (obj[i] == '"') return obj[start..i];
    }
    return "";
}

/// Where the value of `key` starts in a flat JSON object (past the colon and any spaces), or null when the key is
/// absent. The first occurrence that IS a key wins.
fn valueAt(obj: []const u8, key: []const u8) ?usize {
    var kb: [48]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, obj, from, k)) |at| {
        // must be a key: preceded by '{' or ',' (skipping spaces) — not the same bytes inside a string value
        var b = at;
        while (b > 0 and (obj[b - 1] == ' ' or obj[b - 1] == '\n')) b -= 1;
        if (b > 0 and obj[b - 1] != '{' and obj[b - 1] != ',') {
            from = at + 1;
            continue;
        }
        var i = at + k.len;
        while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
        return i;
    }
    return null;
}

/// Unescape a raw JSON string into the arena as ONE line, clipped to `max` at a word boundary when it is longer.
fn excerpt(a: std.mem.Allocator, raw: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var last_space = false;
    while (i < raw.len and out.items.len < max + 1) : (i += 1) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n', 't', 'r' => c = ' ',
                'u' => {
                    c = '?';
                    i += @min(4, raw.len - i - 1);
                },
                else => c = raw[i],
            }
        }
        if (c == ' ') {
            if (last_space or out.items.len == 0) continue;
            last_space = true;
        } else last_space = false;
        try out.append(a, c);
    }
    var s = out.items;
    if (s.len > max) {
        var k = max;
        while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
        if (std.mem.lastIndexOfScalar(u8, s[0..k], ' ')) |sp| if (sp > max / 2) {
            k = sp;
        };
        s = s[0..k];
        return try std.fmt.allocPrint(a, "{s}...", .{std.mem.trimEnd(u8, s, " ")});
    }
    return std.mem.trimEnd(u8, s, " ");
}

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return s[0..k];
}

/// `clip` at a word boundary when one sits in the second half of the allowance.
fn clipWords(s: []const u8, max: usize) []const u8 {
    const c = clip(s, max);
    if (c.len == s.len) return c;
    const sp = std.mem.lastIndexOfScalar(u8, c, ' ') orelse return c;
    return if (sp > max / 2) c[0..sp] else c;
}

// ---------------------------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------------------------

const tt = std.testing;

fn tStep(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, words: []const u8, calls: []const u8) !void {
    try out.print(gpa, ",{{\"role\":\"assistant\",\"content\":\"{s}\",\"tool_calls\":[{s}]}}", .{ words, calls });
}
fn tCall(id: []const u8, name: []const u8, args_escaped: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}", .{ id, name, args_escaped }) catch unreachable;
}
fn tResult(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, id: []const u8, text: []const u8) !void {
    try out.print(gpa, ",{{\"role\":\"tool\",\"tool_call_id\":\"{s}\",\"content\":\"{s}\"}}", .{ id, text });
}

/// Three rounds of a build turn: a read that mattered, a read that did not, a failed run, a write, a frontier.
fn sampleSpan(gpa: std.mem.Allocator) ![]u8 {
    var s: std.ArrayListUnmanaged(u8) = .empty;
    errdefer s.deinit(gpa);
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    var b4: [256]u8 = undefined;
    var b5: [256]u8 = undefined;
    var b12: [512]u8 = undefined;
    const two = std.fmt.bufPrint(&b12, "{s},{s}", .{ tCall("c1", "read_file", "{\\\"path\\\":\\\"src/parser.zig\\\"}", &b1), tCall("c2", "read_file", "{\\\"path\\\":\\\"config.toml\\\"}", &b2) }) catch unreachable;
    try tStep(&s, gpa, "Reading the parser and the config first.", two);
    try tResult(&s, gpa, "c1", "pub fn parseHeader(buf: []const u8) !Header {{ ... MAGIC_V2 = 0x7f45 ... }}");
    try tResult(&s, gpa, "c2", "[server]\\nport = 8787\\nname = \\\"veil\\\"");
    var b6: [256]u8 = undefined;
    var b36: [512]u8 = undefined;
    const two2 = std.fmt.bufPrint(&b36, "{s},{s}", .{ tCall("c3", "run_tests", "{}", &b3), tCall("c6", "fetch_json", "{\\\"url\\\":\\\"https://spec.example.com/magic\\\"}", &b6) }) catch unreachable;
    try tStep(&s, gpa, "parseHeader rejects MAGIC_V2; running the tests to confirm and checking the spec.", two2);
    try tResult(&s, gpa, "c3", "ERROR: 2 tests failed\\nparser.test.header: expected MAGIC_V2 accepted");
    try tResult(&s, gpa, "c6", "ERROR: 404 not found for https://spec.example.com/magic");
    try tStep(&s, gpa, "Fixing parseHeader to accept MAGIC_V2.", tCall("c4", "edit_file", "{\\\"path\\\":\\\"src/parser.zig\\\",\\\"old\\\":\\\"MAGIC_V1\\\",\\\"new\\\":\\\"MAGIC_V1, MAGIC_V2\\\"}", &b4));
    try tResult(&s, gpa, "c4", "edited src/parser.zig \u{2014} 1 op(s) applied, file is now 2210 bytes");
    try tStep(&s, gpa, "Re-running the tests after the parseHeader fix.", tCall("c5", "run_tests", "{}", &b5));
    try tResult(&s, gpa, "c5", "All 12 tests passed.");
    return s.toOwnedSlice(gpa);
}

test "a span becomes a DAG: results hang off the step that issued them, a step depends strongly on the results it reused" {
    const gpa = tt.allocator;
    const span = try sampleSpan(gpa);
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    // 4 steps, 5 results
    var steps: usize = 0;
    var results: usize = 0;
    for (g.nodes.items) |n| switch (n.kind) {
        .step => steps += 1,
        .result => results += 1,
        else => {},
    };
    try tt.expectEqual(@as(usize, 4), steps);
    try tt.expectEqual(@as(usize, 6), results);
    try tt.expectEqual(Kind.step, g.nodes.items[g.frontier].kind);
    try tt.expectEqual(@as(u32, 4), g.nodes.items[g.frontier].round);
    // result c1 was issued by step 1 and carries its call's name and (unescaped) arguments
    const r1 = g.nodes.items[1];
    try tt.expectEqualStrings("c1", r1.id);
    try tt.expectEqualStrings("read_file", r1.name);
    try tt.expectEqualStrings("{\"path\":\"src/parser.zig\"}", r1.args);
    try tt.expectEqual(@as(u32, 0), r1.deps.items[0].to);
    // step 2 reused "parseHeader" and "MAGIC_V2" from c1 (strong) and nothing from c2 (weak)
    const s2 = g.nodes.items[3];
    var strong_to_c1 = false;
    var weak_to_c2 = false;
    for (s2.deps.items) |d| {
        if (d.to == 1 and d.w == W_USED) strong_to_c1 = true;
        if (d.to == 2 and d.w == W_WEAK) weak_to_c2 = true;
    }
    try tt.expect(strong_to_c1);
    try tt.expect(weak_to_c2);
    // the failed test run and the 404 are dead ends; the first read of parser.zig is superseded by the later edit
    // of it, and the failed run by the identical run that later passed (a stale failure must not be carried)
    try tt.expect(g.nodes.items[4].dead);
    try tt.expect(g.nodes.items[5].dead);
    try tt.expect(r1.superseded);
    try tt.expect(g.nodes.items[4].superseded);
    try tt.expect(!g.nodes.items[5].superseded); // the spec fetch was never retried
    try tt.expect(!g.nodes.items[2].superseded); // config.toml was never touched again
}

test "the critical chain is the longest weighted path back from the frontier: it follows what was actually read" {
    const gpa = tt.allocator;
    const span = try sampleSpan(gpa);
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    const chain = try g.criticalChain(gpa);
    defer gpa.free(chain);
    try tt.expectEqual(g.frontier, chain[0]);
    // frontier (r4) -> edited result c4 (it re-ran tests after "the parseHeader fix") -> step 3 -> failed run c3
    // ("parseHeader"/"MAGIC_V2") -> step 2 -> c1 -> step 1: the chain walks reads, not the bare thread
    var has_c4 = false;
    var has_c3 = false;
    var has_c1 = false;
    var has_c2 = false;
    for (chain) |i| {
        const n = g.nodes.items[i];
        if (std.mem.eql(u8, n.id, "c4")) has_c4 = true;
        if (std.mem.eql(u8, n.id, "c3")) has_c3 = true;
        if (std.mem.eql(u8, n.id, "c1")) has_c1 = true;
        if (std.mem.eql(u8, n.id, "c2")) has_c2 = true;
    }
    try tt.expect(has_c4 and has_c3 and has_c1);
    try tt.expect(!has_c2); // the config read nothing ever used is off the chain
    // what a prune must keep: live chain results only — c1 is on the chain but stale (the file was edited)
    const ids = try g.protectedIds(gpa);
    defer gpa.free(ids);
    var kept_c4 = false;
    var kept_c1 = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, "c4")) kept_c4 = true;
        if (std.mem.eql(u8, id, "c1")) kept_c1 = true;
    }
    try tt.expect(kept_c4);
    try tt.expect(!kept_c1);
}

test "NEXT carries the model's nearest words when the frontier was a bare tool call, and names that call" {
    const gpa = tt.allocator;
    var s: std.ArrayListUnmanaged(u8) = .empty;
    defer s.deinit(gpa);
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    try tStep(&s, gpa, "Reading the failing test first.", tCall("c1", "read_file", "{\\\"path\\\":\\\"testing/test_terminal.py\\\"}", &b1));
    try tResult(&s, gpa, "c1", "def test_passes(self, testdir): ...");
    try tStep(&s, gpa, "The fix works. Now add a regression test; checking the existing tests for the style.", tCall("c2", "edit_file", "{\\\"path\\\":\\\"src/_pytest/nodes.py\\\"}", &b2));
    try tResult(&s, gpa, "c2", "edited src/_pytest/nodes.py \u{2014} 1 op(s) applied, file is now 20582 bytes");
    // a model that emits a tool call with EMPTY content: the frontier has no words of its own
    try tStep(&s, gpa, "", tCall("c3", "run_python", "{\\\"code\\\":\\\"import subprocess; print(subprocess.run(['git','grep','-n','chdir','--','testing/']))\\\"}", &b3));
    try tResult(&s, gpa, "c3", "exit=0 stdout: testing/test_terminal.py:660: old = p1.dirpath().chdir()");
    var g = try Graph.fromSpan(gpa, s.items);
    defer g.deinit();
    const net = try g.unfold(gpa, 1400, "");
    defer gpa.free(net);
    // the stated intention first, then the call it had gone on to make — never the call alone
    try tt.expect(std.mem.startsWith(u8, net, "NEXT (the frontier, in its own last words): The fix works. Now add a regression test; checking the existing tests for the style. \u{2014} it had then called run_python "));
    try tt.expect(std.mem.indexOf(u8, net, "'git','grep'") != null);
    // a frontier whose call followed NOTHING said within reach still names the call, as before
    var bare: std.ArrayListUnmanaged(u8) = .empty;
    defer bare.deinit(gpa);
    var b4: [256]u8 = undefined;
    try tStep(&bare, gpa, "", tCall("c9", "run_tests", "{}", &b4));
    try tResult(&bare, gpa, "c9", "All 12 tests passed.");
    var g2 = try Graph.fromSpan(gpa, bare.items);
    defer g2.deinit();
    const net2 = try g2.unfold(gpa, 1400, "");
    defer gpa.free(net2);
    try tt.expect(std.mem.startsWith(u8, net2, "NEXT (the frontier, in its own last words): it had just called run_tests {}"));
}

test "the unfolding carries the frontier's words, the failures, and the chain in tree order, once each, under budget" {
    const gpa = tt.allocator;
    const span = try sampleSpan(gpa);
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    const net = try g.unfold(gpa, 1400, "ENGINE GROUND TRUTH: src/parser.zig (edited this turn)");
    defer gpa.free(net);
    try tt.expect(net.len <= 1400);
    try tt.expect(std.mem.startsWith(u8, net, "NEXT (the frontier, in its own last words): Re-running the tests after the parseHeader fix."));
    try tt.expect(std.mem.indexOf(u8, net, "ON DISK: ENGINE GROUND TRUTH: src/parser.zig") != null);
    try tt.expect(std.mem.indexOf(u8, net, "RULED OUT") != null);
    // the 404 that was never retried is carried as a dead end; the failed run that a later identical run
    // superseded is NOT — "the tests fail" stopped being true
    try tt.expect(std.mem.indexOf(u8, net, "r2 fetch_json") != null);
    try tt.expect(std.mem.indexOf(u8, net, "-> ERROR: 404 not found") != null);
    try tt.expect(std.mem.indexOf(u8, net, "ERROR: 2 tests failed") == null);
    try tt.expect(std.mem.indexOf(u8, net, "ESTABLISHED") != null);
    try tt.expect(std.mem.indexOf(u8, net, "r4 run_tests {}: All 12 tests passed.") != null);
    try tt.expect(std.mem.indexOf(u8, net, "r3 edit_file") != null);
    // the stale first read is not carried; the never-used config read is far and small, so it may ride — but once
    try tt.expect(std.mem.indexOf(u8, net, "MAGIC_V2 = 0x7f45") == null);
    try tt.expect(std.mem.count(u8, net, "port = 8787") <= 1);
    try tt.expectEqual(@as(usize, 1), std.mem.count(u8, net, "All 12 tests passed."));
    // a tight budget keeps NEXT and drops the rest before it drops NEXT
    const tight = try g.unfold(gpa, 320, "");
    defer gpa.free(tight);
    try tt.expect(tight.len <= 320);
    try tt.expect(std.mem.startsWith(u8, tight, "NEXT"));
    // nothing to carry renders nothing, so the caller can fall back
    var empty = try Graph.fromSpan(gpa, "");
    defer empty.deinit();
    const none = try empty.unfold(gpa, 1400, "");
    defer gpa.free(none);
    try tt.expectEqual(@as(usize, 0), none.len);
}

test "the readers: raw JSON strings, failure shapes, distinctive tokens" {
    try tt.expectEqualStrings("tool", jsonStr("{\"role\":\"tool\",\"content\":\"\\\"role\\\":\\\"x\\\"\"}", "role"));
    try tt.expectEqualStrings("c9", jsonStr("{\"role\":\"tool\",\"tool_call_id\":\"c9\",\"content\":\"a\"}", "tool_call_id"));
    try tt.expectEqualStrings("", jsonStr("{\"back\":true}", "path"));
    try tt.expect(looksDead("ERROR: no such tool"));
    try tt.expect(looksDead("(NOT executed: cut off)"));
    try tt.expect(looksDead("python: Traceback (most recent call last) ..."));
    try tt.expect(!looksDead("All 12 tests passed."));
    try tt.expect(!looksDead("the word error appears in this file's prose far from the start ...................................................................................................................................................................................................................................................................................................................................... error"));
    var buf: [16][]const u8 = undefined;
    const n = distinctiveTokens("Fix parseHeader in src/parser.zig because MAGIC_V2 should be accepted; the result was wrong", &buf);
    const toks = buf[0..n];
    var saw_fn = false;
    var saw_path = false;
    var saw_common = false;
    for (toks) |t| {
        if (std.mem.eql(u8, t, "parseHeader")) saw_fn = true;
        if (std.mem.eql(u8, t, "src/parser.zig")) saw_path = true;
        if (std.mem.eql(u8, t, "because") or std.mem.eql(u8, t, "should") or std.mem.eql(u8, t, "result")) saw_common = true;
    }
    try tt.expect(saw_fn and saw_path and !saw_common);
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try tt.expectEqualStrings("one two", try excerpt(arena.allocator(), "one\\n\\n  two", 100));
    const cut = try excerpt(arena.allocator(), "alpha beta gamma delta epsilon", 14);
    try tt.expectEqualStrings("alpha beta...", cut);
}

/// `{"path":"pkg/records.py"` escaped for a call's arguments, left open for the window keys.
const T_REC = "{\\\"path\\\":\\\"pkg/records.py\\\"";

/// A read_file window as readFile answers it in a chat, escaped for the span: the `[lines A-B of N]` header, then one
/// line per line number opening with its hashline tag (`N:abc:def→`; the letters are fixed, the net reads only the
/// number), each carrying a token no other line has (`word`_N). engine.zig's test of the same reads drives the real
/// readFile, so these stand-ins cannot drift from what it renders unnoticed.
fn tWindow(gpa: std.mem.Allocator, first: u32, last: u32, total: u32) ![]u8 {
    return tWindowOf(gpa, first, last, total, "rec");
}
fn tWindowOf(gpa: std.mem.Allocator, first: u32, last: u32, total: u32, word: []const u8) ![]u8 {
    var s: std.ArrayListUnmanaged(u8) = .empty;
    errdefer s.deinit(gpa);
    try s.print(gpa, "[lines {d}-{d} of {d}]\\n", .{ first, last, total });
    try tLines(&s, gpa, first, last, word);
    return s.toOwnedSlice(gpa);
}
fn tLines(s: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, first: u32, last: u32, word: []const u8) !void {
    var i = first;
    while (i <= last) : (i += 1) try s.print(gpa, "{d}:abc:def\u{2192}    output_field = {s}_{d}.field(col)\\n", .{ i, word, i });
}

/// Is `id` on the protect list a prune honours?
fn tProtected(gpa: std.mem.Allocator, g: *const Graph, id: []const u8) !bool {
    const ids = try g.protectedIds(gpa);
    defer gpa.free(ids);
    for (ids) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

/// One call per round, then a frontier note. `rounds[k]` is the tool name, its escaped arguments and its escaped
/// result; the ids run r1, r2, ...
fn tRounds(gpa: std.mem.Allocator, rounds: []const [3][]const u8) ![]u8 {
    var s: std.ArrayListUnmanaged(u8) = .empty;
    errdefer s.deinit(gpa);
    for (rounds, 1..) |r, k| {
        var idb: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&idb, "r{d}", .{k}) catch unreachable;
        var cb: [512]u8 = undefined;
        try tStep(&s, gpa, "Reading output_field where it is built.", tCall(id, r[0], r[1], &cb));
        try tResult(&s, gpa, id, r[2]);
    }
    try s.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":\"The fix assigns the replace() result back into output_field.\"}");
    return s.toOwnedSlice(gpa);
}

fn tResultNode(g: *const Graph, id: []const u8) !Node {
    for (g.nodes.items) |n| if (n.kind == .result and std.mem.eql(u8, n.id, id)) return n;
    return error.NoSuchResult;
}

/// Is the first call's result stale once the second one has run?
fn tStaleAfter(gpa: std.mem.Allocator, first: [3][]const u8, second: [3][]const u8) !bool {
    const span = try tRounds(gpa, &.{ first, second });
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    return (try tResultNode(&g, "r1")).superseded;
}

test "reading another region of a file leaves the earlier read live: the frontier's evidence stays protected and carried" {
    const gpa = tt.allocator;
    const site = try tWindow(gpa, 1230, 1290, 1500);
    defer gpa.free(site);
    const other = try tWindow(gpa, 820, 845, 1500);
    defer gpa.free(other);
    const span = try tRounds(gpa, &.{
        .{ "read_file", T_REC ++ ",\\\"start_line\\\":1230,\\\"end_line\\\":1290}", site },
        .{ "read_file", T_REC ++ ",\\\"start_line\\\":820,\\\"end_line\\\":845}", other },
    });
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    const r1 = try tResultNode(&g, "r1");
    // the window came from the call's own arguments
    try tt.expectEqual(@as(u64, 1230), r1.lines.first);
    try tt.expectEqual(@as(u64, 1290), r1.lines.last);
    try tt.expect(!r1.superseded);
    // the second step reused its output_field, so the frontier rests on it and a prune must leave it alone ...
    try tt.expect(try tProtected(gpa, &g, "r1"));
    // ... and the carry brings its lines along with the later read's
    const net = try g.unfold(gpa, 1400, "");
    defer gpa.free(net);
    try tt.expect(std.mem.indexOf(u8, net, "1230:abc:def\u{2192} output_field = rec_1230") != null);
    try tt.expect(std.mem.indexOf(u8, net, "820:abc:def\u{2192} output_field = rec_820") != null);
}

test "a later read stales an earlier one only when it shows all of it; a write, edit or delete that landed stales every earlier result on the path" {
    const gpa = tt.allocator;
    const site = try tWindow(gpa, 1230, 1290, 1500);
    defer gpa.free(site);
    const at_site = [3][]const u8{ "read_file", T_REC ++ ",\\\"start_line\\\":1230,\\\"end_line\\\":1290}", site };
    // the same window again, keys in another order (so not an identical call: the window rule decides)
    try tt.expect(try tStaleAfter(gpa, at_site, .{ "read_file", "{\\\"end_line\\\":1290,\\\"start_line\\\":1230,\\\"path\\\":\\\"pkg/records.py\\\"}", site }));
    // a wider window shows it all, in either spelling readFile accepts
    const wider = try tWindow(gpa, 1200, 1300, 1500);
    defer gpa.free(wider);
    try tt.expect(try tStaleAfter(gpa, at_site, .{ "read_file", T_REC ++ ",\\\"start_line\\\":1200,\\\"end_line\\\":1300}", wider }));
    try tt.expect(try tStaleAfter(gpa, at_site, .{ "read_file", T_REC ++ ",\\\"offset\\\":1200,\\\"limit\\\":101}", wider }));
    // a window inside it does not
    const inside = try tWindow(gpa, 1240, 1250, 1500);
    defer gpa.free(inside);
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "read_file", T_REC ++ ",\\\"start_line\\\":1240,\\\"end_line\\\":1250}", inside })));
    // a whole-file read of a file small enough to show whole covers any window of it ...
    const small_window = try tWindow(gpa, 10, 20, 40);
    defer gpa.free(small_window);
    var small_whole: std.ArrayListUnmanaged(u8) = .empty;
    defer small_whole.deinit(gpa);
    try tLines(&small_whole, gpa, 1, 40, "rec");
    try tt.expect(try tStaleAfter(gpa, .{ "read_file", "{\\\"path\\\":\\\"small.py\\\",\\\"start_line\\\":10,\\\"end_line\\\":20}", small_window }, .{ "read_file", "{\\\"path\\\":\\\"small.py\\\"}", small_whole.items }));
    // ... and so does it a window whose arguments were clipped past their excerpt cap (an unknown window), by the
    // lines that window's own tags say it showed
    const long_args = "{\\\"path\\\":\\\"small.py\\\",\\\"start_line\\\":10,\\\"end_line\\\":20,\\\"why\\\":\\\"the loop that fills output_field is the one the failing test exercises, so read it and only it this time round, then patch the assignment it makes\\\"}";
    {
        const span = try tRounds(gpa, &.{ .{ "read_file", long_args, small_window }, .{ "read_file", "{\\\"path\\\":\\\"small.py\\\"}", small_whole.items } });
        defer gpa.free(span);
        var g = try Graph.fromSpan(gpa, span);
        defer g.deinit();
        const r1 = try tResultNode(&g, "r1");
        try tt.expect(!r1.lines.known);
        try tt.expect(r1.superseded);
    }
    // ... but of a big one it is the HEAD (readFile clips the view): on paper it covers every line, in its bytes
    // it shows none of these
    var head: std.ArrayListUnmanaged(u8) = .empty;
    defer head.deinit(gpa);
    try tLines(&head, gpa, 1, 200, "rec");
    try head.appendSlice(gpa, "[...view clipped: showing the first 8000 of 52000 bytes. The file on disk is WHOLE.]");
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "read_file", T_REC ++ "}", head.items })));
    // and so is a wider window that stopped short of it
    var short: std.ArrayListUnmanaged(u8) = .empty;
    defer short.deinit(gpa);
    try short.appendSlice(gpa, "[lines 1200-1400 of 1500]\\n");
    try tLines(&short, gpa, 1200, 1240, "rec");
    try short.appendSlice(gpa, "[...window clipped at line 1240 - narrow your range]\\n");
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "read_file", T_REC ++ ",\\\"start_line\\\":1200,\\\"end_line\\\":1400}", short.items })));
    // a read that failed is replaced by the first later read that worked, never the other way round
    const failed = [3][]const u8{ "read_file", T_REC ++ ",\\\"start_line\\\":1230,\\\"end_line\\\":1291}", "ERROR: could not read the file" };
    try tt.expect(try tStaleAfter(gpa, failed, at_site));
    try tt.expect(!(try tStaleAfter(gpa, at_site, failed)));
    // any change to the path that landed stales every earlier result on it, its reads included ...
    const edited = [3][]const u8{ "edit_file", T_REC ++ ",\\\"ops\\\":[]}", "edited pkg/records.py \u{2014} 1 op(s) applied, file is now 52001 bytes" };
    try tt.expect(try tStaleAfter(gpa, at_site, edited));
    try tt.expect(try tStaleAfter(gpa, at_site, .{ "write_file", T_REC ++ ",\\\"content\\\":\\\"x\\\"}", "wrote pkg/records.py \u{2014} file is now 1 bytes" }));
    try tt.expect(try tStaleAfter(gpa, at_site, .{ "delete_file", T_REC ++ "}", "deleted pkg/records.py" }));
    // and so does one whose answer the prune has since stubbed: it can no longer say it failed
    try tt.expect(try tStaleAfter(gpa, at_site, .{ "edit_file", T_REC ++ ",\\\"ops\\\":[]}", PRUNED_STUB ++ " from the working context (3 KB): the assistant already read and acted on it.]" }));
    // ... while a later read of the file leaves the record of the change standing
    try tt.expect(!(try tStaleAfter(gpa, edited, at_site)));
    // A change that was REFUSED left the file as the read saw it, so the read stays live: the tag guard's rejection,
    // a stale anchor, an engine refusal, a delete of nothing
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "edit_file", T_REC ++ ",\\\"ops\\\":[]}", "edit REJECTED (nothing was changed) \u{2014} your `replace` text carries anchor tags (`42:abc:def\u{2192}`)." })));
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "edit_file", T_REC ++ ",\\\"ops\\\":[]}", "op1: anchor \\\"abc:def\\\" is a line tag with its LINE NUMBER dropped, and its hashes match no line in pkg/records.py as it is now \u{2014} that line changed since you read it. Nothing was modified." })));
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "write_file", T_REC ++ ",\\\"content\\\":\\\"x\\\"}", "(NOT executed: this turn's write budget is spent)" })));
    try tt.expect(!(try tStaleAfter(gpa, at_site, .{ "delete_file", T_REC ++ "}", "could not delete (not found?)" })));
}

test "a re-read stales the earlier view by its line numbers, even after the file changed outside the file tools" {
    const gpa = tt.allocator;
    // read the bug site, patch it with run_python (no file tool: the net sees no write), re-read a wider window
    const site = try tWindow(gpa, 1230, 1290, 1500);
    defer gpa.free(site);
    const patched = try tWindowOf(gpa, 1200, 1300, 1500, "fixed");
    defer gpa.free(patched);
    const rounds = [_][3][]const u8{
        .{ "read_file", T_REC ++ ",\\\"start_line\\\":1230,\\\"end_line\\\":1290}", site },
        .{ "run_python", "{\\\"code\\\":\\\"patch()\\\"}", "patched 61 lines of pkg/records.py" },
        .{ "read_file", T_REC ++ ",\\\"start_line\\\":1200,\\\"end_line\\\":1300}", patched },
    };
    const span = try tRounds(gpa, &rounds);
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    // the newer view shows lines 1230-1290 again, as they are NOW: the pre-change view is stale, off the protect
    // list, and out of the carry, which holds the current lines only
    try tt.expect((try tResultNode(&g, "r1")).superseded);
    try tt.expect(!(try tProtected(gpa, &g, "r1")));
    const net = try g.unfold(gpa, 4000, "");
    defer gpa.free(net);
    try tt.expect(std.mem.indexOf(u8, net, "fixed_1200") != null);
    try tt.expect(std.mem.indexOf(u8, net, "rec_1230") == null);
    // An untagged view (a read outside the workdir) has no numbers, so only its bytes can show it: the change
    // between the reads keeps both views live. Pinned so the fallback stays the conservative one.
    const plain_site = "[lines 1230-1231 of 1500]\\n    output_field = rec_1230.field(col)\\n    output_field = rec_1231.field(col)\\n";
    const plain_patched = "[lines 1230-1231 of 1500]\\n    output_field = fixed_1230.field(col)\\n    output_field = fixed_1231.field(col)\\n";
    const plain_args = "{\\\"path\\\":\\\"C:/ext/records.py\\\",\\\"start_line\\\":1230,\\\"end_line\\\":1231}";
    try tt.expect(!(try tStaleAfter(gpa, .{ "read_file", plain_args, plain_site }, .{ "read_file", "{\\\"start_line\\\":1230,\\\"end_line\\\":1231,\\\"path\\\":\\\"C:/ext/records.py\\\"}", plain_patched })));
    try tt.expect(try tStaleAfter(gpa, .{ "read_file", plain_args, plain_site }, .{ "read_file", "{\\\"start_line\\\":1230,\\\"end_line\\\":1231,\\\"path\\\":\\\"C:/ext/records.py\\\"}", plain_site }));
    // ... and its own `[lines A-B of N]` header is not file text, so a whole-file view can show an untagged window
    // even when the window's arguments were clipped past their excerpt cap
    const small_plain = "[lines 2-3 of 4]\\nbeta = 2\\ngamma = 3\\n";
    const small_args = "{\\\"path\\\":\\\"C:/ext/small.ini\\\",\\\"start_line\\\":2,\\\"end_line\\\":3,\\\"why\\\":\\\"the two settings the failing import reads before anything else runs, and nothing past them this time, since the rest of the file is comments\\\"}";
    const span_ini = try tRounds(gpa, &.{ .{ "read_file", small_args, small_plain }, .{ "read_file", "{\\\"path\\\":\\\"C:/ext/small.ini\\\"}", "alpha = 1\\nbeta = 2\\ngamma = 3\\ndelta = 4\\n" } });
    defer gpa.free(span_ini);
    var g2 = try Graph.fromSpan(gpa, span_ini);
    defer g2.deinit();
    const r1 = try tResultNode(&g2, "r1");
    try tt.expect(!r1.lines.known);
    try tt.expect(r1.superseded);
}

test "a read whose own lines read like an error is still a read: not a dead end, not staled by another region" {
    const gpa = tt.allocator;
    // the bug site's first line raises; looksDead alone reads that excerpt as a failed call
    var site: std.ArrayListUnmanaged(u8) = .empty;
    defer site.deinit(gpa);
    try site.appendSlice(gpa, "[lines 1230-1290 of 1500]\\n1230:abc:def\u{2192}        raise KeyError(name + ' not found in registry')\\n");
    try tLines(&site, gpa, 1231, 1290, "rec");
    try tt.expect(looksDead("[lines 1230-1290 of 1500] 1230:abc:def\u{2192} raise KeyError(name + ' not found in registry')"));
    const other = try tWindow(gpa, 820, 845, 1500);
    defer gpa.free(other);
    const span = try tRounds(gpa, &.{
        .{ "read_file", T_REC ++ ",\\\"start_line\\\":1230,\\\"end_line\\\":1290}", site.items },
        .{ "read_file", T_REC ++ ",\\\"start_line\\\":820,\\\"end_line\\\":845}", other },
    });
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    const r1 = try tResultNode(&g, "r1");
    try tt.expect(!r1.dead);
    try tt.expect(!r1.superseded);
    try tt.expect(try tProtected(gpa, &g, "r1"));
    // carried as what the frontier rests on, never as a call that failed
    const net = try g.unfold(gpa, 4000, "");
    defer gpa.free(net);
    try tt.expect(std.mem.indexOf(u8, net, "not found in registry") != null);
    try tt.expect(std.mem.indexOf(u8, net, "RULED OUT") == null);
    // a read that showed no file at all is still the dead end it was
    const gone = try tRounds(gpa, &.{.{ "read_file", T_REC ++ "}", "not found" }});
    defer gpa.free(gone);
    var g2 = try Graph.fromSpan(gpa, gone);
    defer g2.deinit();
    try tt.expect((try tResultNode(&g2, "r1")).dead);
}

test "a line a view cut short is not a line it shows" {
    const gpa = tt.allocator;
    // a wide window the engine elided in the middle (head + notice + tail, both cuts mid-line), as clipToolResult
    // leaves a result past 10 KB
    var cut: std.ArrayListUnmanaged(u8) = .empty;
    defer cut.deinit(gpa);
    try cut.appendSlice(gpa, "[lines 1200-1400 of 1500]\\n");
    try tLines(&cut, gpa, 1200, 1224, "rec");
    try cut.appendSlice(gpa, "1225:abc:def\u{2192}    output_fi\\n...[9000 bytes elided from the middle of this tool result]...\\neld = rec_1380.field(col)\\n");
    try tLines(&cut, gpa, 1381, 1400, "rec");
    const wide = [3][]const u8{ "read_file", T_REC ++ ",\\\"start_line\\\":1200,\\\"end_line\\\":1400}", cut.items };
    const Case = struct { first: u32, last: u32, stale: bool };
    for ([_]Case{
        .{ .first = 1210, .last = 1220, .stale = true }, // shown whole in the head
        .{ .first = 1381, .last = 1400, .stale = true }, // and in the tail
        .{ .first = 1225, .last = 1225, .stale = false }, // the line the head's cut ran through
        .{ .first = 1380, .last = 1380, .stale = false }, // the line the tail starts inside
        .{ .first = 1230, .last = 1290, .stale = false }, // elided
        .{ .first = 1220, .last = 1385, .stale = false }, // across the elision
    }) |c| {
        const older = try tWindow(gpa, c.first, c.last, 1500);
        defer gpa.free(older);
        var ab: [128]u8 = undefined;
        const args = try std.fmt.bufPrint(&ab, "{s},\\\"start_line\\\":{d},\\\"end_line\\\":{d}}}", .{ T_REC, c.first, c.last });
        try tt.expectEqual(c.stale, try tStaleAfter(gpa, .{ "read_file", args, older }, wide));
    }
}

test "a read's window is read from its arguments the way readFile resolves them, and unknown is never guessed" {
    const whole = Lines.of("{\"path\":\"a.py\"}");
    try tt.expect(whole.known and !whole.windowed and whole.first == 1 and whole.last == std.math.maxInt(u64));
    const win = Lines.of("{\"path\":\"a.py\", \"start_line\": 12, \"end_line\": 40}");
    try tt.expect(win.known and win.windowed and win.first == 12 and win.last == 40);
    const open = Lines.of("{\"path\":\"a.py\",\"start_line\":200}");
    try tt.expect(open.windowed and open.first == 200 and open.last == std.math.maxInt(u64));
    const ol = Lines.of("{\"path\":\"a.py\",\"offset\":5,\"limit\":10}");
    try tt.expect(ol.windowed and ol.first == 5 and ol.last == 14);
    // readFile ignores a limit with no start: that is the whole file
    try tt.expect(!Lines.of("{\"path\":\"a.py\",\"limit\":10}").windowed);
    // a bound is read the way readFile's std.json parse reads its usize field: a quoted number and an integral
    // float are that line (readFile serves them), ...
    const quoted = Lines.of("{\"path\":\"a.py\",\"start_line\":\"12\",\"end_line\":\"40\"}");
    try tt.expect(quoted.known and quoted.first == 12 and quoted.last == 40);
    const float = Lines.of("{\"path\":\"a.py\",\"start_line\":1230.0,\"end_line\":1.29e3}");
    try tt.expect(float.known and float.first == 1230 and float.last == 1290);
    // ... while one std.json refuses (readFile answers "bad args"), or arguments clipped past their excerpt cap, stay
    // unknown
    const unknown = Lines.of("{\"path\":\"a/very/long/path.py\",\"start_l...");
    try tt.expect(!unknown.known);
    try tt.expect(!Lines.of("{\"path\":\"a.py\",\"start_line\":1.5}").known);
    try tt.expect(!Lines.of("{\"path\":\"a.py\",\"start_line\":-3}").known);
    try tt.expect(!Lines.of("{\"path\":\"a.py\",\"start_line\":\"twelve\"}").known);
    try tt.expect(!Lines.of("{\"path\":\"a.py\",\"start_line\":null}").known);
    // a whole-file window holds any window, an unknown one holds nothing and only a whole-file one holds it
    try tt.expect(whole.contains(win) and whole.contains(unknown));
    try tt.expect(!win.contains(whole) and !win.contains(unknown) and !unknown.contains(win));
    try tt.expect(win.contains(Lines.of("{\"start_line\":12,\"end_line\":40}")) and !win.contains(open));
}
