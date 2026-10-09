// tot.test.mjs — the tot runtime (tot.js) run whole under node: `node --test cloud/`.
//
// The Durable Object's storage is a sorted Map with the same get/put/list/alarm calls the platform gives, the
// object namespace builds one Tot per name, and the model is a script: each test says what the model answers and
// then reads what the tot did with it. Nothing here talks to Cloudflare.

import test from "node:test";
import assert from "node:assert/strict";
import worker, { Tot, VERSION, DEFAULT_MAX_TOTS, MAX_TOTS_CEIL, PRIMARY, PLATEAU, firstJson, answerText, parseAction, nativeCalls, pickText, searchResults, privateHost, parseGoalCommand, parseVerdict, evidenceVerdict, repeatedGoal, decide, newGoal, recordIteration, validName, parseGuardCommand, watchKey, judgeTarget, chainHash, verifyChain } from "./tot.js";

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
  async deleteAll() {
    this.m.clear();
  }
  async transaction(fn) {
    const previous = this.transactionTail ?? Promise.resolve();
    let release;
    this.transactionTail = new Promise((resolve) => (release = resolve));
    await previous;
    const before = structuredClone(this.m);
    try {
      return await fn(this);
    } catch (e) {
      this.m = before;
      throw e;
    } finally {
      release();
    }
  }
  async list({ prefix = "", startAfter, limit = Infinity, reverse = false } = {}) {
    let keys = [...this.m.keys()].filter((k) => k.startsWith(prefix)).sort();
    if (startAfter !== undefined) keys = keys.filter((k) => k > startAfter);
    if (reverse) keys.reverse();
    return new Map(keys.slice(0, limit).map((k) => [k, structuredClone(this.m.get(k))]));
  }
  async setAlarm(ms) {
    this.alarm = ms;
  }
  async getAlarm() {
    return this.alarm;
  }
  async deleteAlarm() {
    this.alarm = null;
  }
}

/// One account: the namespace, the model script, a clock, and the Worker's front door.
function world(script) {
  const w = { now: Date.parse("2026-10-01T12:00:00Z"), objects: new Map(), asked: [], script: script ?? (() => '{"final": "nothing to do"}') };
  w.env = {
    TOT_TOKEN: "tok-secret",
    AI: {
      run: async (model, input) => {
        w.asked.push({ model, input });
        return { response: await w.script(input.messages ?? input.input, w.asked.length, input) };
      },
    },
    TOT: {
      idFromName: (name) => name,
      get: (name) => {
        if (!w.objects.has(name)) {
          const storage = new Storage();
          const tot = new Tot({ storage }, w.env);
          tot.now = () => w.now;
          w.objects.set(name, tot);
        }
        const tot = w.objects.get(name);
        return { fetch: (url, init) => tot.fetch(new Request(url, init)) };
      },
    },
  };
  w.req = async (method, path, body, token = "tok-secret") => {
    const r = await worker.fetch(new Request("https://veil-tots.example.workers.dev" + path, { method, headers: { authorization: "Bearer " + token }, body: body === undefined ? undefined : JSON.stringify(body) }), w.env);
    return { status: r.status, body: await r.json() };
  };
  w.tot = (name) => w.objects.get("tot:" + name.toLowerCase());
  /// Fire the tot's alarm the way the platform does: the alarm is cleared, then the handler runs.
  w.tick = async (name) => {
    const tot = w.tot(name);
    tot.store.alarm = null;
    await tot.alarm();
  };
  w.events = async (name) => (await w.req("GET", `/v1/tots/${name}/events?after=0&limit=500`)).body.events;
  return w;
}

const said = (messages) => messages.map((m) => m.content).join("\n");
const proofLine = (outcome, evidence, proof, score = "none") => `${outcome} | score: ${score} | evidence: ${evidence} | proof: ${JSON.stringify(proof)}`;

test("progress requires a source observation, not a saved failure, invented quote or ungrounded score", () => {
  const record = [
    { tool: "write_file", args: { name: "result.txt" }, result: "saved result.txt (12 characters)" },
    { tool: "web_fetch", args: { url: "https://tides.example/" }, result: "HTTP 429\nToo many requests" },
    { tool: "browser_read", args: {}, result: "Today\nHigh tide 04:12\nLow tide 10:40" },
    { tool: "read_file", args: { name: "result.txt" }, result: "Login failed" },
  ];
  for (const proof of [
    { tool: 1, quote: "saved result.txt", kind: "observation" },
    { tool: 2, quote: "Too many requests", kind: "observation" },
    { tool: 3, quote: "Report submitted", kind: "observation" },
    { tool: 4, quote: "Login failed", kind: "observation" },
    { tool: 19, quote: "High tide 04:12", kind: "observation" },
  ]) {
    const v = evidenceVerdict(proofLine("IMPROVED", "reported success", proof, "1/1"), record);
    assert.equal(v.verified, false);
    assert.equal(decide({ best_num: 0, best_den: 1 }, v), "same"); // a false score cannot bypass the check
    assert.equal(v.complete, false);
  }
  assert.equal(evidenceVerdict("IMPROVED | score: 1/1 | evidence: trust me", []).outcome, "same");
  const good = evidenceVerdict(proofLine("IMPROVED", "tide time observed", { tool: 3, quote: "High tide 04:12", kind: "observation" }), record);
  assert.equal(good.verified, true);
  assert.equal(good.outcome, "improved");
  assert.equal(evidenceVerdict(proofLine("IMPROVED", "same tide time", { tool: 3, quote: "High tide 04:12", kind: "observation" }), record, [good.proof_key]).outcome, "same");
  const badScore = evidenceVerdict(proofLine("REGRESSED", "request failed", { tool: 2, quote: "Too many requests", kind: "observation", complete: true }, "9/10"), record);
  assert.equal(decide({ best_num: 1, best_den: 10 }, badScore), "regressed");
  assert.equal(badScore.complete, false);
});

test("artifact verification checks content and gives an unchanged file no second improvement", () => {
  const record = [{ tool: "read_file", args: { name: "poem.txt" }, result: "The sea is blue\nThe sky is clear" }];
  const v = evidenceVerdict(proofLine("IMPROVED", "requested poem read back", { tool: 1, quote: "The sea is blue", kind: "artifact", complete: true }, "1/1"), record);
  assert.equal(v.verified, true);
  assert.equal(v.complete, true);
  const again = evidenceVerdict(proofLine("IMPROVED", "another line of the poem", { tool: 1, quote: "The sky is clear", kind: "artifact", complete: true }), record, [v.proof_key]);
  assert.equal(again.outcome, "same");
  assert.equal(again.complete, true); // a completed artifact may still be verified again
  assert.equal(evidenceVerdict(proofLine("IMPROVED", "partial artifact", { tool: 1, quote: "The sea is blue", kind: "artifact", complete: true }, "1/2"), record).complete, false);
});

test("roaming recognizes an ended goal despite punctuation or a repeated-word preamble", () => {
  const ended = [{ text: "Check the tide tables against the harbour source", status: "plateau" }];
  assert.equal(repeatedGoal("CHECK the tide tables against the harbour source!", ended), true);
  assert.equal(repeatedGoal("Check: check the tide tables against the harbour source.", ended), true);
  assert.equal(repeatedGoal("Repair the Python runner and verify requests with a local fixture", ended), false);
});

test("a bare DONE and a fabricated perfect score never mark an unverified goal achieved", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "DONE";
    if (text.includes("THIS ITERATION'S STEP")) return '{"final":"everything is complete"}';
    if (text.includes("Grade the LAST iteration")) return "IMPROVED | score: 10/10 | evidence: everything complete";
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "retrieve ten public tide tables" });
  await w.tick("Gary");
  const g = await w.tot("Gary").store.get("goal");
  assert.equal(g.status, "active");
  assert.equal(g.improved, 0);
  assert.equal(g.best_den, 0);
  assert.equal(g.flat, 1);
  assert.ok((await w.events("Gary")).some((e) => e.kind === "pick" && /Verify the entire goal/.test(e.text)));
  assert.ok(!(await w.events("Gary")).some((e) => /goal achieved/.test(e.text)));
});

test("a failed runner and its saved error earn no progress and remain visible after the human changes the goal", async () => {
  let phase = "failure";
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) {
      if (phase === "fallback") {
        assert.match(text, /LAST MEASURED WORK[\s\S]*NoGilError/);
        assert.match(text, /CURRENT UTC TIME: 2026-10-01T12:00:00\.000Z/);
        return "Read the browser result instead of reusing the broken runner";
      }
      return "Fetch public tide tables with Python and verify the response";
    }
    if (text.includes("THIS ITERATION'S STEP")) {
      if (phase === "fallback") return '{"final":"next method selected"}';
      if (!text.includes("RESULT of run_python")) return '{"tool":"run_python","args":{"code":"print(1)"}}';
      assert.match(text, /This attempt failed\. Diagnose its cause/);
      if (!text.includes("RESULT of write_file")) return '{"tool":"write_file","args":{"name":"failure.txt","text":"NoGilError: runner failed"}}';
      return '{"final":"saved the failure"}';
    }
    if (text.includes("Grade the LAST iteration")) return phase === "failure" ? proofLine("IMPROVED", "failure.txt saved", { tool: 2, quote: "saved failure.txt", kind: "observation" }, "1/1") : "SAME | score: none | evidence: no new result";
    return "NONE";
  });
  w.env.PY = { fetch: async (_url, init) => {
    if (JSON.parse(init.body).caps) return new Response(JSON.stringify({ ok: true, native: [] }));
    throw new Error("NoGilError: Attempted to use PyProxy when Python GIL not held");
  } };
  await w.req("POST", "/v1/tots", { goal: "retrieve public tide tables" });
  await w.tick("Gary");
  assert.equal((await w.tot("Gary").store.get("goal")).improved, 0);
  assert.equal((await w.tot("Gary").store.get("note:failure.txt")).text, "NoGilError: runner failed");
  phase = "fallback";
  await w.req("POST", "/v1/tots/Gary/command", { text: "/goal verify public tide tables using the browser" });
  await w.tick("Gary");
  assert.equal((await w.tot("Gary").store.get("goal")).iteration, 1);
});

test("the judge sees a confirmation at the end of a long tool response", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Fetch and verify the tide table";
    if (text.includes("THIS ITERATION'S STEP")) return text.includes("RESULT of web_fetch") ? '{"final":"table retrieved"}' : '{"tool":"web_fetch","args":{"url":"https://tides.example/today"}}';
    if (text.includes("Grade the LAST iteration")) {
      assert.match(text, /T1 TOOL web_fetch/);
      assert.match(text, /High tide 04:12\nLow tide 10:40/);
      return proofLine("IMPROVED", "tide table retrieved", { tool: 1, quote: "High tide 04:12\nLow tide 10:40", kind: "observation", complete: true }, "1/1");
    }
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "retrieve today's high and low tide times" });
  w.tot("Gary").runTool = async () => "HTTP 200\n" + "Navigation\n".repeat(2200) + "High tide 04:12\nLow tide 10:40";
  await w.tick("Gary");
  assert.equal((await w.tot("Gary").store.get("goal")).status, "achieved");
});

test("roaming remembers more than eight ended goals and explicit queued work can still revisit them", async () => {
  const repeated = "Retrieve public tide times for the harbour from the coast source";
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("You have no active goal")) {
      assert.match(text, /Retrieve public tide times for the harbour from the coast source/);
      return repeated.toUpperCase() + "!";
    }
    if (text.includes("GOAL LOOP")) return "Verify the source again after the human's new request";
    if (text.includes("THIS ITERATION'S STEP")) return '{"final":"no new observation"}';
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "current work has ended", pace_s: 60 });
  const tot = w.tot("Gary");
  const g = await tot.store.get("goal");
  g.status = "plateau";
  await tot.store.put("goal", g);
  for (let i = 1; i <= 12; i++) await tot.store.put("done:" + String(i).padStart(10, "0"), { id: i + 20, text: i === 1 ? repeated : "ended unrelated work " + i, status: "plateau", improved: 0 });
  await tot.store.put("doneseq", 12);
  await w.tick("Gary");
  assert.equal((await tot.store.get("goal")).id, g.id);
  assert.equal(tot.store.alarm, w.now + 120000);
  assert.ok((await w.events("Gary")).some((e) => /proposed goal repeats ended work/.test(e.text)));
  await w.req("POST", "/v1/tots/Gary/command", { text: "/queue " + repeated });
  await w.tick("Gary");
  assert.equal((await tot.store.get("goal")).text, repeated);
  assert.equal((await tot.store.get("goal")).iteration, 1);
});

test("RSI edits the actual shared runtime without a local grant, keeps revisions, and reports deployment failures", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "improve my runtime" });
  const tot = w.tot("Gary");
  const cfg = await tot.store.get("cfg");
  const run = (tool, args = {}) => tot.runTool(cfg, tool, args, "");
  assert.equal(cfg.local, false);
  assert.equal((await w.req("GET", "/v1/runtime", undefined, "wrong")).status, 401);
  assert.equal((await w.req("POST", "/v1/runtime/seed", { source: "x" }, "wrong")).status, 401);
  assert.match(await run("runtime_read"), /not synced yet/);
  const source = "// runtime\n" + "// long source\n".repeat(13000) + "export const STOP = true;\n";
  assert.equal((await w.req("POST", "/v1/runtime/seed", { source })).body.ok, true);
  let read = await run("runtime_read", { offset: source.length - 26 });
  assert.ok(read.includes(source.slice(-26)));
  assert.equal(JSON.parse(read.split("\nSOURCE:\n")[0]).next_offset, source.length);
  assert.match(await run("runtime_read", { find: "STOP = true" }), /export const STOP = true/);
  assert.match(await run("runtime_read", { find: "no such function" }), /^ERROR: that text was not found/);
  const edit = JSON.parse(await run("runtime_edit", { revision: 0, find: "STOP = true", replace: "STOP = false" }));
  assert.equal(edit.revision, 1);
  assert.equal(edit.status, "draft");
  assert.equal((await w.req("GET", "/v1/runtime")).body.source, ""); // drafts are not deployed implicitly
  assert.match(await run("runtime_edit", { revision: 0, find: "STOP", replace: "GO" }), /revision changed/);
  assert.equal(JSON.parse(await run("runtime_deploy", { revision: 1 })).status, "pending");
  let pending = (await w.req("GET", "/v1/runtime")).body;
  assert.equal(pending.source, source.replace("STOP = true", "STOP = false"));
  await w.req("POST", "/v1/runtime/result", { revision: 1, err: "SyntaxError from Cloudflare" });
  read = await run("runtime_read");
  assert.match(read, /"status":"failed"/);
  assert.match(read, /SyntaxError from Cloudflare/);
  assert.match(read, /"deployed_revision":0/);
  await run("runtime_deploy", { revision: 1 });
  await w.req("POST", "/v1/runtime/result", { revision: 1, err: "" });
  assert.match(await run("runtime_read"), /"deployed_revision":1/);
  // A restarted host cannot re-seed over the tot's edited source.
  await w.req("POST", "/v1/runtime/seed", { source: "old bundled runtime" });
  assert.match(await run("runtime_read", { offset: source.length - 26 }), /STOP = false/);
  // Concurrent tots cannot both overwrite the same revision.
  const edits = await Promise.all([
    run("runtime_edit", { revision: 1, source: "export const STOP = 2;" }),
    run("runtime_edit", { revision: 1, source: "export const STOP = 3;" }),
  ]);
  assert.equal(edits.filter((r) => r.startsWith("ERROR:")).length, 1);
  await run("runtime_deploy", { revision: 2 });
  await run("runtime_edit", { revision: 2, source: "export const STOP = 4;" });
  await run("runtime_deploy", { revision: 3 });
  await w.req("POST", "/v1/runtime/result", { revision: 2, err: "" });
  pending = (await w.req("GET", "/v1/runtime")).body;
  assert.equal(pending.status, "pending");
  assert.equal(pending.revision, 3);
  assert.equal(pending.deployed_revision, 2);
  assert.equal(pending.source, "export const STOP = 4;"); // old chunks were removed
});

