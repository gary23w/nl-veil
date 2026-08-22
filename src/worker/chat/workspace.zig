//! chat_workspace.zig — the explicit prompt workspace: every non-transcript block that enters the LLM
//! context becomes a BID (typed, provenance-carrying, scored) instead of an ad-hoc append. A deterministic
//! packer renders admitted bids in a FIXED channel order under per-channel byte budgets, stamps each block
//! with a provenance receipt the model can cite, and reports every admit/drop decision as one JSON log line.
//!
//! What this buys over direct appends:
//!   * one place where "what may enter the context, and at what cost" is decided — not nine call sites,
//!   * a total bound per channel (individual caps never bounded the SUM — a pathological turn could stack
//!     every block at its cap),
//!   * provenance rendered to the model (a recalled fact arrives with its source, not as naked prose),
//!   * an audit trail: {conv}/workspace.jsonl says exactly what the model saw and what was dropped, why.
//!
//! Channel discipline mirrors the engine's cache layout and must not be reordered:
//!   prefix  — turn-stable blocks, rendered right after the system prompt (provider prefix-cache safe),
//!   varying — per-message blocks, spliced after the pinned goal and before the recency window,
//!   suffix  — engine ground truth appended after the window.
//! Within a channel the order is fixed by Kind, then by bid order — NEVER by score. Score only decides who
//! is dropped under budget pressure, so byte layout stays stable across turns with the same inputs.
//!
//! Scores are packing priority, not truth claims: the neuron CLI returns unscored recall text today, so
//! per-fact confidence cannot honestly ride here yet. The field exists so a scored recall path can feed it
//! without reshaping this seam. Pure + std-only; the engine owns all file I/O (it appends the log line).

const std = @import("std");

/// Every block kind the engine may bid. The enum order within each channel IS the render order contract.
pub const Kind = enum {
    // prefix channel (turn-stable)
    durable_memory,
    tool_digest,
    tool_belt,
    image,
    // varying channel (per-message); verifier sits directly after recall so the audit renders
    // adjacent to the block it audits. `continuation` leads the channel: when a previous unit of work on
    // this thread was cut short, where it got to outranks anything recall can offer about it.
    continuation,
    recall,
    verifier,
    correction,
    family,
    plugin,
    // suffix channel (after the recency window)
    ledger,

    pub fn channel(k: Kind) Channel {
        return switch (k) {
            .durable_memory, .tool_digest, .tool_belt, .image => .prefix,
            .continuation, .recall, .verifier, .correction, .family, .plugin => .varying,
            .ledger => .suffix,
        };
    }

    pub fn name(k: Kind) []const u8 {
        return @tagName(k);
    }
};

pub const Channel = enum { prefix, varying, suffix };

/// Per-channel byte budgets over rendered CONTENT (text + receipt, before JSON escaping). Generous by
/// construction: the call sites' own per-block clips keep normal turns well under these, so live behavior
/// is unchanged — the budget exists to bound the pathological stack (e.g. plugin hooks piling up) and to
/// make any drop VISIBLE in the log instead of silent.
pub const PREFIX_BUDGET_BYTES: usize = 12 * 1024;
pub const VARYING_BUDGET_BYTES: usize = 8 * 1024;
pub const SUFFIX_BUDGET_BYTES: usize = 2 * 1024;

fn channelBudget(c: Channel) usize {
    return switch (c) {
        .prefix => PREFIX_BUDGET_BYTES,
        .varying => VARYING_BUDGET_BYTES,
        .suffix => SUFFIX_BUDGET_BYTES,
    };
}

const Bid = struct {
    kind: Kind,
    src: []u8, // provenance handle, e.g. "hive:chat:abc123", "toolperf", "memories.jsonl" (owned)
    text: []u8, // full block content, header included (owned)
    score: f32, // drop priority under budget pressure (higher survives); NOT a truth claim
    cap: usize, // per-item clip; 0 = none (the call site already bounded it)
    n: u32, // item count inside the block when the site knows it (facts, files); 0 = unknown
    conf: f32, // MEASURED confidence (0..1) when the source provides one (scored recall); < 0 = none
};

const Decision = struct {
    admitted: bool,
    clipped: bool,
    bytes: usize, // content bytes that entered (or would have entered) the context
};

/// Clip to at most `max` bytes without splitting a UTF-8 sequence (engine clipBytes twin).
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    var n = @min(s.len, max);
    while (n > 0 and (s[n - 1] & 0x80) != 0) n -= 1;
    return s[0..n];
}

