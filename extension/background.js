// nl-veil browser link — the whole extension.
//
// It is deliberately dumb. It holds no automation logic: no page-snapshot script, no element-ref model, no
// click heuristics. All of that lives in the veil server and arrives here inside the `params` of a
// `Runtime.evaluate` command. This file's entire job is:
//
//     long-poll the server  →  chrome.debugger.sendCommand(tab, method, params)  →  post the reply back
//
// Two consequences worth knowing. (1) Changing how the veil reads or clicks a page never means reinstalling
// or updating this extension — the server ships the new script with the command. (2) Input is REAL: events
// dispatched through chrome.debugger carry isTrusted:true, exactly like a human's mouse and keyboard, which
// a content script physically cannot produce. That is why this is a debugger relay and not a content script.
//
// The veil drives ONE tab, which it opens itself and which stays in the background. It never touches the tab
// you are reading, and `Emulation.setFocusEmulationEnabled` is what lets its tab keep behaving as focused and
// visible while it sits behind yours.

const DEFAULT_PORTS = [8787, 8788, 8080, 3000];
const POLL_TIMEOUT_MS = 32000; // must exceed the server's 25s long poll, or every idle poll aborts
const RETRY_MS = 3000;
const VERSION = chrome.runtime.getManifest().version;
const BROWSER = navigator.userAgent.includes("Edg/") ? "edge" : "chrome";

let running = false; // one poll loop at a time, even if several wake-ups race
let stop = false;

// ---------------------------------------------------------------------------- config

async function cfg() {
  const d = await chrome.storage.local.get(["port", "token", "paused"]);
  return { port: d.port || 0, token: d.token || "", paused: !!d.paused };
}

const base = (port) => `http://127.0.0.1:${port}/api/v1/browser/ext`;

// Find the veil on this machine and pair with it. Pairing is loopback-only server-side, so this only ever
// succeeds from the user's own computer.
async function connect(preferPort) {
  const ports = preferPort ? [preferPort, ...DEFAULT_PORTS] : DEFAULT_PORTS;
  for (const port of ports) {
    try {
      const hello = await fetch(`${base(port)}/hello`, { signal: AbortSignal.timeout(1500) });
      if (!hello.ok) continue;
      const who = await hello.json();
      if (who.app !== "nl-veil") continue;

      const paired = await fetch(`${base(port)}/pair`, { method: "POST", signal: AbortSignal.timeout(3000) });
      if (!paired.ok) continue;
      const { token } = await paired.json();
      if (!token) continue;

      await chrome.storage.local.set({ port, token, protocol: who.protocol });
      return { port, token };
    } catch (_) {
      // A closed port, a different app answering, or a timeout. Try the next one.
    }
  }
  return null;
}

// ---------------------------------------------------------------------------- the driven tab
//
// The tab id doubles as the session handle the server passes back as `sessionId`. It is kept in session
// storage rather than a module variable because an MV3 service worker is evicted whenever it goes idle, and
// losing the handle would strand an attached tab with no way to reach or close it.

async function getTab() {
  const { tabId } = await chrome.storage.session.get("tabId");
  return tabId || 0;
}

async function setTab(tabId) {
  if (tabId) await chrome.storage.session.set({ tabId });
  else await chrome.storage.session.remove("tabId");
}

async function isAttached(tabId) {
  const targets = await chrome.debugger.getTargets();
  return targets.some((t) => t.tabId === tabId && t.attached);
}

async function openTab() {
  const old = await getTab();
  if (old) await closeTab(old).catch(() => {});

  // active:false so it never steals focus mid-task, and pinned so it is visibly the veil's tab rather than
  // something the user opened and forgot.
  const tab = await chrome.tabs.create({ url: "about:blank", active: false, pinned: true });
  await chrome.debugger.attach({ tabId: tab.id }, "1.3");
  const send = (m, p) => chrome.debugger.sendCommand({ tabId: tab.id }, m, p || {});
  await send("Page.enable");
  await send("Runtime.enable");
  // Console + network capture. Best-effort: a tab that refuses these is still fully drivable.
  await send("Log.enable").catch(() => {});
  await send("Network.enable").catch(() => {});
  // The whole point of a background tab: without focus emulation the page reports itself hidden and
  // unfocused, so :focus never lands, autofocus is skipped, rAF throttles, and typing goes nowhere.
  await send("Emulation.setFocusEmulationEnabled", { enabled: true }).catch(() => {});
  await setTab(tab.id);
  return { sessionId: String(tab.id) };
}

async function closeTab(tabId) {
  if (!tabId) return { ok: true };
  try {
    await chrome.debugger.detach({ tabId });
  } catch (_) {
    // Already gone, or the user opened DevTools on it and took the debugger away.
  }
  try {
    await chrome.tabs.remove(tabId);
  } catch (_) {
    // Already closed.
  }
  if ((await getTab()) === tabId) await setTab(0);
  return { ok: true };
}

// ---------------------------------------------------------------------------- command execution

async function execute(cmd) {
  if (cmd.method === "Ext.openTab") return await openTab();
  if (cmd.method === "Ext.closeTab") return await closeTab(Number(cmd.sessionId) || (await getTab()));
  if (cmd.method === "Ext.ping") return { ok: true, browser: BROWSER, version: VERSION };
  if (cmd.method === "Ext.events") return drainEvents();

  const tabId = Number(cmd.sessionId) || (await getTab());
  if (!tabId) throw new Error("no tab is attached — the veil must open one first");

  // The service worker may have been evicted and restarted between commands, or the user may have closed
  // DevTools back off the tab. Re-attaching is cheap and makes a session survive both.
  if (!(await isAttached(tabId))) await chrome.debugger.attach({ tabId }, "1.3");

  const out = await chrome.debugger.sendCommand({ tabId }, cmd.method, cmd.params || {});
  return out === undefined ? {} : out;
}

