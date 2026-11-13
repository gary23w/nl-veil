// render.test.mjs - the video renderer inside veil_core.wasm, run under node:
//   node --test src/web/render.test.mjs            (reads docs/chat/veil_core.wasm)
// Pictures are made here (a smooth pattern, and the same pattern moved), so what a right answer is, is known.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const file = process.env.VEIL_CORE_WASM ?? new URL("../../docs/chat/veil_core.wasm", import.meta.url);
const { instance } = await WebAssembly.instantiate(fs.readFileSync(file), {});
const x = instance.exports;
const mem = () => new Uint8Array(x.memory.buffer);

/// A smooth, busy picture: sums of waves, so every part of it can be told from its neighbours. (ox, oy) moves it.
function pattern(w, h, ox = 0, oy = 0) {
  const px = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) for (let xx = 0; xx < w; xx++) {
    const u = (xx - ox) / w, v = (y - oy) / h;
    const a = Math.sin(u * 19) * Math.cos(v * 13) + Math.sin((u + v) * 31) * 0.6 + Math.cos(u * 7 - v * 23) * 0.5;
    const i = (y * w + xx) * 4;
    px[i] = 128 + 60 * a; px[i + 1] = 128 + 50 * Math.sin(a * 2 + u * 9); px[i + 2] = 128 + 55 * Math.cos(a * 1.5 - v * 11); px[i + 3] = 255;
  }
  return px;
}
function load(slot, w, h, px) {
  const p = x.veil_r_image(slot, w, h);
  assert.ok(p > 0);
  mem().set(px, p);
}
function frame(w, h) {
  const p = x.veil_r_canvas(w, h);
  return () => mem().slice(p, p + w * h * 4);
}
const diff = (a, b, w, h, margin) => {
  let sum = 0, n = 0;
  for (let y = margin; y < h - margin; y++) for (let xx = margin; xx < w - margin; xx++) { const i = (y * w + xx) * 4; sum += Math.abs(a[i] - b[i]) + Math.abs(a[i + 1] - b[i + 1]) + Math.abs(a[i + 2] - b[i + 2]); n += 3; }
  return sum / n;
};

test("the module carries both cores: the context core's exports are still there, the renderer's beside them", () => {
  assert.equal(x.veil_core_abi(), 1);
  assert.equal(x.veil_r_abi(), 1);
  for (const name of ["veil_alloc", "veil_free", "veil_net_unfold", "veil_net_protected", "veil_net_head", "veil_r_image", "veil_r_flow", "veil_r_canvas", "veil_r_draw", "veil_r_morph", "veil_r_fade", "veil_r_mp4_begin", "veil_r_mp4_sample", "veil_r_mp4_head", "veil_r_mp4_moov"]) assert.equal(typeof x[name], "function", name);
});

test("a picture is drawn covering the frame; the camera's scale and offset move it; a fade darkens it", () => {
  const W = 320, H = 180;
  load(0, W, H, pattern(W, H));
  const read = frame(W, H);
  x.veil_r_clear();
  assert.equal(x.veil_r_draw(0, 1, 0, 0, 1), 1);
  const plain = read();
  assert.ok(diff(plain, pattern(W, H), W, H, 2) < 1.5); // the picture itself, at its own size
  x.veil_r_draw(0, 1.2, 0.05, 0, 1);
  assert.ok(diff(read(), plain, W, H, 2) > 8); // not the same frame once the camera has moved
  x.veil_r_draw(0, 1, 0, 0, 1);
  x.veil_r_fade(0.5);
  const dim = read();
  assert.ok(Math.abs(dim[4 * 5000] - plain[4 * 5000] / 2) <= 2);
  x.veil_r_fade(1);
  assert.equal(read()[4 * 5000], 0);
  assert.equal(x.veil_r_draw(7, 1, 0, 0, 1), 0); // an empty slot draws nothing
});

