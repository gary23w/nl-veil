//! GARY'S 4TOPE — the conversation's working span as a dependency graph, and the continuation as its unfolding.
//!
//! Conversation context is captured and retrieved directly.
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
//! Conversation context is captured and retrieved directly.
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
//! round; a step depends on the step before it (the model's own thread). A later read or write of the same file,
//! or an identical call, SUPERSEDES the earlier result; a result that reads as an error is a DEAD END. Superseded
//! results are stale and are neither protected nor carried; dead ends are carried under RULED OUT, which is the
//! negative knowledge a paraphrase forgets and a retrieval must be told about.
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
    /// the message content, unescaped, one line: a result's PAYLOAD (payloadOf) kept head and tail to RESULT_KEEP,
    /// a step's or note's words to NEXT_MAX. The net renders a result at this length only when it is on the
    /// critical chain; everything else is clipped to EXCERPT_MAX at render time (see `shown`).
    text: []const u8 = "",
    /// the round (step index) this message belongs to
    round: u32 = 0,
    deps: std.ArrayListUnmanaged(Dep) = .empty,
    superseded: bool = false,
    dead: bool = false,
    /// bytes this message occupies in the span (for the budget)
    bytes: usize = 0,
    /// byte offset of this message in the span it was read from, so a caller folding a span can say which nodes
    /// sit in the tail it keeps verbatim (Opts.tail_from)
    at: usize = 0,
};

/// How much of one message the net carries when it is NOT on the critical chain. Enough for a path and the line
/// that matters; a 10 KB file read the frontier never leaned on is a stub pointing at a file the next segment can
/// read again.
pub const EXCERPT_MAX: usize = 240;
/// ...and of the frontier's last words, which are the one thing worth more room.
pub const NEXT_MAX: usize = 700;
/// How much of a result the graph KEEPS, and the critical chain carries: head and tail, one line. 240 bytes was
/// the whole allowance before this existed, and on the first long chat it was measured against (conv c477179e8,
/// 2026-10-14) every ESTABLISHED line was the first 240 bytes of a shell tool's JSON envelope — cursor, done_by,
/// an empty output field — and none of the output the model had actually read. The tots keep a chain result to
/// 3000 (cloud/tot.js PROTECT_MAX); the same figure here.
pub const RESULT_KEEP: usize = 3000;
/// How much of a raw result is unescaped to find its payload. Results append to the span elided past
/// TOOL_RESULT_KEEP (10 KB), so this reads a whole one.
const RESULT_SCAN: usize = 16 * 1024;
/// How much of an earlier fold's note or carry row earlierLines reads.
const EARLIER_SCAN: usize = 64 * 1024;

