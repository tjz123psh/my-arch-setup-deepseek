#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { parseDocument } from "yaml";

const defaultConfigRoot = fileURLToPath(new URL("..", import.meta.url));
const configRoot = path.resolve(process.argv[2] || process.env.OPENCODE_CONFIG_DIR || defaultConfigRoot);
const agentRoot = path.join(configRoot, "agents");
const requiredSubagents = new Set(["reviewer", "scout", "worker"]);
const readOnlyAgents = new Set(["reviewer", "scout"]);
const writeTools = ["edit", "write", "patch", "apply_patch"];
const externalTools = ["webfetch", "websearch", "context7_*", "gemini-assistant_*", "playwright_*", "penpot_*"];

function parseAgent(filePath) {
  const lines = fs.readFileSync(filePath, "utf8").split(/\r?\n/);
  if (lines[0] !== "---") throw new Error("frontmatter must begin on line 1");
  const closingOffset = lines.slice(1).findIndex((line) => line === "---");
  if (closingOffset < 0) throw new Error("closing frontmatter delimiter is missing");
  const document = parseDocument(lines.slice(1, closingOffset + 1).join("\n"), {
    prettyErrors: true,
    strict: true,
    uniqueKeys: true,
  });
  if (document.errors.length > 0) throw new Error(document.errors.map((error) => error.message).join("; "));
  if (document.warnings.length > 0) throw new Error(document.warnings.map((warning) => warning.message).join("; "));
  const metadata = document.toJS({ maxAliasCount: 50 });
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
    throw new Error("frontmatter root must be a mapping");
  }
  return metadata;
}

const failures = [];
const parsed = new Map();
let entries;
try {
  entries = fs.readdirSync(agentRoot, { withFileTypes: true });
} catch (error) {
  console.error(`FAIL  cannot read ${agentRoot}: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}

for (const entry of entries.filter((item) => item.isFile() && item.name.endsWith(".md")).sort((a, b) => a.name.localeCompare(b.name))) {
  const name = entry.name.slice(0, -3);
  try {
    parsed.set(name, parseAgent(path.join(agentRoot, entry.name)));
  } catch (error) {
    failures.push(`${entry.name}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

for (const name of requiredSubagents) {
  const metadata = parsed.get(name);
  if (!metadata) {
    failures.push(`${name}.md: required subagent is missing or invalid`);
  } else if (metadata.mode !== "subagent") {
    failures.push(`${name}.md: mode must be subagent`);
  }
}

for (const [name, metadata] of parsed) {
  if (metadata.mode !== "subagent") continue;
  if (Object.hasOwn(metadata, "model")) {
    failures.push(`${name}.md: subagents must omit model so they inherit the invoking primary model`);
  }
  if (metadata.permission?.task !== "deny") {
    failures.push(`${name}.md: permission.task must be deny to prevent nested delegation`);
  }
}

for (const name of requiredSubagents) {
  const permission = parsed.get(name)?.permission;
  if (!permission) continue;
  for (const tool of externalTools) {
    if (permission[tool] !== "deny") failures.push(`${name}.md: permission.${tool} must be deny`);
  }
}

for (const name of readOnlyAgents) {
  const permission = parsed.get(name)?.permission;
  if (!permission) continue;
  for (const tool of writeTools) {
    if (permission[tool] !== "deny") failures.push(`${name}.md: permission.${tool} must be deny`);
  }
}

const workerPermission = parsed.get("worker")?.permission;
if (workerPermission) {
  for (const tool of writeTools) {
    if (workerPermission[tool] !== "allow") failures.push(`worker.md: permission.${tool} must be allow`);
  }
  const bash = workerPermission.bash;
  if (!bash || typeof bash !== "object" || Array.isArray(bash)) {
    failures.push("worker.md: permission.bash must be a mapping that denies every pattern");
  } else {
    if (bash["*"] !== "deny") failures.push('worker.md: permission.bash."*" must be deny');
    for (const [pattern, action] of Object.entries(bash)) {
      if (action !== "deny") failures.push(`worker.md: permission.bash.${pattern} must be deny`);
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL  ${failure}`);
  process.exit(1);
}

console.log(`agent policy: ${parsed.size} agents; model inheritance and bounded subagent permissions: ok`);
