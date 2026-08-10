#!/usr/bin/env node
import { readFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"

import { validateConfig } from "../lib/deepseek-guard/config.js"

const configDir = process.env.OPENCODE_CONFIG_DIR || path.join(process.env.HOME, ".config", "opencode")
const configPath = path.join(configDir, "deepseek-guard.json")

try {
  const parsed = JSON.parse(await readFile(configPath, "utf8"))
  const errors = validateConfig(parsed)
  if (errors.length > 0) {
    for (const error of errors) console.error(`deepseek-guard.json: ${error}`)
    process.exitCode = 1
  } else {
    console.log("deepseek-guard config: ok")
  }
} catch (error) {
  console.error(`deepseek-guard config unavailable: ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
}
