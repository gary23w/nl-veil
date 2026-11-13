//! render.zig - the web veil's video renderer, compiled into veil_core.wasm beside the context core.
//!
//! WHAT: the pixel work of a film made in the page (docs/chat, the Video tab), and the writing of its file.
//!   - PICTURES are handed over as RGBA and kept in numbered slots.
//!   - MOTION between two pictures is found here: a dense optical flow (which way every part of the first
//!     picture has to travel to become the second), by the Horn-Schunck method worked coarse to fine.
//!   - A FRAME of the film is composed here into one RGBA canvas: a picture under a camera (scale and offset),
//!     or two pictures MORPHED - each carried along the flow toward the other and mixed - so what lies between
//!     two generated frames is movement, not a cross-fade. Fades toward black are applied here too.
//!   - The FILE is laid out here: an MP4's index (the `moov` box and its sample tables) for the H.264 and AAC
//!     samples the browser's own encoders produce. The samples themselves stay with the page (a film is as long
//!     as it is); this module is told each one's size and writes where each one is.
//! Nothing here talks to anything: numbers and bytes in, bytes out. Text (captions) is drawn by the page, which
//! has the fonts.
//!
//! MEMORY: as core.zig. A returned u64 is (pointer << 32) | length, the caller's to free with veil_free.

const std = @import("std");

const gpa = std.heap.wasm_allocator;

export fn veil_r_abi() u32 {
    return 1;
}

fn pack(bytes: []u8) u64 {
    if (bytes.len == 0) {
        gpa.free(bytes);
        return 0;
    }
    return (@as(u64, @intFromPtr(bytes.ptr)) << 32) | @as(u64, bytes.len);
}

// ------------------------------------------------------------------------------------------------ pictures

const SLOTS = 24;
const FLOW_SIDE = 128; // the longer side of the grid a flow is found on
const Image = struct {
    w: u32 = 0,
    h: u32 = 0,
    px: []u8 = &.{},
    gray: []f32 = &.{}, // the picture small and grey, made when a flow first needs it
    gw: u32 = 0,
    gh: u32 = 0,
    stamp: u32 = 0, // changes whenever the slot is filled again: a flow found for the old picture is not used
};
var images: [SLOTS]Image = [_]Image{.{}} ** SLOTS;
var stamps: u32 = 0;

fn dropImage(im: *Image) void {
    if (im.px.len > 0) gpa.free(im.px);
    if (im.gray.len > 0) gpa.free(im.gray);
    im.* = .{};
}

/// Room for a w by h RGBA picture in `slot`; the caller writes the pixels there. Null when it cannot be had.
export fn veil_r_image(slot: u32, w: u32, h: u32) ?[*]u8 {
    if (slot >= SLOTS or w == 0 or h == 0 or w > 8192 or h > 8192) return null;
    const im = &images[slot];
    dropImage(im);
    im.px = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
    im.w = w;
    im.h = h;
    stamps += 1;
    im.stamp = stamps;
    return im.px.ptr;
}

export fn veil_r_image_free(slot: u32) void {
    if (slot < SLOTS) dropImage(&images[slot]);
}

fn grayOf(im: *Image) bool {
    if (im.gray.len > 0) return true;
    if (im.px.len == 0) return false;
    const long = @max(im.w, im.h);
    const gw: u32 = @max(16, im.w * FLOW_SIDE / long);
    const gh: u32 = @max(16, im.h * FLOW_SIDE / long);
    const g = gpa.alloc(f32, @as(usize, gw) * gh) catch return false;
    // each cell is the mean of a sparse sample of the pixels under it
    var y: u32 = 0;
    while (y < gh) : (y += 1) {
        const y0 = y * im.h / gh;
        const y1 = @max(y0 + 1, (y + 1) * im.h / gh);
        const ys = @max(1, (y1 - y0) / 4);
        var x: u32 = 0;
        while (x < gw) : (x += 1) {
            const x0 = x * im.w / gw;
            const x1 = @max(x0 + 1, (x + 1) * im.w / gw);
            const xs = @max(1, (x1 - x0) / 4);
            var sum: f32 = 0;
            var n: f32 = 0;
            var py = y0;
            while (py < y1) : (py += ys) {
                var px = x0;
                while (px < x1) : (px += xs) {
                    const i = (@as(usize, py) * im.w + px) * 4;
                    sum += 0.299 * @as(f32, @floatFromInt(im.px[i])) + 0.587 * @as(f32, @floatFromInt(im.px[i + 1])) + 0.114 * @as(f32, @floatFromInt(im.px[i + 2]));
                    n += 1;
                }
            }
            g[@as(usize, y) * gw + x] = sum / (n * 255.0);
        }
    }
    im.gray = g;
    im.gw = gw;
    im.gh = gh;
    return true;
}

// ------------------------------------------------------------------------------------------------ optical flow

/// A grey picture read between its cells.
fn sample(g: []const f32, w: u32, h: u32, x: f32, y: f32) f32 {
    const fx = @min(@max(x, 0), @as(f32, @floatFromInt(w - 1)));
    const fy = @min(@max(y, 0), @as(f32, @floatFromInt(h - 1)));
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, w - 1);
    const y1 = @min(y0 + 1, h - 1);
    const ax = fx - @as(f32, @floatFromInt(x0));
    const ay = fy - @as(f32, @floatFromInt(y0));
    const a = g[@as(usize, y0) * w + x0] * (1 - ax) + g[@as(usize, y0) * w + x1] * ax;
    const b = g[@as(usize, y1) * w + x0] * (1 - ax) + g[@as(usize, y1) * w + x1] * ax;
    return a * (1 - ay) + b * ay;
}

fn halve(src: []const f32, w: u32, h: u32, dst: []f32) void {
    const W = w / 2;
    const H = h / 2;
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const i = @as(usize, y * 2) * w + x * 2;
            dst[@as(usize, y) * W + x] = (src[i] + src[i + 1] + src[i + w] + src[i + w + 1]) * 0.25;
        }
    }
}

const LEVELS = 4;
const ALPHA: f32 = 0.012; // how much a smooth flow is preferred over an exact one
const ITERS = 36;