test("pure: the first JSON object is found through prose, fences and braces inside strings", () => {
  assert.deepEqual(firstJson('Sure!\n```json\n{"tool": "say", "args": {"text": "a } b"}}\n```'), { tool: "say", args: { text: "a } b" } });
  assert.deepEqual(firstJson('{not json} then {"final": "done"}'), { final: "done" });
  assert.equal(firstJson("no braces here"), null);
  assert.equal(firstJson("[1,2]"), null);
});

test("pure: a model answer reads the same from every envelope, with the reasoning block removed", () => {
  assert.equal(answerText({ response: "<think>hm</think> hello" }), "hello");
  assert.equal(answerText({ choices: [{ message: { content: "hi" } }] }), "hi");
  assert.equal(answerText({ output: [{ type: "reasoning", content: [] }, { type: "message", content: [{ type: "output_text", text: "yo" }] }] }), "yo");
  assert.equal(answerText({ response: { tool: "x" } }), '{"tool":"x"}');
  assert.equal(answerText(null), "");
});

test("pure: a model's native tool-call markup is read as the call it meant, and a step written in it becomes plain words", () => {
  const raw = 'I will look first.<|tool_calls_section_begin|><|tool_call_begin|>functions.read_file:1<|tool_call_argument_begin|>{"path": "plan.md"}<|tool_call_end|><|tool_call_begin|>functions.list_files:2<|tool_call_argument_begin|>{}<|tool_call_end|><|tool_calls_section_end|>';
  assert.deepEqual(nativeCalls(raw), [{ tool: "read_file", args: { path: "plan.md" } }, { tool: "list_files", args: {} }]);
  assert.deepEqual(parseAction(raw), { tool: "read_file", args: { path: "plan.md" } });
  assert.equal(pickText(raw), 'I will look first. Do this: read_file {"path":"plan.md"}, then list_files {}.');
  assert.equal(pickText("  Write the checklist.  "), "Write the checklist.");
  assert.equal(pickText("odd <|im_end|> tail"), "odd tail");
  // the JSON protocol is untouched
  assert.deepEqual(parseAction('{"tool": "say", "args": {"text": "hi"}}'), { tool: "say", args: { text: "hi" } });
});

test("pure: the /goal grammar matches the chat loop's", () => {
  assert.equal(parseGoalCommand("make it pass").kind, "none");
  assert.equal(parseGoalCommand("/goals are nice").kind, "none");
  assert.equal(parseGoalCommand("/goal").kind, "status");
  assert.equal(parseGoalCommand(" /goal stop ").kind, "stop");
  assert.equal(parseGoalCommand("/goal resume").kind, "resume");
  assert.equal(parseGoalCommand("/goal --forever").kind, "forever");
  assert.deepEqual(parseGoalCommand("/goal budget 40"), { kind: "budget", n: 40 });
  assert.deepEqual(parseGoalCommand("/goal make every test pass --budget 12 and keep the API stable --forever"), { kind: "start", text: "make every test pass and keep the API stable", forever: true, budget: 12 });
  assert.equal(parseGoalCommand("/goal --budget 5").kind, "status");
});

test("pure: a verdict line parses, noise is SAME, and two scores compare by arithmetic", () => {
  assert.deepEqual(parseVerdict("IMPROVED | score: 12/14 | evidence: 12 of 14 pages saved"), { outcome: "improved", num: 12, den: 14, evidence: "12 of 14 pages saved" });
  assert.equal(parseVerdict("**REGRESSED** | score: none | evidence: x").outcome, "regressed");
  assert.equal(parseVerdict("I think it went well!").outcome, "same");
  assert.ok(parseVerdict("IMPROVED | score: 15/14").den <= 0);
  const g = { best_num: 10, best_den: 14 };
  assert.equal(decide(g, { outcome: "same", num: 12, den: 14 }), "improved");
  assert.equal(decide(g, { outcome: "improved", num: 9, den: 14 }), "regressed");
  assert.equal(decide(g, { outcome: "improved", num: 20, den: 28 }), "same");
  assert.equal(decide(g, { outcome: "improved", num: -1, den: 0 }), "improved");
});

test("pure: a finite goal stops on a plateau or its budget, a forever goal on neither", () => {
  const g = newGoal("x", false, 6, 1);
  assert.equal(recordIteration(g, "a", { outcome: "improved", num: 4, den: 10, evidence: "" }, 2).stop, null);
  assert.equal(recordIteration(g, "b", { outcome: "improved", num: 4, den: 10, evidence: "" }, 3).outcome, "same"); // same score
  assert.equal(recordIteration(g, "c", { outcome: "same", num: -1, den: 0, evidence: "" }, 4).stop, null);
  assert.equal(recordIteration(g, "d", { outcome: "same", num: -1, den: 0, evidence: "" }, 5).stop, "plateau");
  assert.equal(g.flat, PLATEAU);
  const b = newGoal("y", false, 1, 1);
  assert.equal(recordIteration(b, "a", { outcome: "improved", num: -1, den: 0, evidence: "" }, 2).stop, "budget");
  const f = newGoal("z", true, null, 1);
  for (let i = 0; i < 10; i++) assert.equal(recordIteration(f, "s", { outcome: "same", num: -1, den: 0, evidence: "" }, 2).stop, null);
  assert.equal(f.status, "active");
});

test("every route needs the token; a wrong one gets 401 and reaches no object", async () => {
  const w = world();
  for (const [m, p] of [["GET", "/v1/tots"], ["POST", "/v1/tots"], ["GET", "/v1/pad"], ["GET", "/v1/tots/Gary"], ["DELETE", "/v1/tots/Gary"], ["GET", "/v1/version"]]) {
    const r = await w.req(m, p, m === "POST" ? { goal: "x" } : undefined, "wrong");
    assert.equal(r.status, 401, `${m} ${p}`);
  }
  assert.equal((await w.req("GET", "/v1/tots", undefined, "")).status, 401);
  assert.equal(w.objects.size, 0);
});

test("the first tot is always Gary, names are unique, and the one past the owner's limit is refused", async () => {
  const w = world();
  const first = await w.req("POST", "/v1/tots", { name: "Zed", goal: "watch the news" });
  assert.equal(first.status, 200);
  assert.equal(first.body.tot.name, PRIMARY);
  assert.equal(first.body.tot.local, false);
  assert.equal((await w.req("POST", "/v1/tots", { name: "gary", goal: "x y z" })).status, 409);
  assert.equal((await w.req("POST", "/v1/tots", { name: "bad name!", goal: "x y z" })).status, 409);
  assert.equal((await w.req("POST", "/v1/tots", { name: "Ada", goal: "x y z" })).body.tot.name, "Ada");
  assert.equal((await w.req("POST", "/v1/tots", { name: "Nova", goal: "x y z", max_tots: 3 })).status, 200);
  const fourth = await w.req("POST", "/v1/tots", { name: "Rex", goal: "x y z", max_tots: 3 });
  assert.equal(fourth.status, 409);
  assert.match(fourth.body.err, /limit/);
  const list = await w.req("GET", "/v1/tots");
  assert.deepEqual(list.body.tots.map((h) => h.name), ["Gary", "Ada", "Nova"]);
  assert.equal(list.body.max_tots, 3); // the limit the owner sent stands until another comes
  // deleting one frees its slot and its storage
  assert.equal((await w.req("DELETE", "/v1/tots/ada")).body.deleted, "Ada");
  assert.equal(w.tot("Ada").store.m.size, 0);
  assert.equal(w.tot("Ada").store.alarm, null);
  assert.equal((await w.req("GET", "/v1/tots/Ada")).status, 404);
  assert.equal((await w.req("POST", "/v1/tots", { name: "Rex", goal: "x y z" })).status, 200);
  // a raised limit takes the next one at once
  assert.equal((await w.req("POST", "/v1/tots", { name: "Bo", goal: "x y z" })).status, 409);
  assert.equal((await w.req("POST", "/v1/tots", { name: "Bo", goal: "x y z", max_tots: 30 })).status, 200);
  assert.equal((await w.req("GET", "/v1/tots")).body.max_tots, 30);
  assert.ok(validName("Rex") && !validName("9lives") && !validName("") && !validName("a".repeat(25)));
});

test("an account runs 24 tater-tots unless its owner says otherwise, and no more than the ceiling", async () => {
  const w = world();
  for (let i = 0; i < DEFAULT_MAX_TOTS; i++) assert.equal((await w.req("POST", "/v1/tots", { name: `T${i}`, goal: "x y z" })).status, 200);
  const over = await w.req("POST", "/v1/tots", { name: "Extra", goal: "x y z" });
  assert.equal(over.status, 409);
  assert.match(over.body.err, /24 tater-tots \(its limit\); raise the limit/);
  assert.equal((await w.req("GET", "/v1/version")).body.max_tots_ceil, MAX_TOTS_CEIL);
  // a limit past the ceiling is held to it
  assert.equal((await w.req("POST", "/v1/tots", { name: "Extra", goal: "x y z", max_tots: 99999 })).status, 200);
  assert.equal((await w.req("GET", "/v1/tots")).body.max_tots, MAX_TOTS_CEIL);
});

test("one alarm is one iteration: pick, act with tools, a measured verdict, a log row, and the next alarm", async () => {
  const w = world((messages, n) => {
    const text = said(messages);
    if (n === 1) {
      assert.match(text, /GOAL LOOP/);
      assert.match(text, /\(none yet\)/);
      return "Save the three source URLs in a note";
    }
    if (n === 2) {
      assert.match(text, /THIS ITERATION'S STEP: Save the three source URLs/);
      assert.match(text, /write_file/);
      assert.doesNotMatch(text, /local_run/); // not granted
      assert.doesNotMatch(text, /- browser_open|- run_python/); // no binding, so not offered...
      assert.match(text, /NOT AVAILABLE in this account right now: a browser \(browser_\*\), Python \(run_python, skills\), Agent Garrett's security tools/); // ...and said so
      return 'I will save it.\n{"tool": "note_write", "args": {"name": "sources.md", "text": "a\\nb\\nc"}}';
    }
    if (n === 3) {
      assert.match(text, /RESULT of write_file:\nsaved sources.md \(5 characters\)/); // the old name still works
      return '{"tool": "read_file", "args": {"name": "sources.md"}}';
    }
    if (n === 4) {
      assert.match(text, /RESULT of read_file:\na\nb\nc/);
      return '{"final": "saved 3 URLs to sources.md"}';
    }
    if (n === 5) {
      assert.match(text, /TOOL write_file/);
      return proofLine("IMPROVED", "sources.md saved with 3 of 3 sources", { tool: 2, quote: "a\nb\nc", kind: "artifact" }, "3/3");
    }
    throw new Error("unexpected model call " + n);
  });
  await w.req("POST", "/v1/tots", { goal: "write three source URLs in sources.md", pace_s: 120 });
  assert.equal(w.tot("Gary").store.alarm, w.now + 1000);
  await w.tick("Gary");
  assert.equal(w.asked.length, 5);
  const st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
  assert.equal(st.goal.iteration, 1);
  assert.equal(st.goal.improved, 1);
  assert.equal(st.goal.best_num, 3);
  assert.equal(st.calls_today, 5);
  assert.equal(st.next_tick, w.now + 120000);
  assert.equal(st.state, "working");
  const kinds = (await w.events("Gary")).map((e) => e.kind);
  assert.deepEqual(kinds, ["status", "goal", "pick", "act", "act", "verdict"]);
  assert.equal((await w.tot("Gary").store.get("note:sources.md")).text, "a\nb\nc");

  // DONE triggers a fresh read-back; completion is established by that observation.
  w.script = (messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) {
      assert.match(text, /1\. improved: Save the three source URLs in a note \(sources\.md saved with 3 of 3 sources\) \[3\/3\]/);
      return "DONE";
    }
    if (text.includes("THIS ITERATION'S STEP")) return text.includes("RESULT of read_file") ? '{"final":"verified the file"}' : '{"tool":"read_file","args":{"name":"sources.md"}}';
    if (text.includes("Grade the LAST iteration")) return proofLine("SAME", "all sources read back", { tool: 1, quote: "a\nb\nc", kind: "artifact", complete: true }, "3/3");
    return "NONE";
  };
  await w.tick("Gary");
  const done = (await w.req("GET", "/v1/tots/Gary")).body.tot;
  assert.equal(done.goal.status, "achieved");
  assert.equal(done.state, "roaming");
});

test("a step that does not improve the goal becomes a lesson the next prompt carries, and the tot grows after two flat iterations", async () => {
  let phase = "";
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return (phase = "pick"), "Try the thing";
    if (text.includes("THIS ITERATION'S STEP")) return '{"final": "I did it, trust me"}';
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: nothing was run";
    if (text.includes("Write ONE new rule")) return "- Always finish a step with a tool result that shows its effect.";
    throw new Error("unexpected: " + text.slice(0, 80));
  });
  await w.req("POST", "/v1/tots", { goal: "make the report better", size: 3 });
  await w.tick("Gary");
  const lessons = await w.tot("Gary").store.get("lessons");
  assert.equal(lessons.length, 1);
  assert.equal(lessons[0].text, "Always finish a step with a tool result that shows its effect.");
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.minds, 1);
  await w.tick("Gary");
  // the second iteration's prompts carried the lesson; the same lesson is not stored twice
  assert.ok(w.asked.slice(4).some((a) => said(a.input.messages).includes("YOUR LESSONS") && said(a.input.messages).includes("Always finish a step")));
  assert.equal((await w.tot("Gary").store.get("lessons")).length, 1);
  const st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
  assert.equal(st.goal.flat, 2);
  assert.equal(st.minds, 2); // grew
  // the third flat iteration is the plateau: the goal ends and the tot moves on by itself
  await w.tick("Gary");
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.goal.status, "plateau");
  assert.ok((await w.events("Gary")).some((e) => e.kind === "status" && /Moving to the next best thing/.test(e.text)));
  assert.equal(phase, "pick");
});

