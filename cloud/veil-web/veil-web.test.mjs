// veil-web.test.mjs - the harness's LOCAL JOBS, run under node: `node --test cloud/veil-web/veil-web.test.mjs`.
//
// The Durable Object's storage is a Map with the get/put/delete/setAlarm calls the harness uses, the model is a
// script, and the owner check is answered here (it is Cloudflare's to answer, and is not what these tests are
// about). Nothing here talks to Cloudflare. Only the local-job routes and what they must not disturb are covered.

import test from "node:test";
import assert from "node:assert/strict";
import { Harness, VERSION, QUEUE_MAX } from "./veil-web.js";

class Storage {
  constructor() {
    this.m = new Map();
    this.alarm = null;
  }
  async get(k) {
    const v = this.m.get(k);
    return v === undefined ? undefined : structuredClone(v);
  }
  async put(k, v) {
    this.m.set(k, structuredClone(v));
  }
  async delete(k) {
    return this.m.delete(k);
  }
  async setAlarm(t) {
    this.alarm = t;
  }
}

/// A harness whose model answers `say` to everything, with the reference text already read (no fetch).
async function harness(say = "all done") {
  const storage = new Storage();
  await storage.put("llms", { at: Date.now(), source: "", digest: "" });
  const calls = [];
  const env = { AI: { run: async (model, input) => (calls.push({ model, input }), { response: say }) } };
  const h = new Harness({ storage }, env);
  h.owner = async () => ({ token: "t".repeat(40), account: "a".repeat(32), sub: "acme" });
  const call = async (method, path, body) => {
    const r = await h.fetch(new Request("https://veil-web.acme.workers.dev/v1/" + path, { method, headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }));
    return { status: r.status, j: await r.json() };
  };
  return { h, storage, calls, call };
}

test("the version this file tests", () => {
  assert.equal(VERSION, "18");
});

test("a local job is queued, never run by the alarm, and keeps no alarm going while it waits", async () => {
  const { h, storage, calls, call } = await harness();
  const q = await call("POST", "jobs", { task: "run the test suite in my repo", model: "@cf/x/y", local: true });
  assert.equal(q.status, 200);
  assert.equal(q.j.local, true);
  assert.equal(storage.alarm, null); // queueing it wakes nothing

  await h.alarm();
  assert.equal(calls.length, 0); // the model was never asked
  assert.equal(storage.alarm, null); // and nothing is rearmed for it
  const listed = (await call("GET", "jobs")).j.jobs;
  assert.equal(listed.length, 1);
  assert.equal(listed[0].state, "queued");
  assert.equal(listed[0].local, true);
  assert.equal(listed[0].note, "waiting for the owner's machine");
  assert.equal((await call("GET", "status")).j.queue.local, 1);
});

test("a cloud job queued beside a local one runs as before; the local one is still waiting", async () => {
  const { h, calls, call } = await harness("the answer is 4");
  const local = (await call("POST", "jobs", { task: "list my downloads folder", model: "@cf/x/y", local: true })).j.id;
  const cloud = (await call("POST", "jobs", { task: "what is 2 + 2", model: "@cf/x/y" })).j;
  assert.equal(cloud.local, false);
  await h.alarm();
  assert.equal(calls.length, 1);
  const done = (await call("GET", "jobs/" + cloud.id)).j.job;
  assert.equal(done.state, "done");
  assert.equal(done.result, "the answer is 4");
  assert.equal((await call("GET", "jobs/" + local)).j.job.state, "queued");
});

test("the machine asks for local jobs, takes one, and posts its result; an ended job takes no second result", async () => {
  const { call } = await harness();
  const id = (await call("POST", "jobs", { task: "run the test suite\nin my repo", model: "@cf/x/y", local: true })).j.id;
  await call("POST", "jobs", { task: "a cloud job", model: "@cf/x/y" });

  const waiting = (await call("GET", "local")).j.jobs;
  assert.equal(waiting.length, 1); // the cloud job is not the machine's
  assert.equal(waiting[0].id, id);
  assert.equal(waiting[0].task, "run the test suite\nin my repo"); // whole, not the one-line preview
  assert.equal(waiting[0].model, "@cf/x/y");
  assert.equal(waiting[0].state, "queued");
  assert.ok(waiting[0].t > 0);

  const took = await call("POST", "local/" + id, { started: true });
  assert.equal(took.j.state, "running");
  const row = (await call("GET", "jobs")).j.jobs.find((j) => j.id === id);
  assert.equal(row.note, "running on the owner's machine");
  assert.equal((await call("GET", "local")).j.jobs[0].state, "running"); // still listed until it ends

  const ended = await call("POST", "local/" + id, { ok: true, result: "42 passed, 0 failed" });
  assert.equal(ended.j.state, "done");
  const job = (await call("GET", "jobs/" + id)).j.job;
  assert.equal(job.result, "42 passed, 0 failed");
  assert.equal(job.note, "");
  assert.ok(job.finished >= job.started && job.started > 0);
  assert.equal((await call("GET", "local")).j.jobs.length, 0);

  const again = await call("POST", "local/" + id, { ok: true, result: "something else" });
  assert.equal(again.status, 409);
  assert.equal((await call("GET", "jobs/" + id)).j.job.result, "42 passed, 0 failed");
});

