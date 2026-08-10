#!/usr/bin/env node

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) {
  throw new Error("GEMINI_API_KEY must be set for the Gemini MCP smoke test");
}

// 解析被测服务器路径：优先显式覆盖，其次同目录（本文件与 gemini-assistant.mjs 同级），
// 最后按 OPENCODE_CONFIG_DIR 回退。与 check-config.sh 的 OPENCODE_CONFIG_DIR 约定
// 保持一致，避免非默认 HOME 或容器化 CI 下解析失败。
const configDir = process.env.OPENCODE_CONFIG_DIR || join(homedir(), ".config", "opencode");
const candidates = [
  process.env.GEMINI_ASSISTANT_SERVER,
  join(fileURLToPath(new URL(".", import.meta.url)), "gemini-assistant.mjs"),
  join(configDir, "mcp", "gemini-assistant.mjs"),
].filter(Boolean);
const serverPath = candidates.find((candidate) => existsSync(candidate));
if (!serverPath) {
  throw new Error(`gemini-assistant.mjs not found. Looked in:\n${candidates.join("\n")}`);
}
const args = process.argv.slice(2);
const testBrainstorm = args.includes("--brainstorm");
const imageSource = args.find((arg) => arg !== "--brainstorm");
const transport = new StdioClientTransport({
  command: "node",
  args: [serverPath],
  env: {
    ...process.env,
    GEMINI_API_KEY: apiKey,
    GEMINI_ASSISTANT_MODEL: process.env.GEMINI_ASSISTANT_MODEL || "gemini-3.5-flash-lite",
    GEMINI_ASSISTANT_FALLBACK_MODEL: process.env.GEMINI_ASSISTANT_FALLBACK_MODEL || "gemini-3.5-flash",
  },
});
const client = new Client({ name: "gemini-assistant-smoke-test", version: "1.0.0" });

try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  for (const toolName of ["analyze_images", "analyze_recent_screenshots", "analyze_videos", "analyze_recent_videos", "brainstorm"]) {
    if (!tools.some((tool) => tool.name === toolName)) {
      throw new Error(`${toolName} tool was not registered`);
    }
  }
  console.log(`MCP handshake passed: ${tools.map((tool) => tool.name).join(", ")}`);

  if (imageSource) {
    const result = await client.callTool({
      name: "analyze_images",
      arguments: {
        sources: [imageSource],
        prompt: "用一句中文说明图片中的主体和主要颜色。不要猜测看不清的内容。",
      },
    });
    const text = result.content?.find((item) => item.type === "text")?.text;
    if (result.isError || !text) throw new Error(text || "Gemini returned no text");
    console.log(`Gemini response: ${text}`);
  }

  if (testBrainstorm) {
    const result = await client.callTool({
      name: "brainstorm",
      arguments: {
        problem: "为一个本地开发工具选择最小可行的错误报告机制",
        mode: "diverge",
        constraints: ["默认离线", "不得上传源代码", "一周内可实现"],
        ideaCount: 3,
      },
    });
    const text = result.content?.find((item) => item.type === "text")?.text;
    if (result.isError || !text) throw new Error(text || "Gemini returned no brainstorm text");
    console.log(`Brainstorm response: ${text}`);
  }
} finally {
  await client.close();
}