/// Minimal JSON string escaper (std-only, chat_context precedent — the gateway's jstr lives a layer up).
fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

pub const Packed = struct {
    prefix: []u8 = &.{}, // ,{"role":"system",…} objects — splice right after the system prompt
    varying: []u8 = &.{}, // same shape — hand to assembleHistory as the recall fragment
    suffix: []u8 = &.{}, // same shape — append after the recency window
    log: []u8 = &.{}, // one JSON object line (no trailing \n) for {conv}/workspace.jsonl

    pub fn deinit(self: *Packed, gpa: std.mem.Allocator) void {
        if (self.prefix.len > 0) gpa.free(self.prefix);
        if (self.varying.len > 0) gpa.free(self.varying);
        if (self.suffix.len > 0) gpa.free(self.suffix);
        if (self.log.len > 0) gpa.free(self.log);
        self.* = .{};
    }
};

pub const Workspace = struct {
    gpa: std.mem.Allocator,
    bids: std.ArrayListUnmanaged(Bid) = .empty,

    pub fn init(gpa: std.mem.Allocator) Workspace {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.bids.items) |b| {
            self.gpa.free(b.src);
            self.gpa.free(b.text);
        }
        self.bids.deinit(self.gpa);
    }

    /// Register a block for admission. Text and src are duplicated (call-site scratch may die before pack).
    /// Best-effort like every context path: an empty text or OOM silently drops the bid — the turn must
    /// never fail because a context garnish couldn't be recorded.
    pub fn bid(self: *Workspace, kind: Kind, src: []const u8, text: []const u8, score: f32, cap: usize, n: u32) void {
        self.bidConf(kind, src, text, score, cap, n, -1);
    }

    /// bid() carrying a MEASURED confidence (0..1) — for sources with real numbers (scored recall).
    /// Confidence rides the receipt and the decision log; score stays the packing priority.
    pub fn bidConf(self: *Workspace, kind: Kind, src: []const u8, text: []const u8, score: f32, cap: usize, n: u32, conf: f32) void {
        if (text.len == 0) return;
        const tx = self.gpa.dupe(u8, text) catch return;
        const s = self.gpa.dupe(u8, src) catch {
            self.gpa.free(tx);
            return;
        };
        self.bids.append(self.gpa, .{ .kind = kind, .src = s, .text = tx, .score = score, .cap = cap, .n = n, .conf = conf }) catch {
            self.gpa.free(tx);
            self.gpa.free(s);
        };
    }

    pub fn empty(self: *const Workspace) bool {
        return self.bids.items.len == 0;
    }

    /// Render order within a channel: Kind enum order, then bid order. Score never reorders.
    fn orderKey(self: *const Workspace, idx: usize) u64 {
        const b = self.bids.items[idx];
        return (@as(u64, @intFromEnum(b.kind)) << 32) | idx;
    }

    /// Admit + render + log. Deterministic: the same bids (in any insertion order per kind) produce
    /// byte-identical fragments and log. Never fails; on OOM the affected fragment comes back empty.
    pub fn pack(self: *const Workspace, basis: []const u8, ts: i64) Packed {
        const gpa = self.gpa;
        const nbids = self.bids.items.len;

        // Admission per channel: walk bids, drop the lowest score (ties: latest render order) until the
        // channel's content total fits its budget. O(n²) over at most a handful of blocks.
        const decisions = gpa.alloc(Decision, nbids) catch return .{};
        defer gpa.free(decisions);
        for (self.bids.items, 0..) |b, i| {
            const kept = if (b.cap > 0) clipUtf8(b.text, b.cap) else b.text;
            decisions[i] = .{ .admitted = true, .clipped = kept.len < b.text.len, .bytes = kept.len };
        }
        for ([_]Channel{ .prefix, .varying, .suffix }) |ch| {
            var total: usize = 0;
            for (self.bids.items, 0..) |b, i| {
                if (b.kind.channel() == ch and decisions[i].admitted) total += decisions[i].bytes + RECEIPT_RESERVE;
            }
            while (total > channelBudget(ch)) {
                var victim: ?usize = null;
                for (self.bids.items, 0..) |b, i| {
                    if (b.kind.channel() != ch or !decisions[i].admitted) continue;
                    if (victim == null or b.score < self.bids.items[victim.?].score or
                        (b.score == self.bids.items[victim.?].score and self.orderKey(i) > self.orderKey(victim.?)))
                        victim = i;
                }
                const v = victim orelse break;
                decisions[v].admitted = false;
                total -= decisions[v].bytes + RECEIPT_RESERVE;
            }
        }

        // Stable render order across the whole bid set (channels never interleave in one fragment).
        const order = gpa.alloc(usize, nbids) catch return .{};
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, self, struct {
            fn lt(ws: *const Workspace, a: usize, b: usize) bool {
                return ws.orderKey(a) < ws.orderKey(b);
            }
        }.lt);

        var out: Packed = .{};
        out.prefix = self.renderChannel(.prefix, order, decisions) catch &.{};
        out.varying = self.renderChannel(.varying, order, decisions) catch &.{};
        out.suffix = self.renderChannel(.suffix, order, decisions) catch &.{};
        out.log = self.renderLog(basis, ts, decisions) catch &.{};
        return out;
    }

    /// Room reserved per block for its receipt when checking the budget (the receipt is bounded: kind,
    /// a clipped src, two short numbers).
    const RECEIPT_RESERVE: usize = 96;

    fn renderChannel(self: *const Workspace, ch: Channel, order: []const usize, decisions: []const Decision) ![]u8 {
        const gpa = self.gpa;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        for (order) |i| {
            const b = self.bids.items[i];
            if (b.kind.channel() != ch or !decisions[i].admitted) continue;
            const kept = if (b.cap > 0) clipUtf8(b.text, b.cap) else b.text;

            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(gpa);
            try content.appendSlice(gpa, kept);
            // The receipt: a one-line provenance stamp the model can cite ("per [provenance recall: …]").
            // Truthful fields only — source handle, item count when known, measured confidence when the
            // source carries one, bytes, whether clipped.
            var rb: [48]u8 = undefined;
            try content.appendSlice(gpa, "\n[provenance ");
            try content.appendSlice(gpa, b.kind.name());
            try content.appendSlice(gpa, ": ");
            try content.appendSlice(gpa, clipUtf8(b.src, 48));
            if (b.n > 0) try content.appendSlice(gpa, std.fmt.bufPrint(&rb, ", {d} items", .{b.n}) catch "");
            if (b.conf >= 0) try content.appendSlice(gpa, std.fmt.bufPrint(&rb, ", conf {d:.2}", .{b.conf}) catch "");
            try content.appendSlice(gpa, std.fmt.bufPrint(&rb, ", {d}B", .{kept.len}) catch "");
            if (decisions[i].clipped) try content.appendSlice(gpa, ", clipped");
            try content.append(gpa, ']');

            try out.appendSlice(gpa, ",{\"role\":\"system\",\"content\":");
            try appendJsonString(gpa, &out, content.items);
            try out.append(gpa, '}');
        }
        if (out.items.len == 0) return &.{};
        return out.toOwnedSlice(gpa);
    }

    fn renderLog(self: *const Workspace, basis: []const u8, ts: i64, decisions: []const Decision) ![]u8 {
        const gpa = self.gpa;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        var hb: [128]u8 = undefined;
        try out.appendSlice(gpa, std.fmt.bufPrint(&hb, "{{\"ts\":{d},\"basis\":", .{ts}) catch return error.OutOfMemory);
        try appendJsonString(gpa, &out, clipUtf8(basis, 96));
        try out.appendSlice(gpa, std.fmt.bufPrint(&hb, ",\"budgets\":{{\"prefix\":{d},\"varying\":{d},\"suffix\":{d}}},\"bids\":[", .{ PREFIX_BUDGET_BYTES, VARYING_BUDGET_BYTES, SUFFIX_BUDGET_BYTES }) catch return error.OutOfMemory);
        for (self.bids.items, 0..) |b, i| {
            if (i > 0) try out.append(gpa, ',');
            var ib: [128]u8 = undefined;
            var cb: [16]u8 = undefined;
            try out.appendSlice(gpa, "{\"kind\":");
            try appendJsonString(gpa, &out, b.kind.name());
            try out.appendSlice(gpa, ",\"src\":");
            try appendJsonString(gpa, &out, clipUtf8(b.src, 96));
            const conf_s: []const u8 = if (b.conf >= 0) (std.fmt.bufPrint(&cb, "{d:.2}", .{b.conf}) catch "null") else "null";
            try out.appendSlice(gpa, std.fmt.bufPrint(&ib, ",\"score\":{d:.2},\"conf\":{s},\"n\":{d},\"bytes\":{d},\"admitted\":{},\"clipped\":{}}}", .{ b.score, conf_s, b.n, decisions[i].bytes, decisions[i].admitted, decisions[i].clipped }) catch return error.OutOfMemory);
        }
        try out.appendSlice(gpa, "]}");
        return out.toOwnedSlice(gpa);
    }
};