test("a goal that ends hands over to the queue, then to a goal the tot proposes from its charter, then to a rest that backs off", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("You have no active goal")) {
      assert.match(text, /achieved \(0 improved\): first goal here/);
      return roamAnswer;
    }
    if (text.includes("GOAL LOOP")) return "DONE";
    if (text.includes("THIS ITERATION'S STEP")) return text.includes("RESULT of read_file") ? '{"final":"verified"}' : '{"tool":"read_file","args":{"name":"checks.txt"}}';
    if (text.includes("Grade the LAST iteration")) return proofLine("SAME", "all checks passed", { tool: 1, quote: "all checks passed", kind: "artifact", complete: true }, "1/1");
    if (text.includes("Write ONE new rule")) return "NONE";
    throw new Error("unexpected: " + text.slice(0, 80));
  });
  let roamAnswer = "Check the tide tables for errors against a second source";
  await w.req("POST", "/v1/tots", { goal: "first goal here", charter: "keep the tide site accurate", pace_s: 60 });
  await w.tot("Gary").saveFile("checks.txt", "all checks passed");
  await w.req("POST", "/v1/tots/Gary/command", { text: "/queue second goal here" });
  await w.tick("Gary"); // first: DONE and verification
  await w.tick("Gary"); // takes the queued goal and verifies it
  let st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
  assert.equal(st.goal.text, "second goal here");
  assert.equal(st.goal.status, "achieved");
  await w.tick("Gary"); // nothing queued: roam proposes, then pick verifies completion
  st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
  assert.equal(st.goal.text, "Check the tide tables for errors against a second source");
  roamAnswer = "REST";
  await w.tick("Gary");
  const first = w.tot("Gary").store.alarm - w.now;
  await w.tick("Gary");
  const second = w.tot("Gary").store.alarm - w.now;
  assert.equal(first, 120000); // twice the pace
  assert.equal(second, 240000); // and doubling
});

test("commands: plain words reach the next iteration as a directive, /goal replaces the goal, /pause holds the alarm", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) {
      assert.match(text, /NEW MESSAGES[\s\S]*- human: focus on the harbour pages first/);
      return "DONE";
    }
    throw new Error("unexpected");
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  w.tot("Gary").store.alarm = w.now + 500000;
  const r = await w.req("POST", "/v1/tots/Gary/command", { text: "focus on the harbour pages first" });
  assert.match(r.body.reply, /next iteration/);
  assert.equal(w.tot("Gary").store.alarm, w.now + 1000); // woken
  await w.tick("Gary");
  assert.deepEqual(await w.tot("Gary").store.get("inbox"), []);

  const g = await w.req("POST", "/v1/tots/Gary/command", { text: "/goal map every harbour --forever" });
  assert.match(g.body.reply, /runs until you stop it/);
  assert.equal(g.body.tot.goal.budget, 0);
  const p = await w.req("POST", "/v1/tots/Gary/command", { text: "/pause" });
  assert.equal(p.body.tot.state, "paused");
  assert.equal(w.tot("Gary").store.alarm, null);
  const before = w.asked.length;
  await w.tick("Gary"); // a paused tot does nothing, even if an alarm fires
  assert.equal(w.asked.length, before);
  assert.equal(w.tot("Gary").store.alarm, null);
  assert.equal((await w.req("POST", "/v1/tots/Gary/command", { text: "/resume" })).body.tot.state, "working");
  assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/nonsense" })).body.reply, /Commands:/);
  const cfg = await w.req("POST", "/v1/tots/Gary/config", { pace_s: 1, size: 99, local: true, model: "@cf/x/y" });
  assert.equal(cfg.body.tot.pace_s, 5); // 5 seconds is the fastest pace
  assert.equal(cfg.body.tot.size, 8);
  assert.equal(cfg.body.tot.model, "@cf/x/y");
  assert.equal(cfg.body.tot.local, false); // the owner's machine is granted at deployment only
});

test("a tot moved from an older runtime takes its files and its pause, says what did not travel, and the scratchpad keeps who wrote what", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "chart the tides" });
  const r = await w.req("POST", "/v1/tots/Gary/import", { notes: [{ name: "plan.md", text: "# the plan" }, { name: "../bad", text: "x" }, { name: 7 }], paused: true, from: "veil-hots" });
  assert.equal(r.body.ok, true);
  assert.equal(r.body.files, 1);
  assert.equal(r.body.tot.paused, true);
  const gary = w.tot("Gary");
  assert.equal((await gary.store.get("note:plan.md")).text, "# the plan");
  assert.equal(await gary.store.getAlarm(), null); // paused: no iteration is due
  const evs = await w.events("Gary");
  assert.match(evs.at(-1).text, /^moved here from veil-hots: its goal, settings and 1 file\(s\) came along; its lessons, facts and stances start fresh$/);
  assert.equal((await w.req("POST", "/v1/tots/Nobody/import", { notes: [] })).status, 404);
  await w.req("POST", "/v1/pad", { text: "a human line" });
  const p = await w.req("POST", "/v1/pad/import", { entries: [{ t: 9, from: "Gary", text: "hello from before" }, { from: "Ada", text: "   " }, { from: "Ada", text: "second" }] });
  assert.equal(p.body.imported, 2);
  const pad = (await w.req("GET", "/v1/pad?after=0")).body.entries;
  assert.deepEqual(pad.map((e) => [e.from, e.text]), [["human", "a human line"], ["Gary", "hello from before"], ["Ada", "second"]]);
  assert.equal(pad[1].t, 9);
});

test("tots share one scratchpad and can message each other", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  await w.req("POST", "/v1/tots", { name: "Ada", goal: "second goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.match(await gary.runTool(cfg, "pad_write", { text: "harbour list lives in note harbours.md" }, ""), /entry 1 written/);
  const ada = w.tot("Ada");
  const acfg = await ada.store.get("cfg");
  assert.match(await ada.runTool(acfg, "pad_read", {}, ""), /1\. Gary: harbour list lives in note harbours\.md/);
  assert.match(await ada.padTail(), /Gary: harbour list/);
  assert.equal(await gary.runTool(cfg, "tell", { tot: "ada", text: "take the east coast" }, ""), "delivered to Ada");
  assert.equal((await ada.store.get("inbox"))[0].text, "take the east coast");
  assert.equal((await ada.store.get("inbox"))[0].from, "Gary");
  assert.match(await gary.runTool(cfg, "tell", { tot: "Nobody", text: "x" }, ""), /no tot named Nobody/);
  assert.match(await gary.runTool(cfg, "tell", { tot: "Gary", text: "x" }, ""), /ERROR/);
  // the human reads and writes the same pad
  await w.req("POST", "/v1/pad", { text: "from the desk" });
  const pad = await w.req("GET", "/v1/pad?after=1");
  assert.deepEqual(pad.body.entries.map((e) => [e.from, e.text]), [["human", "from the desk"]]);
});

test("an inner swarm runs one mind per task up to the tot's current size, and a mind cannot cast another", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("one mind of Gary's swarm")) return `{"final": "report for: ${messages[1].content}"}`;
    throw new Error("unexpected");
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here", size: 4 });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  cfg.minds = 2;
  const out = await gary.runTool(cfg, "swarm", { tasks: ["east coast", "west coast", "north coast"] }, "");
  assert.match(out, /MIND 1 \(east coast\): report for: east coast/);
  assert.match(out, /MIND 2 \(west coast\): report for: west coast/);
  assert.match(out, /NOT RUN \(this tot runs 2 at a time now\): north coast/);
  assert.equal(w.asked.length, 2);
  assert.match(await gary.runTool(cfg, "swarm", { tasks: ["x y z"] }, "m1"), /a mind cannot cast a swarm/);
  assert.match(await gary.runTool(cfg, "swarm", {}, ""), /ERROR/);
});

test("the owner's machine: local_run exists only when granted at deployment, queues a job, and the result comes back to the inbox", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here", local: true });
  await w.req("POST", "/v1/tots", { name: "Ada", goal: "second goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.equal(cfg.local, true);
  assert.match(await w.tot("Ada").runTool(await w.tot("Ada").store.get("cfg"), "local_run", { instruction: "list the repo" }, ""), /not given the owner's machine/);
  assert.match(await gary.runTool(cfg, "local_run", { instruction: "run the test suite in ~/site" }, ""), /queued as job j1/);
  const jobs = await w.req("GET", "/v1/tots/Gary/jobs");
  assert.deepEqual(jobs.body.jobs.map((j) => [j.id, j.instruction]), [["j1", "run the test suite in ~/site"]]);
  assert.equal((await w.req("GET", "/v1/tots/Ada/jobs")).body.jobs.length, 0);
  gary.store.alarm = w.now + 900000;
  const done = await w.req("POST", "/v1/tots/Gary/jobs/j1", { ok: true, result: "42 passed, 0 failed" });
  assert.equal(done.status, 200);
  assert.equal(gary.store.alarm, w.now + 1000); // the result wakes the tot
  const inbox = await gary.store.get("inbox");
  assert.equal(inbox[0].from, "local");
  assert.match(inbox[0].text, /job j1 finished[\s\S]*42 passed, 0 failed/);
  assert.equal((await w.req("GET", "/v1/tots/Gary/jobs")).body.jobs.length, 0);
  assert.equal((await w.req("POST", "/v1/tots/Gary/jobs/j1", { result: "again" })).status, 404); // a job is answered once
  for (let i = 0; i < 4; i++) await gary.runTool(cfg, "local_run", { instruction: "job number " + i }, "");
  assert.match(await gary.runTool(cfg, "local_run", { instruction: "one too many" }, ""), /already waiting/);
});

test("the daily call budget rests the tot until the next UTC day, and a failing model never ends it", async () => {
  const w = world(() => "Try the thing");
  await w.req("POST", "/v1/tots", { goal: "first goal here", daily_calls: 10, pace_s: 60 });
  const gary = w.tot("Gary");
  await gary.store.put("usage", { day: "2026-10-01", calls: 10, total: 10 });
  await w.tick("Gary");
  assert.equal(w.asked.length, 0);
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.state, "resting");
  assert.equal(gary.store.alarm, Date.parse("2026-10-02T00:00:05Z"));
  assert.ok((await w.events("Gary")).some((e) => /resting until tomorrow/.test(e.text)));
  w.now = Date.parse("2026-10-02T00:00:06Z");
  w.script = () => {
    throw new Error("AI is down: 5007");
  };
  await w.tick("Gary");
  assert.ok((await w.events("Gary")).some((e) => e.kind === "error" && /AI is down/.test(e.text)));
  assert.equal(gary.store.alarm, w.now + 120000); // backs off, comes back
  assert.equal((await gary.store.get("usage")).calls, 1); // a new day started the count over
});

test("a model family that only takes `input` is learned once and remembered", async () => {
  const w = world();
  w.env.AI.run = async (model, input) => {
    w.asked.push(input);
    if (input.messages) throw new Error("request must have required property 'input'");
    return { output: [{ type: "message", content: [{ type: "output_text", text: "DONE" }] }] };
  };
  await w.req("POST", "/v1/tots", { goal: "first goal here", model: "@cf/some/responses-model" });
  const tot = w.tot("Gary");
  await tot.ask(await tot.store.get("cfg"), [{ role: "user", content: "hello" }], 2000);
  assert.deepEqual(w.asked.map((a) => (a.messages ? "messages" : "input")), ["messages", "input"]);
  assert.equal((await tot.store.get("goal")).status, "active"); // a model answer alone never completes a goal
  await w.req("POST", "/v1/tots/Gary/command", { text: "/goal another goal here" });
  await tot.ask(await tot.store.get("cfg"), [{ role: "user", content: "hello again" }], 2000);
  assert.equal(w.asked.length, 3); // straight to `input` this time
  assert.ok(w.asked[2].input);
});

test("the event tail is bounded and a far-behind reader gets the newest rows", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  for (let i = 0; i < 1600; i++) await gary.emit("act", "row " + i);
  const seq = await gary.store.get("seq");
  assert.equal((await gary.store.list({ prefix: "ev:" })).size, 1500);
  const r = await w.req("GET", "/v1/tots/Gary/events?after=0&limit=50");
  assert.equal(r.body.events.length, 50);
  assert.equal(r.body.events.at(-1).seq, seq);
  const tail = await w.req("GET", `/v1/tots/Gary/events?after=${seq - 2}`);
  assert.deepEqual(tail.body.events.map((e) => e.seq), [seq - 1, seq]);
});

test("a command that lands while an iteration is out with the model is kept: a new goal is not overwritten, a stop stays a stop", async () => {
  let during = null;
  const w = world(async (messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Try the thing";
    if (text.includes("THIS ITERATION'S STEP")) {
      if (during) await during(); // the human acts while the model is "thinking"
      return '{"final": "did it"}';
    }
    if (text.includes("Grade the LAST iteration")) return "IMPROVED | score: 1/4 | evidence: x";
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "the old goal here", pace_s: 60 });
  during = async () => void (await w.req("POST", "/v1/tots/Gary/command", { text: "/goal the new goal here --budget 7" }));
  await w.tick("Gary");
  let g = await w.tot("Gary").store.get("goal");
  assert.equal(g.text, "the new goal here");
  assert.equal(g.iteration, 0); // the old goal's step earned the new goal nothing
  assert.equal(g.budget, 7);
  assert.ok((await w.events("Gary")).some((e) => /set aside/.test(e.text)));
  assert.equal((await w.tot("Gary").store.list({ prefix: "log:" })).size, 0);

  // same goal, changed mid-iteration: the iteration counts AND the stop is kept; /pace is not rolled back
  during = async () => {
    await w.req("POST", "/v1/tots/Gary/command", { text: "/goal stop" });
    await w.req("POST", "/v1/tots/Gary/command", { text: "/pace 300" });
  };
  await w.tick("Gary");
  g = await w.tot("Gary").store.get("goal");
  assert.equal(g.status, "stopped");
  assert.equal(g.iteration, 1);
  assert.equal((await w.tot("Gary").store.get("cfg")).pace_s, 300);
});

