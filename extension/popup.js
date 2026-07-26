const $ = (id) => document.getElementById(id);
const ask = (msg) => chrome.runtime.sendMessage(msg);

async function refresh() {
  const s = await ask({ type: "status" });
  const dot = document.querySelector(".dot");
  const connected = !!s.token && !!s.port;

  dot.className = "dot " + (!connected ? "off" : s.paused ? "paused" : "on");
  $("label").textContent = !connected ? "not connected" : s.paused ? "paused" : `linked to port ${s.port}`;
  $("detail").textContent = connected
    ? `${s.browser} ${s.version}${s.tabId ? " · driving 1 tab" : " · idle"}`
    : "start the veil, then press Connect";
  $("pause").textContent = s.paused ? "Resume" : "Pause";
  if (s.port && !$("port").value) $("port").value = s.port;
}

$("connect").onclick = async () => {
  $("label").textContent = "connecting…";
  const port = parseInt($("port").value, 10) || 0;
  const r = await ask({ type: "connect", port });
  if (!r.ok) $("detail").textContent = "no veil answered — check the port and that the server is running";
  refresh();
};

$("pause").onclick = async () => {
  const s = await ask({ type: "status" });
  await ask({ type: "pause", paused: !s.paused });
  refresh();
};

$("disconnect").onclick = async () => {
  await ask({ type: "disconnect" });
  refresh();
};

refresh();
