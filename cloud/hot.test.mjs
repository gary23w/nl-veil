// hot.test.mjs — the hot runtime (hot.js) run whole under node: `node --test cloud/`.
//
// The Durable Object's storage is a sorted Map with the same get/put/list/alarm calls the platform gives, the
// object namespace builds one Hot per name, and the model is a script: each test says what the model answers and
// then reads what the hot did with it. Nothing here talks to Cloudflare.

import test from "node:test";
import assert from "node:assert/strict";
import worker, { Hot, MAX_HOTS, PRIMARY, PLATEAU, firstJson, answerText, parseGoalCommand, parseVerdict, decide, newGoal, recordIteration, validName } from "./hot.js";

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
    HOT_TOKEN: "tok-secret",
    AI: {
      run: async (model, input) => {
        w.asked.push({ model, input });
        return { response: await w.script(input.messages ?? input.input, w.asked.length, input) };
      },
    },
    HOT: {
      idFromName: (name) => name,
      get: (name) => {
        if (!w.objects.has(name)) {
          const storage = new Storage();
          const hot = new Hot({ storage }, w.env);
          hot.now = () => w.now;
          w.objects.set(name, hot);
        }
        const hot = w.objects.get(name);
        return { fetch: (url, init) => hot.fetch(new Request(url, init)) };
      },
    },
  };
  w.req = async (method, path, body, token = "tok-secret") => {
    const r = await worker.fetch(new Request("https://veil-hots.example.workers.dev" + path, { method, headers: { authorization: "Bearer " + token }, body: body === undefined ? undefined : JSON.stringify(body) }), w.env);
    return { status: r.status, body: await r.json() };
  };
  w.hot = (name) => w.objects.get("hot:" + name.toLowerCase());
  /// Fire the hot's alarm the way the platform does: the alarm is cleared, then the handler runs.
  w.tick = async (name) => {
    const hot = w.hot(name);
    hot.store.alarm = null;
    await hot.alarm();
  };
  w.events = async (name) => (await w.req("GET", `/v1/hots/${name}/events?after=0&limit=500`)).body.events;
  return w;
}

const said = (messages) => messages.map((m) => m.content).join("\n");

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
  for (const [m, p] of [["GET", "/v1/hots"], ["POST", "/v1/hots"], ["GET", "/v1/pad"], ["GET", "/v1/hots/Gary"], ["DELETE", "/v1/hots/Gary"], ["GET", "/v1/version"]]) {
    const r = await w.req(m, p, m === "POST" ? { goal: "x" } : undefined, "wrong");
    assert.equal(r.status, 401, `${m} ${p}`);
  }
  assert.equal((await w.req("GET", "/v1/hots", undefined, "")).status, 401);
  assert.equal(w.objects.size, 0);
});