test("a failure posted by the machine fails the job in the machine's words; a long result is cut", async () => {
  const { call } = await harness();
  const a = (await call("POST", "jobs", { task: "build it", model: "@cf/x/y", local: true })).j.id;
  await call("POST", "local/" + a, { ok: false, result: "the run on the owner's machine ended without an answer" });
  const failed = (await call("GET", "jobs/" + a)).j.job;
  assert.equal(failed.state, "failed");
  assert.equal(failed.error, "the run on the owner's machine ended without an answer");
  assert.equal(failed.result, "");

  const b = (await call("POST", "jobs", { task: "print a lot", model: "@cf/x/y", local: true })).j.id;
  await call("POST", "local/" + b, { ok: true, result: "x".repeat(50000) });
  assert.ok((await call("GET", "jobs/" + b)).j.job.result.length <= 10001);
});

test("the local routes refuse what is not theirs: a cloud job, an unknown id, a body that says neither thing", async () => {
  const { call } = await harness();
  const cloud = (await call("POST", "jobs", { task: "a cloud job", model: "@cf/x/y" })).j.id;
  assert.equal((await call("POST", "local/" + cloud, { ok: true, result: "forged" })).status, 404);
  assert.equal((await call("GET", "jobs/" + cloud)).j.job.result, "");
  assert.equal((await call("POST", "local/nosuchjob", { started: true })).status, 404);
  const local = (await call("POST", "jobs", { task: "a local job", model: "@cf/x/y", local: true })).j.id;
  assert.equal((await call("POST", "local/" + local, { result: "no ok field" })).status, 400);
  assert.equal((await call("GET", "jobs/" + local)).j.job.state, "queued");
  // only `local: true` makes a job local
  const loose = (await call("POST", "jobs", { task: "a job", model: "@cf/x/y", local: "yes" })).j;
  assert.equal(loose.local, false);
});

test("a cancelled local job leaves the machine's list, and local jobs count toward the waiting limit", async () => {
  const { call } = await harness();
  const id = (await call("POST", "jobs", { task: "a local job", model: "@cf/x/y", local: true })).j.id;
  assert.equal((await call("DELETE", "jobs/" + id)).status, 200);
  assert.equal((await call("GET", "local")).j.jobs.length, 0);
  assert.equal((await call("POST", "local/" + id, { ok: true, result: "late" })).status, 404);
  for (let i = 0; i < QUEUE_MAX; i++) assert.equal((await call("POST", "jobs", { task: "job " + i, model: "@cf/x/y", local: true })).status, 200);
  assert.equal((await call("POST", "jobs", { task: "one too many", model: "@cf/x/y", local: true })).status, 429);
});

// ---------------------------------------------------------------- the mesh

const DESK = "desk0000aaaa1111";
const SHOP = "shop0000bbbb2222";

test("a node says it is here, is listed online, and goes offline when it stops saying so", async () => {
  const { storage, call } = await harness();
  assert.equal((await call("POST", "nodes/" + DESK, { name: "  Office   desk ", kind: "desk", os: "windows", version: "1.2.3", runs: true, mcp: ["files", "git"], garrett: true })).status, 200);
  assert.equal((await call("POST", "nodes/" + SHOP, { name: "Shop tab", kind: "web", browser: true })).status, 200);
  let got = (await call("GET", "nodes")).j;
  assert.deepEqual(got.nodes.map((n) => [n.id, n.name, n.kind, n.runs, n.browser, n.garrett, n.online, n.waiting]), [[DESK, "Office desk", "desk", true, false, true, true, 0], [SHOP, "Shop tab", "web", false, true, false, true, 0]]);
  assert.deepEqual(got.nodes[0].mcp, ["files", "git"]);
  assert.deepEqual((await call("GET", "status")).j.nodes, { count: 2, online: 2, max: 16 });

  // the shop tab was last seen two minutes ago
  const nodes = await storage.get("nodes");
  nodes[1].seen -= 120000;
  await storage.put("nodes", nodes);
  got = (await call("GET", "nodes")).j;
  assert.deepEqual(got.nodes.map((n) => n.online), [true, false]);

  // saying it again keeps when it was first seen, and a forgotten node is gone
  const first = got.nodes[0].first;
  await call("POST", "nodes/" + DESK, { name: "Office desk", kind: "desk" });
  assert.equal((await call("GET", "nodes")).j.nodes[0].first, first);
  assert.equal((await call("DELETE", "nodes/" + SHOP)).j.deleted, SHOP);
  assert.equal((await call("GET", "nodes")).j.nodes.length, 1);
});

test("a node is refused without a name, with an unknown kind or with a bad id", async () => {
  const { call } = await harness();
  assert.equal((await call("POST", "nodes/" + DESK, { kind: "desk" })).status, 400);
  assert.equal((await call("POST", "nodes/" + DESK, { name: "x", kind: "toaster" })).status, 400);
  assert.equal((await call("POST", "nodes/Short", { name: "x", kind: "desk" })).status, 400);
});

test("a job addressed to a node is handed to that node only; one addressed to nobody goes to whoever asks", async () => {
  const { h, calls, call } = await harness();
  await call("POST", "nodes/" + DESK, { name: "Office", kind: "desk", runs: true });
  await call("POST", "nodes/" + SHOP, { name: "Shop", kind: "desk", runs: true });
  const forShop = (await call("POST", "jobs", { task: "count the stock files", model: "@cf/x/y", node: SHOP, from: DESK })).j;
  assert.equal(forShop.local, true); // an addressed job is a local job
  assert.equal(forShop.node, SHOP);
  const forAny = (await call("POST", "jobs", { task: "say hello", model: "@cf/x/y", local: true })).j;

  await h.alarm();
  assert.equal(calls.length, 0); // the cloud runs neither

  const ids = async (q) => (await call("GET", "local" + q)).j.jobs.map((j) => j.id);
  assert.deepEqual(await ids("?node=" + SHOP), [forShop.id, forAny.id]);
  assert.deepEqual(await ids("?node=" + DESK), [forAny.id]);
  assert.deepEqual(await ids(""), [forAny.id]); // a machine that names no node never sees an addressed job
  const mine = (await call("GET", "local?node=" + SHOP)).j.jobs[0];
  assert.equal(mine.node, SHOP);
  assert.equal(mine.from, DESK);
  assert.equal((await call("GET", "nodes")).j.nodes.find((n) => n.id === SHOP).waiting, 1);

  await call("POST", "local/" + forShop.id, { ok: true, result: "41 files" });
  assert.equal((await call("GET", "jobs/" + forShop.id)).j.job.result, "41 files");
  assert.equal((await call("GET", "nodes")).j.nodes.find((n) => n.id === SHOP).waiting, 0);
});