test("the motion between two pictures is found, and the frame between them is the picture half-way there", () => {
  const W = 320, H = 180, dx = 8, dy = 4; // the second picture is the first, moved 8 right and 4 down
  load(1, W, H, pattern(W, H));
  load(2, W, H, pattern(W, H, dx, dy));
  assert.equal(x.veil_r_flow(1, 2), 1);
  const travel = x.veil_r_flow_travel(); // mean |u|+|v|, in thousandths of the width: (8 + 4) / 320 = 37.5
  assert.ok(travel > 25 && travel < 50, "travel " + travel);

  const read = frame(W, H);
  const truth = pattern(W, H, dx / 2, dy / 2); // where the picture is, half-way
  assert.equal(x.veil_r_morph(1, 2, 0.5, 1, 0, 0, 1), 1);
  const morphed = diff(read(), truth, W, H, 16);
  // against a plain mix of the two pictures (what a slide show's cross-fade shows at that moment)
  x.veil_r_draw(1, 1, 0, 0, 1);
  x.veil_r_draw(2, 1, 0, 0, 0.5);
  const mixed = diff(read(), truth, W, H, 16);
  assert.ok(morphed < mixed * 0.45, `morph is off by ${morphed.toFixed(2)}, a cross-fade by ${mixed.toFixed(2)}`);
  assert.ok(morphed < 6, "morph error " + morphed.toFixed(2));

  // the ends are the pictures themselves
  x.veil_r_morph(1, 2, 0, 1, 0, 0, 1);
  assert.ok(diff(read(), pattern(W, H), W, H, 16) < 2);
  x.veil_r_morph(1, 2, 1, 1, 0, 0, 1);
  assert.ok(diff(read(), pattern(W, H, dx, dy), W, H, 16) < 2);

  // a slot filled again: the old motion is not used for the new picture
  load(2, W, H, pattern(W, H));
  x.veil_r_flow(1, 2);
  assert.ok(x.veil_r_flow_travel() < 3);
});

test("a shot is steadied: the first frame's detail is carried along the motion, and the repainting of each frame is gone", () => {
  // six frames of one move (3 px a frame), each "repainted": the same shapes with fine noise of its own laid over
  const W = 320, H = 180, step = 3;
  let seed = 7;
  const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
  const repaint = (px) => { const out = px.slice(); for (let i = 0; i < out.length; i += 4) { const nz = (rnd() - 0.5) * 44; out[i] = Math.max(0, Math.min(255, out[i] + nz)); out[i + 1] = Math.max(0, Math.min(255, out[i + 1] + nz)); out[i + 2] = Math.max(0, Math.min(255, out[i + 2] + nz)); } return out; };
  const clean = (k) => pattern(W, H, k * step, 0);
  load(10, W, H, clean(0)); // the anchor: a frame as it should look
  assert.equal(x.veil_r_chain_begin(10), 1);
  let raw = 0, steady = 0, carried = 0;
  const outs = [];
  for (let k = 1; k <= 5; k++) {
    const frame = repaint(clean(k));
    load(11, W, H, frame);
    const got = x.veil_r_chain_next(11, 12, 1);
    assert.notEqual(got, 0xFFFFFFFF);
    carried += got;
    assert.equal(x.veil_r_image_w(12), W);
    const p = x.veil_r_image_ptr(12);
    const out = mem().slice(p, p + W * H * 4);
    outs.push(out);
    raw += diff(frame, clean(k), W, H, 20);
    steady += diff(out, clean(k), W, H, 20);
  }
  assert.ok(carried / 5 > 700, "carried " + carried / 5); // nearly all of each frame came from the anchor
  assert.ok(steady < raw * 0.5, `steadied frames are off by ${(steady / 5).toFixed(2)}, the repainted ones by ${(raw / 5).toFixed(2)}`);
  // and something that is NOT in the anchor stays the frame's own: a white block appears in the last frame
  const withBlock = clean(6);
  for (let y = 60; y < 110; y++) for (let xx = 130; xx < 190; xx++) { const i = (y * W + xx) * 4; withBlock[i] = withBlock[i + 1] = withBlock[i + 2] = 255; }
  load(11, W, H, withBlock);
  x.veil_r_chain_next(11, 12, 1);
  const p = x.veil_r_image_ptr(12);
  const out = mem().slice(p, p + W * H * 4);
  const at = (85 * W + 160) * 4;
  assert.ok(out[at] > 215, "the new thing is kept: " + out[at]);
});

test("shape: one thing in a frame that the frame before does not lead to shows in the worst part, though the average barely moves", () => {
  const W = 320, H = 180;
  const a = pattern(W, H), b = pattern(W, H, 2, 1); // the same picture, moved a little
  load(14, W, H, a);
  load(15, W, H, b);
  x.veil_r_flow(14, 15);
  const calm = [x.veil_r_flow_miss(), x.veil_r_flow_worst()];
  // now a thing appears in the second frame: a dark block a tenth of the frame wide
  const c = b.slice();
  for (let y = 70; y < 105; y++) for (let xx = 200; xx < 235; xx++) { const i = (y * W + xx) * 4; c[i] = c[i + 1] = c[i + 2] = 20; }
  load(15, W, H, c);
  x.veil_r_flow(14, 15);
  const added = [x.veil_r_flow_miss(), x.veil_r_flow_worst()];
  console.log(`  same shapes: miss ${calm[0]}, worst part ${calm[1]}; a thing added: miss ${added[0]}, worst part ${added[1]}`);
  assert.ok(calm[1] < 40, "calm worst " + calm[1]);
  assert.ok(added[1] > calm[1] * 3 && added[1] > 90, "the added thing shows: " + added[1]);
  assert.ok(added[0] < calm[0] + 25); // the average alone would have let it through
});