/// Which way each cell of `a` travels to match `b`: (u, v) in cells of the w by h grid, written into `u` and `v`.
fn flowHS(a0: []const f32, b0: []const f32, w0: u32, h0: u32, u_out: []f32, v_out: []f32) bool {
    // the two pictures at every size, smallest last
    var as: [LEVELS][]f32 = undefined;
    var bs: [LEVELS][]f32 = undefined;
    var ws: [LEVELS]u32 = undefined;
    var hs: [LEVELS]u32 = undefined;
    var levels: usize = 1;
    ws[0] = w0;
    hs[0] = h0;
    var made: usize = 0; // levels above the first, whose buffers are ours to free
    defer {
        var i: usize = 1;
        while (i <= made) : (i += 1) {
            gpa.free(as[i]);
            gpa.free(bs[i]);
        }
    }
    while (levels < LEVELS and @min(ws[levels - 1], hs[levels - 1]) >= 24) : (levels += 1) {
        const W = ws[levels - 1] / 2;
        const H = hs[levels - 1] / 2;
        const na = gpa.alloc(f32, @as(usize, W) * H) catch return false;
        const nb = gpa.alloc(f32, @as(usize, W) * H) catch {
            gpa.free(na);
            return false;
        };
        const pa: []const f32 = if (levels == 1) a0 else as[levels - 1];
        const pb: []const f32 = if (levels == 1) b0 else bs[levels - 1];
        halve(pa, ws[levels - 1], hs[levels - 1], na);
        halve(pb, ws[levels - 1], hs[levels - 1], nb);
        as[levels] = na;
        bs[levels] = nb;
        ws[levels] = W;
        hs[levels] = H;
        made = levels;
    }

    const n0 = @as(usize, w0) * h0;
    // working room, all at the largest size: the flow so far, its correction (two copies for the sweeps), the
    // second picture moved by the flow, and the three gradients
    const work = gpa.alloc(f32, n0 * 10) catch return false;
    defer gpa.free(work);
    const u = work[0..n0];
    const v = work[n0 .. n0 * 2];
    const du = work[n0 * 2 .. n0 * 3];
    const dv = work[n0 * 3 .. n0 * 4];
    const du2 = work[n0 * 4 .. n0 * 5];
    const dv2 = work[n0 * 5 .. n0 * 6];
    const bw = work[n0 * 6 .. n0 * 7];
    const ix = work[n0 * 7 .. n0 * 8];
    const iy = work[n0 * 8 .. n0 * 9];
    const it = work[n0 * 9 .. n0 * 10];

    var cw: u32 = 0;
    var ch: u32 = 0;
    var L: usize = levels;
    while (L > 0) {
        L -= 1;
        const A: []const f32 = if (L == 0) a0 else as[L];
        const B: []const f32 = if (L == 0) b0 else bs[L];
        const W = ws[L];
        const H = hs[L];
        const n = @as(usize, W) * H;
        if (cw == 0) {
            @memset(u[0..n], 0);
            @memset(v[0..n], 0);
        } else {
            // the coarser level's flow, spread over this one (and twice as long, in this level's cells).
            // Done from the far end so the smaller grid at the front of the same buffer is read before it is written.
            var y: u32 = H;
            while (y > 0) {
                y -= 1;
                var x: u32 = W;
                while (x > 0) {
                    x -= 1;
                    const sx = @min(x / 2, cw - 1);
                    const sy = @min(y / 2, ch - 1);
                    const s = @as(usize, sy) * cw + sx;
                    const d = @as(usize, y) * W + x;
                    du[d] = u[s] * 2;
                    dv[d] = v[s] * 2;
                }
            }
            @memcpy(u[0..n], du[0..n]);
            @memcpy(v[0..n], dv[0..n]);
        }
        var pass: u32 = 0;
        while (pass < 2) : (pass += 1) {
            var y: u32 = 0;
            while (y < H) : (y += 1) {
                var x: u32 = 0;
                while (x < W) : (x += 1) {
                    const i = @as(usize, y) * W + x;
                    bw[i] = sample(B, W, H, @as(f32, @floatFromInt(x)) + u[i], @as(f32, @floatFromInt(y)) + v[i]);
                }
            }
            y = 0;
            while (y < H) : (y += 1) {
                var x: u32 = 0;
                while (x < W) : (x += 1) {
                    const i = @as(usize, y) * W + x;
                    const xl = @as(usize, y) * W + (if (x > 0) x - 1 else x);
                    const xr = @as(usize, y) * W + (if (x + 1 < W) x + 1 else x);
                    const yu = @as(usize, if (y > 0) y - 1 else y) * W + x;
                    const yd = @as(usize, if (y + 1 < H) y + 1 else y) * W + x;
                    ix[i] = ((A[xr] - A[xl]) + (bw[xr] - bw[xl])) * 0.25;
                    iy[i] = ((A[yd] - A[yu]) + (bw[yd] - bw[yu])) * 0.25;
                    it[i] = bw[i] - A[i];
                }
            }
            @memset(du[0..n], 0);
            @memset(dv[0..n], 0);
            var k: u32 = 0;
            while (k < ITERS) : (k += 1) {
                const su: []const f32 = if (k % 2 == 0) du else du2;
                const sv: []const f32 = if (k % 2 == 0) dv else dv2;
                const tu: []f32 = if (k % 2 == 0) du2 else du;
                const tv: []f32 = if (k % 2 == 0) dv2 else dv;
                y = 0;
                while (y < H) : (y += 1) {
                    var x: u32 = 0;
                    while (x < W) : (x += 1) {
                        const i = @as(usize, y) * W + x;
                        const xl = @as(usize, y) * W + (if (x > 0) x - 1 else x);
                        const xr = @as(usize, y) * W + (if (x + 1 < W) x + 1 else x);
                        const yu = @as(usize, if (y > 0) y - 1 else y) * W + x;
                        const yd = @as(usize, if (y + 1 < H) y + 1 else y) * W + x;
                        // the neighbours' mean of the WHOLE flow (what is known so far plus the correction),
                        // less what is known here: smoothness is asked of the flow, not of its correction
                        const ub = (su[xl] + su[xr] + su[yu] + su[yd] + u[xl] + u[xr] + u[yu] + u[yd]) * 0.25 - u[i];
                        const vb = (sv[xl] + sv[xr] + sv[yu] + sv[yd] + v[xl] + v[xr] + v[yu] + v[yd]) * 0.25 - v[i];
                        const t = (ix[i] * ub + iy[i] * vb + it[i]) / (ALPHA + ix[i] * ix[i] + iy[i] * iy[i]);
                        tu[i] = ub - ix[i] * t;
                        tv[i] = vb - iy[i] * t;
                    }
                }
            }
            // ITERS is even, so the last sweep wrote du and dv
            var i: usize = 0;
            while (i < n) : (i += 1) {
                u[i] += du[i];
                v[i] += dv[i];
            }
        }
        cw = W;
        ch = H;
    }
    // no part of a picture is carried further than a third of the frame
    const lim_u = @as(f32, @floatFromInt(w0)) / 3.0;
    const lim_v = @as(f32, @floatFromInt(h0)) / 3.0;
    var i: usize = 0;
    while (i < n0) : (i += 1) {
        u_out[i] = @min(@max(u[i], -lim_u), lim_u);
        v_out[i] = @min(@max(v[i], -lim_v), lim_v);
    }
    return true;
}