test("a job cannot be addressed to a node the harness has not heard from", async () => {
  const { call } = await harness();
  const r = await call("POST", "jobs", { task: "x", model: "@cf/x/y", node: "nobody00cccc3333" });
  assert.equal(r.status, 404);
  assert.equal((await call("GET", "jobs")).j.jobs.length, 0);
});

test("shared settings: the last write of a name wins, each carries its time, a bad name or value is refused whole", async () => {
  const { call } = await harness();
  const a = (await call("POST", "settings", { set: { "desk.model": "@cf/x/y", "desk.clef": true, "desk.font_scale": 110 } })).j;
  assert.equal(a.settings["desk.model"].v, "@cf/x/y");
  assert.ok(a.settings["desk.model"].at > 0);
  await call("POST", "settings", { set: { "desk.model": "@cf/z/w" }, del: ["desk.clef"] });
  const got = (await call("GET", "settings")).j.settings;
  assert.equal(got["desk.model"].v, "@cf/z/w");
  assert.equal(got["desk.font_scale"].v, 110);
  assert.equal(got["desk.clef"], undefined);

  assert.equal((await call("POST", "settings", { set: { "Bad Name": 1 } })).status, 400);
  assert.equal((await call("POST", "settings", { set: { "desk.ok": "fine", "desk.obj": { a: 1 } } })).status, 400);
  assert.equal((await call("GET", "settings")).j.settings["desk.ok"], undefined); // the refused write kept nothing
  assert.equal((await call("POST", "settings", { set: { "desk.long": "x".repeat(2001) } })).status, 400);
});

test("share hands the owner the kept connections whole; status still shows no token", async () => {
  const { storage, call } = await harness();
  assert.deepEqual((await call("GET", "share")).j, { ok: true, garrett: null, mcp: [] });
  await storage.put("garrett", { url: "https://agent.example.com/mcp", token: "gtt_secret", tools: 7, at: 5 });
  await storage.put("mcp", [{ name: "files", url: "https://mcp.example.com/", token: "tok", session: "s", tools: 3 }]);
  const got = (await call("GET", "share")).j;
  assert.deepEqual(got.garrett, { url: "https://agent.example.com/mcp", token: "gtt_secret", tools: 7, at: 5 });
  assert.deepEqual(got.mcp, [{ name: "files", url: "https://mcp.example.com/", token: "tok" }]);
  assert.ok(!JSON.stringify((await call("GET", "status")).j).includes("gtt_secret"));
});

// ---------------------------------------------------------------------------------------------- images
//
// The image catalog and what image() sends. The model list and the schemas below are cut from the definitions
// Cloudflare publishes for these models (developers.cloudflare.com/workers-ai/models, read 2026-11-13); the
// account's API is answered here, and env.AI is a script that records what it was asked.

const SD_INPUT = { type: "object", properties: { prompt: { type: "string" }, negative_prompt: { type: "string" }, height: { type: "integer", minimum: 256, maximum: 2048 }, width: { type: "integer", minimum: 256, maximum: 2048 }, image: { type: "array" }, image_b64: { type: "string" }, mask: { type: "array" }, num_steps: { type: "integer", default: 20, maximum: 20 }, strength: { type: "number", default: 1 }, guidance: { type: "number", default: 7.5 }, seed: { type: "integer" } }, required: ["prompt"] };
const SCHNELL_INPUT = { type: "object", properties: { prompt: { type: "string", maxLength: 2048 }, steps: { type: "integer", maximum: 8 } }, required: ["prompt"] };
const FORM_INPUT = { type: "object", properties: { multipart: { type: "object", properties: { body: { type: "object" }, contentType: { type: "string" } } } }, required: ["multipart"] };
const IMAGE_ROWS = [
  { name: "@cf/stabilityai/stable-diffusion-xl-base-1.0", description: "SDXL", created_at: "2023-11-01 10:00:00.000", properties: [{ property_id: "beta", value: "true" }], input: SD_INPUT },
  { name: "@cf/black-forest-labs/flux-1-schnell", description: "FLUX.1 schnell", created_at: "2024-08-01 10:00:00.000", properties: [], input: SCHNELL_INPUT },
  { name: "@cf/black-forest-labs/flux-2-dev", description: "FLUX.2 dev", created_at: "2025-11-24 15:44:06.050", properties: [{ property_id: "partner", value: "true" }, { property_id: "terms", value: "https://bfl.ai/legal/terms-of-service" }], input: FORM_INPUT },
  { name: "@cf/lykon/dreamshaper-8-lcm", description: "Dreamshaper", created_at: "2024-03-01 10:00:00.000", properties: [{ property_id: "planned_deprecation_date", value: "2026-11-20" }], input: null }, // no schema answered
];
// models the account marks as seeing pictures: two to ask about one (each in its own shape), one with no schema
// answered, and a decision model that reads pictures to another end
const SEES = [{ property_id: "vision", value: "true" }];
const LOOK_ROWS = [
  { name: "@cf/moondream/moondream3.1-9B-A2B", description: "Moondream", input: { type: "object", properties: { task: { type: "string", enum: ["query", "caption", "point", "detect"] }, image: { type: "string" }, question: { type: "string" } } } },
  { name: "@cf/meta/llama-4-scout-17b-16e-instruct", properties: SEES, input: { oneOf: [{ type: "object", properties: { prompt: { type: "string" } } }, { type: "object", properties: { messages: { type: "array" } } }] } },
  { name: "@cf/x/no-schema-vision", properties: SEES, input: null },
  { name: "@cf/cloudflare/clef-flash", properties: SEES, input: { type: "object", properties: { state: { type: "string" }, questions: { type: "object" } } } },
];
// a one-pixel PNG, as bytes and as base64
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const PNG_B64 = btoa(String.fromCharCode(...PNG));

