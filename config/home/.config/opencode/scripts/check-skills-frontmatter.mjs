#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import { parseDocument } from "yaml";

const skillRoot = path.resolve(process.argv[2] || path.join(process.env.HOME, ".config", "opencode", "skills"));
const OFFICIAL_DESCRIPTION_MAX = 1024;
// OpenCode 1.18.11 injects every available name, description, and absolute
// location on each turn. The 2026-08 audit measured 17,978 description chars;
// these local budgets keep the optimized catalog reviewable without pretending
// they are upstream schema limits.
const LOCAL_DESCRIPTION_MAX = 500;
const LOCAL_DESCRIPTION_TOTAL_BUDGET = 14_000;
const ALLOWED_FIELDS = new Set(["name", "description", "license", "compatibility", "metadata"]);
const NAME_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function findSkills(directory) {
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...findSkills(entryPath));
    else if (entry.isFile() && entry.name === "SKILL.md") result.push(entryPath);
  }
  return result.sort();
}

function parseFrontmatter(filePath) {
  const text = fs.readFileSync(filePath, "utf8");
  const lines = text.split(/\r?\n/);
  if (lines[0] !== "---") throw new Error("frontmatter must begin on line 1");
  const closingOffset = lines.slice(1).findIndex((line) => line === "---");
  if (closingOffset < 0) throw new Error("closing frontmatter delimiter is missing");
  const yamlText = lines.slice(1, closingOffset + 1).join("\n");
  const document = parseDocument(yamlText, { prettyErrors: true, strict: true, uniqueKeys: true });
  if (document.errors.length > 0) throw new Error(document.errors.map((error) => error.message).join("; "));
  if (document.warnings.length > 0) throw new Error(document.warnings.map((warning) => warning.message).join("; "));
  const value = document.toJS({ maxAliasCount: 50 });
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("frontmatter root must be a mapping");
  return value;
}

const files = findSkills(skillRoot);
if (files.length === 0) {
  console.error(`FAIL  no SKILL.md found below ${skillRoot}`);
  process.exit(1);
}

const failures = [];
const seen = new Map();
const descriptions = [];
for (const filePath of files) {
  const relativePath = path.relative(skillRoot, filePath);
  try {
    const metadata = parseFrontmatter(filePath);
    const unknown = Object.keys(metadata).filter((key) => !ALLOWED_FIELDS.has(key));
    if (unknown.length > 0) throw new Error(`unsupported frontmatter fields: ${unknown.join(", ")}`);

    const { name, description, license, compatibility } = metadata;
    if (typeof name !== "string" || !NAME_PATTERN.test(name) || [...name].length > 64) {
      throw new Error("name must match ^[a-z0-9]+(-[a-z0-9]+)*$ and be at most 64 characters");
    }
    const directoryName = path.basename(path.dirname(filePath));
    if (name !== directoryName) throw new Error(`name ${name} does not match directory ${directoryName}`);
    if (seen.has(name)) throw new Error(`duplicate name; first defined by ${seen.get(name)}`);
    seen.set(name, relativePath);

    if (typeof description !== "string") throw new Error("description must be a string");
    if (description !== description.trim() || description.includes("\n")) {
      throw new Error("description must be one trimmed line");
    }
    const descriptionChars = [...description].length;
    if (descriptionChars < 1 || descriptionChars > OFFICIAL_DESCRIPTION_MAX) {
      throw new Error(`description must be 1-${OFFICIAL_DESCRIPTION_MAX} characters`);
    }
    if (descriptionChars > LOCAL_DESCRIPTION_MAX) {
      throw new Error(`description exceeds local ${LOCAL_DESCRIPTION_MAX}-character routing budget (${descriptionChars})`);
    }
    descriptions.push({ name, chars: descriptionChars, bytes: Buffer.byteLength(description) });

    for (const [key, value] of [["license", license], ["compatibility", compatibility]]) {
      if (value !== undefined && typeof value !== "string") throw new Error(`${key} must be a string when present`);
    }
    if (metadata.metadata !== undefined) {
      if (!metadata.metadata || typeof metadata.metadata !== "object" || Array.isArray(metadata.metadata)) {
        throw new Error("metadata must be a string-to-string mapping");
      }
      for (const [key, value] of Object.entries(metadata.metadata)) {
        if (typeof value !== "string") throw new Error(`metadata.${key} must be a string`);
      }
    }
  } catch (error) {
    failures.push(`${relativePath}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

const totalChars = descriptions.reduce((sum, item) => sum + item.chars, 0);
const totalBytes = descriptions.reduce((sum, item) => sum + item.bytes, 0);
if (totalChars > LOCAL_DESCRIPTION_TOTAL_BUDGET) {
  failures.push(`description total exceeds local ${LOCAL_DESCRIPTION_TOTAL_BUDGET}-character budget (${totalChars})`);
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL  ${failure}`);
  process.exit(1);
}

const sortedLengths = descriptions.map((item) => item.chars).sort((left, right) => left - right);
const median = sortedLengths.length % 2
  ? sortedLengths[(sortedLengths.length - 1) / 2]
  : (sortedLengths[sortedLengths.length / 2 - 1] + sortedLengths[sortedLengths.length / 2]) / 2;
const longest = descriptions.reduce((current, item) => item.chars > current.chars ? item : current, descriptions[0]);
console.log(
  `skill frontmatter: ${descriptions.length} entries; descriptions ${totalChars} chars/${totalBytes} bytes; ` +
  `avg ${(totalChars / descriptions.length).toFixed(1)}, median ${median}, max ${longest.chars} (${longest.name})`,
);