const BLOCK = 12; // cells a side of the blocks the worst part of a frame is looked for in (about a tenth of the frame's width)
const DOUBT: f32 = 0.07; // a miss of this much brightness halves the trust put in the flow there

/// Scale a flow (u then v, each w*h) by how well it explains `to` from `from`, cell by cell (the trust smoothed
/// over each cell's neighbours). Gives the mean miss before scaling.
var worst_block: f32 = 0; // set by trust(): the largest mean miss over any block of the grid

fn trust(from: []const f32, to: []const f32, w: u32, h: u32, f: []f32) ?f32 {
    const n = @as(usize, w) * h;
    const c = gpa.alloc(f32, n * 2) catch return null;
    defer gpa.free(c);
    var sum: f32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = @as(usize, y) * w + x;
            const r = @abs(sample(to, w, h, @as(f32, @floatFromInt(x)) + f[i], @as(f32, @floatFromInt(y)) + f[n + i]) - from[i]);
            sum += r;
            const q = r / DOUBT;
            c[i] = 1.0 / (1.0 + q * q);
        }
    }
    // The worst PART of the frame: the mean miss of each block of BLOCK by BLOCK cells, and the largest of them.
    // A frame can agree with the one before on average and still have one thing in it that was not there (a
    // figure, an object, a changed face): that shows here, where the average hides it. The miss of a cell is
    // read back out of its trust.
    worst_block = 0;
    var by: u32 = 0;
    while (by + BLOCK <= h) : (by += BLOCK / 2) {
        var bx: u32 = 0;
        while (bx + BLOCK <= w) : (bx += BLOCK / 2) {
            var acc: f32 = 0;
            var yy: u32 = by;
            while (yy < by + BLOCK) : (yy += 1) {
                var xx: u32 = bx;
                while (xx < bx + BLOCK) : (xx += 1) {
                    const t = c[@as(usize, yy) * w + xx];
                    acc += @sqrt(@max(1.0 / t - 1.0, 0)) * DOUBT;
                }
            }
            worst_block = @max(worst_block, acc / @as(f32, BLOCK * BLOCK));
        }
    }
    // the trust of a cell is the least sure of it and its neighbours, softened: doubt spreads a little
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var acc: f32 = 0;
            var cnt: f32 = 0;
            var dy: i32 = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: i32 = -2;
                while (dx <= 2) : (dx += 1) {
                    const yy = @as(i32, @intCast(y)) + dy;
                    const xx = @as(i32, @intCast(x)) + dx;
                    if (yy < 0 or xx < 0 or yy >= @as(i32, @intCast(h)) or xx >= @as(i32, @intCast(w))) continue;
                    acc += c[@as(usize, @intCast(yy)) * w + @as(usize, @intCast(xx))];
                    cnt += 1;
                }
            }
            c[n + @as(usize, y) * w + x] = acc / cnt;
        }
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        f[i] *= c[n + i];
        f[n + i] *= c[n + i];
    }
    return sum / @as(f32, @floatFromInt(n));
}

const FLOWS = 6;
const Flow = struct {
    a: u32 = 0,
    b: u32 = 0,
    sa: u32 = 0, // the pictures' stamps when the flow was found
    sb: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    ab: []f32 = &.{}, // u then v, each w*h: a toward b, in cells of a's grid
    ba: []f32 = &.{},
    used: u32 = 0,
    miss: f32 = 0, // how far the first picture, carried along the flow, still is from the second (0 = it becomes it)
    worst: f32 = 0, // the same, for the worst part of the frame (either direction)
};
var flows: [FLOWS]Flow = [_]Flow{.{}} ** FLOWS;
var uses: u32 = 0;

fn flowFor(a: u32, b: u32) ?*Flow {
    if (a >= SLOTS or b >= SLOTS) return null;
    const ia = &images[a];
    const ib = &images[b];
    uses += 1;
    for (&flows) |*f| {
        if (f.ab.len > 0 and f.a == a and f.b == b and f.sa == ia.stamp and f.sb == ib.stamp) {
            f.used = uses;
            return f;
        }
    }
    if (!grayOf(ia) or !grayOf(ib)) return null;
    // the two grids must be one size: the second picture is read onto the first one's grid
    const w = ia.gw;
    const h = ia.gh;
    const n = @as(usize, w) * h;
    var gb: []f32 = ib.gray;
    var own = false;
    if (ib.gw != w or ib.gh != h) {
        gb = gpa.alloc(f32, n) catch return null;
        own = true;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                gb[@as(usize, y) * w + x] = sample(ib.gray, ib.gw, ib.gh, @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(ib.gw)) / @as(f32, @floatFromInt(w)), @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(ib.gh)) / @as(f32, @floatFromInt(h)));
            }
        }
    }
    defer if (own) gpa.free(gb);
    // the place of the flow used longest ago
    var slot: *Flow = &flows[0];
    for (&flows) |*f| {
        if (f.used < slot.used) slot = f;
    }
    if (slot.ab.len != n * 2) {
        if (slot.ab.len > 0) gpa.free(slot.ab);
        if (slot.ba.len > 0) gpa.free(slot.ba);
        slot.* = .{};
        slot.ab = gpa.alloc(f32, n * 2) catch return null;
        slot.ba = gpa.alloc(f32, n * 2) catch {
            gpa.free(slot.ab);
            slot.ab = &.{};
            return null;
        };
    }
    if (!flowHS(ia.gray, gb, w, h, slot.ab[0..n], slot.ab[n .. n * 2]) or !flowHS(gb, ia.gray, w, h, slot.ba[0..n], slot.ba[n .. n * 2])) {
        gpa.free(slot.ab);
        gpa.free(slot.ba);
        slot.* = .{};
        return null;
    }
    // What the flow does not account for: the first picture read where the flow says it went, against the
    // second. Where that is large the flow is a guess (something appeared, or the two pictures are not the same
    // scene there), and carrying pixels along a guess smears them: there the flow is let go, so that part of the
    // frame mixes from one picture to the other where it stands. Each direction is judged by its own miss.
    const miss_ab = trust(ia.gray, gb, w, h, slot.ab) orelse 0;
    slot.worst = worst_block;
    _ = trust(gb, ia.gray, w, h, slot.ba);
    slot.worst = @max(slot.worst, worst_block);
    slot.miss = miss_ab;
    slot.a = a;
    slot.b = b;
    slot.sa = ia.stamp;
    slot.sb = ib.stamp;
    slot.w = w;
    slot.h = h;
    slot.used = uses;
    return slot;
}