/// What introduces the fold note compactWorking writes by the net (the engine's counterpart of cloud/tot.js
/// NET_HEAD): the note is an assistant message in the span, so it must say what it is — an engine layout of tool
/// results, not the assistant's own words — and earlierLines finds a previous fold by this head.
pub const NET_NOTE_HEAD = "CONTINUATION (Gary's 4tope: the earlier rounds of this turn, laid out from where the work stands; every line below is verbatim from a tool result, so nothing here is a paraphrase):\n";
/// The start of NET_NOTE_HEAD, as earlierLines matches it in the span's escaped bytes.
pub const NET_MARK = "CONTINUATION (Gary's 4tope";
/// What the engine's continuation row (the carry at the spend ceiling) always contains, so earlierLines finds a
/// previous pass's carry the same way. The engine pins its header to this with a test.
pub const CARRY_MARK = "CONTINUATION STATE";
/// What introduces the lines an earlier fold or carry established, when a later net carries them on.
pub const EARLIER_HEAD = "EARLIER (established by the fold or pass before this one; failed calls first):\n";
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
        // pass 1: the nodes, in order (which is a topological order: every edge points at an older node)
        var round: u32 = 0;
        var at: usize = 0;
        const marker = "{\"role\":\"";
        while (std.mem.indexOfPos(u8, span, at, marker)) |start| {
            const next = std.mem.indexOfPos(u8, span, start + marker.len, "," ++ marker) orelse span.len;
            const obj = span[start..next];
            at = next;
            const role = jsonStr(obj, "role");
            var n: Node = .{ .kind = .engine, .bytes = obj.len, .at = start };
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
                n.text = try g.resultText(a, raw);
                n.dead = looksDead(n.text);
                n.round = round;
                // name/args from the issuing step's call list
                if (g.callOf(n.id)) |c| {
                    n.name = c.name;
                    n.args = c.args;
                    try n.deps.append(gpa, .{ .to = c.step, .w = W_ISSUED });
                }
            } else {
                n.kind = .engine;
                n.text = try excerpt(a, jsonStr(obj, "content"), EXCERPT_MAX);
                n.round = round;
            }
            try g.nodes.append(gpa, n);
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
        g.markSuperseded();
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

    /// A later read or write of the same file, or an identical call, makes the earlier result stale.
    fn markSuperseded(g: *Graph) void {
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
                if (path.len > 0 and isFileTool(newer.name) and std.mem.eql(u8, jsonStr(newer.args, "path"), path)) {
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
        return g.unfoldWith(gpa, budget, ground, .{});
    }

    /// How a net is unfolded beyond the defaults: the tail a fold keeps verbatim, what introduces the frontier's
    /// words, and the lines an earlier fold or carry established.
    pub const Opts = struct {
        /// nodes from this index on are the caller's verbatim tail: never carried (they ride whole after the
        /// note), still part of the distances the rest is chosen by
        tail_from: u32 = NONE,
        /// what introduces the frontier's own last words
        next_label: []const u8 = "NEXT (the frontier, in its own last words): ",
        /// earlierLines of the span this unfolds, carried under EARLIER inside the budget (at most a third of it,
        /// whole lines) — what cloud/tot.js carries the same way, so a second fold or a later pass keeps what the
        /// first established instead of knowing only its own rounds
        earlier: []const u8 = "",
    };

    /// unfold with Opts. The critical chain's results render at RESULT_KEEP (what the frontier rests on is the
    /// part worth bytes); every other result is clipped to EXCERPT_MAX with a "..." mark.
    pub fn unfoldWith(g: *Graph, gpa: std.mem.Allocator, budget: usize, ground: []const u8, opts: Opts) ![]u8 {
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
        // THE CRITICAL CHAIN rides at length; everything else is an excerpt
        const on_chain = try gpa.alloc(bool, n);
        defer gpa.free(on_chain);
        @memset(on_chain, false);
        {
            const chain = try g.criticalChain(gpa);
            defer gpa.free(chain);
            for (chain) |i| on_chain[i] = true;
        }
        // SELECT in distance order under the budget: NEXT, ON DISK and EARLIER are reserved first (NEXT gets at
        // most a third, ON DISK a quarter, EARLIER a third, and the section headers their room)
        const next_text = clipWords(g.nodes.items[g.frontier].text, @max(80, budget / 3));
        const earlier = clipLines(opts.earlier, budget / 3);
        var spent: usize = opts.next_label.len + next_text.len + 8 + @min(ground.len, budget / 4) + 200;
        if (earlier.len > 0) spent += EARLIER_HEAD.len + earlier.len + 1;
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
            // the caller's verbatim tail rides whole after the note: never carried twice
            if (i >= opts.tail_from) continue;
            // steps are the model's narration — their decisions show in what they then called, and the
            // frontier's own words are NEXT; a note rides only when it is a distillation (a fold note), and a
            // note the net itself wrote is carried by earlierLines, never as a node
            if (i == g.frontier or node.kind == .user or node.kind == .engine or node.kind == .step or node.superseded) continue;
            if (node.kind == .note and (!isDistillation(node.text) or isNetNote(node.text))) continue;
            if (node.kind == .result and node.text.len == 0) continue;
            const s = shown(node, on_chain[i]);
            const cost = s.text.len + @as(usize, if (s.more) 3 else 0) + node.name.len + node.args.len + 24;
            if (spent + cost > budget) continue;
            spent += cost;
            chosen[i] = true;
        }
        // LAY OUT: NEXT (the frontier's own words), ON DISK, RULED OUT (dead ends, nearest first), then
        // ESTABLISHED in shortest-path-tree order — a depth-first walk from the frontier, children by distance —
        // and EARLIER last
        try out.appendSlice(gpa, opts.next_label);
        if (next_text.len > 0) {
            try out.appendSlice(gpa, next_text);
        } else if (g.lastCallsOf(g.frontier)) |calls| {
            try out.appendSlice(gpa, "it had just called ");
            try out.appendSlice(gpa, calls);
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
            try g.line(gpa, &out, i, on_chain[i]);
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
                try g.line(gpa, &out, u, on_chain[u]);
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
        if (earlier.len > 0) {
            try out.appendSlice(gpa, EARLIER_HEAD);
            try out.appendSlice(gpa, earlier);
            try out.append(gpa, '\n');
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

    /// One carried node as a line; a result `full` (the critical chain) renders all it kept, else an excerpt.
    fn line(g: *const Graph, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), i: u32, full: bool) !void {
        const node = g.nodes.items[i];
        switch (node.kind) {
            .result => {
                try out.print(gpa, "- r{d} {s}", .{ node.round, if (node.name.len > 0) node.name else "tool" });
                if (node.args.len > 0) try out.print(gpa, " {s}", .{node.args});
                try out.appendSlice(gpa, if (node.dead) " -> " else ": ");
                const s = shown(node, full);
                try out.appendSlice(gpa, s.text);
                if (s.more) try out.appendSlice(gpa, "...");
                try out.append(gpa, '\n');
            },
            .step, .note => {
                try out.print(gpa, "- r{d} note: {s}\n", .{ node.round, node.text });
            },
            else => {},
        }
    }

    /// A result's text for the graph: its payload (payloadOf), unescaped, one line, head and tail to RESULT_KEEP.
    /// The whole result is unescaped into scratch (g.gpa) to find the payload; only what is kept lands in the
    /// arena, so a span of a hundred 10 KB results costs the graph three hundred KB, not a megabyte.
    fn resultText(g: *Graph, a: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const full = try unescapeAlloc(g.gpa, raw, RESULT_SCAN, false);
        defer g.gpa.free(full);
        const pay = payloadOf(full);
        if (pay.ptr == full.ptr and pay.len == full.len) return try keepEnds(a, full, RESULT_KEEP);
        // the payload is a JSON string VALUE inside the result: one more level of escaping to strip
        const inner = try unescapeAlloc(g.gpa, pay, RESULT_SCAN, false);
        defer g.gpa.free(inner);
        return try keepEnds(a, inner, RESULT_KEEP);
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
    var kb: [48]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return "";
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
    return "";
}

/// Unescape a raw JSON string as the span holds it, into an `a`-owned buffer of at most `max` bytes: `\r` and
/// `\t` become one space, `\n` too unless `newlines` keeps it, `\uXXXX` a '?', every other escape the character
/// it escapes; runs of spaces collapse and a leading space is dropped. The first `max` bytes of the string, so
/// a clipped result is an honest head.
fn unescapeAlloc(a: std.mem.Allocator, raw: []const u8, max: usize, newlines: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var last_space = false;
    while (i < raw.len and out.items.len < max) : (i += 1) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => c = if (newlines) '\n' else ' ',
                't', 'r' => c = ' ',
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
    return out.toOwnedSlice(a);
}

/// Unescape a raw JSON string into the arena as ONE line, clipped to `max` at a word boundary when it is longer.
fn excerpt(a: std.mem.Allocator, raw: []const u8, max: usize) ![]const u8 {
    var s: []u8 = try unescapeAlloc(a, raw, max + 1, false);
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

/// Whole lines of `s` under `max` bytes: the cut lands on a line boundary, so a clipped list never ends mid-line;
/// nothing when not even the first line fits.
fn clipLines(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    const c = clip(s, max);
    const nl = std.mem.lastIndexOfScalar(u8, c, '\n') orelse return "";
    return c[0..nl];
}

/// What a node renders as: all it kept when `full` (the critical chain), else clipped to EXCERPT_MAX at a word,
/// with `more` saying a "..." mark belongs after it.
const Shown = struct { text: []const u8, more: bool };
fn shown(node: Node, full: bool) Shown {
    if (full or node.text.len <= EXCERPT_MAX) return .{ .text = node.text, .more = false };
    return .{ .text = clipWords(node.text, EXCERPT_MAX), .more = true };
}

/// A fold note the net itself wrote (NET_NOTE_HEAD). Never carried as a node: earlierLines carries its lines.
fn isNetNote(text: []const u8) bool {
    return std.mem.startsWith(u8, text, NET_MARK);
}

/// `s` whole when it fits `max`, else its head (two thirds) and tail (the rest) around an elision mark — the
/// shape cloud/tot.js resultExcerpt gives the tots. A command's output keeps its first lines and its last ones,
/// which is where a result says what happened. `a`-owned.
fn keepEnds(a: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return try a.dupe(u8, s);
    const head = clip(s, max * 2 / 3);
    var tail_start = s.len - (max - head.len);
    while (tail_start < s.len and (s[tail_start] & 0xC0) == 0x80) tail_start += 1;
    return try std.fmt.allocPrint(a, "{s} ...(middle omitted)... {s}", .{ std.mem.trimEnd(u8, head, " "), std.mem.trimStart(u8, s[tail_start..], " ") });
}

/// Keys a tool's envelope carries its payload under; one of these wins over an unknown key of similar size.
fn isPayloadKey(key: []const u8) bool {
    const keys = [_][]const u8{ "output", "stdout", "stderr", "content", "text", "body", "result", "data", "message", "error", "html", "markdown", "answer" };
    for (keys) |k| if (std.ascii.eqlIgnoreCase(k, key)) return true;
    return false;
}

/// The part of a result worth carrying. A tool that answers with a JSON envelope — Agent Garrett's shell tools
/// answer {"cursor":..,"output":"...","running":..} inside an EVIDENCE wrapper — keeps what the model actually
/// read in ONE string field, and the first bytes of such a result are all envelope. The longest string value is
/// the payload when it is at least half the result, or at least a quarter of it under a payload key
/// (isPayloadKey); anything else — prose, an error line, a listing whose strings are all short — is carried as
/// it is. The value comes back still escaped as the JSON string it is: the caller unescapes it once more.
pub fn payloadOf(text: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, text, " \t");
    if (t.len < 24 or (t[0] != '{' and t[0] != '[')) return text;
    var best: []const u8 = "";
    var best_known = false;
    var i: usize = 0;
    while (i + 3 < t.len) : (i += 1) {
        if (t[i] != '"') continue;
        // a string: a key when ':' follows its closing quote, a value otherwise
        const ks = i + 1;
        var ke = ks;
        while (ke < t.len and t[ke] != '"') : (ke += 1) {
            if (t[ke] == '\\') ke += 1;
        }
        if (ke >= t.len) break;
        var j = ke + 1;
        while (j < t.len and t[j] == ' ') j += 1;
        if (j >= t.len or t[j] != ':') {
            i = ke; // a value or a stray string: step past it whole
            continue;
        }
        j += 1;
        while (j < t.len and t[j] == ' ') j += 1;
        if (j >= t.len or t[j] != '"') {
            i = ke; // a number, a bool, a nested object or array: walk on into it
            continue;
        }
        const vs = j + 1;
        var ve = vs;
        while (ve < t.len and t[ve] != '"') : (ve += 1) {
            if (t[ve] == '\\') ve += 1;
        }
        const val = t[vs..@min(ve, t.len)];
        const known = isPayloadKey(t[ks..ke]);
        if (val.len > best.len or (known and !best_known and val.len * 4 >= best.len)) {
            best = val;
            best_known = known;
        }
        i = @min(ve, t.len - 1);
    }
    if (best.len * 2 >= t.len or (best_known and best.len * 4 >= t.len)) return best;
    return text;
}

/// What an earlier fold or carry in `span` established and ruled out, verbatim: every "- r" line of every net
/// note (NET_MARK) and continuation row (CARRY_MARK) in the span — assistant and system messages only — the
/// failed calls ("->") first, each line once, whole lines under `budget`. This is how a second fold keeps what
/// the first one carried and a later pass keeps what an earlier pass carried (cloud/tot.js earlierLines): the
/// net itself never selects a net note or an engine row as a node. gpa-owned; empty when the span holds none.
pub fn earlierLines(gpa: std.mem.Allocator, span: []const u8, budget: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    if (budget < 16) return out.toOwnedSlice(gpa);
    var dead: std.ArrayListUnmanaged([]u8) = .empty;
    var live: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (dead.items) |l| gpa.free(l);
        for (live.items) |l| gpa.free(l);
        dead.deinit(gpa);
        live.deinit(gpa);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    const marker = "{\"role\":\"";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, span, at, marker)) |start| {
        const next = std.mem.indexOfPos(u8, span, start + marker.len, "," ++ marker) orelse span.len;
        const obj = span[start..next];
        at = next;
        const role = jsonStr(obj, "role");
        if (!std.mem.eql(u8, role, "assistant") and !std.mem.eql(u8, role, "system")) continue;
        const raw = jsonStr(obj, "content");
        if (std.mem.indexOf(u8, raw, NET_MARK) == null and std.mem.indexOf(u8, raw, CARRY_MARK) == null) continue;
        const text = try unescapeAlloc(gpa, raw, EARLIER_SCAN, true);
        defer gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            const line = std.mem.trimEnd(u8, l, " \r");
            if (!std.mem.startsWith(u8, line, "- r")) continue;
            if (seen.contains(line)) continue;
            const owned = try gpa.dupe(u8, line);
            errdefer gpa.free(owned);
            try seen.put(gpa, owned, {});
            if (std.mem.indexOf(u8, line, " -> ") != null) try dead.append(gpa, owned) else try live.append(gpa, owned);
        }
    }
    for ([_][]const []u8{ dead.items, live.items }) |group| for (group) |l| {
        const sep: usize = if (out.items.len > 0) 1 else 0;
        if (out.items.len + sep + l.len > budget) break;
        if (sep == 1) try out.append(gpa, '\n');
        try out.appendSlice(gpa, l);
    };
    return out.toOwnedSlice(gpa);
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
    try tResult(&s, gpa, "c4", "edited src/parser.zig (1 replacement)");
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

