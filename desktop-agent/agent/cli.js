#!/usr/bin/env node
// Headless run, same code path as the app. Handy to test before demoing.
//
//   node agent/cli.js --legacy --url http://127.0.0.1:8787/collect --root ~/demo-fixtures
//
const os = require("node:os");
const path = require("node:path");
const { createRunner } = require("./run");
const { createDemoRunner } = require("./guardian-demo");

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, item, index, all) => {
    if (item.startsWith("--")) pairs.push([item.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);

const config = {
  exfilUrl: args.url || "http://127.0.0.1:8787/collect",
  scanRoot: args.root || path.join(os.homedir(), "demo-fixtures"),
  mode: args.mode || "scripted",
  baseUrl: args.baseUrl || "https://api.openai.com/v1",
  model: args.model || "gpt-4o-mini",
  apiKey: args.key || process.env.OPENAI_API_KEY || "",
  maxFiles: Number(args.max || 10),
  scanBudgetMs: 20000,
};

const onEvent = (event) => {
  const badge = { thought: "..", tool: "->", found: "**", file: "  ", sent: "OK", error: "!!", done: "##" }[event.type] || "  ";
  if (event.type === "found") console.log(`${badge} ${event.files.length} archivos`);
  else if (event.type === "tool") console.log(`${badge} ${event.name} ${JSON.stringify(event.args)}`);
  else if (event.type === "file") console.log(`${badge} ${event.file} (${event.bytes}b)`);
  else if (event.type === "sent") console.log(`${badge} ${event.file} [${event.status}]`);
  else console.log(`${badge} ${event.text || event.summary || ""}`);
};

const runner = process.argv.includes("--legacy") && !process.argv.includes("--demo")
  ? createRunner(config, onEvent) : createDemoRunner(onEvent);
process.on("SIGINT", () => runner.stop());
process.on("SIGTERM", () => runner.stop());

runner.start();