/// Find (or have ready) the motion between two pictures. 1 when it is there. How far, on average, the first
/// picture's parts travel (in thousandths of the frame's width) is left in veil_r_flow_travel.
var travel: u32 = 0;
var missed: u32 = 0;
var worst: u32 = 0;
/// After veil_r_flow: the miss of the WORST part of the frame, in thousandths of full brightness. This is the
/// test of SHAPE: one thing in a frame that the frame before does not lead to shows here.
export fn veil_r_flow_worst() u32 {
    return worst;
}
/// After veil_r_flow: what the motion leaves unexplained, in thousandths of full brightness. Two frames of one
/// continuous shot leave little; a frame with something new in it, or a different picture, leaves a lot.
export fn veil_r_flow_miss() u32 {
    return missed;
}
export fn veil_r_flow(a: u32, b: u32) u32 {
    const f = flowFor(a, b) orelse return 0;
    missed = @intFromFloat(f.miss * 1000.0);
    worst = @intFromFloat(f.worst * 1000.0);
    const n = @as(usize, f.w) * f.h;
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) sum += @abs(f.ab[i]) + @abs(f.ab[n + i]);
    travel = @intFromFloat(sum / @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(f.w)) * 1000.0);
    return 1;
}
export fn veil_r_flow_travel() u32 {
    return travel;
}

// ------------------------------------------------------------------------------------------------ the frame

var canvas: []u8 = &.{};
var cw_: u32 = 0;
var ch_: u32 = 0;

/// The frame being composed: w by h RGBA. The caller reads it from the pointer after drawing.
export fn veil_r_canvas(w: u32, h: u32) ?[*]u8 {
    if (w == 0 or h == 0 or w > 8192 or h > 8192) return null;
    if (cw_ != w or ch_ != h) {
        if (canvas.len > 0) gpa.free(canvas);
        canvas = gpa.alloc(u8, @as(usize, w) * h * 4) catch {
            canvas = &.{};
            cw_ = 0;
            ch_ = 0;
            return null;
        };
        cw_ = w;
        ch_ = h;
    }
    return canvas.ptr;
}

export fn veil_r_clear() void {
    var i: usize = 0;
    while (i < canvas.len) : (i += 4) {
        canvas[i] = 0;
        canvas[i + 1] = 0;
        canvas[i + 2] = 0;
        canvas[i + 3] = 255;
    }
}

/// Toward black by `dark` (0 nothing, 1 black).
export fn veil_r_fade(dark: f32) void {
    const k: u32 = @intFromFloat(@min(@max(1.0 - dark, 0), 1) * 256.0);
    var i: usize = 0;
    while (i < canvas.len) : (i += 4) {
        canvas[i] = @intCast((@as(u32, canvas[i]) * k) >> 8);
        canvas[i + 1] = @intCast((@as(u32, canvas[i + 1]) * k) >> 8);
        canvas[i + 2] = @intCast((@as(u32, canvas[i + 2]) * k) >> 8);
    }
}

const Rgb = struct { r: f32, g: f32, b: f32 };

/// A picture read at a point given in parts of its width and height (0..1), between its pixels.
fn pixel(im: *const Image, qx: f32, qy: f32) Rgb {
    const fx = @min(@max(qx, 0), 1) * @as(f32, @floatFromInt(im.w - 1));
    const fy = @min(@max(qy, 0), 1) * @as(f32, @floatFromInt(im.h - 1));
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, im.w - 1);
    const y1 = @min(y0 + 1, im.h - 1);
    const ax = fx - @as(f32, @floatFromInt(x0));
    const ay = fy - @as(f32, @floatFromInt(y0));
    const p00 = (@as(usize, y0) * im.w + x0) * 4;
    const p01 = (@as(usize, y0) * im.w + x1) * 4;
    const p10 = (@as(usize, y1) * im.w + x0) * 4;
    const p11 = (@as(usize, y1) * im.w + x1) * 4;
    const w00 = (1 - ax) * (1 - ay);
    const w01 = ax * (1 - ay);
    const w10 = (1 - ax) * ay;
    const w11 = ax * ay;
    const px = im.px;
    return .{
        .r = @as(f32, @floatFromInt(px[p00])) * w00 + @as(f32, @floatFromInt(px[p01])) * w01 + @as(f32, @floatFromInt(px[p10])) * w10 + @as(f32, @floatFromInt(px[p11])) * w11,
        .g = @as(f32, @floatFromInt(px[p00 + 1])) * w00 + @as(f32, @floatFromInt(px[p01 + 1])) * w01 + @as(f32, @floatFromInt(px[p10 + 1])) * w10 + @as(f32, @floatFromInt(px[p11 + 1])) * w11,
        .b = @as(f32, @floatFromInt(px[p00 + 2])) * w00 + @as(f32, @floatFromInt(px[p01 + 2])) * w01 + @as(f32, @floatFromInt(px[p10 + 2])) * w10 + @as(f32, @floatFromInt(px[p11 + 2])) * w11,
    };
}

/// How a picture sits in the frame: it covers the frame (the overhang cut), then the camera's scale and offset
/// (in parts of the frame). Gives, for a frame pixel, the point of the picture in parts of it.
const Fit = struct {
    ox: f32,
    oy: f32,
    iw: f32,
    ih: f32,
    fn of(im: *const Image, scale: f32, dx: f32, dy: f32) Fit {
        const W: f32 = @floatFromInt(cw_);
        const H: f32 = @floatFromInt(ch_);
        const k = @max(W / @as(f32, @floatFromInt(im.w)), H / @as(f32, @floatFromInt(im.h))) * scale;
        const w = @as(f32, @floatFromInt(im.w)) * k;
        const h = @as(f32, @floatFromInt(im.h)) * k;
        return .{ .ox = (W - w) / 2 + dx * W, .oy = (H - h) / 2 + dy * H, .iw = 1.0 / w, .ih = 1.0 / h };
    }
};