// ---------------------------------------------------------------------------- console + network capture
//
// chrome.debugger delivers events by callback rather than in a reply, so they are buffered here until the
// veil asks for them (Ext.events). The server does the same on its own transport, and both report `dropped`
// — a truncated console that LOOKS complete is worse than no console at all, because it reads as "your page
// is fine" when the truth is "I stopped looking".

const KEPT_EVENTS = new Set([
  "Runtime.consoleAPICalled",
  "Runtime.exceptionThrown",
  "Log.entryAdded",
  "Network.requestWillBeSent",
  "Network.responseReceived",
  "Network.loadingFailed",
]);

const EVENTS_CAP = 2000; // entries, not bytes — a service worker has no business holding megabytes
let events = [];
let dropped = 0;

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (!KEPT_EVENTS.has(method)) return;
  if (events.length >= EVENTS_CAP) {
    events.shift(); // keep the most RECENT: "what just happened" is the question being asked
    dropped++;
  }
  events.push(JSON.stringify({ method, params }));
});

function drainEvents() {
  const out = { ndjson: events.join("\n"), dropped };
  events = [];
  dropped = 0;
  return out;
}

// ---------------------------------------------------------------------------- the poll loop

async function loop() {
  if (running) return;
  running = true;
  stop = false;
  try {
    while (!stop) {
      let { port, token, paused } = await cfg();
      if (!token || !port) {
        const got = await connect(port);
        if (!got) {
          await sleep(RETRY_MS);
          continue;
        }
        ({ port, token } = got);
      }

      const url = `${base(port)}/poll?browser=${BROWSER}&version=${VERSION}&paused=${paused ? 1 : 0}`;
      let batch;
      try {
        const r = await fetch(url, {
          headers: { "x-veil-ext-token": token },
          signal: AbortSignal.timeout(POLL_TIMEOUT_MS),
        });
        if (r.status === 401) {
          // The server restarted and minted a new token. Re-pair rather than spinning on 401s.
          await chrome.storage.local.remove("token");
          continue;
        }
        if (!r.ok) {
          await sleep(RETRY_MS);
          continue;
        }
        batch = (await r.json()).cmds || [];
      } catch (_) {
        // Server down, restarting, or the long poll timed out on our side. Neither is an error worth
        // surfacing — back off briefly and poll again.
        await sleep(RETRY_MS);
        continue;
      }

      // Sequentially, not in parallel: the commands in one batch are steps of one interaction (move, press,
      // release), and running them concurrently would scramble the order the page sees them in.
      for (const cmd of batch) {
        let payload;
        try {
          payload = { id: cmd.id, result: await execute(cmd) };
        } catch (e) {
          payload = { id: cmd.id, err: String((e && e.message) || e) };
        }
        try {
          await fetch(`${base(port)}/result`, {
            method: "POST",
            headers: { "content-type": "application/json", "x-veil-ext-token": token },
            body: JSON.stringify(payload),
            signal: AbortSignal.timeout(30000),
          });
        } catch (_) {
          // The waiter has already timed out if we cannot deliver; dropping it is correct.
        }
      }
    }
  } finally {
    running = false;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------- lifecycle
//
// A pending fetch keeps an MV3 service worker alive, so the long poll is its own keep-alive. The alarm is the
// belt-and-braces: if the worker is ever evicted between polls (an abort, a suspend/resume, a browser
// restart), this restarts the loop within 30s. chrome.alarms is the only timer that survives eviction.

chrome.alarms.create("veil-poll", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => loop());
chrome.runtime.onStartup.addListener(() => loop());
chrome.runtime.onInstalled.addListener(() => loop());

// If the user closes the veil's tab, forget it — the next command opens a fresh one instead of failing
// against a dead handle.
chrome.tabs.onRemoved.addListener(async (tabId) => {
  if ((await getTab()) === tabId) await setTab(0);
});

// Same when the debugger is taken away (the user opened DevTools on that tab, or hit "cancel" on the banner).
chrome.debugger.onDetach.addListener(async (source) => {
  if (source.tabId && (await getTab()) === source.tabId) await setTab(0);
});

// The popup's controls.
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  (async () => {
    if (msg.type === "status") {
      const c = await cfg();
      reply({ ...c, tabId: await getTab(), browser: BROWSER, version: VERSION, running });
      return;
    }
    if (msg.type === "connect") {
      await chrome.storage.local.set({ port: msg.port || 0, paused: false });
      await chrome.storage.local.remove("token");
      const got = await connect(msg.port);
      loop();
      reply({ ok: !!got, port: got?.port });
      return;
    }
    if (msg.type === "pause") {
      await chrome.storage.local.set({ paused: !!msg.paused });
      if (msg.paused) {
        const tabId = await getTab();
        if (tabId) await closeTab(tabId); // hand the tab back rather than leaving it attached and idle
      }
      loop();
      reply({ ok: true });
      return;
    }
    if (msg.type === "disconnect") {
      const { port, token } = await cfg();
      const tabId = await getTab();
      if (tabId) await closeTab(tabId);
      if (port && token) {
        await fetch(`${base(port)}/bye`, { method: "POST", headers: { "x-veil-ext-token": token } }).catch(() => {});
      }
      await chrome.storage.local.remove(["token", "port"]);
      stop = true;
      reply({ ok: true });
      return;
    }
    reply({ ok: false });
  })();
  return true; // keeps the message channel open for the async reply
});

loop();
