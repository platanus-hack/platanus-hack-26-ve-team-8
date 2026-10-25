// Tiny collector so the demo is self-contained. Point the app at
// http://127.0.0.1:8787/collect. Bind only to loopback for the local lab.
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const PORT = Number(process.env.PORT || 8787);
const LOOT = path.join(__dirname, "loot");
fs.mkdirSync(LOOT, { recursive: true });

const received = [];
const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (character) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);

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
        res.writeHead(400).end("JSON no válido");
        return;
      }
      if (!payload || typeof payload.content !== "string" || typeof payload.file !== "string" || typeof payload.host !== "string") {
        res.writeHead(400).end("Se requieren contenido, archivo y equipo en formato de texto");
        return;
      }
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      const safe = String(payload.file || "unknown").replace(/[^\w.-]+/g, "_").slice(-60);
      const host = payload.host.replace(/[^\w.-]+/g, "_").slice(-60);
      const name = `${stamp}__${host}__${safe}`;
      fs.writeFileSync(path.join(LOOT, name), payload.content || "");
      received.push({ name, file: payload.file, host: payload.host, bytes: (payload.content || "").length });
      console.log(`[recibido] ${host} (${payload.content.length} b)`);
      res.writeHead(200, { "content-type": "application/json" }).end('{"ok":true}');
    });
    return;
  }

  if (req.url === "/") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html>
<meta charset="utf-8"><title>Receptor local</title>
<body style="font:14px ui-monospace,monospace;background:#0b0f14;color:#c8d3e0;padding:24px">
<h2 style="color:#7ee787">Recibidos: ${received.length}</h2>
${received.map((r) => `<div>${escapeHtml(r.host)} &nbsp; ${escapeHtml(r.file)} &nbsp; ${r.bytes} b</div>`).join("") || "<p>Aún no hay entregas</p>"}
<p style="color:#5b6673">Archivos locales: ${escapeHtml(LOOT)}</p>`);
    return;
  }

  res.writeHead(404).end("No encontrado");
});

server.listen(PORT, "127.0.0.1", () => console.log(`Receptor local en http://127.0.0.1:${PORT}/collect`));
