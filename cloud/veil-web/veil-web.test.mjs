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
  assert.equal(VERSION, "9");
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
