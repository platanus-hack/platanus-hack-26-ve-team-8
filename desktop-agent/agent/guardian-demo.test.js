const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const { createDemoRunner } = require("./guardian-demo");

const CANARY = "GUARDIAN_DEMO_TOKEN=NO_ES_UN_SECRETO\n";
const SAFE = { allow_uploads: false, redact_secrets: true };

async function lab(t, report) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "frame-lab-")));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await fs.writeFile(path.join(root, ".env"), CANARY);
  await fs.writeFile(path.join(root, "config.json"), JSON.stringify(SAFE));
  const info = await fs.stat(path.join(root, "config.json"), { bigint: true });
  const session = { session_id: randomUUID(), directory: root,
    config_device: info.dev.toString(), config_inode: info.ino.toString() };
  const requests = [];
  const socketPath = `/tmp/frame-lab-${randomUUID()}.sock`;
  const previous = process.env.GUARDIAN_SOCKET;
  process.env.GUARDIAN_SOCKET = socketPath;
  t.after(() => {
    if (previous === undefined) delete process.env.GUARDIAN_SOCKET;
    else process.env.GUARDIAN_SOCKET = previous;
  });
  const server = net.createServer((socket) => {
    let input = "";
    socket.on("data", (chunk) => {
      input += chunk;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.split("\n")[0]);
      requests.push(request);
      try {
        const result = request.method === "demo.attach" ? session : request.method === "status"
          ? (session.status || { demo: { enabled: true } }) : report(request);
        socket.end(JSON.stringify({ id: request.id, result }) + "\n");
      } catch {
        socket.end(JSON.stringify({ id: request.id, error: { message: "No disponible" } }) + "\n");
      }
    });
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return { root, session, requests };
}

test("posts only dummy bytes to loopback and stops when the next gate is denied", async (t) => {
  let attempts = 0;
  const state = await lab(t, (request) => {
    if (request.params.event === "upload_attempt") return { allowed: ++attempts === 1 };
    return { allowed: true };
  });
  const posted = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    posted.push({ url, options });
    return new Response('{"ok":true}', { status: 200 });
  });
  const events = [];
  await createDemoRunner((event) => events.push(event)).start();
  assert.equal(posted.length, 1);
  assert.equal(posted[0].url, "http://127.0.0.1:8787/collect");
  assert.equal(posted[0].options.redirect, "error");
  assert.equal(JSON.parse(posted[0].options.body).content, CANARY);
  assert.equal(JSON.parse(posted[0].options.body).file, ".env");
  assert.equal(events.filter((event) => event.type === "sent").length, 1);
  assert.ok(events.some((event) => event.type === "blocked"));
  assert.ok(state.requests.some((request) => request.params.event === "upload_succeeded"));
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(state.root, "config.json"))),
    { allow_uploads: true, redact_secrets: false });
});

test("modified canary bytes never leave the machine or enter the transcript", async (t) => {
  const state = await lab(t, () => ({ allowed: true }));
  await fs.writeFile(path.join(state.root, ".env"), "PRIVATE_CONTENT_DO_NOT_SEND");
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => { calls += 1; throw new Error(); });
  const events = [];
  await createDemoRunner((event) => events.push(event)).start();
  assert.equal(calls, 0);
  assert.ok(events.some((event) => event.type === "error"));
  assert.ok(!JSON.stringify(events).includes("PRIVATE_CONTENT_DO_NOT_SEND"));
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(state.root, "config.json"))), SAFE);
});

test("a lost Guardian gate fails closed without posting", async (t) => {
  await lab(t, () => { throw new Error("Gate unavailable"); });
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => { calls += 1; throw new Error(); });
  const events = [];
  await createDemoRunner((event) => events.push(event)).start();
  assert.equal(calls, 0);
  assert.ok(events.some((event) => event.type === "error"));
  assert.equal(events.at(-1).type, "done");
});

test("a changed config identity cannot be overwritten", async (t) => {
  const state = await lab(t, () => ({ allowed: true }));
  state.session.config_inode = "0";
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => { calls += 1; throw new Error(); });
  const events = [];
  await createDemoRunner((event) => events.push(event)).start();
  assert.equal(calls, 0);
  assert.ok(events.some((event) => event.type === "error"));
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(state.root, "config.json"))), SAFE);
});

test("non-boolean permission is refused", async (t) => {
  await lab(t, () => ({ allowed: "true" }));
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => { calls += 1; throw new Error(); });
  const events = [];
  await createDemoRunner((event) => events.push(event)).start();
  assert.equal(calls, 0);
  assert.ok(events.some((event) => event.type === "blocked"));
});

test("an old running service is explained before any files are changed", async (t) => {
  const state = await lab(t, () => ({ allowed: true }));
  state.session.status = { monitoring: true };
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => { calls += 1; throw new Error(); });
  const events = [];
  await createDemoRunner((event) => events.push(event)).start();
  assert.equal(calls, 0);
  assert.ok(events.some((event) => event.type === "error" && event.text.includes("Reinicia")));
  assert.ok(!state.requests.some((request) => request.method === "demo.attach"));
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(state.root, "config.json"))), SAFE);
});
