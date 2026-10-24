// Panel en vivo de la demo: muestra quién está conectado a arkangel_demo y lo que inserta.
// Solo biblioteca estándar de Node; consulta Postgres con psql (consulta fija, sin entrada del usuario).
// Lo lanza demo/start.sh, que define PG_BIN, PGHOST y PGPORT.
import { createServer } from "node:http";
import { execFile } from "node:child_process";

const QUERY = `SELECT json_build_object(
  'rows', (SELECT count(*) FROM intrusion),
  'recent', (SELECT coalesce(json_agg(r), '[]') FROM
    (SELECT id, created_at, junk FROM intrusion ORDER BY id DESC LIMIT 8) r),
  'clients', (SELECT coalesce(json_agg(c), '[]') FROM
    (SELECT host(client_addr) AS addr, usename AS "user", backend_start AS since, state
     FROM pg_stat_activity
     WHERE datname = 'arkangel_demo' AND client_addr IS NOT NULL AND pid <> pg_backend_pid()
     ORDER BY backend_start) c))`;

const stats = () => new Promise((resolve, reject) =>
  execFile(`${process.env.PG_BIN}/psql`, ["-X", "-A", "-t", "-q", "-d", "arkangel_demo", "-c", QUERY],
    { timeout: 3000 }, (err, out, stderr) => err ? reject(new Error(stderr || err.message)) : resolve(out)));

const PAGE = `<!doctype html><html lang="es"><meta charset="utf-8"><title>Arkangel · Demo Postgres</title>
<style>
  body{margin:0;background:#080909;color:#ecede8;font:16px/1.4 -apple-system,system-ui,sans-serif;padding:40px}
  h1{margin:0 0 4px;font-size:22px} .muted{color:#9a9d94} .lime{color:#e0f505}
  .grid{display:grid;grid-template-columns:1fr 2fr;gap:20px;margin-top:28px}
  .card{background:#101111;border:1px solid #282b26;border-radius:14px;padding:20px}
  .big{font-size:72px;font-weight:700;line-height:1} table{width:100%;border-collapse:collapse;font-size:14px}
  td,th{text-align:left;padding:6px 8px;border-bottom:1px solid #282b26} th{color:#9a9d94;font-weight:500}
  .alert{color:#080909;background:#e0f505;border-radius:8px;padding:2px 8px;font-weight:600}
  code{font-family:ui-monospace,monospace}
</style>
<h1>Postgres de la demo <span class="lime">· arkangel_demo</span></h1>
<div class="muted" id="status">Conectando…</div>
<div class="grid">
  <div class="card"><div class="muted">Filas insertadas por el intruso</div><div class="big lime" id="rows">–</div></div>
  <div class="card"><div class="muted">Conexiones desde la red</div><table><thead><tr><th>Equipo</th><th>Rol</th><th>Desde</th><th>Estado</th></tr></thead><tbody id="clients"></tbody></table></div>
</div>
<div class="card" style="margin-top:20px"><div class="muted">Últimas filas</div>
  <table><thead><tr><th>#</th><th>Hora</th><th>Contenido</th></tr></thead><tbody id="recent"></tbody></table></div>
<script>
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const time = t => new Date(t).toLocaleTimeString("es");
async function tick() {
  try {
    const r = await fetch("/api/estado"); const d = await r.json();
    if (!r.ok) throw new Error(d.error);
    document.getElementById("rows").textContent = d.rows.toLocaleString("es");
    document.getElementById("clients").innerHTML = d.clients.length
      ? d.clients.map(c => "<tr><td><span class='alert'>" + esc(c.addr) + "</span></td><td>" + esc(c.user) + "</td><td>" + time(c.since) + "</td><td>" + esc(c.state) + "</td></tr>").join("")
      : "<tr><td colspan=4 class='muted'>Nadie conectado desde la red.</td></tr>";
    document.getElementById("recent").innerHTML = d.recent.map(x =>
      "<tr><td>" + x.id + "</td><td>" + time(x.created_at) + "</td><td><code>" + esc(x.junk) + "</code></td></tr>").join("");
    document.getElementById("status").textContent = "En vivo · actualizado " + new Date().toLocaleTimeString("es");
  } catch (e) { document.getElementById("status").textContent = "Sin conexión con Postgres: " + e.message; }
}
tick(); setInterval(tick, 1000);
</script></html>`;

createServer(async (req, res) => {
  if (req.url === "/api/estado") {
    try {
      res.writeHead(200, { "content-type": "application/json" }).end(await stats());
    } catch (e) {
      res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ error: e.message.trim() }));
    }
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(PAGE);
}).listen(3000, "127.0.0.1", () => console.log("Panel en http://localhost:3000"));