/// A harness whose account lists IMAGE_ROWS, with an AI that answers pictures the way `answer` says.
async function studio(answer = () => ({ image: PNG_B64 })) {
  const made = await harness();
  const asked = [];
  made.h.api = async (token, method, path) => {
    asked.push(path);
    const u = new URL("https://x" + path);
    if (u.pathname.endsWith("/ai/models/search")) {
      const task = u.searchParams.get("task");
      if (task === "Text-to-Image") return { success: true, result: IMAGE_ROWS.map(({ input, ...row }) => row) };
      if (task === "Image-to-Text") return { success: true, result: LOOK_ROWS.filter((r) => r.name.includes("moondream")).map(({ input, ...row }) => row) };
      return { success: true, result: [...LOOK_ROWS.filter((r) => !r.name.includes("moondream")).map(({ input, ...row }) => row), { name: "@cf/meta/llama-3.3-70b-instruct-fp8-fast", properties: [] }] };
    }
    if (u.pathname.endsWith("/ai/models/schema")) {
      const row = [...IMAGE_ROWS, ...LOOK_ROWS].find((r) => r.name === u.searchParams.get("model"));
      return row?.input ? { success: true, result: { input: row.input, output: {} } } : { success: false, errors: [{ message: "no schema" }] };
    }
    return { success: false, errors: [{ message: "not found" }] };
  };
  const runs = [];
  made.h.env.AI.run = async (model, input) => {
    let form = null;
    if (input.multipart) form = Object.fromEntries([...(await new Response(input.multipart.body, { headers: { "content-type": input.multipart.contentType } }).formData()).entries()].map(([k, v]) => [k, typeof v === "string" ? v : `<${v.type}>`]));
    runs.push({ model, input, form });
    return answer(model, input, form);
  };
  return { ...made, asked, runs };
}

test("the image catalog reads each model's own schema: its settings, their names and their limits", async () => {
  const { call, asked } = await studio();
  const j = (await call("GET", "image/models")).j;
  assert.equal(j.ok, true);
  const by = Object.fromEntries(j.models.map((m) => [m.id.split("/").pop(), m]));
  const sd = by["stable-diffusion-xl-base-1.0"];
  assert.equal(sd.form, "json");
  assert.equal(sd.schema, true);
  assert.equal(sd.negative, true);
  assert.deepEqual(sd.width, { key: "width", int: true, min: 256, max: 2048, def: null });
  assert.deepEqual(sd.steps, { key: "num_steps", int: true, min: null, max: 20, def: 20 }); // the schema's name for steps
  assert.equal(sd.init, "image_b64");
  assert.equal(sd.mask, true);
  assert.equal(sd.seed, true);
  assert.equal(sd.beta, true);
  const schnell = by["flux-1-schnell"];
  assert.equal(schnell.width, null); // it takes no size
  assert.equal(schnell.prompt_max, 2048);
  assert.deepEqual(schnell.steps, { key: "steps", int: true, min: null, max: 8, def: null });
  assert.equal(schnell.negative, false);
  assert.equal(schnell.seed, false);
  const flux2 = by["flux-2-dev"];
  assert.equal(flux2.form, "multipart");
  assert.equal(flux2.refs, 4);
  assert.equal(flux2.width.max, 1920);
  assert.equal(flux2.partner, true);
  const dream = by["dreamshaper-8-lcm"];
  assert.equal(dream.schema, false); // Cloudflare answered no schema for it
  assert.equal(dream.retires, "2026-11-20");
  // the models to ask about a picture, each with the shape its schema names; the decision model is not one
  assert.deepEqual(j.vision.map((v) => [v.id, v.how]), [["@cf/meta/llama-4-scout-17b-16e-instruct", "parts"], ["@cf/moondream/moondream3.1-9B-A2B", "skill"], ["@cf/x/no-schema-vision", "parts"]]);

  // kept: a second ask costs the account no API call; ?fresh=1 asks again
  const n = asked.length;
  await call("GET", "image/models");
  assert.equal(asked.length, n);
  await call("GET", "image/models?fresh=1");
  assert.ok(asked.length > n);
});