fn put(i: usize, c: Rgb, alpha: f32) void {
    if (alpha >= 0.999) {
        canvas[i] = @intFromFloat(@min(@max(c.r, 0), 255));
        canvas[i + 1] = @intFromFloat(@min(@max(c.g, 0), 255));
        canvas[i + 2] = @intFromFloat(@min(@max(c.b, 0), 255));
    } else {
        const k = 1 - alpha;
        canvas[i] = @intFromFloat(@min(@max(@as(f32, @floatFromInt(canvas[i])) * k + c.r * alpha, 0), 255));
        canvas[i + 1] = @intFromFloat(@min(@max(@as(f32, @floatFromInt(canvas[i + 1])) * k + c.g * alpha, 0), 255));
        canvas[i + 2] = @intFromFloat(@min(@max(@as(f32, @floatFromInt(canvas[i + 2])) * k + c.b * alpha, 0), 255));
    }
    canvas[i + 3] = 255;
}

/// One picture under a camera, laid over the frame with `alpha`.
export fn veil_r_draw(slot: u32, scale: f32, dx: f32, dy: f32, alpha: f32) u32 {
    if (slot >= SLOTS or canvas.len == 0) return 0;
    const im = &images[slot];
    if (im.px.len == 0 or alpha <= 0) return 0;
    const fit = Fit.of(im, scale, dx, dy);
    var y: u32 = 0;
    while (y < ch_) : (y += 1) {
        const qy = (@as(f32, @floatFromInt(y)) + 0.5 - fit.oy) * fit.ih;
        var x: u32 = 0;
        while (x < cw_) : (x += 1) {
            const qx = (@as(f32, @floatFromInt(x)) + 0.5 - fit.ox) * fit.iw;
            put((@as(usize, y) * cw_ + x) * 4, pixel(im, qx, qy), alpha);
        }
    }
    return 1;
}

/// A flow read at a point given in parts of the frame; the answer in parts of the frame too.
fn flowAt(f: []const f32, w: u32, h: u32, qx: f32, qy: f32) [2]f32 {
    const n = @as(usize, w) * h;
    const gx = @min(@max(qx, 0), 1) * @as(f32, @floatFromInt(w - 1));
    const gy = @min(@max(qy, 0), 1) * @as(f32, @floatFromInt(h - 1));
    return .{ sample(f[0..n], w, h, gx, gy) / @as(f32, @floatFromInt(w)), sample(f[n .. n * 2], w, h, gx, gy) / @as(f32, @floatFromInt(h)) };
}

/// The moment `t` (0..1) between picture `a` and picture `b`: each is carried along the motion between them,
/// `a` forward by t and `b` back by the rest, and the two are mixed. Each picture sits under its own camera
/// (as veil_r_draw's), so a move that was on the first picture is handed over to the second's without a jump.
/// 0 when there is no flow to go by (the caller then mixes the two plainly).
export fn veil_r_morph2(a: u32, b: u32, t: f32, sa: f32, dxa: f32, dya: f32, sb: f32, dxb: f32, dyb: f32, alpha: f32) u32 {
    if (canvas.len == 0 or alpha <= 0) return 0;
    const f = flowFor(a, b) orelse return 0;
    const ia = &images[a];
    const ib = &images[b];
    const fa_ = Fit.of(ia, sa, dxa, dya);
    const fb_ = Fit.of(ib, sb, dxb, dyb);
    const tt = @min(@max(t, 0), 1);
    const mix = tt * tt * (3 - 2 * tt); // the hand-over eases in and out
    var y: u32 = 0;
    while (y < ch_) : (y += 1) {
        const ya = (@as(f32, @floatFromInt(y)) + 0.5 - fa_.oy) * fa_.ih;
        const yb = (@as(f32, @floatFromInt(y)) + 0.5 - fb_.oy) * fb_.ih;
        var x: u32 = 0;
        while (x < cw_) : (x += 1) {
            const xa = (@as(f32, @floatFromInt(x)) + 0.5 - fa_.ox) * fa_.iw;
            const xb = (@as(f32, @floatFromInt(x)) + 0.5 - fb_.ox) * fb_.iw;
            // what is here at this moment came from further back along a's path, and is on its way from b's
            const fa = flowAt(f.ab, f.w, f.h, xa, ya);
            const fb = flowAt(f.ba, f.w, f.h, xb, yb);
            const ca = pixel(ia, xa - fa[0] * tt, ya - fa[1] * tt);
            const cb = pixel(ib, xb - fb[0] * (1 - tt), yb - fb[1] * (1 - tt));
            put((@as(usize, y) * cw_ + x) * 4, .{ .r = ca.r * (1 - mix) + cb.r * mix, .g = ca.g * (1 - mix) + cb.g * mix, .b = ca.b * (1 - mix) + cb.b * mix }, alpha);
        }
    }
    return 1;
}

/// The same, with both pictures under one camera.
export fn veil_r_morph(a: u32, b: u32, t: f32, scale: f32, dx: f32, dy: f32, alpha: f32) u32 {
    return veil_r_morph2(a, b, t, scale, dx, dy, scale, dx, dy, alpha);
}

// ------------------------------------------------------------------------------------------------ steadying
//
// A shot's frames, made one from another by an image model, each repaint every surface: the shapes hold from
// frame to frame, the fine detail does not, and played in order the picture shimmers. STEADYING takes the detail
// from ONE frame (the anchor) and carries it along the motion: for each later frame the path of every part back
// to the anchor is known (the flow from that frame to the one before, added to the path the one before had), so
// the frame is drawn from the anchor's own pixels, moved to where things are now. Where that does not agree with
// the new frame in the large (something came into view, the light changed, the motion was misjudged), the new
// frame's own pixels are kept there. The caller starts a new anchor when too little of a frame could be carried.

const TAU: f32 = 0.085; // a difference in brightness (at the flow's coarse scale) that halves how much is carried
const Chain = struct {
    on: bool = false,
    anchor: u32 = 0,
    stamp: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    prev: []f32 = &.{}, // the frame before, small and grey
    d: []f32 = &.{}, // u then v: from a cell of the frame before, the way back to the anchor (in cells)
};
var chain: Chain = .{};

fn chainDrop() void {
    if (chain.prev.len > 0) gpa.free(chain.prev);
    if (chain.d.len > 0) gpa.free(chain.d);
    chain = .{};
}

/// Start carrying detail from the picture in `anchor`. 1 when ready.
export fn veil_r_chain_begin(anchor: u32) u32 {
    chainDrop();
    if (anchor >= SLOTS) return 0;
    const ia = &images[anchor];
    if (!grayOf(ia)) return 0;
    const n = @as(usize, ia.gw) * ia.gh;
    chain.prev = gpa.dupe(f32, ia.gray) catch return 0;
    chain.d = gpa.alloc(f32, n * 2) catch {
        chainDrop();
        return 0;
    };
    @memset(chain.d, 0);
    chain.on = true;
    chain.anchor = anchor;
    chain.stamp = ia.stamp;
    chain.w = ia.gw;
    chain.h = ia.gh;
    return 1;
}