test("the first hot is always Gary, names are unique, and the fourth is refused", async () => {
  const w = world();
  const first = await w.req("POST", "/v1/hots", { name: "Zed", goal: "watch the news" });
  assert.equal(first.status, 200);
  assert.equal(first.body.hot.name, PRIMARY);
  assert.equal(first.body.hot.local, false);
  assert.equal((await w.req("POST", "/v1/hots", { name: "gary", goal: "x y z" })).status, 409);
  assert.equal((await w.req("POST", "/v1/hots", { name: "bad name!", goal: "x y z" })).status, 409);
  assert.equal((await w.req("POST", "/v1/hots", { name: "Ada", goal: "x y z" })).body.hot.name, "Ada");
  assert.equal((await w.req("POST", "/v1/hots", { name: "Nova", goal: "x y z" })).status, 200);
  const fourth = await w.req("POST", "/v1/hots", { name: "Rex", goal: "x y z" });
  assert.equal(fourth.status, 409);
  assert.match(fourth.body.err, /limit/);
  const list = await w.req("GET", "/v1/hots");
  assert.deepEqual(list.body.hots.map((h) => h.name), ["Gary", "Ada", "Nova"]);
  assert.equal(list.body.max_hots, MAX_HOTS);
  // deleting one frees its slot and its storage
  assert.equal((await w.req("DELETE", "/v1/hots/ada")).body.deleted, "Ada");
  assert.equal(w.hot("Ada").store.m.size, 0);
  assert.equal(w.hot("Ada").store.alarm, null);
  assert.equal((await w.req("GET", "/v1/hots/Ada")).status, 404);
  assert.equal((await w.req("POST", "/v1/hots", { name: "Rex", goal: "x y z" })).status, 200);
  assert.ok(validName("Rex") && !validName("9lives") && !validName("") && !validName("a".repeat(25)));
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
      assert.match(text, /note_write/);
      assert.doesNotMatch(text, /local_run/); // not granted
      return 'I will save it.\n{"tool": "note_write", "args": {"name": "sources.md", "text": "a\\nb\\nc"}}';
    }
    if (n === 3) {
      assert.match(text, /RESULT of note_write:\nsaved sources.md \(5 characters\)/);
      return '{"final": "saved 3 URLs to sources.md"}';
    }
    if (n === 4) {
      assert.match(text, /TOOL note_write/);
      return "IMPROVED | score: 3/10 | evidence: sources.md saved with 3 of 10 sources";
    }
    throw new Error("unexpected model call " + n);
  });
  await w.req("POST", "/v1/hots", { goal: "collect ten sources on tide tables", pace_s: 120 });
  assert.equal(w.hot("Gary").store.alarm, w.now + 1000);
  await w.tick("Gary");
  assert.equal(w.asked.length, 4);
  const st = (await w.req("GET", "/v1/hots/Gary")).body.hot;
  assert.equal(st.goal.iteration, 1);
  assert.equal(st.goal.improved, 1);
  assert.equal(st.goal.best_num, 3);
  assert.equal(st.calls_today, 4);
  assert.equal(st.next_tick, w.now + 120000);
  assert.equal(st.state, "working");
  const kinds = (await w.events("Gary")).map((e) => e.kind);
  assert.deepEqual(kinds, ["status", "goal", "pick", "act", "verdict"]);
  assert.equal((await w.hot("Gary").store.get("note:sources.md")).text, "a\nb\nc");

  // The next iteration's pick sees the log, and DONE ends a finite goal as achieved.
  w.script = (messages) => {
    assert.match(said(messages), /1\. improved: Save the three source URLs in a note \(sources\.md saved with 3 of 10 sources\) \[3\/10\]/);
    return "DONE";
  };
  await w.tick("Gary");
  const done = (await w.req("GET", "/v1/hots/Gary")).body.hot;
  assert.equal(done.goal.status, "achieved");
  assert.equal(done.state, "roaming");
});

test("a step that does not improve the goal becomes a lesson the next prompt carries, and the hot grows after two flat iterations", async () => {
  let phase = "";
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("GOAL LOOP")) return (phase = "pick"), "Try the thing";
    if (text.includes("THIS ITERATION'S STEP")) return '{"final": "I did it, trust me"}';
    if (text.includes("Grade the LAST iteration")) return "SAME | score: none | evidence: nothing was run";
    if (text.includes("Write ONE new rule")) return "- Always finish a step with a tool result that shows its effect.";
    throw new Error("unexpected: " + text.slice(0, 80));
  });
  await w.req("POST", "/v1/hots", { goal: "make the report better", size: 3 });
  await w.tick("Gary");
  const lessons = await w.hot("Gary").store.get("lessons");
  assert.equal(lessons.length, 1);
  assert.equal(lessons[0].text, "Always finish a step with a tool result that shows its effect.");
  assert.equal((await w.req("GET", "/v1/hots/Gary")).body.hot.minds, 1);
  await w.tick("Gary");
  // the second iteration's prompts carried the lesson; the same lesson is not stored twice
  assert.ok(w.asked.slice(4).some((a) => said(a.input.messages).includes("YOUR LESSONS") && said(a.input.messages).includes("Always finish a step")));
  assert.equal((await w.hot("Gary").store.get("lessons")).length, 1);
  const st = (await w.req("GET", "/v1/hots/Gary")).body.hot;
  assert.equal(st.goal.flat, 2);
  assert.equal(st.minds, 2); // grew
  // the third flat iteration is the plateau: the goal ends and the hot moves on by itself
  await w.tick("Gary");
  assert.equal((await w.req("GET", "/v1/hots/Gary")).body.hot.goal.status, "plateau");
  assert.ok((await w.events("Gary")).some((e) => e.kind === "status" && /Moving to the next best thing/.test(e.text)));
  assert.equal(phase, "pick");
});

