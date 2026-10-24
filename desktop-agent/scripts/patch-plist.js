// Electron's dev binary ships without a screen-capture usage string, so macOS
// never prompts and desktopCapturer fails silently. Add one to its Info.plist.
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const plist = path.join(
  __dirname, "..", "node_modules", "electron", "dist", "Electron.app", "Contents", "Info.plist",
);

if (!fs.existsSync(plist)) process.exit(0);

const KEY = "NSScreenCaptureUsageDescription";
const VALUE = "Frame records your screen to show a live preview.";

try {
  const existing = execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print ${KEY}`, plist], {
    stdio: ["ignore", "pipe", "ignore"],
  }).toString().trim();
  if (existing) process.exit(0);
} catch {
  // key absent
}

execFileSync("/usr/libexec/PlistBuddy", ["-c", `Add ${KEY} string ${VALUE}`, plist]);
console.log("patched Info.plist with " + KEY);