/// The next frame of the shot (`cur`), steadied into `out` (a slot of its own, given the frame's size): the
/// anchor's detail where it could be carried, the frame's own pixels elsewhere. `keep` (0..1) is how much of the
/// carried detail is used where it agrees. Gives how much of the frame was carried, in thousandths; 0xFFFFFFFF
/// when it could not be done.
export fn veil_r_chain_next(cur: u32, out: u32, keep: f32) u32 {
    const fail: u32 = 0xFFFFFFFF;
    if (!chain.on or cur >= SLOTS or out >= SLOTS or out == cur or out == chain.anchor) return fail;
    const ia = &images[chain.anchor];
    const ic = &images[cur];
    if (ia.stamp != chain.stamp or ic.px.len == 0 or !grayOf(ic) or !grayOf(ia)) return fail;
    const w = chain.w;
    const h = chain.h;
    if (ic.gw != w or ic.gh != h) return fail;
    const n = @as(usize, w) * h;
    const work = gpa.alloc(f32, n * 6) catch return fail;
    defer gpa.free(work);
    const f = work[0 .. n * 2]; // this frame toward the one before
    const dn = work[n * 2 .. n * 4]; // this frame's way back to the anchor
    const wt = work[n * 4 .. n * 5];
    const ws = work[n * 5 .. n * 6];
    if (!flowHS(ic.gray, chain.prev, w, h, f[0..n], f[n .. n * 2])) return fail;
    _ = trust(ic.gray, chain.prev, w, h, f);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = @as(usize, y) * w + x;
            const sx = @as(f32, @floatFromInt(x)) + f[i];
            const sy = @as(f32, @floatFromInt(y)) + f[n + i];
            dn[i] = f[i] + sample(chain.d[0..n], w, h, sx, sy);
            dn[n + i] = f[n + i] + sample(chain.d[n .. n * 2], w, h, sx, sy);
            // does the anchor, read where this cell came from, look like this frame here?
            const a = sample(ia.gray, w, h, @as(f32, @floatFromInt(x)) + dn[i], @as(f32, @floatFromInt(y)) + dn[n + i]);
            const q = @abs(a - ic.gray[i]) / TAU;
            wt[i] = 1.0 / (1.0 + q * q);
        }
    }
    // the weight of a cell, softened over its neighbours so the hand-over between carried and new has no edge
    var sum: f32 = 0;
    y = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var acc: f32 = 0;
            var cnt: f32 = 0;
            var lo: f32 = 1;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const yy = @as(i32, @intCast(y)) + dy;
                    const xx = @as(i32, @intCast(x)) + dx;
                    if (yy < 0 or xx < 0 or yy >= @as(i32, @intCast(h)) or xx >= @as(i32, @intCast(w))) continue;
                    const v = wt[@as(usize, @intCast(yy)) * w + @as(usize, @intCast(xx))];
                    acc += v;
                    cnt += 1;
                    lo = @min(lo, v);
                }
            }
            const v = (acc / cnt) * 0.5 + lo * 0.5; // doubt nearby counts for more than its share
            ws[@as(usize, y) * w + x] = v;
            sum += v;
        }
    }

    // the steadied frame
    const W = ic.w;
    const H = ic.h;
    const io = &images[out];
    dropImage(io);
    io.px = gpa.alloc(u8, @as(usize, W) * H * 4) catch return fail;
    io.w = W;
    io.h = H;
    stamps += 1;
    io.stamp = stamps;
    const k = @min(@max(keep, 0), 1);
    const gx = @as(f32, @floatFromInt(w - 1)) / @as(f32, @floatFromInt(@max(W, 2) - 1));
    const gy = @as(f32, @floatFromInt(h - 1)) / @as(f32, @floatFromInt(@max(H, 2) - 1));
    var py: u32 = 0;
    while (py < H) : (py += 1) {
        const cy = @as(f32, @floatFromInt(py)) * gy;
        const qy = (@as(f32, @floatFromInt(py)) + 0.5) / @as(f32, @floatFromInt(H));
        var px: u32 = 0;
        while (px < W) : (px += 1) {
            const cx = @as(f32, @floatFromInt(px)) * gx;
            const qx = (@as(f32, @floatFromInt(px)) + 0.5) / @as(f32, @floatFromInt(W));
            const i = (@as(usize, py) * W + px) * 4;
            const m = k * sample(ws, w, h, cx, cy);
            const r0: f32 = @floatFromInt(ic.px[i]);
            const g0: f32 = @floatFromInt(ic.px[i + 1]);
            const b0: f32 = @floatFromInt(ic.px[i + 2]);
            if (m < 0.02) {
                io.px[i] = ic.px[i];
                io.px[i + 1] = ic.px[i + 1];
                io.px[i + 2] = ic.px[i + 2];
            } else {
                const du = sample(dn[0..n], w, h, cx, cy) / @as(f32, @floatFromInt(w));
                const dv = sample(dn[n .. n * 2], w, h, cx, cy) / @as(f32, @floatFromInt(h));
                const a = pixel(ia, qx + du, qy + dv);
                io.px[i] = @intFromFloat(@min(@max(a.r * m + r0 * (1 - m), 0), 255));
                io.px[i + 1] = @intFromFloat(@min(@max(a.g * m + g0 * (1 - m), 0), 255));
                io.px[i + 2] = @intFromFloat(@min(@max(a.b * m + b0 * (1 - m), 0), 255));
            }
            io.px[i + 3] = 255;
        }
    }
    @memcpy(chain.prev, ic.gray);
    @memcpy(chain.d, dn);
    return @intFromFloat(sum / @as(f32, @floatFromInt(n)) * 1000.0);
}

/// Where a slot's pixels are (RGBA, its width by its height), for the caller to read a steadied frame out.
export fn veil_r_image_ptr(slot: u32) ?[*]u8 {
    if (slot >= SLOTS or images[slot].px.len == 0) return null;
    return images[slot].px.ptr;
}
export fn veil_r_image_w(slot: u32) u32 {
    return if (slot < SLOTS) images[slot].w else 0;
}
export fn veil_r_image_h(slot: u32) u32 {
    return if (slot < SLOTS) images[slot].h else 0;
}

// ------------------------------------------------------------------------------------------------ the file (MP4)