test("a full-size frame is composed fast enough to play", () => {
  const W = 1280, H = 720;
  load(3, 1344, 768, pattern(1344, 768));
  load(4, 1344, 768, pattern(1344, 768, 20, 6));
  frame(W, H);
  x.veil_r_flow(3, 4);
  const t0 = performance.now();
  for (let i = 0; i < 10; i++) x.veil_r_morph(3, 4, i / 10, 1, 0, 0, 1);
  const ms = (performance.now() - t0) / 10;
  console.log(`  a 1280x720 morphed frame: ${ms.toFixed(1)} ms`);
  assert.ok(ms < 120);
});

test("the file's index: every sample's size and place, the two tracks, and boxes whose sizes add up", () => {
  x.veil_r_mp4_begin(1280, 720, 30, 48000, 2);
  const cfg = (track, bytes) => { const p = x.veil_alloc(bytes.length); mem().set(bytes, p); x.veil_r_mp4_config(track, p, bytes.length); x.veil_free(p, bytes.length); };
  cfg(0, Uint8Array.from([1, 0x64, 0, 0x28, 0xff, 0xe1, 0, 4, 0x67, 0x64, 0, 0x28, 1, 0, 4, 0x68, 0xee, 0x3c, 0x80]));
  cfg(1, Uint8Array.from([0x11, 0x90]));
  // one second of pictures, then one of sound, twice over
  const sizes = [];
  for (let s = 0; s < 2; s++) {
    for (let i = 0; i < 30; i++) { x.veil_r_mp4_sample(0, 1000 + i, i === 0 ? 1 : 0); sizes.push(1000 + i); }
    for (let i = 0; i < 47; i++) { x.veil_r_mp4_sample(1, 200, 0); sizes.push(200); }
  }
  const take = (packed) => { const v = BigInt.asUintN(64, BigInt(packed)); const ptr = Number(v >> 32n), len = Number(v & 0xffffffffn); const out = mem().slice(ptr, ptr + len); x.veil_free(ptr, len); return out; };
  const head = take(x.veil_r_mp4_head()), moov = take(x.veil_r_mp4_moov());
  const dv = new DataView(head.buffer);
  assert.equal(head.length, 48);
  assert.equal(String.fromCharCode(...head.subarray(4, 8)), "ftyp");
  assert.equal(String.fromCharCode(...head.subarray(36, 40)), "mdat");
  const total = sizes.reduce((a, b) => a + b, 0);
  assert.equal(Number(dv.getBigUint64(40)), 16 + total); // the mdat box: its header and every sample
  // the boxes nest exactly: each one's size is its header plus what is in it
  const mv = new DataView(moov.buffer);
  const walk = (at, end, depth, seen) => {
    while (at < end) {
      const size = mv.getUint32(at), name = String.fromCharCode(...moov.subarray(at + 4, at + 8));
      assert.ok(size >= 8 && at + size <= end, `${name} at ${at} overruns`);
      seen.push(name);
      if (["moov", "trak", "mdia", "minf", "stbl", "dinf"].includes(name)) walk(at + 8, at + size, depth + 1, seen);
      at += size;
    }
    assert.equal(at, end);
    return seen;
  };
  const names = walk(0, moov.length, 0, []);
  assert.equal(names.filter((n) => n === "trak").length, 2);
  for (const n of ["mvhd", "tkhd", "mdhd", "hdlr", "vmhd", "smhd", "stsd", "stts", "stss", "stsc", "stsz", "stco"]) assert.ok(names.includes(n), n);
  // the first picture chunk starts right after the head; the first sound chunk after the first 30 pictures
  const find = (name, nth) => { let k = -1; for (let i = 0; i + 8 <= moov.length; i++) if (String.fromCharCode(...moov.subarray(i + 4, i + 8)) === name && ++k === nth) return i; return -1; };
  const stco0 = find("stco", 0), stco1 = find("stco", 1);
  assert.equal(mv.getUint32(stco0 + 12), 2); // two chunks of pictures
  assert.equal(mv.getUint32(stco0 + 16), 48);
  assert.equal(mv.getUint32(stco1 + 16), 48 + sizes.slice(0, 30).reduce((a, b) => a + b, 0));
  // nothing to write before a decoder's first word is known
  x.veil_r_mp4_begin(64, 64, 30, 48000, 2);
  x.veil_r_mp4_sample(0, 10, 1);
  assert.equal(x.veil_r_mp4_moov(), 0n);
});