test("a goal that ends hands over to the queue, then to a goal the hot proposes from its charter, then to a rest that backs off", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("You have no active goal")) {
      assert.match(text, /achieved \(0 improved\): first goal here/);
      return roamAnswer;
    }
    if (text.includes("GOAL LOOP")) return "DONE";
    throw new Error("unexpected: " + text.slice(0, 80));
  });
  let roamAnswer = "Check the tide tables for errors against a second source";
  await w.req("POST", "/v1/hots", { goal: "first goal here", charter: "keep the tide site accurate", pace_s: 60 });
  await w.req("POST", "/v1/hots/Gary/command", { text: "/queue second goal here" });
  await w.tick("Gary"); // first: DONE
  await w.tick("Gary"); // takes the queued goal and picks: DONE
  let st = (await w.req("GET", "/v1/hots/Gary")).body.hot;
  assert.equal(st.goal.text, "second goal here");
  assert.equal(st.goal.status, "achieved");
  await w.tick("Gary"); // nothing queued: roam proposes, then pick says DONE
  st = (await w.req("GET", "/v1/hots/Gary")).body.hot;
  assert.equal(st.goal.text, "Check the tide tables for errors against a second source");
  roamAnswer = "REST";
  await w.tick("Gary");
  const first = w.hot("Gary").store.alarm - w.now;
  await w.tick("Gary");
  const second = w.hot("Gary").store.alarm - w.now;
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
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  w.hot("Gary").store.alarm = w.now + 500000;
  const r = await w.req("POST", "/v1/hots/Gary/command", { text: "focus on the harbour pages first" });
  assert.match(r.body.reply, /next iteration/);
  assert.equal(w.hot("Gary").store.alarm, w.now + 1000); // woken
  await w.tick("Gary");
  assert.deepEqual(await w.hot("Gary").store.get("inbox"), []);

  const g = await w.req("POST", "/v1/hots/Gary/command", { text: "/goal map every harbour --forever" });
  assert.match(g.body.reply, /runs until you stop it/);
  assert.equal(g.body.hot.goal.budget, 0);
  const p = await w.req("POST", "/v1/hots/Gary/command", { text: "/pause" });
  assert.equal(p.body.hot.state, "paused");
  assert.equal(w.hot("Gary").store.alarm, null);
  const before = w.asked.length;
  await w.tick("Gary"); // a paused hot does nothing, even if an alarm fires
  assert.equal(w.asked.length, before);
  assert.equal(w.hot("Gary").store.alarm, null);
  assert.equal((await w.req("POST", "/v1/hots/Gary/command", { text: "/resume" })).body.hot.state, "working");
  assert.match((await w.req("POST", "/v1/hots/Gary/command", { text: "/nonsense" })).body.reply, /Commands:/);
  const cfg = await w.req("POST", "/v1/hots/Gary/config", { pace_s: 5, size: 99, local: true, model: "@cf/x/y" });
  assert.equal(cfg.body.hot.pace_s, 30); // clamped
  assert.equal(cfg.body.hot.size, 8);
  assert.equal(cfg.body.hot.model, "@cf/x/y");
  assert.equal(cfg.body.hot.local, false); // the owner's machine is granted at deployment only
});

test("hots share one scratchpad and can message each other", async () => {
  const w = world();
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  await w.req("POST", "/v1/hots", { name: "Ada", goal: "second goal here" });
  const gary = w.hot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.match(await gary.runTool(cfg, "pad_write", { text: "harbour list lives in note harbours.md" }, ""), /entry 1 written/);
  const ada = w.hot("Ada");
  const acfg = await ada.store.get("cfg");
  assert.match(await ada.runTool(acfg, "pad_read", {}, ""), /1\. Gary: harbour list lives in note harbours\.md/);
  assert.match(await ada.padTail(), /Gary: harbour list/);
  assert.equal(await gary.runTool(cfg, "tell", { hot: "ada", text: "take the east coast" }, ""), "delivered to Ada");
  assert.equal((await ada.store.get("inbox"))[0].text, "take the east coast");
  assert.equal((await ada.store.get("inbox"))[0].from, "Gary");
  assert.match(await gary.runTool(cfg, "tell", { hot: "Nobody", text: "x" }, ""), /no hot named Nobody/);
  assert.match(await gary.runTool(cfg, "tell", { hot: "Gary", text: "x" }, ""), /ERROR/);
  // the human reads and writes the same pad
  await w.req("POST", "/v1/pad", { text: "from the desk" });
  const pad = await w.req("GET", "/v1/pad?after=1");
  assert.deepEqual(pad.body.entries.map((e) => [e.from, e.text]), [["human", "from the desk"]]);
});