test "payloadOf and keepEnds: an envelope's payload, a known key over an unknown one, prose untouched, both ends kept" {
    try tt.expectEqualStrings("hello there world", payloadOf("{\"ok\":true,\"output\":\"hello there world\",\"n\":1}"));
    // an envelope whose strings are all short is carried whole: a listing is not its longest filename
    const listing = "{\"files\":[\"a.zig\",\"b.zig\",\"c.zig\"],\"dir\":\"src\"}";
    try tt.expectEqualStrings(listing, payloadOf(listing));
    // a payload key wins over an unknown key of similar size
    try tt.expectEqualStrings("the real output text here", payloadOf("{\"evidenceBasis\":\"tool-reported medium confidence\",\"output\":\"the real output text here\"}"));
    try tt.expectEqualStrings("plain prose, not JSON", payloadOf("plain prose, not JSON"));
    try tt.expectEqualStrings("ERROR: 2 tests failed", payloadOf("ERROR: 2 tests failed"));
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const long = "0123456789" ** 40;
    const kept = try keepEnds(arena.allocator(), long, 100);
    try tt.expect(kept.len <= 100 + 30);
    try tt.expect(std.mem.startsWith(u8, kept, "0123456789"));
    try tt.expect(std.mem.endsWith(u8, kept, "0123456789"));
    try tt.expect(std.mem.indexOf(u8, kept, "middle omitted") != null);
    try tt.expectEqualStrings("short", try keepEnds(arena.allocator(), "short", 100));
}

