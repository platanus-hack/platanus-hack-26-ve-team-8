const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("ghost", {
  init: () => ipcRenderer.invoke("app:init"),
  saveConfig: (patch) => ipcRenderer.invoke("config:save", patch),
  toggleCapture: (on) => ipcRenderer.invoke("capture:toggle", on),
  start: () => ipcRenderer.invoke("agent:start"),
  stop: () => ipcRenderer.invoke("agent:stop"),
  open: (p) => ipcRenderer.invoke("shell:open", p),
  requestPermission: () => ipcRenderer.invoke("perm:request"),
  onShot: (cb) => ipcRenderer.on("shot", (_e, payload) => cb(payload)),
  onEvent: (cb) => ipcRenderer.on("agent:event", (_e, payload) => cb(payload)),
});