test("a tot deleted while its iteration is out stays deleted: nothing it writes afterwards survives, and no alarm is set", async () => {
  let during = null;
  const w = world(async (messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Try the thing";
    if (text.includes("THIS ITERATION'S STEP")) {
      if (during) await during();
      return '{"tool": "note_write", "args": {"name": "ghost.md", "text": "boo"}}';
    }
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: none";
    return "A rule that would otherwise be stored as a lesson.";
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  during = async () => {
    during = null;
    assert.equal((await w.req("DELETE", "/v1/tots/Gary")).status, 200);
  };
  await w.tick("Gary");
  assert.equal(gary.store.m.size, 0);
  assert.equal(gary.store.alarm, null);
  assert.deepEqual((await w.req("GET", "/v1/tots")).body.tots, []);
});

test("DONE is checked against the goal as stored when the answer arrives: a goal made forever, or stopped, meanwhile is not marked achieved", async () => {
  let during = null;
  const w = world(async () => {
    if (during) await during();
    return "DONE";
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  during = async () => void (await w.req("POST", "/v1/tots/Gary/command", { text: "/goal forever" }));
  await w.tick("Gary");
  let g = await w.tot("Gary").store.get("goal");
  assert.equal(g.status, "active");
  assert.equal(g.forever, true);
  await w.req("POST", "/v1/tots", { name: "Ada", goal: "second goal here" });
  during = async () => void (await w.req("POST", "/v1/tots/Ada/command", { text: "/goal stop" }));
  await w.tick("Ada");
  g = await w.tot("Ada").store.get("goal");
  assert.equal(g.status, "stopped"); // not "achieved": the human's stop is what the record shows
});

test("the local mirror's counters: notes come back changed-after a stamp, a delete moves the revision, the roster names the pad's seq", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  await gary.runTool(cfg, "note_write", { name: "a.md", text: "one" }, "");
  await gary.runTool(cfg, "note_write", { name: "b.md", text: "two" }, ""); // same millisecond: still a later stamp
  let r = (await w.req("GET", "/v1/tots/Gary/notes?after=0")).body;
  assert.deepEqual(r.notes.map((n) => [n.name, n.text]), [["a.md", "one"], ["b.md", "two"]]);
  assert.ok(r.notes[1].t > r.notes[0].t);
  assert.equal(r.more, false);
  const t = r.notes[1].t;
  await gary.runTool(cfg, "note_write", { name: "a.md", text: "one, again" }, "");
  r = (await w.req("GET", `/v1/tots/Gary/notes?after=${t}`)).body;
  assert.deepEqual(r.notes.map((n) => n.text), ["one, again"]);
  const rev = (await w.req("GET", "/v1/tots/Gary")).body.tot.notes_rev;
  assert.equal(rev, 3);
  await gary.runTool(cfg, "note_delete", { name: "b.md" }, "");
  const after = (await w.req("GET", "/v1/tots/Gary")).body.tot.notes_rev;
  assert.equal(after, 4);
  assert.deepEqual((await w.req("GET", "/v1/tots/Gary/notes?after=0")).body.names, ["a.md"]);
  await gary.runTool(cfg, "pad_write", { text: "x" }, "");
  assert.equal((await w.req("GET", "/v1/tots")).body.pad_seq, 1);
});

test("an inner swarm runs at least two minds when the tot's size allows, whatever its current width", async () => {
  const w = world((messages) => `{"final": "ok ${messages[1].content}"}`);
  await w.req("POST", "/v1/tots", { goal: "first goal here", size: 3 });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.equal(cfg.minds, 1);
  const out = await gary.runTool(cfg, "swarm", { tasks: ["east coast", "west coast", "north coast"] }, "");
  assert.match(out, /MIND 2 \(west coast\)/);
  assert.match(out, /NOT RUN \(this tot runs 2 at a time now\): north coast/);
  cfg.size = 1;
  assert.match(await gary.runTool(cfg, "swarm", { tasks: ["east coast", "west coast"] }, ""), /NOT RUN \(this tot runs 1 at a time now\)/);
});

test("a forward read of the event tail starts where the reader left off, however far behind it is", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  for (let i = 0; i < 30; i++) await gary.emit("act", "row " + i);
  const tail = (await w.req("GET", "/v1/tots/Gary/events?after=0&limit=5")).body.events;
  assert.equal(tail[0].seq, (await gary.store.get("seq")) - 4); // a console gets the newest
  const fwd = (await w.req("GET", "/v1/tots/Gary/events?after=0&limit=5&forward=1")).body.events;
  assert.deepEqual(fwd.map((e) => e.seq), [1, 2, 3, 4, 5]); // the mirror gets the next five
});

test("a goal and a charter are held to the text limit the server sends for the tot's model", async () => {
  const w = world();
  const long = "x".repeat(3000);
  await w.req("POST", "/v1/tots", { goal: long, charter: long, text_max: 1200 });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.equal(cfg.text_max, 1200);
  assert.ok(cfg.charter.length <= 1201 && (await gary.store.get("goal")).text.length <= 1201);
  await w.req("POST", "/v1/tots/Gary/command", { text: "/goal " + "y".repeat(5000) });
  assert.ok((await gary.store.get("goal")).text.length <= 1201);
  await w.req("POST", "/v1/tots/Gary/config", { model: "@cf/big/model", text_max: 4000 });
  await w.req("POST", "/v1/tots/Gary/command", { text: "/charter " + "z".repeat(5000) });
  assert.equal((await gary.store.get("cfg")).charter.length, 4001); // 4000 and the ellipsis
});

test("clearing the scratchpad empties it for the next set of tots, and its seq moves on", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  await w.req("POST", "/v1/pad", { text: "one" });
  await w.req("POST", "/v1/pad", { text: "two" });
  const r = await w.req("POST", "/v1/pad/clear", {});
  assert.equal(r.body.cleared, 2);
  const pad = (await w.req("GET", "/v1/pad")).body;
  assert.deepEqual(pad.entries, []);
  assert.equal(pad.seq, 3);
  await w.req("POST", "/v1/pad", { text: "fresh" });
  assert.deepEqual((await w.req("GET", "/v1/pad")).body.entries.map((e) => [e.seq, e.text]), [[4, "fresh"]]);
  assert.equal((await w.req("POST", "/v1/pad/clear", {}, "wrong")).status, 401);
});

test("a tool call is understood however the model spells it", () => {
  const want = { tool: "web_fetch", args: { url: "https://example.com" } };
  for (const reply of [
    '{"tool": "web_fetch", "args": {"url": "https://example.com"}}',
    '{"tool": "web_fetch", "arguments": {"url": "https://example.com"}}',
    '{"tool": "web_fetch", "parameters": {"url": "https://example.com"}}',
    '{"tool": "web_fetch", "input": {"url": "https://example.com"}}',
    '{"tool": "web_fetch", "url": "https://example.com"}', // flat
    '{"name": "web_fetch", "arguments": "{\\"url\\": \\"https://example.com\\"}"}', // arguments as a JSON string
    '{"tool_calls": [{"id": "c1", "type": "function", "function": {"name": "web_fetch", "arguments": "{\\"url\\": \\"https://example.com\\"}"}}]}',
    'I will fetch it.\n```json\n{"action": "web_fetch", "args": {"url": "https://example.com"}}\n```',
    '{"tool": "functions.web_fetch", "args": {"url": "https://example.com"}}',
  ]) assert.deepEqual(parseAction(reply), want, reply);
  assert.deepEqual(parseAction('{"final": "done, 3 saved"}'), { final: "done, 3 saved" });
  assert.deepEqual(parseAction('{"tool": "final", "args": {"text": "all done"}}'), { final: "all done" });
  assert.deepEqual(parseAction('{"tool": "list_files"}'), { tool: "list_files", args: {} });
  assert.equal(parseAction("just prose"), null);
  assert.equal(parseAction('{"thought": "hmm"}'), null);
});

test("a reply with no text is asked again with more room, and a model that stays silent is an error, never an empty step", async () => {
  const sizes = [];
  const w = world();
  let silent = 1;
  w.env.AI.run = async (model, input) => {
    sizes.push(input.max_tokens);
    if (silent-- > 0) return { choices: [{ message: { content: "", reasoning_content: "thinking for a long time..." } }] };
    return { response: "DONE" };
  };
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const tot = w.tot("Gary");
  await tot.ask(await tot.store.get("cfg"), [{ role: "user", content: "hello" }], 2000);
  assert.deepEqual(sizes, [2000, 6000]); // the pick, then the pick again with three times the room
  assert.equal((await tot.store.get("goal")).status, "active");

  await w.req("POST", "/v1/tots/Gary/command", { text: "/goal another goal here" });
  // a model that only ever reasons: the model that does not reason answers for it, and the tot says so once
  silent = 99;
  const real = w.env.AI.run;
  w.env.AI.run = async (model, input) => (model === "@cf/meta/llama-3.3-70b-instruct-fp8-fast" ? { response: "DONE" } : real(model, input));
  await w.req("POST", "/v1/tots/Gary/config", { model: "@cf/zai-org/reasons-only" });
  await tot.ask(await tot.store.get("cfg"), [{ role: "user", content: "hello again" }], 2000);
  assert.equal((await tot.store.get("goal")).status, "active");
  assert.equal((await w.events("Gary")).filter((e) => /returned no visible answer/.test(e.text)).length, 1);

  // and when nothing answers at all, it is an error
  await w.req("POST", "/v1/tots/Gary/command", { text: "/goal a third goal here" });
  w.env.AI.run = real;
  await w.tick("Gary");
  const evs = await w.events("Gary");
  assert.ok(evs.some((e) => e.kind === "error" && /returned no text twice/.test(e.text)));
  assert.ok(!evs.some((e) => e.kind === "pick" && e.text === "")); // no empty step was ever recorded
  assert.equal((await w.tot("Gary").store.get("goal")).iteration, 0);
});

test("model calls a day can be unlimited, and a tot may iterate every 5 seconds", async () => {
  const w = world((messages) => said(messages).includes("GOAL LOOP") ? "Inspect the current result" : '{"final":"nothing verified"}');
  const made = await w.req("POST", "/v1/tots", { goal: "first goal here", daily_calls: 0, pace_s: 5 });
  assert.equal(made.body.tot.daily_calls, 0);
  assert.equal(made.body.tot.pace_s, 5);
  const gary = w.tot("Gary");
  await gary.store.put("usage", { day: "2026-10-01", calls: 999999, total: 999999 });
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.state, "working"); // never "resting"
  await w.tick("Gary");
  assert.ok(w.asked.length > 0); // it still called the model
  assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/calls 250" })).body.reply, /250 model calls a day/);
  assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/calls unlimited" })).body.reply, /no limit on model calls/);
  assert.equal((await w.req("POST", "/v1/tots/Gary/config", { daily_calls: 3 })).body.tot.daily_calls, 10); // a count is at least 10
  assert.equal((await w.req("POST", "/v1/tots/Gary/command", { text: "/pace 10" })).body.tot.pace_s, 10);
});

test("files: write, append, edit one exact passage, list, delete - and bad names never become keys", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  const run = (tool, args) => gary.runTool(cfg, tool, args, "");
  assert.match(await run("write_file", { name: "plan.md", text: "alpha\nbeta\nalpha\n" }), /saved plan.md/);
  assert.equal(await run("append_file", { name: "plan.md", text: "gamma\n" }), "saved plan.md (23 characters)");
  assert.match(await run("edit_file", { name: "plan.md", old: "alpha", new: "x" }), /more than once/);
  assert.match(await run("edit_file", { name: "plan.md", old: "beta", new: "BETA" }), /saved/);
  assert.equal(await run("read_file", { name: "plan.md" }), "alpha\nBETA\nalpha\ngamma\n");
  assert.match(await run("edit_file", { name: "plan.md", old: "nope", new: "x" }), /not in the file/);
  assert.match(await run("write_file", { name: "../x", text: "y" }), /ERROR/);
  assert.match(await run("write_file", { name: "..", text: "y" }), /ERROR/);
  assert.equal(await run("list_files", {}), "plan.md (23 characters)");
  assert.equal(await run("delete_file", { name: "plan.md" }), "deleted");
  assert.equal(await run("list_files", {}), "(no files yet)");
});

test("memory and plan: facts are kept and found again, the plan rides every later prompt", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) {
      assert.match(text, /YOUR PLAN[\s\S]*1\. \[x\] find sources[\s\S]*2\. \[ \] check them/);
      assert.match(text, /FACTS YOU KEPT[\s\S]*the tide API key lives in settings.json/);
      assert.match(text, /YOUR FILES: notes.md \(2\)/);
      return "Inspect the current plan";
    }
    if (text.includes("THIS ITERATION'S STEP")) return '{"final":"plan inspected"}';
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  const run = (tool, args) => gary.runTool(cfg, tool, args, "");
  assert.match(await run("remember", { fact: "the tide API key lives in settings.json" }), /kept \(1 facts\)/);
  assert.equal(await run("remember", { fact: "the tide API key lives in settings.json" }), "already kept");
  await run("remember", { fact: "harbour pages are served from /h/<slug>" });
  assert.equal(await run("recall", { query: "where is the API key?" }), "- the tide API key lives in settings.json");
  assert.equal(await run("recall", { query: "zebra" }), "(nothing kept matches)");
  assert.match(await run("plan_set", { items: ["find sources", "check them"] }), /plan set \(2 steps\)/);
  assert.match(await run("plan_done", { item: 1 }), /1 of 2 done/);
  assert.match(await run("plan_done", { item: 9 }), /ERROR/);
  await run("write_file", { name: "notes.md", text: "hi" });
  await w.tick("Gary");
  assert.equal((await gary.store.get("goal")).iteration, 1); // the prompt assertions above ran
  assert.equal((await gary.store.get("goal")).status, "active");
});

test("search results are read out of an engine's HTML: the real link, the title, the snippet; engine links dropped", () => {
  const ddg = `<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Ftides&amp;rut=abc">Tide <b>tables</b></a>
    <a class="result__snippet" href="x">High and low <b>tides</b> for the coast.</a></div>
    <div class="result"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">An ad</a></div>
    <div class="result"><a class="result__a" href="https://noaa.example/x">NOAA &amp; tides</a></div>`;
  assert.deepEqual(searchResults(ddg, "duckduckgo"), [
    { title: "Tide tables", url: "https://example.com/tides", snippet: "High and low tides for the coast." },
    { title: "NOAA & tides", url: "https://noaa.example/x", snippet: "" },
  ]);
  const bing = `<li class="b_algo"><h2><a href="https://a.example/1" h="x">First</a></h2><div><p class="b_lineclamp">About the first.</p></div></li><li class="b_algo"><h2><a href="https://a.example/1">Repeat</a></h2></li>`;
  assert.deepEqual(searchResults(bing, "bing"), [{ title: "First", url: "https://a.example/1", snippet: "About the first." }]);
  assert.deepEqual(searchResults("<html>captcha</html>", "duckduckgo"), []);
});