// ------------------------------------------------------------------------------------------------- tests

const t = std.testing;

fn parseMsgs(gpa: std.mem.Allocator, frag: []const u8) !std.json.Parsed(std.json.Value) {
    // fragments are ",{obj},{obj}" — wrap into a real JSON array to validate shape end-to-end
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '[');
    if (frag.len > 0) try buf.appendSlice(gpa, frag[1..]);
    try buf.append(gpa, ']');
    return std.json.parseFromSlice(std.json.Value, gpa, buf.items, .{});
}

test "pack: fixed channel order regardless of bid insertion order; deterministic bytes" {
    const gpa = t.allocator;
    var ws = Workspace.init(gpa);
    defer ws.deinit();
    // insert deliberately out of render order
    ws.bid(.plugin, "plug:style", "PLUGIN CONTEXT: house style.", 0.50, 0, 0);
    ws.bid(.recall, "hive:chat:c1", "RELEVANT MEMORY:\n- fact one", 0.60, 0, 1);
    ws.bid(.tool_belt, "toolperf", "TOOL BELT: read_file web_search", 0.55, 0, 0);
    ws.bid(.durable_memory, "memories.jsonl", "YOUR MEMORY:\n- [env] zig at ~/zig-0.16.0", 0.90, 0, 1);
    ws.bid(.ledger, "file_ledger", "[ENGINE GROUND TRUTH: index.html (912 B)]", 0.90, 0, 1);

    var p1 = ws.pack("conv-c1", 1000);
    defer p1.deinit(gpa);
    var p2 = ws.pack("conv-c1", 1000);
    defer p2.deinit(gpa);
    try t.expectEqualStrings(p1.prefix, p2.prefix); // deterministic
    try t.expectEqualStrings(p1.varying, p2.varying);
    try t.expectEqualStrings(p1.log, p2.log);

    // prefix renders durable_memory BEFORE tool_belt (Kind order), varying holds recall then plugin
    const dm = std.mem.indexOf(u8, p1.prefix, "YOUR MEMORY").?;
    const tb = std.mem.indexOf(u8, p1.prefix, "TOOL BELT").?;
    try t.expect(dm < tb);
    const rc = std.mem.indexOf(u8, p1.varying, "RELEVANT MEMORY").?;
    const pl = std.mem.indexOf(u8, p1.varying, "PLUGIN CONTEXT").?;
    try t.expect(rc < pl);
    try t.expect(std.mem.indexOf(u8, p1.suffix, "ENGINE GROUND TRUTH") != null);
    // channels never bleed
    try t.expect(std.mem.indexOf(u8, p1.prefix, "RELEVANT MEMORY") == null);
    try t.expect(std.mem.indexOf(u8, p1.varying, "ENGINE GROUND TRUTH") == null);
}