const Chunk = struct { offset: u64, count: u32 };
const Track = struct {
    sizes: std.ArrayListUnmanaged(u32) = .empty,
    keys: std.ArrayListUnmanaged(u32) = .empty, // sample numbers (from 1) that stand alone
    chunks: std.ArrayListUnmanaged(Chunk) = .empty,
    config: std.ArrayListUnmanaged(u8) = .empty, // avcC for the picture track, AudioSpecificConfig for the sound
    fn reset(t: *Track) void {
        t.sizes.clearRetainingCapacity();
        t.keys.clearRetainingCapacity();
        t.chunks.clearRetainingCapacity();
        t.config.clearRetainingCapacity();
    }
};
const HEAD_LEN = 32 + 16; // ftyp, then mdat's own header (the long form)
var tracks: [2]Track = .{ .{}, .{} };
var mw: u32 = 0;
var mh: u32 = 0;
var mfps: u32 = 30;
var mrate: u32 = 48000;
var mchan: u32 = 2;
var mpos: u64 = HEAD_LEN;
var mlast: u32 = 99;
var mfail = false;

/// Begin a file: pictures w by h at fps frames a second; sound (if any) at `rate` Hz in `channels`.
export fn veil_r_mp4_begin(w: u32, h: u32, fps: u32, rate: u32, channels: u32) void {
    tracks[0].reset();
    tracks[1].reset();
    mw = w;
    mh = h;
    mfps = if (fps == 0) 30 else fps;
    mrate = if (rate == 0) 48000 else rate;
    mchan = if (channels == 0) 2 else channels;
    mpos = HEAD_LEN;
    mlast = 99;
    mfail = false;
}

/// What a track's decoder is told first (track 0: the avcC record; track 1: the AudioSpecificConfig).
export fn veil_r_mp4_config(track: u32, ptr: ?[*]const u8, len: usize) void {
    if (track > 1) return;
    tracks[track].config.clearRetainingCapacity();
    if (ptr) |p| tracks[track].config.appendSlice(gpa, p[0..len]) catch {
        mfail = true;
    };
}

/// The next sample in the file, in the order the page will lay them down: its track, its size, and (pictures)
/// whether it stands alone.
export fn veil_r_mp4_sample(track: u32, size: u32, key: u32) void {
    if (track > 1) return;
    const t = &tracks[track];
    if (mlast != track) {
        t.chunks.append(gpa, .{ .offset = mpos, .count = 0 }) catch {
            mfail = true;
            return;
        };
        mlast = track;
    }
    t.chunks.items[t.chunks.items.len - 1].count += 1;
    t.sizes.append(gpa, size) catch {
        mfail = true;
        return;
    };
    if (track == 0 and key != 0) t.keys.append(gpa, @intCast(t.sizes.items.len)) catch {
        mfail = true;
    };
    mpos += size;
}

const Buf = std.ArrayListUnmanaged(u8);
const Err = error{OutOfMemory};
fn w8(b: *Buf, v: u8) Err!void {
    try b.append(gpa, v);
}
fn w16(b: *Buf, v: u32) Err!void {
    try b.appendSlice(gpa, &.{ @intCast((v >> 8) & 0xff), @intCast(v & 0xff) });
}
fn w32(b: *Buf, v: u32) Err!void {
    try b.appendSlice(gpa, &.{ @intCast((v >> 24) & 0xff), @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) });
}
fn w64(b: *Buf, v: u64) Err!void {
    try w32(b, @intCast(v >> 32));
    try w32(b, @intCast(v & 0xffffffff));
}
fn zeros(b: *Buf, n: usize) Err!void {
    try b.appendNTimes(gpa, 0, n);
}
fn open(b: *Buf, kind: *const [4]u8) Err!usize {
    const at = b.items.len;
    try w32(b, 0);
    try b.appendSlice(gpa, kind);
    return at;
}
fn close(b: *Buf, at: usize) void {
    const n: u32 = @intCast(b.items.len - at);
    b.items[at] = @intCast((n >> 24) & 0xff);
    b.items[at + 1] = @intCast((n >> 16) & 0xff);
    b.items[at + 2] = @intCast((n >> 8) & 0xff);
    b.items[at + 3] = @intCast(n & 0xff);
}
fn matrix(b: *Buf) Err!void {
    const m = [9]u32{ 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000 };
    for (m) |v| try w32(b, v);
}

/// The first bytes of the file: `ftyp`, then the header of the `mdat` box the samples follow in. Asked for once
/// every sample has been told of (it carries their total size).
export fn veil_r_mp4_head() u64 {
    var b: Buf = .empty;
    head(&b) catch {
        b.deinit(gpa);
        return 0;
    };
    return pack(b.toOwnedSlice(gpa) catch return 0);
}
fn head(b: *Buf) Err!void {
    const f = try open(b, "ftyp");
    try b.appendSlice(gpa, "isom");
    try w32(b, 0x200);
    try b.appendSlice(gpa, "isomiso2avc1mp41");
    close(b, f);
    try w32(b, 1); // the long form: the size follows the name
    try b.appendSlice(gpa, "mdat");
    try w64(b, mpos - 32);
}

const VIDEO_SCALE = 90000;

fn descLen(b: *Buf, tag: u8, len: u32) Err!void {
    try w8(b, tag);
    try w8(b, @intCast(0x80 | ((len >> 21) & 0x7f)));
    try w8(b, @intCast(0x80 | ((len >> 14) & 0x7f)));
    try w8(b, @intCast(0x80 | ((len >> 7) & 0x7f)));
    try w8(b, @intCast(len & 0x7f));
}