test("Python: a script runs in the companion Worker beside the tot's files, what it writes is kept, and a skill is a script kept by name", async () => {
  const w = world();
  const sent = [];
  w.env.PY = {
    fetch: async (url, init) => {
      const body = JSON.parse(init.body);
      sent.push(body);
      if (body.code.includes("boom")) return new Response(JSON.stringify({ ok: false, out: "Traceback...\nZeroDivisionError", files: {} }));
      if (body.install.includes("nativepkg")) return new Response(JSON.stringify({ ok: false, out: "pip install failed: nativepkg has no pure-Python wheel", files: {}, installed: [] }));
      const installed = [...new Set([...body.packages, ...body.install, ...(body.code.includes("import bs4") ? ["beautifulsoup4"] : [])])].sort();
      return new Response(JSON.stringify({ ok: true, out: `ran with ${JSON.stringify(body.args)}\n`, files: body.code ? { "out.csv": "a,b\n1,2\n", "../evil": "x" } : {}, installed }));
    },
  };
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  const run = (tool, args) => gary.runTool(cfg, tool, args, "");
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.python, true);
  await run("write_file", { name: "in.csv", text: "x\n1\n" });
  const out = await run("run_python", { code: "print('hi')", files: ["in.csv", "missing.csv"] });
  assert.match(out, /^exit ok\nran with null\n\nfiles written: out.csv$/);
  assert.deepEqual(sent[0].files, { "in.csv": "x\n1\n" });
  assert.equal(await run("read_file", { name: "out.csv" }), "a,b\n1,2\n");
  assert.equal((await gary.store.list({ prefix: "note:" })).size, 2); // "../evil" was refused
  assert.match(await run("run_python", { code: "boom" }), /^FAILED\nTraceback/);
  assert.deepEqual(Object.keys(sent.at(-1).files).sort(), ["in.csv", "out.csv"]); // named none: the whole workspace
  assert.match(await run("save_skill", { name: "double_it", about: "doubles ARGS['n']", code: "print(ARGS['n'] * 2)" }), /skill double_it saved/);
  assert.match(await run("save_skill", { name: "Bad Name", about: "", code: "print(1)" }), /ERROR/);
  assert.match(await run("run_skill", { name: "double_it", args: { n: 21 } }), /ran with \{"n":21\}/);
  assert.equal(sent.at(-1).code, "print(ARGS['n'] * 2)");
  assert.match(await run("run_skill", { name: "nope" }), /no skill named nope/);
  assert.match(await gary.workingMemory(), /YOUR SKILLS \(run_skill\):\n- double_it: doubles ARGS\['n'\]/);
  // packages: what a script made the runner install is remembered and sent with every later script
  await run("run_python", { code: "import bs4" });
  assert.deepEqual(await gary.store.get("py_packages"), ["beautifulsoup4"]);
  assert.equal(await run("pip_install", { packages: ["tidekit", "bad name!"] }), "installed. Your Python now has: beautifulsoup4, tidekit");
  assert.deepEqual(sent.at(-1), { code: "", files: {}, args: null, packages: ["beautifulsoup4"], install: ["tidekit"], skip: [] });
  await run("run_python", { code: "print(1)" });
  assert.deepEqual(sent.at(-1).packages, ["beautifulsoup4", "tidekit"]);
  assert.match(await run("pip_install", { packages: ["nativepkg"] }), /^ERROR: pip install failed: nativepkg has no pure-Python wheel/);
  assert.match(await run("pip_install", {}), /ERROR: name the packages/);
  // without the binding the tool says so in words instead of throwing
  delete w.env.PY;
  assert.match(await run("run_python", { code: "print(1)" }), /Python is not available/);
});

test("Python as it is: the tot is told what its Python has and cannot have, a refused package is never looked up twice, and a failed attempt is graded against what stood before", async () => {
  const sent = [];
  const w = world((messages) => {
    const all = said(messages);
    if (all.includes("You grade ONE iteration")) return "SAME | score: none | evidence: the install failed, nothing changed";
    if (all.includes("You improve an autonomous agent")) return "NONE";
    if (all.includes("THIS ITERATION'S STEP")) return messages.some((m) => m.role === "user" && m.content.startsWith("RESULT of run_python")) ? '{"final": "could not chart it"}' : '{"tool": "run_python", "args": {"code": "import matplotlib"}}';
    return "Chart the table with matplotlib.";
  });
  let native = [];
  w.env.PY = {
    fetch: async (url, init) => {
      const body = JSON.parse(init.body);
      sent.push(body);
      if (body.caps) return new Response(JSON.stringify({ ok: true, native, python: "3.12.7" }));
      return new Response(JSON.stringify({ ok: false, out: "ModuleNotFoundError: No module named 'matplotlib'\n(matplotlib was looked up on PyPI: matplotlib has no pure-Python wheel (it needs native code))", files: {}, installed: [], native, unavailable: ["matplotlib", "oddnative"] }));
    },
  };
  // the server's question after an upload: does the Python start, and with what
  assert.deepEqual((await w.req("GET", "/v1/python")).body, { ok: true, python: true, native: [], error: "" });
  await w.req("POST", "/v1/tots", { goal: "chart the tide table" });
  await w.tick("Gary");
  const gary = w.tot("Gary");
  // before its first step the tot asked its Python what it is, once
  assert.equal(sent.filter((b) => b.caps).length, 2);
  assert.deepEqual(await gary.store.get("py_native"), []);
  const pick = said(w.asked.find((q) => said(q.input.messages).includes("GOAL LOOP")).input.messages);
  assert.match(pick, /YOUR PYTHON: the standard library, requests and urllib\. Any other pure-Python package installs/);
  assert.match(pick, /NOT here and not installable \(native code\): numpy, pandas, matplotlib, /);
  assert.match(pick, /choose only a step your tools and YOUR PYTHON as listed above can carry out/);
  assert.match(pick, /Establish how finished is measured once/);
  // what the runner refused is kept, named in the next prompt, and sent along so it is not looked up again
  assert.deepEqual(await gary.store.get("py_missing"), ["matplotlib", "oddnative"]);
  assert.match(await gary.workingMemory(), /not installable \(native code\): .*oddnative - never choose a step that needs one/);
  // the judge is told a failed attempt is SAME, and sees the iterations before this one
  const judge = w.asked.find((q) => said(q.input.messages).includes("You grade ONE iteration"));
  assert.match(said(judge.input.messages), /left everything as it was is SAME, not REGRESSED/);
  assert.match(said(judge.input.messages), /A first measurement is a baseline/);
  assert.match(said(judge.input.messages), /EARLIER ITERATIONS \(what stood before this one\):\n  \(none yet\)/);
  assert.equal((await gary.store.get("goal")).flat, 1);
  assert.match(await gary.store.get("mood"), /^steady/); // a failed attempt is not "made things worse"
  await w.tick("Gary");
  assert.deepEqual(sent.at(-1).skip, ["matplotlib", "oddnative"]);
  assert.equal(sent.filter((b) => b.caps).length, 2); // not asked again
  const judge2 = w.asked.filter((q) => said(q.input.messages).includes("You grade ONE iteration")).at(-1);
  assert.match(said(judge2.input.messages), /EARLIER ITERATIONS \(what stood before this one\):\n  1\. same: Chart the table with matplotlib\./);
  // a Python uploaded with native packages says so; the tot's prompt follows, and they leave the cannot-have list
  native = ["matplotlib", "numpy"];
  await gary.runTool(await gary.store.get("cfg"), "run_python", { code: "import matplotlib" }, "");
  assert.deepEqual(await gary.store.get("py_native"), ["matplotlib", "numpy"]);
  assert.deepEqual(await gary.store.get("py_missing"), ["oddnative"]);
  const mem = await gary.workingMemory();
  assert.match(mem, /and these native packages: matplotlib, numpy\./);
  assert.doesNotMatch(mem, /not installable \(native code\): [^-]*\b(numpy|matplotlib)\b/);
  // a Python Worker that does not start is reported as such, in words
  w.env.PY = { fetch: async () => { throw new Error("Worker threw exception"); } };
  assert.deepEqual((await w.req("GET", "/v1/python")).body, { ok: true, python: false, native: [], error: "Worker threw exception" });
  delete w.env.PY;
  assert.equal((await w.req("GET", "/v1/python")).body.python, false);
});

/// A stand-in for Cloudflare's browser binding: one session and a small site of pages, each a text and a list of
/// elements, answering the DevTools commands the tot uses - the page snapshot, element lookup, real mouse and key
/// input, and evaluated scripts.
function fakeBrowser() {
  const site = {
    "https://tides.example/": { title: "Tides", text: "Tide tables for the coast", els: [{ kind: "link", label: "Today", href: "https://tides.example/today" }, { kind: "input text", label: "", name: "q" }, { kind: "button", label: "Search" }] },
    "https://tides.example/today": { title: "Today", text: "High tide 04:12\nLow tide 10:40", els: [{ kind: "link", label: "Home", href: "https://tides.example/" }] },
    "https://tides.example/results": { title: "Results", text: "Results for tofino", els: [] },
    "https://wall.example/": { title: "Just a moment...", text: "Verify you are human: what is 2 + 3?", els: [{ kind: "input text", label: "Answer", name: "answer" }, { kind: "button", label: "Verify", href: "https://tides.example/", answer: "5" }] },
  };
  const b = { acquired: 0, connects: 0, log: [], url: "about:blank", history: [], typed: "", focused: 0, alive: true, serp: null, site };
  const page = () => site[b.url] ?? { title: "", text: "", els: [] };
  b.fetch = async (url, init) => {
    const u = new URL(url);
    if (init?.method === "POST" && u.pathname === "/v1/devtools/browser") {
      b.acquired++;
      b.alive = true;
      assert.equal(u.searchParams.get("keep_alive"), "600000");
      return new Response(JSON.stringify({ sessionId: "sess-" + b.acquired }), { status: 200 });
    }
    const m = /^\/v1\/devtools\/browser\/(sess-\d+)$/.exec(u.pathname);
    assert.ok(m, "unexpected browser call " + url);
    assert.equal(init.headers.Upgrade, "websocket");
    if (!b.alive || m[1] !== "sess-" + b.acquired) return new Response("session not found", { status: 404 });
    b.connects++;
    const listeners = { message: [], close: [], error: [] };
    const emit = (obj) => queueMicrotask(() => listeners.message.forEach((f) => f({ data: JSON.stringify(obj) })));
    const go = (to) => {
      b.history.push(b.url);
      b.url = to;
      emit({ method: "Page.frameNavigated", sessionId: "S1", params: {} });
      emit({ method: "Page.loadEventFired", sessionId: "S1", params: {} });
    };
    const ws = {
      accept() {},
      addEventListener: (type, f) => listeners[type].push(f),
      close() {},
      send(raw) {
        const c = JSON.parse(raw);
        b.log.push(c.method);
        const ok = (result) => emit({ id: c.id, result });
        const val = (v) => ok({ result: { value: v } });
        if (c.method === "Target.createTarget") return ok({ targetId: "T1" });
        if (c.method === "Target.attachToTarget") return c.params.targetId === "T1" ? ok({ sessionId: "S1" }) : emit({ id: c.id, error: { message: "No target with given id" } });
        if (c.method === "Page.navigate") {
          ok({ frameId: "F" });
          return go(c.params.url);
        }
        if (c.method === "Input.dispatchMouseEvent") {
          if (c.params.type === "mouseReleased") {
            const el = page().els[c.params.x / 10 - 1]; // an element's x is its number times ten
            b.focused = c.params.x / 10;
            if (el?.href && (el.answer === undefined || el.answer === b.typed)) go(el.href);
          }
          return ok({});
        }
        if (c.method === "Input.insertText") {
          b.typed += c.params.text;
          return ok({});
        }
        if (c.method === "Input.dispatchKeyEvent") {
          if (c.params.type !== "keyUp" && c.params.key === "Enter" && b.url === "https://tides.example/") go("https://tides.example/results");
          return ok({});
        }
        if (c.method === "Runtime.evaluate") {
          assert.equal(c.sessionId, "S1");
          const e = c.params.expression;
          if (e.includes("data-veil-n") && e.includes("els: out")) {
            const pg = page();
            return val(JSON.stringify({ url: b.url, title: pg.title, text: pg.text, els: pg.els.map((x, k) => `[${k + 1}] ${x.kind}${x.label ? ` "${x.label}"` : ""}${x.href ? " -> " + new URL(x.href).pathname : ""}${x.name ? " name=" + x.name : ""}`) }));
          }
          if (e.includes("scrollIntoView")) {
            const [, n, sel, t] = /const n = (.*?), sel = (".*?"), t = (".*?");/.exec(e);
            const els = page().els;
            let k = n === "null" ? -1 : Number(n) - 1;
            if (k < 0 && JSON.parse(sel) === "#q") k = els.findIndex((x) => x.name === "q");
            if (k < 0 && JSON.parse(t)) k = els.findIndex((x) => x.label.toLowerCase().includes(JSON.parse(t)));
            if (!els[k]) return val(JSON.stringify({ err: n !== "null" ? `no element number ${n} on this page` : "no element matches" }));
            return val(JSON.stringify({ x: (k + 1) * 10, y: 5, tag: els[k].kind.split(" ")[0] === "link" ? "a" : els[k].kind.split(" ")[0], label: els[k].label }));
          }
          if (e.includes("document.activeElement")) {
            b.typed = "";
            return val(null);
          }
          if (e.includes("b_algo")) return val(JSON.stringify(b.serp ? b.serp(b.url) : { results: [], blocked: false }));
          if (e.includes("history.back()")) {
            const prev = b.history.pop();
            b.url = prev;
            emit({ method: "Page.frameNavigated", sessionId: "S1", params: {} });
            emit({ method: "Page.loadEventFired", sessionId: "S1", params: {} });
            return val(null);
          }
          if (e.includes("window.scroll")) return val(null);
          if (e.includes(".includes(")) return val(page().text.toLowerCase().includes(JSON.parse(/includes\((".*?")\)$/.exec(e)[1])));
          if (e.includes("__l")) {
            // the eval wrapper: answer for the scripts the test sends
            if (e.includes("return (let x = 1")) return ok({ exceptionDetails: { text: "Uncaught", exception: { description: "SyntaxError: Unexpected identifier 'x'" } } });
            if (e.includes("let x = 1; return x + 1")) return val(JSON.stringify({ v: 2, l: [] }));
            if (e.includes("throw new Error")) return ok({ exceptionDetails: { text: "Uncaught", exception: { description: "Error: nope" } } });
            if (e.includes('console.log("logged it")')) return val(JSON.stringify({ v: null, l: ["logged it"] }));
            if (e.includes("document.title")) return val(JSON.stringify({ v: page().title, l: [] }));
            return val(JSON.stringify({ v: null, l: [] }));
          }
          return val(null);
        }
        return ok({});
      },
    };
    return { status: 101, webSocket: ws, text: async () => "" };
  };
  return b;
}