test "a result carries its payload, not its envelope, and the critical chain carries it at length" {
    const gpa = tt.allocator;
    // the envelope Agent Garrett's shell tools answer with (conv c477179e8, 2026-10-14), as the span holds it: the
    // result is a JSON string whose content is itself JSON, so its quotes are escaped once more
    const listing = "total 3 notes.md 2200 bytes README.md 120 bytes install.sh 90 bytes ";
    const out_field = listing ** 12;
    var s: std.ArrayListUnmanaged(u8) = .empty;
    defer s.deinit(gpa);
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    var b4: [256]u8 = undefined;
    var b23: [512]u8 = undefined;
    try tStep(&s, gpa, "Listing the workspace first.", tCall("c1", "security_gary_shell_read", "{\\\"session_id\\\":\\\"sh_1\\\"}", &b1));
    try s.print(gpa, ",{{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"{{\\\"cursor\\\":8729,\\\"done_by\\\":\\\"prompt\\\",\\\"omitted\\\":false,\\\"output\\\":\\\"{s}\\\",\\\"running\\\":false,\\\"session_id\\\":\\\"sh_1\\\"}} EVIDENCE: {{\\\"tool\\\":\\\"gary_shell_read\\\",\\\"confidence\\\":\\\"medium\\\"}}\"}}", .{out_field});
    const readme = "README.md explains the install steps: run make install, then make check. " ** 10;
    const config = "[server] port = 8787 name = veil tunnel = quick retention_days = 30 " ** 12;
    const two = std.fmt.bufPrint(&b23, "{s},{s}", .{ tCall("c2", "read_file", "{\\\"path\\\":\\\"README.md\\\"}", &b2), tCall("c3", "read_file", "{\\\"path\\\":\\\"config.toml\\\"}", &b3) }) catch unreachable;
    try tStep(&s, gpa, "notes.md is 2200 bytes; reading README.md and config.toml next.", two);
    try tResult(&s, gpa, "c2", readme);
    try tResult(&s, gpa, "c3", config);
    try tStep(&s, gpa, "The install steps are make install then make check; writing summary.md.", tCall("c4", "write_file", "{\\\"path\\\":\\\"summary.md\\\"}", &b4));
    try tResult(&s, gpa, "c4", "wrote summary.md (210 B)");
    var g = try Graph.fromSpan(gpa, s.items);
    defer g.deinit();
    // the shell result's text is its OUTPUT, not the cursor/done_by envelope, and it is kept past 240 bytes
    const r1 = g.nodes.items[1];
    try tt.expect(std.mem.startsWith(u8, r1.text, "total 3 notes.md"));
    try tt.expect(std.mem.indexOf(u8, r1.text, "cursor") == null);
    try tt.expect(r1.text.len > EXCERPT_MAX);
    // every node knows where it sits in the span (past the joining comma), so a fold can tell its kept tail apart
    try tt.expectEqual(@as(usize, 1), g.nodes.items[0].at);
    try tt.expect(r1.at > 1 and r1.at < g.nodes.items[2].at);
    const net = try g.unfold(gpa, 6000, "");
    defer gpa.free(net);
    try tt.expect(net.len <= 6000);
    // on the chain (the next step reused "notes.md", the frontier reused "install"): the whole listing and the
    // whole README ride
    try tt.expectEqual(@as(usize, 12), std.mem.count(u8, net, "install.sh 90 bytes"));
    try tt.expectEqual(@as(usize, 10), std.mem.count(u8, net, "then make check."));
    // off the chain: the config read nothing used is an excerpt with a mark
    try tt.expect(std.mem.indexOf(u8, net, "retention_days") != null);
    try tt.expect(std.mem.count(u8, net, "retention_days = 30") < 12);
    try tt.expect(std.mem.indexOf(u8, net, "...\n") != null);
}

test "a fold keeps its tail out of the net, labels the frontier as asked, and carries EARLIER lines whole" {
    const gpa = tt.allocator;
    const span = try sampleSpan(gpa);
    defer gpa.free(span);
    var g = try Graph.fromSpan(gpa, span);
    defer g.deinit();
    // the last round (the frontier's step and its passing run) is the tail a fold keeps verbatim
    const earlier = "- r0 fetch_json {\"url\":\"x\"} -> ERROR: 500\n- r0 read_file {\"path\":\"old.md\"}: old notes about the parser, the config file and the spec page";
    const net = try g.unfoldWith(gpa, 2000, "", .{ .tail_from = g.frontier, .next_label = "LAST WORDS: ", .earlier = earlier });
    defer gpa.free(net);
    try tt.expect(std.mem.startsWith(u8, net, "LAST WORDS: Re-running the tests"));
    try tt.expect(std.mem.indexOf(u8, net, "All 12 tests passed.") == null); // in the tail, so never carried twice
    try tt.expect(std.mem.indexOf(u8, net, "r3 edit_file") != null); // before the tail: carried
    try tt.expect(std.mem.indexOf(u8, net, EARLIER_HEAD) != null);
    try tt.expect(std.mem.indexOf(u8, net, "- r0 fetch_json {\"url\":\"x\"} -> ERROR: 500\n- r0 read_file") != null);
    // EARLIER is clipped to whole lines under a third of the budget, and the budget still holds
    const tight = try g.unfoldWith(gpa, 300, "", .{ .earlier = earlier });
    defer gpa.free(tight);
    try tt.expect(tight.len <= 300);
    try tt.expect(std.mem.indexOf(u8, tight, "-> ERROR: 500") != null);
    try tt.expect(std.mem.indexOf(u8, tight, "old notes") == null);
}

test "earlierLines: a previous fold note and a previous pass's carry give up their lines, failures first, once each" {
    const gpa = tt.allocator;
    var s: std.ArrayListUnmanaged(u8) = .empty;
    defer s.deinit(gpa);
    // a fold note the net wrote (assistant), a user line that never counts, then a carry row (system) that
    // restates one of the note's lines
    try s.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":\"CONTINUATION (Gary's 4tope: the earlier rounds of this turn):\\nNEXT (the frontier, in its own last words): fixing it\\nESTABLISHED (what the frontier rests on):\\n- r2 read_file {\\\"path\\\":\\\"a.zig\\\"}: pub fn a() void\\nRULED OUT (calls that failed):\\n- r1 run_tests {} -> ERROR: 1 failed\"}");
    try s.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"- r9 not_a_tool {} -> a user line never counts\"}");
    try s.appendSlice(gpa, ",{\"role\":\"system\",\"content\":\"engine: the working context for this stretch was COMPACTED.\\n\\nCONTINUATION STATE - written by the engine\\nNEXT: run it\\nESTABLISHED:\\n- r2 read_file {\\\"path\\\":\\\"a.zig\\\"}: pub fn a() void\\n- r3 edit_file {\\\"path\\\":\\\"a.zig\\\"}: edited a.zig (1 replacement)\"}");
    const lines = try earlierLines(gpa, s.items, 4096);
    defer gpa.free(lines);
    try tt.expectEqualStrings("- r1 run_tests {} -> ERROR: 1 failed\n- r2 read_file {\"path\":\"a.zig\"}: pub fn a() void\n- r3 edit_file {\"path\":\"a.zig\"}: edited a.zig (1 replacement)", lines);
    // under budget: whole lines, the failures kept longest
    const few = try earlierLines(gpa, s.items, 60);
    defer gpa.free(few);
    try tt.expectEqualStrings("- r1 run_tests {} -> ERROR: 1 failed", few);
    // a span with no earlier net gives nothing
    const span = try sampleSpan(gpa);
    defer gpa.free(span);
    const none = try earlierLines(gpa, span, 4096);
    defer gpa.free(none);
    try tt.expectEqual(@as(usize, 0), none.len);
}