test "pack: fragments are valid message objects and receipts carry provenance" {
    const gpa = t.allocator;
    var ws = Workspace.init(gpa);
    defer ws.deinit();
    ws.bid(.recall, "hive:chat:c9", "RELEVANT MEMORY:\n- the user's name is Gary", 0.60, 0, 3);

    var p = ws.pack("conv-c9", 42);
    defer p.deinit(gpa);
    const parsed = try parseMsgs(gpa, p.varying);
    defer parsed.deinit();
    const arr = parsed.value.array;
    try t.expectEqual(@as(usize, 1), arr.items.len);
    const content = arr.items[0].object.get("content").?.string;
    try t.expectEqualStrings("system", arr.items[0].object.get("role").?.string);
    try t.expect(std.mem.indexOf(u8, content, "[provenance recall: hive:chat:c9, 3 items,") != null);

    // the log line is one valid JSON object naming the same bid
    const lp = try std.json.parseFromSlice(std.json.Value, gpa, p.log, .{});
    defer lp.deinit();
    const bids = lp.value.object.get("bids").?.array;
    try t.expectEqual(@as(usize, 1), bids.items.len);
    try t.expectEqualStrings("recall", bids.items[0].object.get("kind").?.string);
    try t.expect(bids.items[0].object.get("admitted").?.bool);
    try t.expectEqual(@as(i64, 42), lp.value.object.get("ts").?.integer);
}