/// A tot with a browser whose waits are short enough for a test.
async function browserWorld() {
  const w = world();
  const b = fakeBrowser();
  w.env.BROWSER = b;
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  gary.navMs = 20;
  gary.settleMs = 1;
  gary.pollMs = 1;
  const cfg = await gary.store.get("cfg");
  return { w, b, gary, run: (tool, args) => gary.runTool(cfg, tool, args, "") };
}

test("the browser: a page comes back as its text and a numbered list of what can be acted on; clicking and typing go by number, with real mouse and key input", async () => {
  const { w, b, run } = await browserWorld();
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.browser, true);
  const page = await run("browser_open", { url: "https://tides.example/" });
  assert.equal(page, 'Tides\nhttps://tides.example/\n\nTide tables for the coast\n\nELEMENTS (act on one by its number):\n[1] link "Today" -> /today\n[2] input text name=q\n[3] button "Search"');
  assert.deepEqual(b.log.slice(0, 5), ["Target.createTarget", "Target.attachToTarget", "Page.enable", "Runtime.enable", "Page.navigate"]);

  // type into field 2 and submit: the field is focused by a click, cleared, typed into, and Enter is a real key
  b.log.length = 0;
  b.typed = "old text";
  const typed = await run("browser_type", { n: 2, text: "tofino", submit: true });
  assert.match(typed, /^typed into input "" and pressed Enter\n\nResults\nhttps:\/\/tides\.example\/results/);
  assert.equal(b.typed, "tofino");
  assert.deepEqual(b.log.filter((m) => m.startsWith("Input.")), ["Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Input.insertText", "Input.dispatchKeyEvent", "Input.dispatchKeyEvent"]);

  // back, then click link 1 by number: the click navigates, and the new page comes back with it
  assert.match(await run("browser_back", {}), /^Tides\n/);
  assert.match(await run("browser_click", { n: 1 }), /^clicked a "Today"\n\nToday\nhttps:\/\/tides\.example\/today\n\nHigh tide 04:12/);
  // by text, and by an alias of the argument a model might use
  assert.match(await run("browser_click", { text: "home" }), /^clicked a "Home"\n\nTides\n/);
  assert.match(await run("browser_click", { index: 1 }), /clicked a "Today"/);
  // what is not there is said, with the way out
  assert.equal(await run("browser_click", { n: 9 }), "ERROR: no element number 9 on this page (browser_read lists the page's elements by number)");
  assert.match(await run("browser_click", { selector: "#nope" }), /ERROR: no element matches/);
  assert.match(await run("browser_type", { n: 1 }), /ERROR: give what to type/);
  assert.match(await run("browser_key", { key: "F13" }), /ERROR: keys are Enter, Tab/);
  assert.match(await run("browser_key", { key: "pagedown" }), /^pressed pagedown\n\nToday/);
  assert.match(await run("browser_scroll", { to: "bottom" }), /^Today\n/);
  assert.match(await run("browser_wait", { text: "low tide" }), /^"low tide" is on the page\n\nToday/);
  assert.match(await run("browser_wait", { text: "never there", seconds: 0.2 }), /did not appear in 0\.2 s/);
  assert.match(await run("browser_open", { url: "ftp://x" }), /ERROR: an http\(s\) URL/);
  assert.match(await run("browser_open", { url: "http://192.168.1.1/admin" }), /private or internal/);
  assert.equal(b.connects, 1); // one connection for the whole iteration
});

test("the browser: a script's value or what it logs comes back, statements run with return, and a bot check is called one", async () => {
  const { b, run } = await browserWorld();
  await run("browser_open", { url: "https://tides.example/" });
  assert.equal(await run("browser_eval", { js: "document.title" }), "Tides");
  assert.equal(await run("browser_eval", { code: "document.title;" }), "Tides"); // an alias, and a trailing semicolon
  assert.equal(await run("browser_eval", { js: 'console.log("logged it")' }), "logged it");
  assert.equal(await run("browser_eval", { js: "let x = 1; return x + 1" }), "2"); // statements: tried as an expression first, then as a body
  assert.match(await run("browser_eval", { js: "throw new Error('nope')" }), /^ERROR: Error: nope/);
  assert.match(await run("browser_eval", { text: "Select all squares" }), /ERROR: give the JavaScript/);
  const wall = await run("browser_open", { url: "https://wall.example/" });
  assert.match(wall, /^BOT CHECK: this page has a verification challenge\./);
  assert.match(wall, /\[1\] input text "Answer" name=answer/);
  assert.match(wall, /\[2\] button "Verify"/);
  assert.equal(b.connects, 1);
});

test("a tot completes a challenge and continues in the same browser session without marking the challenge read as failed", async () => {
  const { w, b } = await browserWorld();
  const actions = [
    { tool: "browser_open", args: { url: "https://wall.example/" } },
    { tool: "browser_type", args: { n: 1, text: "5" } },
    { tool: "browser_click", args: { n: 2 } },
    { final: "The challenge is complete and the tide tables are available." },
  ];
  w.script = (messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Open the tide tables and complete any verification";
    if (text.includes("THIS ITERATION'S STEP")) return JSON.stringify(actions.shift());
    if (text.includes("Grade the LAST iteration")) return "IMPROVED | score: 1/1 | evidence: the browser returned Tide tables for the coast";
    return "NONE";
  };
  await w.tick("Gary");
  assert.equal(actions.length, 0);
  assert.equal(b.typed, "5");
  assert.equal(b.url, "https://tides.example/");
  assert.equal(b.acquired, 1);
  const acts = (await w.events("Gary")).filter((e) => e.kind === "act");
  assert.deepEqual(acts.map((e) => e.tool), ["browser_open", "browser_type", "browser_click"]);
  assert.ok(acts.every((e) => e.ok));
  assert.match(acts[0].text, /BOT CHECK/);
  assert.match(acts[2].text, /Tide tables for the coast/);
});

test("the browser: the session and its page are kept between iterations, and replaced when Cloudflare has ended it", async () => {
  const { w, b, gary, run } = await browserWorld();
  await run("browser_open", { url: "https://tides.example/today" });
  gary.br.cdp.close();
  gary.br = null; // the next iteration: a new connection to the SAME session and page
  assert.match(await run("browser_read", {}), /^Today\nhttps:\/\/tides\.example\/today/);
  assert.equal(b.acquired, 1);
  assert.equal(b.connects, 2);
  assert.equal(b.log.filter((m) => m === "Target.createTarget").length, 1); // re-attached, no new tab
  gary.br.cdp.close();
  gary.br = null;
  b.alive = false; // its ten idle minutes passed on Cloudflare's side
  assert.match(await run("browser_open", { url: "https://tides.example/" }), /^Tides\n/);
  assert.equal(b.acquired, 2);
  assert.equal(await run("browser_close", {}), "browser closed");
  assert.equal(await gary.store.get("browser"), undefined);
  delete w.env.BROWSER;
  assert.match(await run("browser_open", { url: "https://x.example" }), /no browser in this account/);
});

test("the mind: facts are recalled by neuron-db, stances and a mood are kept and ride every prompt, and all of it survives a new isolate", async () => {
  const { NeuronDB } = await import("./neuron-db.mjs");
  const fs = await import("node:fs");
  const bytes = fs.readFileSync(new URL("./neuron_core.wasm", import.meta.url));
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Try the thing";
    if (text.includes("THIS ITERATION'S STEP")) return '{"final": "nothing shown"}';
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: nothing ran";
    return "NONE";
  });
  w.env.NDB = () => NeuronDB.fromBytes(bytes);
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  const run = (tool, args) => gary.runTool(cfg, tool, args, "");
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.neuron, true);
  await run("remember", { fact: "the tide API key lives in settings.json" });
  await run("remember", { fact: "harbour pages are served from /h/<slug>" });
  assert.equal(await run("recall", { query: "where is the API key?" }), "- the tide API key lives in settings.json");
  assert.equal(await run("feel", { about: "web search", feeling: "frustrated: every engine refuses this address" }), "noted: web search - frustrated: every engine refuses this address");
  await run("feel", { about: "Web Search", feeling: "better: the browser gets results" }); // one stance per topic
  assert.deepEqual((await gary.store.get("stances")).map((x) => [x.topic, x.feeling]), [["Web Search", "better: the browser gets results"]]);
  assert.match(await run("feel", { about: "x" }), /ERROR: give both/);
  await w.tick("Gary"); // a flat iteration sets the mood
  assert.equal(await gary.store.get("mood"), "steady - the last step changed nothing measurable");
  await w.tick("Gary");
  assert.match(await gary.store.get("mood"), /^frustrated but persistent/);
  const mem = await gary.workingMemory();
  assert.match(mem, /HOW YOU FEEL ABOUT THE WORK[\s\S]*- right now: frustrated but persistent[\s\S]*- Web Search: better: the browser gets results/);
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.mood.startsWith("frustrated"), true);
  assert.ok((await w.events("Gary")).some((e) => e.kind === "feel" && e.text === "Web Search: better: the browser gets results"));

  // a new isolate: the engine is loaded again from what the tot kept
  gary.ndb = undefined;
  const db = await gary.mind();
  assert.equal(db.recall("tot", "API key", 3)[0], "the tide API key lives in settings.json");
  assert.match(db.raw("stanceof", "tot", "Web Search"), /better: the browser gets results/);

  // without the engine, recall still answers (by keyword) and stances are still kept
  const w2 = world();
  await w2.req("POST", "/v1/tots", { goal: "first goal here" });
  const g2 = w2.tot("Gary");
  const c2 = await g2.store.get("cfg");
  assert.equal((await w2.req("GET", "/v1/tots/Gary")).body.tot.neuron, false);
  await g2.runTool(c2, "remember", { fact: "the tide API key lives in settings.json" }, "");
  assert.equal(await g2.runTool(c2, "recall", { query: "API key" }, ""), "- the tide API key lives in settings.json");
  await g2.runTool(c2, "feel", { about: "python", feeling: "satisfied" }, "");
  assert.equal((await g2.store.get("stances")).length, 1);
});

