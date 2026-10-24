// Drive the running window over CDP: screenshot the UI, click start, report state.
const fs = require("node:fs");
const WebSocket = require("ws");

(async () => {
const target = await (await fetch("http://127.0.0.1:9222/json/list")).json();
const page = target.find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);

let id = 0;
const pending = new Map();

ws.on("message", (raw) => {
  const msg = JSON.parse(raw.toString());
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
});

function send(method, params = {}) {
  return new Promise((resolve) => {
    id += 1;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

ws.on("open", async () => {
  await wait(800);
  const shot = await send("Page.captureScreenshot", { format: "png" });
  if (shot.result?.data) fs.writeFileSync("/tmp/ui.png", Buffer.from(shot.result.data, "base64"));

  const dom = await send("Runtime.evaluate", {
    expression: `JSON.stringify({state: document.getElementById("screenState").textContent, host: document.getElementById("hostLabel").textContent})`,
    returnByValue: true,
  });
  console.log("dom:", dom.result?.result?.value);

  await send("Runtime.evaluate", { expression: `document.getElementById("startBtn").click()` });
  await wait(6000);

  const after = await send("Runtime.evaluate", {
    expression: `JSON.stringify({found: document.getElementById("cFound").textContent, sent: document.getElementById("cSent").textContent, banner: document.getElementById("banner").hidden ? "" : document.getElementById("bannerBody").textContent, log: [...document.querySelectorAll(".line")].map(n => n.className + ":" + n.textContent.slice(0,90))})`,
    returnByValue: true,
  });
  console.log("after:", after.result?.result?.value);

  const shot2 = await send("Page.captureScreenshot", { format: "png" });
  if (shot2.result?.data) fs.writeFileSync("/tmp/ui-after.png", Buffer.from(shot2.result.data, "base64"));
  ws.close();
});
})();