test("a picture's settings go to the model under its schema's names, inside its limits, and only if it takes them", async () => {
  const { call, runs } = await studio((model) => (model.includes("stable-diffusion") ? new ReadableStream({ start(c) { c.enqueue(PNG); c.close(); } }) : { image: PNG_B64 }));
  await call("GET", "image/models");

  const sd = await call("POST", "image", { model: "@cf/stabilityai/stable-diffusion-xl-base-1.0", prompt: "a fox", negative: "blurry", width: 4000, height: 512, steps: 99, guidance: 6.5, seed: 7 });
  assert.equal(sd.status, 200);
  assert.equal(sd.j.type, "image/png"); // the bytes came back as a stream and are handed on as base64
  assert.equal(sd.j.image, PNG_B64);
  assert.deepEqual(runs[0].input, { prompt: "a fox", width: 2048, height: 512, num_steps: 20, guidance: 6.5, seed: 7, negative_prompt: "blurry" });

  // a model that takes no size, no seed and no negative prompt is sent none
  await call("POST", "image", { model: "@cf/black-forest-labs/flux-1-schnell", prompt: "a fox", negative: "blurry", width: 1024, height: 1024, steps: 6, guidance: 5, seed: 7 });
  assert.deepEqual(runs[1].input, { prompt: "a fox", steps: 6 });

  // a model whose schema is a form is sent a form, at once, with the pictures in it
  const form = await call("POST", "image", { model: "@cf/black-forest-labs/flux-2-dev", prompt: "the subject of image 0 at night", width: 1024, height: 768, seed: 3, guidance: 4, images: ["data:image/png;base64," + PNG_B64, "data:image/png;base64," + PNG_B64] });
  assert.equal(form.status, 200);
  assert.equal(runs.length, 3); // no plain try first
  assert.deepEqual(runs[2].form, { prompt: "the subject of image 0 at night", width: "1024", height: "768", guidance: "4", seed: "3", input_image_0: "<image/png>", input_image_1: "<image/png>" });
});

test("a picture to start from, its strength and its mask reach a model that takes them", async () => {
  const { call, runs } = await studio();
  await call("GET", "image/models");
  const r = await call("POST", "image", { model: "@cf/stabilityai/stable-diffusion-xl-base-1.0", prompt: "a fox at night", images: ["data:image/png;base64," + PNG_B64], strength: 0.4, mask: "data:image/png;base64," + PNG_B64 });
  assert.equal(r.status, 200);
  assert.equal(runs[0].input.image_b64, PNG_B64);
  assert.equal(runs[0].input.strength, 0.4);
  assert.deepEqual(runs[0].input.mask, [...PNG]); // the mask picture's bytes, as the schema asks
  assert.equal((await call("POST", "image", { model: "@cf/stabilityai/stable-diffusion-xl-base-1.0", prompt: "x", images: ["data:image/png;base64," + PNG_B64], mask: "not a picture" })).status, 400);
});

test("a model's refusal comes back as the model's own words, and a model with no schema is still asked both ways", async () => {
  const { call, runs } = await studio((model, input) => {
    if (model.includes("stable-diffusion")) throw new Error("3030: the prompt was flagged");
    if (model.includes("dreamshaper") && !input.multipart) throw new Error("5006: expected multipart");
    return { image: PNG_B64 };
  });
  await call("GET", "image/models");
  const no = await call("POST", "image", { model: "@cf/stabilityai/stable-diffusion-xl-base-1.0", prompt: "x" });
  assert.equal(no.status, 502);
  assert.match(no.j.err, /3030: the prompt was flagged/);
  assert.equal(runs.length, 1); // its schema said JSON: the form was not tried, so the refusal is the real one
  // and it stays the real one after a call that worked taught the harness this model's way
  const { call: call2, runs: runs2 } = await studio((model, input) => { if (/flagged/.test(input.prompt)) throw new Error("3030: the prompt was flagged"); return { image: PNG_B64 }; });
  await call2("GET", "image/models");
  assert.equal((await call2("POST", "image", { model: "@cf/stabilityai/stable-diffusion-xl-base-1.0", prompt: "fine" })).status, 200);
  const again = await call2("POST", "image", { model: "@cf/stabilityai/stable-diffusion-xl-base-1.0", prompt: "flagged" });
  assert.equal(again.j.err, "no picture came back: 3030: the prompt was flagged");
  assert.equal(runs2.length, 2);
  const learned = await call("POST", "image", { model: "@cf/lykon/dreamshaper-8-lcm", prompt: "x", steps: 4 });
  assert.equal(learned.status, 200);
  assert.equal(runs.length, 3); // fields, then the form
  await call("POST", "image", { model: "@cf/lykon/dreamshaper-8-lcm", prompt: "x" });
  assert.equal(runs.length, 4); // the form at once: it was learned
});

test("a schema outranks what was learned, and a model that refuses a start picture is remembered and listed without it", async () => {
  const { call, runs, storage } = await studio((model, input) => {
    if (input.image_b64) throw new Error("3030: Model input is not valid: input tensor `image` is not present in the model");
    return { image: PNG_B64 };
  });
  await call("GET", "image/models");
  // an earlier harness learned, wrongly, that this JSON model wants a form: its schema is what is followed
  await storage.put("quirks", { "@cf/black-forest-labs/flux-1-schnell": { form: true } });
  assert.equal((await call("POST", "image", { model: "@cf/black-forest-labs/flux-1-schnell", prompt: "a fox", steps: 4 })).status, 200);
  assert.deepEqual(runs[0].input, { prompt: "a fox", steps: 4 });
  assert.equal(runs[0].form, null);

  const sd = "@cf/stabilityai/stable-diffusion-xl-base-1.0";
  const listed = async () => (await call("GET", "image/models")).j.models.find((m) => m.id === sd);
  assert.equal((await listed()).init, "image_b64"); // what its schema says
  const no = await call("POST", "image", { model: sd, prompt: "the fox at night", images: ["data:image/png;base64," + PNG_B64] });
  assert.equal(no.status, 502);
  assert.match(no.j.err, /does not take a picture to start from/);
  assert.match(no.j.err, /is not present in the model/); // the model's own words are still there
  const now = await listed();
  assert.equal(now.init, "");
  assert.equal(now.mask, false);
  assert.equal(now.negative, true); // nothing else about it changed
  assert.equal((await call("POST", "image", { model: sd, prompt: "a fox" })).status, 200); // and it still makes pictures from words
});