test("every event carries a one-line brief and whether it went well, beside its full text", async () => {
  const w = world((messages, n) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Fetch the page";
    if (text.includes("THIS ITERATION'S STEP")) return n === 2 ? '{"tool": "web_fetch", "args": {"url": "ftp://nope"}}' : n === 3 ? '{"tool": "write_file", "args": {"name": "a.md", "text": "line one\\nline two"}}' : '{"final": "done"}';
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: none";
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  await w.tick("Gary");
  const evs = await w.events("Gary");
  const acts = evs.filter((e) => e.kind === "act");
  assert.equal(acts[0].ok, false);
  assert.equal(acts[0].brief, 'web_fetch ftp://nope -> ERROR: an http(s) URL is needed, as {"url": "https://..."}');
  assert.equal(acts[1].ok, true);
  assert.equal(acts[1].brief, "write_file a.md -> saved a.md (17 characters)");
  assert.ok(acts[1].text.includes("line one\\nline two")); // the full row keeps the arguments
  for (const e of evs) {
    assert.equal(typeof e.brief, "string");
    assert.ok(!e.brief.includes("\n") && e.brief.length <= 181, e.brief);
    assert.equal(typeof e.ok, "boolean");
  }
});

test("a tot never calls a private address, directly or through a redirect; a reply still thinking at its end has no text", async () => {
  for (const h of ["localhost", "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.20.0.1", "169.254.169.254", "100.64.0.1", "::1", "fd00::1", "x.internal", "0.0.0.0"]) assert.ok(privateHost(h), h);
  for (const h of ["example.com", "8.8.8.8", "172.32.0.1", "100.63.0.1", "1.1.1.1"]) assert.ok(!privateHost(h), h);
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.match(await gary.runTool(cfg, "web_fetch", { url: "http://169.254.169.254/latest/meta-data" }, ""), /private or internal/);
  assert.match(await gary.runTool(cfg, "http_request", { method: "POST", url: "http://localhost:8787/api/v1/x", body: "{}" }, ""), /private or internal/);
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push([init.method, String(url)]);
    if (String(url) === "https://a.example/go") return new Response("", { status: 302, headers: { location: "https://b.example/page" } });
    if (String(url) === "https://a.example/trap") return new Response("", { status: 302, headers: { location: "http://10.0.0.5/admin" } });
    return new Response("<html><head><title>x</title></head><body><p>Hello</p><p>World</p><script>bad()</script></body></html>", { status: 200, headers: { "content-type": "text/html" } });
  };
  try {
    assert.equal(await gary.runTool(cfg, "web_fetch", { url: "https://a.example/go" }, ""), "HTTP 200\nHello\nWorld");
    assert.deepEqual(seen, [["GET", "https://a.example/go"], ["GET", "https://b.example/page"]]);
    assert.match(await gary.runTool(cfg, "web_fetch", { url: "https://a.example/trap" }, ""), /redirects to 10\.0\.0\.5, which a tot does not call/);
    assert.equal(seen.length, 3); // the private hop was never fetched
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(answerText({ response: "<think>still going" }), "");
  assert.equal(answerText({ result: { response: "ok" } }), "ok");
  assert.equal(answerText({ choices: [{ text: "legacy" }] }), "legacy");
});

test("web_search walks the keyless chain: a SearXNG instance that answers is remembered, and a refusal falls through to the next source", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  const realFetch = globalThis.fetch;
  const hosts = [];
  let mode = "searx-second";
  globalThis.fetch = async (url) => {
    const u = new URL(String(url));
    hosts.push(u.hostname);
    if (mode === "searx-second" && u.hostname === "search.disroot.org") return new Response(JSON.stringify({ results: [{ title: "Tide tables", url: "https://tides.example/", content: "High and low" }] }), { status: 200 });
    if (mode === "wikipedia" && u.hostname === "en.wikipedia.org") return new Response(JSON.stringify(["tides", ["Tide"], ["The rise and fall"], ["https://en.wikipedia.org/wiki/Tide"]]), { status: 200 });
    if (u.hostname === "api.duckduckgo.com") return new Response("{}", { status: 200 });
    return new Response("blocked", { status: 429 });
  };
  try {
    const out = await gary.runTool(cfg, "web_search", { query: "tide tables" }, "");
    assert.equal(out, '1 results for "tide tables" (SearXNG):\n1. Tide tables\n   https://tides.example/\n   High and low');
    assert.deepEqual(hosts, ["searx.be", "search.disroot.org"]);
    hosts.length = 0;
    await gary.runTool(cfg, "web_search", { q: "again" }, ""); // an alias for the argument; starts at the one that worked
    assert.equal(hosts[0], "search.disroot.org");
    mode = "wikipedia";
    hosts.length = 0;
    assert.match(await gary.runTool(cfg, "web_search", { query: "tides" }, ""), /\(Wikipedia\):\n1\. Tide\n   https:\/\/en\.wikipedia\.org\/wiki\/Tide\n   The rise and fall/);
    assert.ok(hosts.includes("html.duckduckgo.com") && hosts.includes("www.bing.com") && hosts.includes("api.duckduckgo.com"));
    mode = "nothing";
    const none = await gary.runTool(cfg, "web_search", { query: "tides" }, "");
    assert.match(none, /^ERROR: no search source answered \(/);
    assert.match(none, /veil --tater key brave <key>/); // the way out is named
    // Keep Bing's challenge open, return its controls, and let the tot complete it without switching engines.
    const fb = fakeBrowser();
    const bingUrl = "https://www.bing.com/search?q=tide%20tables&setlang=en";
    fb.site[bingUrl] = fb.site["https://wall.example/"];
    fb.serp = (url) => (url.includes("bing.com") ? { results: [], blocked: true } : { results: [{ title: "Tide tables", url: "https://tides.example/", snippet: "from the browser" }], blocked: false });
    w.env.BROWSER = fb;
    gary.settleMs = 1;
    gary.navMs = 20;
    const challenge = await gary.runTool(cfg, "web_search", { query: "tide tables" }, "");
    assert.match(challenge, /^BOT CHECK: Bing needs verification/);
    assert.match(challenge, /\[1\] input text "Answer"/);
    assert.equal(fb.url, bingUrl);
    assert.equal(fb.log.filter((m) => m === "Page.navigate").length, 1);
    await gary.runTool(cfg, "browser_type", { n: 1, text: "5" }, "");
    assert.match(await gary.runTool(cfg, "browser_click", { n: 2 }, ""), /Tide tables for the coast/);
    // An ordinary empty search page still falls through to the next engine.
    fb.serp = (url) => (url.includes("bing.com") ? { results: [], blocked: false } : { results: [{ title: "Tide tables", url: "https://tides.example/", snippet: "from the browser" }], blocked: false });
    assert.equal(await gary.runTool(cfg, "web_search", { query: "tide tables" }, ""), '1 results for "tide tables" (Brave, through the browser):\n1. Tide tables\n   https://tides.example/\n   from the browser');
    delete w.env.BROWSER;
    gary.br = null;
    // with a key, the search API is asked first and nothing else is
    hosts.length = 0;
    w.env.BRAVE_KEY = "k-123";
    globalThis.fetch = async (url, init) => {
      hosts.push(new URL(String(url)).hostname);
      assert.equal(init.headers["x-subscription-token"], "k-123");
      return new Response(JSON.stringify({ web: { results: [{ title: "Keyed", url: "https://k.example/", description: "from <b>Brave</b>" }] } }), { status: 200 });
    };
    assert.equal(await gary.runTool(cfg, "web_search", { query: "tides" }, ""), '1 results for "tides" (Brave):\n1. Keyed\n   https://k.example/\n   from Brave');
    assert.deepEqual(hosts, ["api.search.brave.com"]);
    delete w.env.BRAVE_KEY;
    assert.match(await gary.runTool(cfg, "web_search", {}, ""), /ERROR: give the words/);
  } finally {
    globalThis.fetch = realFetch;
  }
});

// ------------------------------------------------------------------------------------------ the day-after kit

const TOT_UA = `veil-tot/${VERSION} (Gary; +https://github.com/gary23w/nl-veil)`;

test("pure: the /guard grammar, each target's key, and what one look at a target says", () => {
  assert.deepEqual(parseGuardCommand(""), { op: "list" });
  assert.deepEqual(parseGuardCommand("clear"), { op: "clear" });
  assert.deepEqual(parseGuardCommand('add https://svc.example/health --text "status: OK" --status 200 --every 45 --pin'), { op: "add", target: { url: "https://svc.example/health", text: "status: OK", status: 200, every_s: 45, pin: true } });
  assert.deepEqual(parseGuardCommand("add https://svc.example/"), { op: "add", target: { url: "https://svc.example/", text: "", status: 0, every_s: 0, pin: false } });
  assert.deepEqual(parseGuardCommand("add dns:Example.com. --type mx"), { op: "add", target: { dns: "example.com", type: "MX", every_s: 0 } });
  assert.equal(parseGuardCommand("add dns:example.com --type PTR").op, "error");
  assert.equal(parseGuardCommand("add dns:not a name").op, "error");
  assert.equal(parseGuardCommand("add http://10.0.0.1/").op, "error"); // a private address is never guarded
  assert.equal(parseGuardCommand("add ftp://x").op, "error");
  assert.equal(parseGuardCommand("add https://x.example/ --bogus").op, "error");
  assert.equal(parseGuardCommand("add https://x.example/ --status 42").op, "error");
  assert.equal(parseGuardCommand("add https://x.example/ --every 5").target.every_s, 30); // floored
  assert.deepEqual(parseGuardCommand("rm #2"), { op: "rm", index: 2 });
  assert.deepEqual(parseGuardCommand("rm https://x.example/"), { op: "rm", key: "http:https://x.example/" });
  assert.deepEqual(parseGuardCommand("rm dns:x.example"), { op: "rm", key: "dns:x.example/A" });
  assert.equal(parseGuardCommand("bogus").op, "error");
  assert.equal(watchKey({ url: "https://x/" }), "http:https://x/");
  assert.equal(watchKey({ dns: "x.example", type: "NS" }), "dns:x.example/NS");
  const t = { url: "https://x/", text: "OK", status: 0, pin: true };
  assert.deepEqual(judgeTarget(t, { error: "fetch failed" }), { state: "tripped", why: "unreachable: fetch failed", change: "" });
  assert.equal(judgeTarget(t, { status: 503, text: "OK" }).why, "HTTP 503");
  assert.equal(judgeTarget({ ...t, status: 204 }, { status: 200, text: "OK" }).why, "HTTP 200 (expected 204)");
  assert.equal(judgeTarget(t, { status: 200, text: "nope" }).why, 'expected text missing: "OK"');
  assert.deepEqual(judgeTarget(t, { status: 200, text: "OK", hash: "b" }, { hash: "a" }), { state: "ok", why: "HTTP 200", change: "content changed (fingerprint a -> b)" });
  assert.equal(judgeTarget({ ...t, pin: false }, { status: 200, text: "OK", hash: "b" }, { hash: "a" }).change, ""); // not pinned: a page may change
  assert.equal(judgeTarget({ ...t, text: "" }, { status: 301, text: "" }).state, "ok");
  const d = { dns: "x.example", type: "A" };
  assert.equal(judgeTarget(d, { status: 2, answers: [] }).why, "DNS status 2 (SERVFAIL)");
  assert.equal(judgeTarget(d, { status: 0, answers: [] }).why, "no A answer");
  assert.deepEqual(judgeTarget(d, { status: 0, answers: ["1.1.1.1"] }, { answers: ["2.2.2.2"] }), { state: "ok", why: "1 A answer(s)", change: "A answer changed: [2.2.2.2] -> [1.1.1.1]" });
  assert.equal(judgeTarget(d, { status: 0, answers: ["1.1.1.1"] }, { answers: ["1.1.1.1"] }).change, "");
});

test("the guard runs every heartbeat before the model and without one: a tripwire reaches the events, the scratchpad, the inbox and the owner's webhook, and the watch keeps its cadence through a dead model and a spent budget", async () => {
  const w = world(() => {
    throw new Error("AI is down: 5007"); // the model is gone from the start
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here", pace_s: 600, daily_calls: 10 });
  const gary = w.tot("Gary");
  w.env.ALERT_URL = "https://hooks.example/abc";
  const realFetch = globalThis.fetch;
  const seen = [];
  let up = true;
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    seen.push({ method: init?.method ?? "GET", url: u, ua: init?.headers?.["user-agent"] ?? "", body: init?.body });
    if (u === "https://hooks.example/abc") return new Response("", { status: 204 });
    if (u === "https://svc.example/health") return up ? new Response("<html><body><p>status: OK</p></body></html>", { status: 200, headers: { "content-type": "text/html" } }) : new Response("down", { status: 503 });
    return new Response("?", { status: 404 });
  };
  try {
    const r = (await w.req("POST", "/v1/tots/Gary/command", { text: '/guard add https://svc.example/health --text "status: OK" --every 60' })).body;
    assert.match(r.reply, /^Guarding https:\/\/svc\.example\/health every 60s/);
    assert.equal(r.tot.watch, 1);
    assert.equal(gary.store.alarm, w.now + 1000);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard add https://svc.example/health" })).body.reply, /already guarded/);

    // the first heartbeat: the guard looks (no model), then the goal loop tries the model and fails
    await w.tick("Gary");
    let evs = await w.events("Gary");
    const first = evs.find((e) => e.kind === "guard");
    assert.match(first.text, /^watching https:\/\/svc\.example\/health: HTTP 200/);
    assert.equal(first.ok, true);
    assert.equal(first.target, "http:https://svc.example/health");
    assert.ok(evs.some((e) => e.kind === "error" && /AI is down/.test(e.text)));
    assert.equal(seen[0].ua, TOT_UA); // the guard's checks name the tot, always
    assert.equal(gary.store.alarm, w.now + 60000); // the guard's cadence, not the loop's 1200 s backoff
    assert.equal(await gary.store.get("loop_due"), w.now + 1200000);
    let st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
    assert.equal(st.guard_ok, 1);
    assert.equal(st.guard_tripped, 0);
    assert.match(said(w.asked[0].input.messages), /GUARD LIST \(checked every heartbeat before you run, without a model/);

    // the target goes down: the guard trips, and the tripwire brings the goal loop forward in the same heartbeat
    up = false;
    w.now += 60000;
    await w.tick("Gary");
    assert.equal(w.asked.length, 2); // the loop ran at once (its 1200 s backoff dropped), reading the tripwire as a directive
    assert.match(said(w.asked[1].input.messages), /NEW MESSAGES \(a message from human or guard is a directive[^]*- guard: TRIPWIRE https:\/\/svc\.example\/health: HTTP 503\nThe guard checks this target again every pass/);
    evs = await w.events("Gary");
    const trip = evs.find((e) => e.kind === "tripwire");
    assert.match(trip.text, /^TRIPWIRE https:\/\/svc\.example\/health: HTTP 503/);
    assert.equal(trip.ok, false);
    assert.equal(trip.outcome, "tripped");
    assert.ok(evs.findIndex((e) => e.kind === "tripwire") < evs.findLastIndex((e) => e.kind === "error")); // the guard spoke first
    const pad = (await w.req("GET", "/v1/pad")).body.entries;
    assert.ok(pad.some((e) => e.from === "Gary" && /^TRIPWIRE https:\/\/svc\.example\/health/.test(e.text)));
    const hook = seen.find((s) => s.url === "https://hooks.example/abc");
    assert.equal(hook.method, "POST");
    assert.equal(hook.ua, TOT_UA);
    const body = JSON.parse(hook.body);
    assert.equal(body.source, "veil-tot");
    assert.equal(body.tot, "Gary");
    assert.equal(body.kind, "tripped");
    assert.match(body.content, /^\[veil-tot Gary\] tripped: TRIPWIRE https:\/\/svc\.example\/health: HTTP 503$/);
    assert.equal(body.text, body.content); // Discord reads content, Slack reads text
    assert.equal(body.event.hash, trip.hash);
    assert.equal(body.event.target, "http:https://svc.example/health");
    assert.equal(await gary.store.get("loop_due"), w.now + 1800000); // the loop failed again: its backoff grew
    st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
    assert.equal(st.guard_tripped, 1);
    assert.equal(st.guard_ok, 0);

    // the next heartbeat: still down, so nothing new to say, and the loop's backoff holds
    w.now += 60000;
    await w.tick("Gary");
    assert.equal(w.asked.length, 2);
    assert.equal((await w.events("Gary")).filter((e) => e.kind === "tripwire").length, 1);

    // recovery: said, and the loop is brought forward again
    up = true;
    w.now += 60000;
    await w.tick("Gary");
    const rec = (await w.events("Gary")).filter((e) => e.kind === "tripwire").at(-1);
    assert.match(rec.text, /^RECOVERED https:\/\/svc\.example\/health: HTTP 200, after 120 s/);
    assert.equal(rec.ok, true);
    assert.equal(rec.outcome, "ok");
    assert.equal(w.asked.length, 3);
    assert.equal(seen.filter((s) => s.url === "https://hooks.example/abc").length, 2);

    // the daily budget is spent: the rest is said once, and the guard keeps its cadence until tomorrow
    await gary.store.put("usage", { day: "2026-10-01", calls: 10, total: 10 });
    await gary.store.put("loop_due", 0);
    w.now += 60000;
    await w.tick("Gary");
    assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.state, "resting");
    assert.equal(gary.store.alarm, w.now + 60000);
    w.now += 60000;
    await w.tick("Gary");
    assert.equal((await w.events("Gary")).filter((e) => /resting until tomorrow/.test(e.text)).length, 1);
    assert.equal(seen.filter((s) => s.url === "https://svc.example/health").length, 6);
    assert.equal(gary.store.alarm, w.now + 60000);

    // the list, and clearing it
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard" })).body.reply, /^1\. https:\/\/svc\.example\/health every 60s text "status: OK": OK HTTP 200 \(since 2026-10-01T12:03:00\.000Z\)$/);
    assert.equal((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard clear" })).body.reply, "The guard list is empty.");
    assert.equal(await gary.store.get("watch:http:https://svc.example/health"), undefined);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard" })).body.reply, /^Nothing is guarded\. Usage:/);
  } finally {
    globalThis.fetch = realFetch;
    delete w.env.ALERT_URL;
  }
});

test("the guard reads a name's DNS answers by type: a changed answer is noted once and becomes the baseline, NXDOMAIN trips, and a target is removed by number", async () => {
  const w = world(() => {
    throw new Error("no model");
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here", pace_s: 60 });
  const gary = w.tot("Gary");
  const realFetch = globalThis.fetch;
  let answer = { Status: 0, Answer: [{ name: "example.com", type: 5, data: "edge.example.net." }, { name: "edge.example.net", type: 1, data: "203.0.113.7" }, { name: "edge.example.net", type: 1, data: "203.0.113.5" }] };
  const urls = [];
  globalThis.fetch = async (url, init) => {
    urls.push(String(url));
    assert.equal(init.headers.accept, "application/dns-json");
    assert.equal(init.headers["user-agent"], TOT_UA);
    return new Response(JSON.stringify(answer), { status: 200 });
  };
  try {
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard add dns:Example.COM. --type a --every 60" })).body.reply, /^Guarding dns example\.com A every 60s/);
    await w.tick("Gary");
    assert.equal(urls[0], "https://cloudflare-dns.com/dns-query?name=example.com&type=A");
    assert.match((await w.events("Gary")).find((e) => e.kind === "guard").text, /^watching dns example\.com A: 2 A answer\(s\)/);
    assert.deepEqual((await gary.store.get("watch:dns:example.com/A")).answers, ["203.0.113.5", "203.0.113.7"]); // the CNAME is not an A answer; sorted
    // the answer changes: noted once, the target stays ok, the new answer is the baseline
    answer = { Status: 0, Answer: [{ name: "example.com", type: 1, data: "198.51.100.9" }] };
    w.now += 60000;
    await w.tick("Gary");
    const ch = (await w.events("Gary")).filter((e) => e.kind === "tripwire");
    assert.equal(ch.length, 1);
    assert.match(ch[0].text, /^CHANGED dns example\.com A: A answer changed: \[203\.0\.113\.5, 203\.0\.113\.7\] -> \[198\.51\.100\.9\]$/);
    assert.equal(ch[0].outcome, "changed");
    assert.equal(ch[0].ok, false);
    assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.guard_tripped, 0);
    w.now += 60000;
    await w.tick("Gary");
    assert.equal((await w.events("Gary")).filter((e) => e.kind === "tripwire").length, 1); // not noted again
    // NXDOMAIN trips
    answer = { Status: 3 };
    w.now += 60000;
    await w.tick("Gary");
    assert.match((await w.events("Gary")).filter((e) => e.kind === "tripwire").at(-1).text, /^TRIPWIRE dns example\.com A: DNS status 3 \(NXDOMAIN\)$/);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard" })).body.reply, /^1\. dns example\.com A every 60s: TRIPPED DNS status 3 \(NXDOMAIN\)/);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard rm 1" })).body.reply, /^No longer guarding dns example\.com A\.$/);
    assert.equal((await gary.store.get("cfg")).watch.length, 0);
    assert.equal(await gary.store.get("watch:dns:example.com/A"), undefined);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/guard rm 1" })).body.reply, /^Not guarded/);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("every event is chained to the one before it: the rows verify, an altered or dropped row is caught, and the hash is pinned to its bytes for the Zig verifier", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Write the note";
    if (text.includes("THIS ITERATION'S STEP")) return text.includes("RESULT of") ? '{"final":"done"}' : '{"tool":"write_file","args":{"name":"a.md","text":"héllo"}}';
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: none";
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  await w.tick("Gary");
  const evs = await w.events("Gary");
  assert.ok(evs.length >= 5);
  assert.equal(evs[0].prev, "");
  for (let i = 1; i < evs.length; i++) assert.equal(evs[i].prev, evs[i - 1].hash);
  for (const e of evs) assert.equal(e.hash, await chainHash(e.prev, e.seq, e.t, e.kind, e.text));
  assert.deepEqual(await verifyChain(evs), { ok: true, signed: evs.length, unsigned: 0, seq: 0, why: "" });
  assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.chain, evs.at(-1).hash);
  // a row an older runtime wrote unsigned is counted, not judged
  assert.deepEqual(await verifyChain([{ seq: 0, t: 1, kind: "status", text: "from before" }, ...evs]), { ok: true, signed: evs.length, unsigned: 1, seq: 0, why: "" });
  // the rows as the mirror writes them (JSON, re-read) still verify; an altered text and a dropped row do not
  const mirrored = evs.map((e) => JSON.parse(JSON.stringify(e)));
  assert.equal((await verifyChain(mirrored)).ok, true);
  const altered = structuredClone(evs);
  altered[2].text += " (edited)";
  assert.match((await verifyChain(altered)).why, /^event 3 was altered/);
  assert.equal((await verifyChain(altered)).seq, 3);
  const dropped = evs.filter((e) => e.seq !== 2);
  assert.match((await verifyChain(dropped)).why, /^event 3 does not follow the event before it/);
  // the vectors src/cli/tot.zig's test holds: the same bytes, the same digest
  assert.equal(await chainHash("", 1, 1700000000000, "status", "Gary deployed"), "ee277e3b7484a3200287ecddfb64a112c39df30eb1ea8a384c30cd634f265b35");
  assert.equal(await chainHash("a".repeat(64), 2, 1700000001000, "pick", "look at the harbour\nthen the tide"), "a95660e7604f89bd2a16d1c3b088bd40d340180a7320eb8f09759853399e73fb");
});

test("posture DEFEND freezes the runtime, names the tot in every request and swaps the bot-check line; a leash holds the goal loop while the guard goes on, until the owner's veil is back", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return "Fetch the page";
    if (text.includes("THIS ITERATION'S STEP")) return text.includes("RESULT of") ? '{"final":"done"}' : '{"tool":"web_fetch","args":{"url":"https://a.example/"}}';
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: none";
    return "NONE";
  });
  await w.req("POST", "/v1/tots", { goal: "first goal here", pace_s: 60 });
  const gary = w.tot("Gary");
  const realFetch = globalThis.fetch;
  const uas = [];
  globalThis.fetch = async (url, init) => {
    uas.push(init?.headers?.["user-agent"] ?? "");
    return new Response("hi", { status: 200, headers: { "content-type": "text/plain" } });
  };
  try {
    // normal: the page sees a browser, and the prompt says bot checks are worked through and the runtime is its own
    await w.tick("Gary");
    assert.match(uas[0], /^Mozilla\/5\.0/);
    const normal = said(w.asked[0].input.messages);
    assert.match(normal, /solve CAPTCHAs/);
    assert.match(normal, /runtime_edit/);
    assert.doesNotMatch(normal, /POSTURE: DEFEND/);

    const r = (await w.req("POST", "/v1/tots/Gary/command", { text: "/posture defend" })).body;
    assert.match(r.reply, /posture DEFEND/);
    assert.equal(r.tot.posture, "defend");
    assert.ok((await w.events("Gary")).some((e) => e.kind === "status" && /^posture DEFEND: the runtime is frozen/.test(e.text)));
    const cfg = await gary.store.get("cfg");
    assert.match(await gary.runTool(cfg, "runtime_edit", { revision: 0, find: "a", replace: "b" }, ""), /^ERROR: posture is DEFEND: the runtime is frozen/);
    assert.match(await gary.runTool(cfg, "runtime_deploy", { revision: 0 }, ""), /^ERROR: posture is DEFEND/);
    uas.length = 0;
    assert.equal(await gary.runTool(cfg, "http_request", { method: "GET", url: "https://a.example/", headers: { "user-agent": "Mozilla/9 (fake)" } }, ""), "HTTP 200\nhi");
    assert.equal(uas[0], TOT_UA); // whatever the model asked for
    const before = w.asked.length;
    w.now += 60000;
    await w.tick("Gary");
    const sys = said(w.asked[before].input.messages);
    assert.match(sys, /POSTURE: DEFEND\. Your human declared an incident posture/);
    assert.doesNotMatch(sys, /solve CAPTCHAs/);
    assert.doesNotMatch(sys, /improve your own prompts/);
    assert.equal(uas.at(-1), TOT_UA);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/posture sideways" })).body.reply, /^Usage: \/posture defend \| normal/);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/posture normal" })).body.reply, /^model /);
    assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.posture, "normal");

    // the leash: 120 s without a call from the owner's veil holds the loop; the guard goes on
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/leash 10" })).body.reply, /leash 60s/); // under the floor: floored
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/leash 120" })).body.reply, /leash 120s/);
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/leash soon" })).body.reply, /^Usage: \/leash <seconds> \| off/);
    assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.leash_s, 120);
    await w.req("POST", "/v1/tots/Gary/command", { text: "/guard add https://svc.example/ --every 60" });
    const asked = w.asked.length;
    const peek = async () => [...(await gary.store.list({ prefix: "ev:" })).values()]; // reading events through the API would itself be contact
    w.now += 121000;
    await w.tick("Gary");
    assert.equal(w.asked.length, asked); // the model was not called
    let evs = await peek();
    const held = evs.find((e) => e.kind === "status" && /^leashed: no contact from the owner's veil for 121 s \(the leash is 120 s\)/.test(e.text));
    assert.equal(held.ok, false);
    assert.ok(evs.some((e) => e.kind === "guard" && /^watching https:\/\/svc\.example\/: HTTP 200/.test(e.text))); // the guard still looked
    assert.equal(gary.store.alarm, w.now + 60000);
    assert.equal(await gary.store.get("leashed"), w.now);
    w.now += 60000;
    await w.tick("Gary");
    assert.equal(w.asked.length, asked); // still held
    assert.equal((await peek()).filter((e) => /^leashed:/.test(e.text)).length, 1); // said once
    assert.ok(!(await peek()).some((e) => /owner's veil is back/.test(e.text)));
    // any call from the owner's veil releases it: the status call itself is contact
    const st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
    assert.equal(st.leashed, false);
    assert.equal(st.state, "working");
    evs = await w.events("Gary");
    assert.ok(evs.some((e) => /^the owner's veil is back; Gary resumes its goal loop/.test(e.text)));
    assert.equal(gary.store.alarm, w.now + 1000);
    await w.tick("Gary");
    assert.ok(w.asked.length > asked); // the loop ran again
    assert.match((await w.req("POST", "/v1/tots/Gary/command", { text: "/leash off" })).body.reply, /^model /);
    assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.leash_s, 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("Agent Garrett: its tools appear only with both secrets, a call goes over MCP under the bearer and comes back with its evidence, and a tot asks for the launch through the pad", async () => {
  const w = world();
  await w.req("POST", "/v1/tots", { goal: "first goal here" });
  const gary = w.tot("Gary");
  const cfg = await gary.store.get("cfg");
  const st0 = (await w.req("GET", "/v1/tots/Gary")).body.tot;
  assert.equal(st0.garrett, false);
  assert.match(await gary.runTool(cfg, "garrett", { name: "nvd_lookup", args: { cveId: "CVE-2026-1" } }, ""), /^ERROR: Agent Garrett is not launched/);
  assert.equal((await w.req("GET", "/v1/garrett")).body.status, "none");
  assert.match(await gary.runTool(cfg, "garrett_launch", {}, ""), /^asked: your human's veil launches Agent Garrett/);
  let g = (await w.req("GET", "/v1/garrett")).body;
  assert.equal(g.status, "pending");
  assert.equal(g.asked_by, "Gary");
  assert.equal(g.asked_at, w.now);
  // the owner's veil reports a failure; a tot may ask again; then it reports success
  await w.req("POST", "/v1/garrett/result", { err: "Cloudflare refused the upload" });
  g = (await w.req("GET", "/v1/garrett")).body;
  assert.equal(g.status, "failed");
  assert.equal(g.error, "Cloudflare refused the upload");
  await gary.runTool(cfg, "garrett_launch", {}, "");
  assert.equal((await w.req("GET", "/v1/garrett")).body.status, "pending");
  await w.req("POST", "/v1/garrett/result", { url: "https://veil-garrett.acme.workers.dev/mcp" });
  g = (await w.req("GET", "/v1/garrett")).body;
  assert.equal(g.status, "deployed");
  assert.equal(g.url, "https://veil-garrett.acme.workers.dev/mcp");
  assert.equal((await w.req("POST", "/v1/garrett/bogus", {})).status, 405);

  w.env.GARRETT_MCP_URL = "https://veil-garrett.acme.workers.dev/mcp";
  w.env.GARRETT_MCP_TOKEN = "garrett-bearer-token-24chars!";
  const realFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const body = JSON.parse(init.body);
    if (body.method === "tools/list") return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { tools: [{ name: "nvd_lookup", description: "NVD CVE metadata lookup. Passive/read-only evidence lookup.", inputSchema: { type: "object", properties: { target: {}, cveId: {} } } }], ttlMs: 60000 } }));
    if (body.params.name === "nvd_lookup") return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content: [{ type: "text", text: "CVE-2026-1: CVSS 9.8" }], structuredContent: { tool: "nvd_lookup", via: "builtin", target: "CVE-2026-1" }, isError: false } }));
    if (body.params.name === "nmap_scan") return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content: [{ type: "text", text: "Active MCP tools are disabled." }], isError: true } }));
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: -32602, message: "Unknown tool argument: bogus" } }), { status: 400 });
  };
  try {
    const st = (await w.req("GET", "/v1/tots/Gary")).body.tot;
    assert.equal(st.garrett, true);
    assert.equal(st.tools, st0.tools + 1); // garrett + garrett_tools in, garrett_launch out
    assert.equal(await gary.runTool(cfg, "garrett_launch", {}, ""), "Agent Garrett is already up; garrett_tools lists its tools");
    const list = await gary.runTool(cfg, "garrett_tools", {}, "");
    assert.match(list, /^- nvd_lookup: NVD CVE metadata lookup/);
    assert.match(list, /reads the ones it needs from: target, cveId$/);
    assert.deepEqual(JSON.parse(calls[0].init.body), { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
    const out = await gary.runTool(cfg, "garrett", { name: "NVD_lookup", args: { cveId: "CVE-2026-1" } }, "");
    assert.equal(out, 'CVE-2026-1: CVSS 9.8\nEVIDENCE: {"tool":"nvd_lookup","via":"builtin","target":"CVE-2026-1"}');
    const c = calls.at(-1);
    assert.equal(c.url, "https://veil-garrett.acme.workers.dev/mcp");
    assert.equal(c.init.method, "POST");
    assert.equal(c.init.headers.authorization, "Bearer garrett-bearer-token-24chars!");
    assert.equal(c.init.headers["user-agent"], TOT_UA);
    assert.equal(c.init.headers["mcp-protocol-version"], undefined); // the stateless legacy form: no protocol header, no Mcp-* headers
    assert.deepEqual(JSON.parse(c.init.body), { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "nvd_lookup", arguments: { cveId: "CVE-2026-1" } } });
    assert.match(await gary.runTool(cfg, "garrett", { name: "nmap_scan", arguments: { target: "example.com" } }, ""), /^FAILED: Active MCP tools are disabled\./);
    assert.match(await gary.runTool(cfg, "garrett", { name: "whois", args: { bogus: "1" } }, ""), /^ERROR: Agent Garrett: Unknown tool argument: bogus/);
    assert.match(await gary.runTool(cfg, "garrett", { args: {} }, ""), /^ERROR: name one of Agent Garrett's tools/);
    globalThis.fetch = async () => {
      throw new Error("connect timeout");
    };
    assert.match(await gary.runTool(cfg, "garrett", { name: "nvd_lookup", args: {} }, ""), /^ERROR: Agent Garrett did not answer: connect timeout/);
    w.env.GARRETT_MCP_URL = "https://10.0.0.9/mcp";
    assert.match(await gary.runTool(cfg, "garrett", { name: "nvd_lookup", args: {} }, ""), /^ERROR: Agent Garrett's address is private/);
    w.env.GARRETT_MCP_URL = "http://veil-garrett.acme.workers.dev/mcp"; // not https: as good as unset
    assert.equal((await w.req("GET", "/v1/tots/Gary")).body.tot.garrett, false);
  } finally {
    globalThis.fetch = realFetch;
    delete w.env.GARRETT_MCP_URL;
    delete w.env.GARRETT_MCP_TOKEN;
  }
});