test "pack: channel budget drops whole lowest-score bids first and records the drop" {
    const gpa = t.allocator;
    var ws = Workspace.init(gpa);
    defer ws.deinit();
    const big = "x" ** 3000;
    // three varying bids ~3KB each: 9KB + receipts > 8KB budget → exactly one must go, the lowest score
    ws.bid(.recall, "hive:chat:c2", "R:" ++ big, 0.60, 0, 0);
    ws.bid(.correction, "belt", "C:" ++ big, 0.95, 0, 0);
    ws.bid(.plugin, "plug:x", "P:" ++ big, 0.50, 0, 0);

    var p = ws.pack("conv-c2", 0);
    defer p.deinit(gpa);
    try t.expect(std.mem.indexOf(u8, p.varying, "R:") != null);
    try t.expect(std.mem.indexOf(u8, p.varying, "C:") != null);
    try t.expect(std.mem.indexOf(u8, p.varying, "P:") == null); // plugin (0.50) dropped whole — never truncated

    const lp = try std.json.parseFromSlice(std.json.Value, gpa, p.log, .{});
    defer lp.deinit();
    for (lp.value.object.get("bids").?.array.items) |bid_v| {
        const o = bid_v.object;
        const admitted = o.get("admitted").?.bool;
        if (std.mem.eql(u8, o.get("kind").?.string, "plugin")) try t.expect(!admitted) else try t.expect(admitted);
    }
}

test "pack: per-item cap clips UTF-8 safely and the receipt says so" {
    const gpa = t.allocator;
    var ws = Workspace.init(gpa);
    defer ws.deinit();
    // multibyte char straddling the cap must back off, not tear
    ws.bid(.image, "pixelrag", "abcé" ++ "def", 0.85, 4, 0); // é is 2 bytes; cap lands mid-sequence
    var p = ws.pack("conv-c3", 0);
    defer p.deinit(gpa);
    const parsed = try parseMsgs(gpa, p.prefix);
    defer parsed.deinit();
    const content = parsed.value.array.items[0].object.get("content").?.string;
    try t.expect(std.mem.startsWith(u8, content, "abc\n[provenance image:")); // backed off to 3 clean bytes
    try t.expect(std.mem.indexOf(u8, content, ", clipped]") != null);
}

test "pack: measured confidence rides the receipt and the log; verifier renders after recall" {
    const gpa = t.allocator;
    var ws = Workspace.init(gpa);
    defer ws.deinit();
    ws.bid(.verifier, "memverify", "MEMORY VERIFIER — caution on fact #2", 0.92, 0, 0);
    ws.bidConf(.recall, "hive:chat:c7", "RELEVANT MEMORY:\n1. the port is 8080", 0.60, 0, 2, 0.82);
    var p = ws.pack("conv-c7", 5);
    defer p.deinit(gpa);
    const rc = std.mem.indexOf(u8, p.varying, "RELEVANT MEMORY").?;
    const vf = std.mem.indexOf(u8, p.varying, "MEMORY VERIFIER").?;
    try t.expect(rc < vf); // fixed order: the audit renders right after the block it audits
    try t.expect(std.mem.indexOf(u8, p.varying, ", conf 0.82,") != null); // receipt carries the number
    try t.expect(std.mem.indexOf(u8, p.log, "\"conf\":0.82") != null);
    try t.expect(std.mem.indexOf(u8, p.log, "\"conf\":null") != null); // the verifier bid carries none
}

test "pack: empty workspace yields empty fragments and an empty-bids log" {
    const gpa = t.allocator;
    var ws = Workspace.init(gpa);
    defer ws.deinit();
    ws.bid(.recall, "hive:chat:c4", "", 0.60, 0, 0); // empty text is refused at bid time
    try t.expect(ws.empty());
    var p = ws.pack("conv-c4", 7);
    defer p.deinit(gpa);
    try t.expectEqual(@as(usize, 0), p.prefix.len);
    try t.expectEqual(@as(usize, 0), p.varying.len);
    try t.expectEqual(@as(usize, 0), p.suffix.len);
    try t.expect(std.mem.indexOf(u8, p.log, "\"bids\":[]") != null);
}