test("a vision model is asked in the shape it answers, and its answer is read under the name it uses", async () => {
  const { call, runs, storage } = await studio((model, input) => {
    if (input.messages) { if (model.includes("moondream") || model.includes("llava")) throw new Error("5006: no messages here"); return { response: "a red square" }; }
    if (input.task) return model.includes("moondream") ? { answer: "a red square, says the skill" } : (() => { throw new Error("5006"); })();
    if (Array.isArray(input.image)) return model.includes("llava") ? { description: "a red square, described" } : (() => { throw new Error("5006"); })();
    return {};
  });
  const image = "data:image/png;base64," + PNG_B64;
  assert.equal((await call("POST", "look", { model: "@cf/meta/llama-4-scout-17b-16e-instruct", image })).j.text, "a red square");
  assert.equal((await call("POST", "look", { model: "@cf/llava-hf/llava-1.5-7b-hf", image, question: "what is it?" })).j.text, "a red square, described");
  assert.equal((await call("POST", "look", { model: "@cf/moondream/moondream3.1-9B-A2B", image })).j.text, "a red square, says the skill");
  const n = runs.length;
  await call("POST", "look", { model: "@cf/moondream/moondream3.1-9B-A2B", image });
  assert.equal(runs.length, n + 1); // the shape that answered is asked first from then on
  assert.equal((await storage.get("quirks"))["@cf/moondream/moondream3.1-9B-A2B"].look, "skill");
});

test("left to choose, the harness takes the best working model listed now, and the next one when that fails", async () => {
  const { rankModels } = await import("./veil-web.js");
  const now = Date.parse("2026-11-13T12:00:00Z");
  const list = [
    { id: "old", created: "2023-01-01", beta: false, retires: "" },
    { id: "new", created: "2026-01-01", beta: false, retires: "" },
    { id: "newer-beta", created: "2026-06-01", beta: true, retires: "" },
    { id: "leaving", created: "2026-09-01", beta: false, retires: "2026-11-20" },
    { id: "gone", created: "2026-10-01", beta: false, retires: "2026-11-01" },
  ];
  const ids = (health) => rankModels(list, health, now).map((m) => m.id);
  assert.deepEqual(ids({}), ["new", "old", "newer-beta", "leaving"]); // staying before leaving, finished before beta, newer before older; the retired one is not there
  assert.deepEqual(ids({ new: { ok: 0, fail: 1, streak: 1, at: now - 1000 } }), ["old", "newer-beta", "leaving", "new"]); // one that failed its first call waits
  assert.deepEqual(ids({ new: { ok: 5, fail: 1, streak: 1, at: now - 1000 } }), ["new", "old", "newer-beta", "leaving"]); // one that has worked is forgiven one failure
  assert.deepEqual(ids({ new: { ok: 0, fail: 3, streak: 3, at: now - 7 * 3600 * 1000 } }), ["new", "old", "newer-beta", "leaving"]); // and a rest ends

  const down = new Set(["@cf/black-forest-labs/flux-2-dev"]);
  const { call, runs } = await studio((model, input) => {
    if (down.has(model)) throw new Error("7000: the model is not available");
    if (/flagged/.test(input.prompt ?? "")) throw new Error("3030: the prompt was flagged");
    return { image: PNG_B64 };
  });
  const cat = (await call("GET", "image/models")).j;
  // of the four listed: flux-2-dev is the newest that stays and is no beta; dreamshaper leaves in a week
  assert.deepEqual(cat.order.make.map((id) => id.split("/").pop()), ["flux-2-dev", "flux-1-schnell", "stable-diffusion-xl-base-1.0", "dreamshaper-8-lcm"]);
  assert.equal(cat.picks.make, "@cf/black-forest-labs/flux-2-dev");
  assert.deepEqual(cat.order.edit.map((id) => id.split("/").pop()), ["flux-2-dev", "stable-diffusion-xl-base-1.0"]);
  assert.equal(cat.picks.inpaint, "@cf/stabilityai/stable-diffusion-xl-base-1.0");

  // the first choice is down: the picture still comes, from the next one, and the reply says who made it
  const made = await call("POST", "image", { model: "auto", prompt: "a fox" });
  assert.equal(made.status, 200);
  assert.equal(made.j.model, "@cf/black-forest-labs/flux-1-schnell");
  assert.equal(made.j.auto, true);
  assert.equal(made.j.tried[0].model, "@cf/black-forest-labs/flux-2-dev");
  // and the one that failed is not the first choice any more, nor tried again while it rests
  const after = (await call("GET", "image/models")).j;
  assert.equal(after.picks.make, "@cf/black-forest-labs/flux-1-schnell");
  assert.equal(after.models.find((m) => m.id === "@cf/black-forest-labs/flux-2-dev").health.streak, 1);
  const n = runs.length;
  assert.equal((await call("POST", "image", { prompt: "a fox" })).j.model, "@cf/black-forest-labs/flux-1-schnell"); // no model named at all
  assert.equal(runs.length, n + 1);

  // a refusal of the request is nobody's failure: no other model is asked, and no model is marked down
  const flagged = await call("POST", "image", { model: "auto", prompt: "flagged" });
  assert.equal(flagged.status, 502);
  assert.match(flagged.j.err, /3030: the prompt was flagged/);
  assert.equal(runs.length, n + 2);
  assert.equal((await call("GET", "image/models")).j.picks.make, "@cf/black-forest-labs/flux-1-schnell");

  // work from a picture goes to a model that takes one
  const edit = await call("POST", "image", { model: "auto", prompt: "at night", images: ["data:image/png;base64," + PNG_B64] });
  assert.equal(edit.j.model, "@cf/stabilityai/stable-diffusion-xl-base-1.0"); // flux-2-dev is resting

  // reading a picture: the model made for it first, until another has answered
  assert.equal(after.picks.look, "@cf/moondream/moondream3.1-9B-A2B");
});