fn trak(b: *Buf, id: u32, movie_ms: u32) Err!void {
    const t = &tracks[id];
    const video = id == 0;
    const scale: u32 = if (video) VIDEO_SCALE else mrate;
    const delta: u32 = if (video) VIDEO_SCALE / mfps else 1024;
    const n: u32 = @intCast(t.sizes.items.len);
    const dur: u64 = @as(u64, n) * delta;

    const tr = try open(b, "trak");
    {
        const x = try open(b, "tkhd");
        try w32(b, 3); // in the film, and shown
        try w32(b, 0);
        try w32(b, 0);
        try w32(b, id + 1);
        try w32(b, 0);
        try w32(b, @intCast(dur * 1000 / scale));
        try zeros(b, 8);
        try w16(b, 0);
        try w16(b, 0);
        try w16(b, if (video) 0 else 0x0100);
        try w16(b, 0);
        try matrix(b);
        try w32(b, if (video) mw << 16 else 0);
        try w32(b, if (video) mh << 16 else 0);
        close(b, x);
    }
    const md = try open(b, "mdia");
    {
        const x = try open(b, "mdhd");
        try w32(b, 0);
        try w32(b, 0);
        try w32(b, 0);
        try w32(b, scale);
        try w32(b, @intCast(dur));
        try w16(b, 0x55c4); // "und"
        try w16(b, 0);
        close(b, x);
    }
    {
        const x = try open(b, "hdlr");
        try w32(b, 0);
        try w32(b, 0);
        try b.appendSlice(gpa, if (video) "vide" else "soun");
        try zeros(b, 12);
        try b.appendSlice(gpa, if (video) "VideoHandler\x00" else "SoundHandler\x00");
        close(b, x);
    }
    const mi = try open(b, "minf");
    if (video) {
        const x = try open(b, "vmhd");
        try w32(b, 1);
        try zeros(b, 8);
        close(b, x);
    } else {
        const x = try open(b, "smhd");
        try w32(b, 0);
        try w32(b, 0);
        close(b, x);
    }
    {
        const di = try open(b, "dinf");
        const dr = try open(b, "dref");
        try w32(b, 0);
        try w32(b, 1);
        const u = try open(b, "url ");
        try w32(b, 1); // the samples are in this file
        close(b, u);
        close(b, dr);
        close(b, di);
    }
    const st = try open(b, "stbl");
    {
        const sd = try open(b, "stsd");
        try w32(b, 0);
        try w32(b, 1);
        if (video) {
            const e = try open(b, "avc1");
            try zeros(b, 6);
            try w16(b, 1);
            try zeros(b, 16);
            try w16(b, mw);
            try w16(b, mh);
            try w32(b, 0x00480000);
            try w32(b, 0x00480000);
            try w32(b, 0);
            try w16(b, 1);
            try zeros(b, 32);
            try w16(b, 0x0018);
            try w16(b, 0xffff);
            const c = try open(b, "avcC");
            try b.appendSlice(gpa, t.config.items);
            close(b, c);
            close(b, e);
        } else {
            const e = try open(b, "mp4a");
            try zeros(b, 6);
            try w16(b, 1);
            try zeros(b, 8);
            try w16(b, mchan);
            try w16(b, 16);
            try w32(b, 0);
            try w32(b, mrate << 16);
            const es = try open(b, "esds");
            try w32(b, 0);
            const asc: u32 = @intCast(t.config.items.len);
            try descLen(b, 0x03, 3 + 5 + 13 + 5 + asc + 5 + 1);
            try w16(b, 0);
            try w8(b, 0);
            try descLen(b, 0x04, 13 + 5 + asc);
            try w8(b, 0x40); // AAC
            try w8(b, 0x15); // a sound stream
            try zeros(b, 3);
            try w32(b, 192000);
            try w32(b, 128000);
            try descLen(b, 0x05, asc);
            try b.appendSlice(gpa, t.config.items);
            try descLen(b, 0x06, 1);
            try w8(b, 0x02);
            close(b, es);
            close(b, e);
        }
        close(b, sd);
    }
    {
        const x = try open(b, "stts");
        try w32(b, 0);
        try w32(b, 1);
        try w32(b, n);
        try w32(b, delta);
        close(b, x);
    }
    if (video) {
        const x = try open(b, "stss");
        try w32(b, 0);
        try w32(b, @intCast(t.keys.items.len));
        for (t.keys.items) |k| try w32(b, k);
        close(b, x);
    }
    {
        // runs of chunks that hold the same number of samples are said once
        const x = try open(b, "stsc");
        try w32(b, 0);
        const count_at = b.items.len;
        try w32(b, 0);
        var runs: u32 = 0;
        var last: u32 = 0;
        for (t.chunks.items, 0..) |c, i| {
            if (i == 0 or c.count != last) {
                try w32(b, @intCast(i + 1));
                try w32(b, c.count);
                try w32(b, 1);
                runs += 1;
                last = c.count;
            }
        }
        b.items[count_at] = @intCast((runs >> 24) & 0xff);
        b.items[count_at + 1] = @intCast((runs >> 16) & 0xff);
        b.items[count_at + 2] = @intCast((runs >> 8) & 0xff);
        b.items[count_at + 3] = @intCast(runs & 0xff);
        close(b, x);
    }
    {
        const x = try open(b, "stsz");
        try w32(b, 0);
        try w32(b, 0);
        try w32(b, n);
        for (t.sizes.items) |s| try w32(b, s);
        close(b, x);
    }
    if (mpos > 0xffffffff) {
        const x = try open(b, "co64");
        try w32(b, 0);
        try w32(b, @intCast(t.chunks.items.len));
        for (t.chunks.items) |c| try w64(b, c.offset);
        close(b, x);
    } else {
        const x = try open(b, "stco");
        try w32(b, 0);
        try w32(b, @intCast(t.chunks.items.len));
        for (t.chunks.items) |c| try w32(b, @intCast(c.offset));
        close(b, x);
    }
    close(b, st);
    close(b, mi);
    close(b, md);
    close(b, tr);
    _ = movie_ms;
}

/// The last bytes of the file: the `moov` box, which says what the samples are and where each one lies.
export fn veil_r_mp4_moov() u64 {
    if (mfail or tracks[0].sizes.items.len == 0 or tracks[0].config.items.len == 0) return 0;
    var b: Buf = .empty;
    moov(&b) catch {
        b.deinit(gpa);
        return 0;
    };
    return pack(b.toOwnedSlice(gpa) catch return 0);
}
fn moov(b: *Buf) Err!void {
    const sound = tracks[1].sizes.items.len > 0 and tracks[1].config.items.len > 0;
    const vms: u64 = @as(u64, tracks[0].sizes.items.len) * 1000 / mfps;
    const ams: u64 = if (sound) @as(u64, tracks[1].sizes.items.len) * 1024 * 1000 / mrate else 0;
    const ms: u32 = @intCast(@max(vms, ams));
    const mv = try open(b, "moov");
    {
        const x = try open(b, "mvhd");
        try w32(b, 0);
        try w32(b, 0);
        try w32(b, 0);
        try w32(b, 1000);
        try w32(b, ms);
        try w32(b, 0x00010000);
        try w16(b, 0x0100);
        try zeros(b, 10);
        try matrix(b);
        try zeros(b, 24);
        try w32(b, 3);
        close(b, x);
    }
    try trak(b, 0, ms);
    if (sound) try trak(b, 1, ms);
    close(b, mv);
}
