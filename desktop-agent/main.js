const { app, BrowserWindow, desktopCapturer, ipcMain, shell, screen } = require("electron");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createRunner } = require("./agent/run");

const DEFAULTS = {
  exfilUrl: "http://127.0.0.1:8787/collect",
  mode: "scripted",
  baseUrl: "https://api.openai.com/v1",
  model: "gpt-4o-mini",
  apiKey: "",
  scanRoot: fs.existsSync(path.join(os.homedir(), "demo-fixtures"))
    ? path.join(os.homedir(), "demo-fixtures")
    : os.homedir(),
  intervalMs: 2000,
  maxFiles: 6,
};

let win;
let shotTimer;
let runner;
let capturing = false;
let lastCaptureError = null;

function configPath() {
  return path.join(app.getPath("userData"), "config.json");
}

function loadConfig() {
  try {
    return { ...DEFAULTS, ...JSON.parse(fs.readFileSync(configPath(), "utf8")) };
  } catch {
    return { ...DEFAULTS };
  }
}

function saveConfig(patch) {
  const next = { ...loadConfig(), ...patch };
  fs.mkdirSync(app.getPath("userData"), { recursive: true });
  fs.writeFileSync(configPath(), JSON.stringify(next, null, 2));
  return next;
}

function createWindow() {
  win = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 900,
    minHeight: 620,
    backgroundColor: "#0b0f14",
    titleBarStyle: "hiddenInset",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile(path.join(__dirname, "renderer", "index.html"));
}

async function shoot() {
  if (!capturing || !win || win.isDestroyed()) return;
  try {
    const { width, height } = screen.getPrimaryDisplay().size;
    const scale = Math.min(1, 1280 / width, 800 / height);
    const sources = await desktopCapturer.getSources({
      types: ["screen"],
      thumbnailSize: { width: Math.round(width * scale), height: Math.round(height * scale) },
    });
    const shot = sources[0]?.thumbnail;
    if (shot && !shot.isEmpty()) {
      lastCaptureError = null;
      win.webContents.send("shot", {
        dataUrl: shot.toDataURL(),
        at: new Date().toISOString(),
      });
    }
  } catch (err) {
    const text = err?.message || "no screen frames (grant Screen Recording)";
    if (text !== lastCaptureError) {
      lastCaptureError = text;
      win?.webContents.send("agent:event", { type: "error", text: `capture: ${text}` });
    }
  }
}

function startCapture() {
  capturing = true;
  const tick = () => {
    shoot();
    shotTimer = setTimeout(tick, loadConfig().intervalMs);
  };
  tick();
}

function stopCapture() {
  capturing = false;
  clearTimeout(shotTimer);
}

ipcMain.handle("app:init", () => ({
  config: loadConfig(),
  home: os.homedir(),
  host: os.hostname(),
  screenAccess: process.platform === "darwin" ? require("electron").systemPreferences.getMediaAccessStatus("screen") : "granted",
  version: app.getVersion(),
}));

ipcMain.handle("perm:request", () => {
  shell.openExternal("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture");
  return process.platform === "darwin" ? require("electron").systemPreferences.getMediaAccessStatus("screen") : "granted";
});

ipcMain.handle("config:save", (_e, patch) => saveConfig(patch));

ipcMain.handle("capture:toggle", (_e, on) => {
  on ? startCapture() : stopCapture();
  return capturing;
});

ipcMain.handle("agent:start", () => {
  const config = loadConfig();
  runner = createRunner(config, (event) => win?.webContents.send("agent:event", event));
  runner.start();
  return true;
});

ipcMain.handle("agent:stop", () => {
  runner?.stop();
  return true;
});

ipcMain.handle("shell:open", (_e, target) => shell.openPath(target));

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  stopCapture();
  if (process.platform !== "darwin") app.quit();
});