test("speech: each model's own field and voices, the harness's choice when none is named, sound back as base64", async () => {
  const VOICE_ROWS = [
    { name: "@cf/deepgram/aura-2-en", description: "Aura 2", created_at: "2025-10-09 22:19:34.483", input: { type: "object", properties: { speaker: { type: "string", default: "luna", enum: ["luna", "orion", "zeus"] }, text: { type: "string" } } } },
    { name: "@cf/deepgram/aura-2-es", description: "Aura 2, Spanish", created_at: "2025-10-09 22:42:37.002", input: { type: "object", properties: { speaker: { type: "string", default: "aquila", enum: ["aquila", "diana"] }, text: { type: "string" } } } },
    { name: "@cf/myshell-ai/melotts", description: "MeloTTS", created_at: "2024-07-19 15:51:04.819", properties: [{ property_id: "planned_deprecation_date", value: "2026-11-20" }], input: { type: "object", properties: { prompt: { type: "string" }, lang: { type: "string", default: "en" } }, required: ["prompt"] } },
  ];
  const MP3 = Uint8Array.from({ length: 400 }, (_, i) => (i === 0 ? 0xff : i === 1 ? 0xfb : i % 251));
  const WAV = new Uint8Array(400);
  WAV.set([..."RIFF"].map((c) => c.charCodeAt(0)), 0);
  WAV.set([..."WAVE"].map((c) => c.charCodeAt(0)), 8);
  const { h, call, runs } = await studio((model, input) => (model.includes("aura") ? new ReadableStream({ start(c) { c.enqueue(MP3); c.close(); } }) : { audio: btoa(String.fromCharCode(...WAV)) }));
  const images = h.api;
  h.api = async (token, method, path) => {
    const u = new URL("https://x" + path);
    if (u.pathname.endsWith("/ai/models/search") && u.searchParams.get("task") === "Text-to-Speech") return { success: true, result: VOICE_ROWS.map(({ input, ...row }) => row) };
    const row = VOICE_ROWS.find((r) => r.name === u.searchParams.get("model"));
    if (u.pathname.endsWith("/ai/models/schema") && row) return { success: true, result: { input: row.input } };
    return images(token, method, path);
  };
  const cat = (await call("GET", "image/models")).j;
  const aura = cat.voices.find((v) => v.id.endsWith("aura-2-en")), melo = cat.voices.find((v) => v.id.endsWith("melotts"));
  assert.equal(aura.key, "text");
  assert.deepEqual(aura.speakers, ["luna", "orion", "zeus"]);
  assert.equal(aura.speaker, "luna");
  assert.equal(melo.key, "prompt");
  assert.equal(melo.lang, true);
  assert.equal(cat.picks.speak, "@cf/deepgram/aura-2-en"); // English unless told otherwise, though the Spanish one is newer; never the one retiring next week
  assert.equal((await call("POST", "speak", { text: "Buenas noches.", lang: "es-MX" })).j.model, "@cf/deepgram/aura-2-es"); // a text is spoken by a model of its language

  assert.equal((await call("POST", "speak", { text: "Bonsoir.", lang: "fr" })).j.model, "@cf/myshell-ai/melotts"); // no French model: the one that takes a language, though it is leaving
  const said = await call("POST", "speak", { text: "The lamp turned once more.", voice: "orion", lang: "en-GB" });
  assert.equal(said.status, 200);
  assert.equal(said.j.model, "@cf/deepgram/aura-2-en");
  assert.equal(said.j.type, "audio/mpeg");
  assert.equal(atob(said.j.audio).length, 400);
  assert.deepEqual(runs.at(-1).input, { text: "The lamp turned once more.", speaker: "orion" }); // a voice it lists; no language, it takes none

  const melod = await call("POST", "speak", { model: "@cf/myshell-ai/melotts", text: "Bonsoir.", voice: "orion", lang: "fr" });
  assert.equal(melod.j.type, "audio/wav"); // told from the bytes, whatever the model was expected to send
  assert.deepEqual(runs.at(-1).input, { prompt: "Bonsoir.", lang: "fr" }); // its own field; a voice it does not list is not sent
  assert.equal((await call("POST", "speak", { text: "  " })).status, 400);
});

test("clef is shown the pictures a question is about; a picture that cannot be read gives no answer at all", async () => {
  const { call, runs } = await studio((model, input) => ({ answers: Object.fromEntries(Object.keys(input.questions).map((k) => [k, { noul: input.images ? 0.9 : 0.1 }])) }));
  const pic = "data:image/png;base64," + PNG_B64;
  const seen = await call("POST", "clef", { state: "Two frames of one shot.", questions: ["Is the second the same scene as the first?"], images: [pic, pic] });
  assert.deepEqual(seen.j.probs, [0.9]);
  assert.deepEqual(runs.at(-1).input.images, [{ content_type: "image/png", base64: PNG_B64 }, { content_type: "image/png", base64: PNG_B64 }]);
  const plain = await call("POST", "clef", { state: "Text only.", questions: ["Is it text?"] });
  assert.deepEqual(plain.j.probs, [0.1]);
  assert.equal(runs.at(-1).input.images, undefined); // as before, when no picture is sent
  const n = runs.length;
  assert.equal((await call("POST", "clef", { state: "x", questions: ["q?"], images: [pic, "not a picture"] })).j.probs, null);
  assert.equal(runs.length, n); // and Clef was not asked
});

