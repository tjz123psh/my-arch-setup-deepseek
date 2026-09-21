#!/usr/bin/env node
/**
 * 校验 ~/.dsh/settings.yaml 中 llm-pi-ai 段是否为运行中的 dsh（含 dev 源码版）
 * 所接受。跑的是 deepseek-harness 源码里的 Config schema + serviceability
 * 检查 —— 与运行服务器同源，设置被拒时能直接定位到具体路由/模型/字段。
 *
 * 用法（本机）:
 *   node --experimental-strip-types check-settings.mjs          # 校验全部 providers
 *   node --experimental-strip-types check-settings.mjs agentrouter qwen   # 只校验指定路由
 *
 * 依赖: Node >= 22.6（strip-types）；deepseek-harness 源码在 /home/pang/Projects/deepseek-harness
 */
import { readFileSync } from "node:fs";
import { parseDocument } from "/home/pang/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/yaml/dist/index.js";
import { assertServiceable, Config } from "/home/pang/Projects/deepseek-harness/packages/llm/llm-pi-ai/src/config.ts";

const doc = parseDocument(readFileSync(`${process.env.HOME}/.dsh/settings.yaml`, "utf8"), {
  prettyErrors: true,
});
if (doc.errors.length > 0) {
  console.error(
    "YAML 错误:",
    doc.errors.map((e) => e.message).join("; "),
  );
  process.exit(1);
}
const section = doc.toJS()["llm-pi-ai"] ?? {};
const targets = process.argv.slice(2);
const providers = targets.length
  ? Object.fromEntries(targets.map((name) => [name, section.providers?.[name]]))
  : section.providers ?? {};

const checked = Config["~standard"].validate({ providers });
if (checked.issues) {
  console.error("schema REJECTED:");
  for (const issue of checked.issues) console.error("  -", issue.message ?? issue);
  process.exit(1);
}
try {
  assertServiceable(checked.value);
} catch (error) {
  console.error("serviceability REJECTED:", error.message);
  process.exit(1);
}
console.log(
  `PASS: providers [${Object.keys(providers).join(", ") || "(none)"}] 通过运行服务器同源校验`,
);