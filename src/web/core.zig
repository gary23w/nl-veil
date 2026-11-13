//! veil_core.wasm - the veil's own context core, compiled for the browser (docs/app, the web veil).
//!
//! WHAT: a thin export layer over src/worker/chat/net.zig (Gary's 4tope). The web veil runs its tool loop in the
//! page; when the loop's messages outgrow the model's room it hands the span to this module and gets back the
//! same net the server's engine would lay out, plus the tool_call ids of the critical chain's live results
//! (the ones a fold must keep verbatim). Nothing here talks to anything: bytes in, bytes out.
//!
//! THE SPAN is what net.Graph.fromSpan reads: OpenAI-shaped chat messages as JSON objects, each starting
//! `{"role":"` and joined by commas (a JSON array's text without its brackets).
//!
//! BUILD (no build.zig step; the output is checked in beside the page):
//!   zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
//!       --dep net -Mroot=src/web/core.zig -Mnet=src/worker/chat/net.zig -femit-bin=docs/app/veil_core.wasm
//!
//! MEMORY: the caller asks for a buffer with veil_alloc, writes into it, and frees it with veil_free. A result
//! comes back as one u64: (pointer << 32) | length, the caller's to free with veil_free. 0 means failure or an
//! empty answer.

const std = @import("std");
const net = @import("net");

const gpa = std.heap.wasm_allocator;

/// Bumped when an export's meaning changes; the page refuses a module it was not written for.
export fn veil_core_abi() u32 {
    return 1;
}

export fn veil_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, if (len == 0) 1 else len) catch return null;
    return buf.ptr;
}

export fn veil_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| gpa.free(p[0..if (len == 0) 1 else len]);
}

fn pack(bytes: []u8) u64 {
    if (bytes.len == 0) {
        gpa.free(bytes);
        return 0;
    }
    return (@as(u64, @intFromPtr(bytes.ptr)) << 32) | @as(u64, bytes.len);
}

fn view(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

/// The span unfolded from its frontier under `budget` bytes. `ground` is the caller's own file ledger for the
/// net's ON DISK section. `tail_from` is the index (message number in the span, from 0) of the first message the
/// caller keeps verbatim after the net, so the net does not restate it; 0xFFFFFFFF when there is no such tail.
export fn veil_net_unfold(span_ptr: ?[*]const u8, span_len: usize, budget: usize, ground_ptr: ?[*]const u8, ground_len: usize, tail_from: u32) u64 {
    var g = net.Graph.fromSpan(gpa, view(span_ptr, span_len)) catch return 0;
    defer g.deinit();
    const out = g.unfoldWith(gpa, budget, view(ground_ptr, ground_len), .{ .tail_from = tail_from }) catch return 0;
    return pack(out);
}

/// The tool_call ids of the critical chain's live results, one per line.
export fn veil_net_protected(span_ptr: ?[*]const u8, span_len: usize) u64 {
    var g = net.Graph.fromSpan(gpa, view(span_ptr, span_len)) catch return 0;
    defer g.deinit();
    const ids = g.protectedIds(gpa) catch return 0;
    defer gpa.free(ids);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (ids) |id| {
        out.appendSlice(gpa, id) catch {
            out.deinit(gpa);
            return 0;
        };
        out.append(gpa, '\n') catch {
            out.deinit(gpa);
            return 0;
        };
    }
    const owned = out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return 0;
    };
    return pack(owned);
}

/// The sentence a net note opens with (net.NET_NOTE_HEAD), so the page's fold writes the same note the engine does.
export fn veil_net_head() u64 {
    const out = gpa.dupe(u8, net.NET_NOTE_HEAD) catch return 0;
    return pack(out);
}

/// The video renderer (render.zig) is part of this module: its exports ride beside the ones above.
pub const render = @import("render.zig");
comptime {
    _ = render;
}