test("a frame is directed: the harness looks, writes the prompt, has it made, and has Clef confirm it; a frame that fails is corrected and made again", async () => {
  let clefAsks = 0;
  const { call, runs, storage } = await studio((model, input) => {
    if (input.questions) { clefAsks++; return { answers: Object.fromEntries(Object.keys(input.questions).map((k, i) => [k, { noul: clefAsks === 1 && i === 0 ? 0.1 : 0.9 }])) }; } // the first frame has something added
    const says = (m) => (m.includes("moondream") ? "Sure! Your prompt must say VERBATIM what the image model never sees." : '{"stays": "A red fox sits at the left of a snowy field under a pale sky, facing right, in soft watercolour.", "change": "The ear of the fox turns slightly toward the camera."}');
    if (input.task) return { answer: says(model) };
    if (input.messages) return { response: says(model) };
    return { image: PNG_B64 };
  });
  await call("GET", "image/models");
  const pic = "data:image/png;base64," + PNG_B64;
  const r = await call("POST", "frame", { shot: "a fox in snow", style: "watercolour", beat: "the fox looks up", before: pic, start: pic, anchor: pic, model: "@cf/black-forest-labs/flux-2-dev", width: 1024, height: 576 });
  assert.equal(r.status, 200);
  assert.equal(r.j.fits, true);
  assert.equal(r.j.tries, 2); // made, refused by Clef, corrected, made again
  assert.equal(r.j.directed, true);
  assert.deepEqual(r.j.probs, [0.9, 0.9, 0.9]);
  // the order of the work: one look, then (a picture, then Clef) twice
  const kinds = runs.map((x) => (x.input.messages || x.input.task ? "look" : x.input.questions ? "clef" : "image"));
  // the first vision model talked about the task instead of the picture: its answer was not used, the next was asked
  assert.deepEqual(kinds, ["look", "look", "image", "clef", "image", "clef"]);
  assert.match(runs[0].model, /moondream/);
  runs.shift();
  assert.equal((await storage.get("quirks"))["@cf/moondream/moondream3.1-9B-A2B"].directs, false); // and that is remembered
  assert.equal(r.j.director, runs[0].model);
  // the director was shown the frame and told the shot, its style and where it is going
  const asked = runs[0].input.messages[0].content;
  assert.match(asked.find((x) => x.type === "text").text, /THE SHOT: a fox in snow[\s\S]*THE STYLE: watercolour[\s\S]*WHERE THE SHOT IS GOING: the fox looks up/);
  // the image model was given the director's words, the frame as the camera moved it, and the shot's first frame
  assert.match(runs[1].form.prompt, /^A red fox sits at the left of a snowy field[\s\S]*Add nothing and take nothing away\.$/);
  assert.equal(runs[1].form.input_image_0, "<image/png>");
  assert.equal(runs[1].form.input_image_1, "<image/png>");
  // Clef saw both frames; and the second try carries the correction for what the first failed
  assert.equal(runs[2].input.images.length, 2);
  assert.equal(Object.keys(runs[2].input.questions).length, 3);
  assert.match(runs[3].form.prompt, /IMPORTANT: exactly the same people and things/);
  assert.equal(r.j.prompt, runs[3].form.prompt);
  // without a frame to go from there is nothing to direct
  assert.equal((await call("POST", "frame", { shot: "a fox", before: "nope" })).status, 400);
});

test("with no word from Clef, a vision model is shown both frames and confirms the frame in its place", async () => {
  const { call, runs, storage } = await studio((model, input) => {
    if (input.questions) throw new Error("5007: clef is not here");
    const parts = input.messages?.[0]?.content;
    if (Array.isArray(parts) && parts.filter((x) => x.type === "image_url").length === 2) return { response: model.includes("scout") ? '{"same": false, "follows": true, "sound": true}' : "They look alike to me." };
    if (input.messages || input.task) return { response: '{"stays": "A red fox sits at the left of a snowy field under a pale sky, facing right, in soft watercolour.", "change": "The ear of the fox turns slightly."}', answer: '{"stays": "A red fox sits at the left of a snowy field under a pale sky, facing right, in soft watercolour.", "change": "The ear of the fox turns slightly."}' };
    return { image: PNG_B64 };
  });
  await call("GET", "image/models");
  const pic = "data:image/png;base64," + PNG_B64;
  const r = await call("POST", "frame", { shot: "a fox in snow", before: pic, model: "@cf/black-forest-labs/flux-2-dev", tries: 1 });
  assert.equal(r.status, 200);
  assert.equal(r.j.judge, "@cf/meta/llama-4-scout-17b-16e-instruct"); // who confirmed it
  assert.deepEqual(r.j.probs, [0.1, 0.9, 0.9]); // and it said the scene is not the same
  assert.equal(r.j.fits, false);
  const twin = runs.find((x) => Array.isArray(x.input.messages?.[0]?.content) && x.input.messages[0].content.filter((p) => p.type === "image_url").length === 2);
  assert.ok(twin, "a model was shown both frames in one message");
  assert.equal((await storage.get("quirks"))["@cf/meta/llama-4-scout-17b-16e-instruct"].pair, true);
});
