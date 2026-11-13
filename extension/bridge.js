// nl-veil browser link — the bridge to the web chat.
//
// The web chat (https://gary23w.github.io/nl-veil/chat/) has no local veil server to long-poll, and a web page
// cannot talk to chrome.debugger. This content script is the only thing the manifest injects, and only into that
// one page. It carries messages between the page and the extension's background worker and does nothing else:
//
//     page:  window.postMessage({ veilLink: "page", id, cmd })      ->  background  ->  the driven tab
//     here:  window.postMessage({ veilLink: "ext",  id, result|err })   back to the page
//
// The background worker refuses every command until the user has ticked "Let the web chat drive a tab" in the
// popup, and it only ever acts on the one tab the veil opened itself (see background.js).

const say = (msg) => window.postMessage({ veilLink: "ext", ...msg }, location.origin);

async function hello() {
  try {
    const s = await chrome.runtime.sendMessage({ type: "web-status" });
    say({ type: "hello", version: s.version, allowed: s.allowed === true });
  } catch (_) {
    // The extension was reloaded or removed while this page stayed open. The page simply sees no hello.
  }
}

window.addEventListener("message", async (e) => {
  if (e.source !== window || e.origin !== location.origin) return;
  const m = e.data;
  if (!m || m.veilLink !== "page") return;
  if (m.type === "hello") return hello();
  if (typeof m.id !== "number" || !m.cmd || typeof m.cmd.method !== "string") return;
  try {
    const r = await chrome.runtime.sendMessage({ type: "web", cmd: m.cmd });
    if (r && r.err) say({ id: m.id, err: r.err });
    else say({ id: m.id, result: r ? r.result : {} });
  } catch (err) {
    say({ id: m.id, err: String((err && err.message) || err) });
  }
});

// The popup's tick changes what the page may do: tell the page at once.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.web_allowed) hello();
});

hello();