test("an inner swarm runs one mind per task up to the hot's current size, and a mind cannot cast another", async () => {
  const w = world((messages) => {
    const text = said(messages);
    if (text.includes("one mind of Gary's swarm")) return `{"final": "report for: ${messages[1].content}"}`;
    throw new Error("unexpected");
  });
  await w.req("POST", "/v1/hots", { goal: "first goal here", size: 4 });
  const gary = w.hot("Gary");
  const cfg = await gary.store.get("cfg");
  cfg.minds = 2;
  const out = await gary.runTool(cfg, "swarm", { tasks: ["east coast", "west coast", "north coast"] }, "");
  assert.match(out, /MIND 1 \(east coast\): report for: east coast/);
  assert.match(out, /MIND 2 \(west coast\): report for: west coast/);
  assert.match(out, /NOT RUN \(this hot runs 2 at a time now\): north coast/);
  assert.equal(w.asked.length, 2);
  assert.match(await gary.runTool(cfg, "swarm", { tasks: ["x y z"] }, "m1"), /a mind cannot cast a swarm/);
  assert.match(await gary.runTool(cfg, "swarm", {}, ""), /ERROR/);
});

test("the owner's machine: local_run exists only when granted at deployment, queues a job, and the result comes back to the inbox", async () => {
  const w = world();
  await w.req("POST", "/v1/hots", { goal: "first goal here", local: true });
  await w.req("POST", "/v1/hots", { name: "Ada", goal: "second goal here" });
  const gary = w.hot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.equal(cfg.local, true);
  assert.match(await w.hot("Ada").runTool(await w.hot("Ada").store.get("cfg"), "local_run", { instruction: "list the repo" }, ""), /not given the owner's machine/);
  assert.match(await gary.runTool(cfg, "local_run", { instruction: "run the test suite in ~/site" }, ""), /queued as job j1/);
  const jobs = await w.req("GET", "/v1/hots/Gary/jobs");
  assert.deepEqual(jobs.body.jobs.map((j) => [j.id, j.instruction]), [["j1", "run the test suite in ~/site"]]);
  assert.equal((await w.req("GET", "/v1/hots/Ada/jobs")).body.jobs.length, 0);
  gary.store.alarm = w.now + 900000;
  const done = await w.req("POST", "/v1/hots/Gary/jobs/j1", { ok: true, result: "42 passed, 0 failed" });
  assert.equal(done.status, 200);
  assert.equal(gary.store.alarm, w.now + 1000); // the result wakes the hot
  const inbox = await gary.store.get("inbox");
  assert.equal(inbox[0].from, "local");
  assert.match(inbox[0].text, /job j1 finished[\s\S]*42 passed, 0 failed/);
  assert.equal((await w.req("GET", "/v1/hots/Gary/jobs")).body.jobs.length, 0);
  assert.equal((await w.req("POST", "/v1/hots/Gary/jobs/j1", { result: "again" })).status, 404); // a job is answered once
  for (let i = 0; i < 4; i++) await gary.runTool(cfg, "local_run", { instruction: "job number " + i }, "");
  assert.match(await gary.runTool(cfg, "local_run", { instruction: "one too many" }, ""), /already waiting/);
});

test("the daily call budget rests the hot until the next UTC day, and a failing model never ends it", async () => {
  const w = world(() => "Try the thing");
  await w.req("POST", "/v1/hots", { goal: "first goal here", daily_calls: 10, pace_s: 60 });
  const gary = w.hot("Gary");
  await gary.store.put("usage", { day: "2026-10-01", calls: 10, total: 10 });
  await w.tick("Gary");
  assert.equal(w.asked.length, 0);
  assert.equal((await w.req("GET", "/v1/hots/Gary")).body.hot.state, "resting");
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
  await w.req("POST", "/v1/hots", { goal: "first goal here", model: "@cf/some/responses-model" });
  await w.tick("Gary");
  assert.deepEqual(w.asked.map((a) => (a.messages ? "messages" : "input")), ["messages", "input"]);
  assert.equal((await w.hot("Gary").store.get("goal")).status, "achieved");
  await w.req("POST", "/v1/hots/Gary/command", { text: "/goal another goal here" });
  await w.tick("Gary");
  assert.equal(w.asked.length, 3); // straight to `input` this time
  assert.ok(w.asked[2].input);
});

test("the event tail is bounded and a far-behind reader gets the newest rows", async () => {
  const w = world();
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  const gary = w.hot("Gary");
  for (let i = 0; i < 1600; i++) await gary.emit("act", "row " + i);
  const seq = await gary.store.get("seq");
  assert.equal((await gary.store.list({ prefix: "ev:" })).size, 1500);
  const r = await w.req("GET", "/v1/hots/Gary/events?after=0&limit=50");
  assert.equal(r.body.events.length, 50);
  assert.equal(r.body.events.at(-1).seq, seq);
  const tail = await w.req("GET", `/v1/hots/Gary/events?after=${seq - 2}`);
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
  await w.req("POST", "/v1/hots", { goal: "the old goal here", pace_s: 60 });
  during = async () => void (await w.req("POST", "/v1/hots/Gary/command", { text: "/goal the new goal here --budget 7" }));
  await w.tick("Gary");
  let g = await w.hot("Gary").store.get("goal");
  assert.equal(g.text, "the new goal here");
  assert.equal(g.iteration, 0); // the old goal's step earned the new goal nothing
  assert.equal(g.budget, 7);
  assert.ok((await w.events("Gary")).some((e) => /set aside/.test(e.text)));
  assert.equal((await w.hot("Gary").store.list({ prefix: "log:" })).size, 0);

  // same goal, changed mid-iteration: the iteration counts AND the stop is kept; /pace is not rolled back
  during = async () => {
    await w.req("POST", "/v1/hots/Gary/command", { text: "/goal stop" });
    await w.req("POST", "/v1/hots/Gary/command", { text: "/pace 300" });
  };
  await w.tick("Gary");
  g = await w.hot("Gary").store.get("goal");
  assert.equal(g.status, "stopped");
  assert.equal(g.iteration, 1);
  assert.equal((await w.hot("Gary").store.get("cfg")).pace_s, 300);
});

test("a hot deleted while its iteration is out stays deleted: nothing it writes afterwards survives, and no alarm is set", async () => {
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
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  const gary = w.hot("Gary");
  during = async () => {
    during = null;
    assert.equal((await w.req("DELETE", "/v1/hots/Gary")).status, 200);
  };
  await w.tick("Gary");
  assert.equal(gary.store.m.size, 0);
  assert.equal(gary.store.alarm, null);
  assert.deepEqual((await w.req("GET", "/v1/hots")).body.hots, []);
});

test("DONE is checked against the goal as stored when the answer arrives: a goal made forever, or stopped, meanwhile is not marked achieved", async () => {
  let during = null;
  const w = world(async () => {
    if (during) await during();
    return "DONE";
  });
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  during = async () => void (await w.req("POST", "/v1/hots/Gary/command", { text: "/goal forever" }));
  await w.tick("Gary");
  let g = await w.hot("Gary").store.get("goal");
  assert.equal(g.status, "active");
  assert.equal(g.forever, true);
  await w.req("POST", "/v1/hots", { name: "Ada", goal: "second goal here" });
  during = async () => void (await w.req("POST", "/v1/hots/Ada/command", { text: "/goal stop" }));
  await w.tick("Ada");
  g = await w.hot("Ada").store.get("goal");
  assert.equal(g.status, "stopped"); // not "achieved": the human's stop is what the record shows
});

test("the local mirror's counters: notes come back changed-after a stamp, a delete moves the revision, the roster names the pad's seq", async () => {
  const w = world();
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  const gary = w.hot("Gary");
  const cfg = await gary.store.get("cfg");
  await gary.runTool(cfg, "note_write", { name: "a.md", text: "one" }, "");
  await gary.runTool(cfg, "note_write", { name: "b.md", text: "two" }, ""); // same millisecond: still a later stamp
  let r = (await w.req("GET", "/v1/hots/Gary/notes?after=0")).body;
  assert.deepEqual(r.notes.map((n) => [n.name, n.text]), [["a.md", "one"], ["b.md", "two"]]);
  assert.ok(r.notes[1].t > r.notes[0].t);
  assert.equal(r.more, false);
  const t = r.notes[1].t;
  await gary.runTool(cfg, "note_write", { name: "a.md", text: "one, again" }, "");
  r = (await w.req("GET", `/v1/hots/Gary/notes?after=${t}`)).body;
  assert.deepEqual(r.notes.map((n) => n.text), ["one, again"]);
  const rev = (await w.req("GET", "/v1/hots/Gary")).body.hot.notes_rev;
  assert.equal(rev, 3);
  await gary.runTool(cfg, "note_delete", { name: "b.md" }, "");
  const after = (await w.req("GET", "/v1/hots/Gary")).body.hot.notes_rev;
  assert.equal(after, 4);
  assert.deepEqual((await w.req("GET", "/v1/hots/Gary/notes?after=0")).body.names, ["a.md"]);
  await gary.runTool(cfg, "pad_write", { text: "x" }, "");
  assert.equal((await w.req("GET", "/v1/hots")).body.pad_seq, 1);
});

test("an inner swarm runs at least two minds when the hot's size allows, whatever its current width", async () => {
  const w = world((messages) => `{"final": "ok ${messages[1].content}"}`);
  await w.req("POST", "/v1/hots", { goal: "first goal here", size: 3 });
  const gary = w.hot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.equal(cfg.minds, 1);
  const out = await gary.runTool(cfg, "swarm", { tasks: ["east coast", "west coast", "north coast"] }, "");
  assert.match(out, /MIND 2 \(west coast\)/);
  assert.match(out, /NOT RUN \(this hot runs 2 at a time now\): north coast/);
  cfg.size = 1;
  assert.match(await gary.runTool(cfg, "swarm", { tasks: ["east coast", "west coast"] }, ""), /NOT RUN \(this hot runs 1 at a time now\)/);
});

test("a forward read of the event tail starts where the reader left off, however far behind it is", async () => {
  const w = world();
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
  const gary = w.hot("Gary");
  for (let i = 0; i < 30; i++) await gary.emit("act", "row " + i);
  const tail = (await w.req("GET", "/v1/hots/Gary/events?after=0&limit=5")).body.events;
  assert.equal(tail[0].seq, (await gary.store.get("seq")) - 4); // a console gets the newest
  const fwd = (await w.req("GET", "/v1/hots/Gary/events?after=0&limit=5&forward=1")).body.events;
  assert.deepEqual(fwd.map((e) => e.seq), [1, 2, 3, 4, 5]); // the mirror gets the next five
});

test("a goal and a charter are held to the text limit the server sends for the hot's model", async () => {
  const w = world();
  const long = "x".repeat(3000);
  await w.req("POST", "/v1/hots", { goal: long, charter: long, text_max: 1200 });
  const gary = w.hot("Gary");
  const cfg = await gary.store.get("cfg");
  assert.equal(cfg.text_max, 1200);
  assert.ok(cfg.charter.length <= 1201 && (await gary.store.get("goal")).text.length <= 1201);
  await w.req("POST", "/v1/hots/Gary/command", { text: "/goal " + "y".repeat(5000) });
  assert.ok((await gary.store.get("goal")).text.length <= 1201);
  await w.req("POST", "/v1/hots/Gary/config", { model: "@cf/big/model", text_max: 4000 });
  await w.req("POST", "/v1/hots/Gary/command", { text: "/charter " + "z".repeat(5000) });
  assert.equal((await gary.store.get("cfg")).charter.length, 4001); // 4000 and the ellipsis
});

test("clearing the scratchpad empties it for the next set of hots, and its seq moves on", async () => {
  const w = world();
  await w.req("POST", "/v1/hots", { goal: "first goal here" });
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
