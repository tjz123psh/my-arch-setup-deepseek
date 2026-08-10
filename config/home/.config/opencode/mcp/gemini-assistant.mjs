#!/usr/bin/env node

import { constants, createReadStream, createWriteStream } from "node:fs";
import { lstat, mkdtemp, open, readdir, rm } from "node:fs/promises";
import { basename, extname, join, resolve } from "node:path";
import { pipeline } from "node:stream/promises";
import { Readable, Transform } from "node:stream";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

import { GoogleGenAI } from "@google/genai";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const PRIMARY_MODEL = process.env.GEMINI_ASSISTANT_MODEL || "gemini-3.5-flash-lite";
const FALLBACK_MODEL = process.env.GEMINI_ASSISTANT_FALLBACK_MODEL || "gemini-3.5-flash";
const MAX_SOURCE_COUNT = 4;
const MAX_SOURCE_BYTES = 12 * 1024 * 1024;
const MAX_TOTAL_BYTES = 24 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 20_000;
const VIDEO_FETCH_TIMEOUT_MS = 120_000;
const VIDEO_PROCESS_TIMEOUT_MS = 180_000;
const TOOL_TIMEOUT_MS = 270_000;
const CLEANUP_TIMEOUT_MS = 20_000;
const VIDEO_OFFSET_PATTERN = /^(\d+(?:\.\d+)?)s$/;
const DEFAULT_SCREENSHOT_DIR = "/home/pang/Pictures/Screenshots";
const DEFAULT_VIDEO_DIR = "/home/pang/Videos";
const MAX_VIDEO_SOURCE_COUNT = 2;
const MAX_VIDEO_SOURCE_BYTES = 512 * 1024 * 1024;
const MAX_VIDEO_TOTAL_BYTES = 1 * 1024 * 1024 * 1024;

const MIME_BY_EXTENSION = new Map([
  [".avif", "image/avif"],
  [".bmp", "image/bmp"],
  [".gif", "image/gif"],
  [".heic", "image/heic"],
  [".heif", "image/heif"],
  [".jpeg", "image/jpeg"],
  [".jpg", "image/jpeg"],
  [".png", "image/png"],
  [".webp", "image/webp"],
  [".tif", "image/tiff"],
  [".tiff", "image/tiff"],
]);

const VIDEO_MIME_BY_EXTENSION = new Map([
  [".3gp", "video/3gpp"],
  [".avi", "video/x-msvideo"],
  [".flv", "video/x-flv"],
  [".m4v", "video/x-m4v"],
  [".mkv", "video/x-matroska"],
  [".mov", "video/quicktime"],
  [".mp4", "video/mp4"],
  [".mpeg", "video/mpeg"],
  [".mpg", "video/mpeg"],
  [".webm", "video/webm"],
]);

function formatMediaPrompt(sources, prompt) {
  const mediaOrder = sources.map((_, index) => `- 媒体 ${index + 1}`).join("\n");
  return [
    "以下媒体已按顺序附加，请使用媒体编号引用它们：",
    mediaOrder,
    "只依据媒体实际可见或可听内容回答；不要根据本地路径、文件名或用户文字描述猜测未验证事实。",
    "",
    prompt,
  ].join("\n");
}

function displaySource(source) {
  if (!/^https?:\/\//i.test(source)) {
    if (!source.startsWith("file://")) return source;
    try {
      return fileURLToPath(source);
    } catch {
      return "[本地 file URL]";
    }
  }

  // Do not echo credentials or signed query parameters in the local report.
  try {
    const url = new URL(source);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return "[远程媒体 URL]";
  }
}

function formatSelectionReport(sources, warnings = []) {
  const lines = [
    "已选择媒体来源（按工具请求顺序）：",
    ...sources.map((source, index) => `- 媒体 ${index + 1}: ${displaySource(source)}`),
  ];
  if (warnings.length > 0) {
    lines.push("", ...warnings.map((warning) => `[扫描警告] ${warning}`));
  }
  return lines.join("\n");
}

function sanitizeErrorText(input) {
  let text = typeof input === "string" ? input : String(input ?? "unknown error");
  text = text.replace(/https?:\/\/[^\s<>"']+/gi, (value) => displaySource(value));
  text = text.replace(
    /((?:authorization|x-goog-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)\s*[:=]\s*)(?:bearer\s+|basic\s+)?[^\s,;}]+/gi,
    "$1[REDACTED]",
  );
  text = text.replace(/\b(?:sk|gh[pousr]|AIza)[-_A-Za-z0-9]{12,}\b/g, "[REDACTED CREDENTIAL]");
  return text;
}

function errorMessage(error) {
  if (error?.name === "TimeoutError") return "操作超时";
  if (error?.name === "AbortError") return "操作已取消";
  return sanitizeErrorText(error instanceof Error ? error.message : String(error));
}

function formatToolError(prefix, error, sources = [], warnings = []) {
  const selection = sources.length > 0 ? `${formatSelectionReport(sources, warnings)}\n\n` : "";
  return `${selection}${prefix}: ${errorMessage(error)}`;
}

function operationSignal(signal, timeoutMs) {
  const timeoutSignal = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;
}

function throwIfAborted(signal) {
  signal?.throwIfAborted();
}

function parseVideoOffset(value, fieldName) {
  if (value === undefined) return undefined;
  if (typeof value !== "string") {
    throw new Error(`${fieldName} 必须使用类似 10s 或 2.5s 的格式`);
  }
  const match = VIDEO_OFFSET_PATTERN.exec(value);
  if (!match || !Number.isFinite(Number(match[1]))) {
    throw new Error(`${fieldName} 必须使用类似 10s 或 2.5s 的格式`);
  }
  return Number(match[1]);
}

function validateVideoMetadata(input = {}) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("视频 metadata 必须是对象");
  }
  const { fps, startOffset, endOffset } = input;
  const metadata = {};
  if (fps !== undefined) {
    if (typeof fps !== "number" || !Number.isFinite(fps) || fps <= 0 || fps > 24) {
      throw new Error("fps 必须大于 0 且不超过 24");
    }
    metadata.fps = fps;
  }

  const startSeconds = parseVideoOffset(startOffset, "startOffset");
  const endSeconds = parseVideoOffset(endOffset, "endOffset");
  if (startSeconds !== undefined && endSeconds !== undefined && startSeconds >= endSeconds) {
    throw new Error("startOffset 必须小于 endOffset");
  }
  if (startOffset !== undefined) metadata.startOffset = startOffset;
  if (endOffset !== undefined) metadata.endOffset = endOffset;
  return metadata;
}

function expandHome(path) {
  if (path === "~") return process.env.HOME;
  if (path.startsWith("~/")) return resolve(process.env.HOME, path.slice(2));
  return resolve(path);
}

function localPathFromSource(source) {
  return source.startsWith("file://") ? fileURLToPath(source) : expandHome(source);
}

function extensionFromSource(source) {
  try {
    return extname(new URL(source).pathname).toLowerCase();
  } catch {
    return extname(source).toLowerCase();
  }
}

function videoMimeFromSource(source, responseMime) {
  const cleanResponseMime = responseMime?.split(";", 1)[0]?.trim().toLowerCase();
  if (cleanResponseMime?.startsWith("video/")) return cleanResponseMime;
  return VIDEO_MIME_BY_EXTENSION.get(extensionFromSource(source));
}

function mimeFromBytes(buffer, source, responseMime) {
  if (buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    return "image/png";
  }
  if (buffer.subarray(0, 3).equals(Buffer.from([255, 216, 255]))) return "image/jpeg";
  if (buffer.subarray(0, 6).toString("ascii") === "GIF87a" || buffer.subarray(0, 6).toString("ascii") === "GIF89a") {
    return "image/gif";
  }
  if (buffer.subarray(0, 4).toString("ascii") === "RIFF" && buffer.subarray(8, 12).toString("ascii") === "WEBP") {
    return "image/webp";
  }

  const cleanResponseMime = responseMime?.split(";", 1)[0]?.trim().toLowerCase();
  if (cleanResponseMime?.startsWith("image/")) return cleanResponseMime;
  return MIME_BY_EXTENSION.get(extname(source).toLowerCase());
}

async function readRemoteSource(source, budget, signal) {
  const sourceLabel = displaySource(source);
  const response = await fetch(source, {
    headers: { "user-agent": "opencode-gemini-assistant-mcp/1.0" },
    signal: operationSignal(signal, FETCH_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`下载失败 (${response.status} ${response.statusText}): ${sourceLabel}`);

  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_SOURCE_BYTES) {
    throw new Error(`远程图片超过单文件 12 MiB 限制: ${sourceLabel}`);
  }

  if (!response.body) throw new Error(`远程图片没有响应内容: ${sourceLabel}`);
  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;

  try {
    while (true) {
      throwIfAborted(signal);
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_SOURCE_BYTES) {
        await reader.cancel();
        throw new Error(`远程图片超过单文件 12 MiB 限制: ${sourceLabel}`);
      }
      budget.used += value.byteLength;
      if (budget.used > MAX_TOTAL_BYTES) {
        await reader.cancel();
        throw new Error("图片总大小超过 24 MiB 限制");
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }

  return { buffer: Buffer.concat(chunks, totalBytes), responseMime: response.headers.get("content-type") };
}

async function readLocalImageSource(source, budget, signal) {
  const sourceLabel = displaySource(source);
  const sourcePath = localPathFromSource(source);
  let handle;
  try {
    handle = await open(sourcePath, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  } catch (error) {
    if (error?.code === "ELOOP") throw new Error(`图片来源不能是符号链接: ${sourceLabel}`);
    throw error;
  }

  try {
    throwIfAborted(signal);
    const metadata = await handle.stat();
    if (!metadata.isFile()) throw new Error(`图片来源不是普通文件: ${sourceLabel}`);
    if (metadata.size > MAX_SOURCE_BYTES) throw new Error(`图片超过单文件 12 MiB 限制: ${sourceLabel}`);
    if (budget.used + metadata.size > MAX_TOTAL_BYTES) throw new Error("图片总大小超过 24 MiB 限制");
    budget.used += metadata.size;
    return await handle.readFile({ signal });
  } finally {
    await handle.close();
  }
}

async function loadSource(source, budget, signal) {
  let buffer;
  let responseMime;

  if (/^https?:\/\//i.test(source)) {
    ({ buffer, responseMime } = await readRemoteSource(source, budget, signal));
  } else {
    buffer = await readLocalImageSource(source, budget, signal);
  }

  const mimeType = mimeFromBytes(buffer, source, responseMime);
  if (!mimeType) throw new Error(`无法确认图片格式: ${displaySource(source)}`);

  return {
    inlineData: {
      data: buffer.toString("base64"),
      mimeType,
    },
    size: buffer.length,
  };
}

const apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
if (!apiKey) {
  console.error("GEMINI_API_KEY or GOOGLE_API_KEY is required");
  process.exit(1);
}

const ai = new GoogleGenAI({
  apiKey,
  // Keep SDK requests longer than normal image calls so video upload/generation
  // is not cut off before the MCP server-level timeout.
  httpOptions: { timeout: 180_000 },
});
const server = new McpServer({ name: "gemini-assistant", version: "1.5.0" });

function isQuotaError(error) {
  if (!error || typeof error !== "object") return false;
  if (error.status === 429 || error.statusCode === 429) return true;

  const message = error instanceof Error ? error.message : String(error);
  return /RESOURCE_EXHAUSTED|quota[^\n]*exceed|rate[ -]?limit/i.test(message);
}

async function generateWithFallback(contents, config = {}, signal) {
  const request = {
    contents,
    config: {
      temperature: 0.2,
      maxOutputTokens: 16_384,
      ...config,
      abortSignal: signal,
    },
  };

  try {
    const response = await ai.models.generateContent({ model: PRIMARY_MODEL, ...request });
    return { response, model: PRIMARY_MODEL, usedFallback: false };
  } catch (error) {
    throwIfAborted(signal);
    if (!isQuotaError(error) || !FALLBACK_MODEL || FALLBACK_MODEL === PRIMARY_MODEL) throw error;

    const response = await ai.models.generateContent({ model: FALLBACK_MODEL, ...request });
    return { response, model: FALLBACK_MODEL, usedFallback: true };
  }
}

async function runImageAnalysis(sources, prompt, signal) {
  // Keep loading sequential so the shared byte budget is deterministic and a
  // large batch cannot create an avoidable memory spike.
  const budget = { used: 0 };
  const loaded = [];
  for (const source of sources) loaded.push(await loadSource(source, budget, signal));

  const { response, model, usedFallback } = await generateWithFallback([
    {
      role: "user",
      parts: [
        { text: prompt },
        ...loaded.map(({ inlineData }) => ({ inlineData })),
      ],
    },
  ], {}, signal);

  const result = response.text?.trim();
  if (!result) throw new Error("Gemini 返回了空结果");
  return usedFallback ? `[主模型额度不足，已回退至 ${model}]\n\n${result}` : result;
}

async function listRecentMediaSources(directory, mimeMap, kind, limit, signal) {
  const resolvedDirectory = expandHome(directory);
  let entries;
  try {
    entries = await readdir(resolvedDirectory, { withFileTypes: true });
  } catch (error) {
    const code = error && typeof error === "object" ? error.code : undefined;
    if (code === "ENOENT") throw new Error(`${kind}目录不存在: ${resolvedDirectory}`);
    if (code === "EACCES" || code === "EPERM") {
      throw new Error(`${kind}目录不可访问: ${resolvedDirectory}（错误码 ${code}）`);
    }
    throw new Error(`${kind}目录查询失败: ${resolvedDirectory}（错误码 ${code || "unknown"}）`);
  }

  if (entries.length === 0) {
    throw new Error(`${kind}目录为空: ${resolvedDirectory}`);
  }

  const candidates = [];
  let supportedCount = 0;
  const disappeared = [];
  const changedType = [];
  const statFailures = [];
  for (const entry of entries) {
    throwIfAborted(signal);
    if (!entry.isFile()) continue;
    const source = join(resolvedDirectory, entry.name);
    const mimeType = mimeMap.get(extname(entry.name).toLowerCase());
    if (!mimeType) continue;
    supportedCount += 1;
    try {
      const metadata = await lstat(source);
      if (metadata.isFile()) {
        candidates.push({ source, mtimeMs: metadata.mtimeMs });
      } else {
        changedType.push(entry.name);
      }
    } catch (error) {
      const code = error && typeof error === "object" ? error.code : undefined;
      if (code === "ENOENT" || code === "ESTALE") {
        disappeared.push(entry.name);
      } else {
        statFailures.push(`${entry.name}（错误码 ${code || "unknown"}）`);
      }
    }
  }

  if (statFailures.length > 0) {
    throw new Error(`${kind}候选文件状态查询失败: ${statFailures.join(", ")}`);
  }
  if (supportedCount === 0) {
    throw new Error(`${kind}目录中没有支持的媒体文件: ${resolvedDirectory}`);
  }
  if (candidates.length === 0) {
    const invalidated = [...disappeared, ...changedType];
    if (invalidated.length === supportedCount) {
      throw new Error(`${kind}候选文件在扫描期间消失或不再是普通文件: ${resolvedDirectory}`);
    }
    throw new Error(`${kind}目录中没有可分析的候选文件: ${resolvedDirectory}`);
  }

  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  const selected = candidates.slice(0, limit).map(({ source }) => source);
  const warnings = [];
  if (disappeared.length > 0 || changedType.length > 0) {
    const invalidated = [...disappeared, ...changedType];
    warnings.push(`${kind}候选文件在扫描期间消失或变为非普通文件，已跳过: ${invalidated.join(", ")}`);
  }
  return { sources: selected, warnings };
}

function videoSizeLimiter(sourceLabel, budget) {
  let sourceBytes = 0;
  return new Transform({
    transform(chunk, _encoding, callback) {
      sourceBytes += chunk.length;
      budget.used += chunk.length;
      if (sourceBytes > MAX_VIDEO_SOURCE_BYTES) {
        callback(new Error(`视频超过单文件 ${MAX_VIDEO_SOURCE_BYTES / 1024 / 1024} MiB 限制: ${sourceLabel}`));
      } else if (budget.used > MAX_VIDEO_TOTAL_BYTES) {
        callback(new Error(`视频总大小超过 ${MAX_VIDEO_TOTAL_BYTES / 1024 / 1024} MiB 限制`));
      } else {
        callback(null, chunk);
      }
    },
  });
}

async function downloadRemoteVideo(source, tempDir, index, budget, signal) {
  const sourceLabel = displaySource(source);
  const response = await fetch(source, {
    headers: { "user-agent": "opencode-gemini-assistant-mcp/1.5" },
    signal: operationSignal(signal, VIDEO_FETCH_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`下载视频失败 (${response.status} ${response.statusText}): ${sourceLabel}`);
  if (!response.body) throw new Error(`远程视频没有响应内容: ${sourceLabel}`);

  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_VIDEO_SOURCE_BYTES) {
    throw new Error(`远程视频超过单文件 ${MAX_VIDEO_SOURCE_BYTES / 1024 / 1024} MiB 限制: ${sourceLabel}`);
  }
  if (Number.isFinite(declaredLength) && budget.used + declaredLength > MAX_VIDEO_TOTAL_BYTES) {
    throw new Error(`视频总大小超过 ${MAX_VIDEO_TOTAL_BYTES / 1024 / 1024} MiB 限制`);
  }

  const mimeType = videoMimeFromSource(source, response.headers.get("content-type"));
  if (!mimeType) throw new Error(`无法确认远程视频格式: ${sourceLabel}`);
  const extension = extensionFromSource(source);
  const target = join(tempDir, `remote-video-${index}${extension}`);
  await pipeline(
    Readable.fromWeb(response.body),
    videoSizeLimiter(sourceLabel, budget),
    createWriteStream(target, { flags: "wx", mode: 0o600 }),
    { signal },
  );
  return { path: target, mimeType, displayName: `video-${index + 1}${extension}` };
}

async function prepareVideoSource(source, index, tempDir, budget, signal) {
  if (/^https?:\/\//i.test(source)) return downloadRemoteVideo(source, tempDir, index, budget, signal);

  const sourcePath = localPathFromSource(source);
  const sourceLabel = displaySource(source);
  const metadata = await lstat(sourcePath);
  if (metadata.isSymbolicLink()) throw new Error(`视频来源不能是符号链接: ${sourceLabel}`);
  if (!metadata.isFile()) throw new Error(`视频来源不是普通文件: ${sourceLabel}`);
  if (metadata.size > MAX_VIDEO_SOURCE_BYTES) {
    throw new Error(`视频超过单文件 ${MAX_VIDEO_SOURCE_BYTES / 1024 / 1024} MiB 限制: ${sourceLabel}`);
  }
  if (budget.used + metadata.size > MAX_VIDEO_TOTAL_BYTES) {
    throw new Error(`视频总大小超过 ${MAX_VIDEO_TOTAL_BYTES / 1024 / 1024} MiB 限制`);
  }

  const mimeType = videoMimeFromSource(source);
  if (!mimeType) throw new Error(`无法确认视频格式（请使用支持的视频扩展名）: ${sourceLabel}`);
  const extension = extensionFromSource(source);
  const target = join(tempDir, `local-video-${index}${extension}`);
  await pipeline(
    createReadStream(sourcePath, { flags: constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) }),
    videoSizeLimiter(sourceLabel, budget),
    createWriteStream(target, { flags: "wx", mode: 0o600 }),
    { signal },
  );
  return { path: target, mimeType, displayName: `video-${index + 1}${extension}` };
}

async function waitForUploadedFile(file, signal, client = ai) {
  if (!file?.name || !file.uri) throw new Error("Gemini 视频上传未返回可用的文件引用");
  let current = file;
  const deadline = Date.now() + VIDEO_PROCESS_TIMEOUT_MS;
  while (current.state === "PROCESSING" || current.state === "STATE_UNSPECIFIED" || !current.state) {
    throwIfAborted(signal);
    if (Date.now() >= deadline) throw new Error(`Gemini 视频处理超时: ${current.name}`);
    await delay(2_000, undefined, { signal });
    current = await client.files.get({ name: current.name, config: { abortSignal: signal } });
  }
  if (current.state === "FAILED") {
    throw new Error(`Gemini 视频处理失败: ${sanitizeErrorText(current.error?.message || current.name)}`);
  }
  if (current.state !== "ACTIVE") throw new Error(`Gemini 视频处于不可用状态: ${current.state}`);
  return current;
}

async function analyzeVideos(sources, prompt, videoMetadataInput = {}, signal) {
  const videoMetadata = validateVideoMetadata(videoMetadataInput);
  const tempDir = await mkdtemp("/tmp/gemini-assistant-video-");
  const budget = { used: 0 };
  const uploaded = [];
  let result;
  let primaryError;
  const cleanupErrors = [];

  try {
    for (let index = 0; index < sources.length; index += 1) {
      throwIfAborted(signal);
      const prepared = await prepareVideoSource(sources[index], index, tempDir, budget, signal);
      const file = await ai.files.upload({
        file: prepared.path,
        config: { mimeType: prepared.mimeType, displayName: prepared.displayName, abortSignal: signal },
      });
      const uploadRecord = { file, mimeType: prepared.mimeType };
      uploaded.push(uploadRecord);
      uploadRecord.file = await waitForUploadedFile(file, signal);
    }

    const parts = [
      { text: prompt },
      ...uploaded.map(({ file, mimeType }) => {
        const part = { fileData: { fileUri: file.uri, mimeType } };
        if (Object.keys(videoMetadata).length > 0) part.videoMetadata = videoMetadata;
        return part;
      }),
    ];
    const { response, model, usedFallback } = await generateWithFallback(
      [{ role: "user", parts }],
      { maxOutputTokens: 8_192 },
      signal,
    );
    result = response.text?.trim();
    if (!result) throw new Error("Gemini 返回了空结果");
    if (usedFallback) result = `[主模型额度不足，已回退至 ${model}]\n\n${result}`;
  } catch (error) {
    primaryError = error;
  } finally {
    const remoteCleanup = await Promise.allSettled(
      uploaded.map(({ file }) => ai.files.delete({
        name: file.name,
        config: { abortSignal: AbortSignal.timeout(CLEANUP_TIMEOUT_MS) },
      })),
    );
    for (const cleanup of remoteCleanup) {
      if (cleanup.status === "rejected") cleanupErrors.push(errorMessage(cleanup.reason));
    }
    try {
      await rm(tempDir, { recursive: true, force: true });
    } catch (error) {
      cleanupErrors.push(errorMessage(error));
    }
  }

  const cleanupWarning = cleanupErrors.length > 0
    ? `本次 Gemini 临时视频的远端或本地清理未完全成功：${cleanupErrors.join("; ")}`
    : "";
  if (primaryError) {
    if (cleanupWarning) {
      throw new Error(`${errorMessage(primaryError)}\n\n[警告] ${cleanupWarning}`, { cause: primaryError });
    }
    throw primaryError;
  }
  if (cleanupWarning) result += `\n\n[警告] ${cleanupWarning}`;
  return result;
}

async function runImageTool(sources, prompt, warnings = [], signal) {
  const result = await runImageAnalysis(sources, formatMediaPrompt(sources, prompt), signal);
  return `${formatSelectionReport(sources, warnings)}\n\n${result}`;
}

async function runVideoTool(sources, prompt, videoMetadataInput, warnings = [], signal) {
  const videoMetadata = validateVideoMetadata(videoMetadataInput);
  const result = await analyzeVideos(sources, formatMediaPrompt(sources, prompt), videoMetadata, signal);
  return `${formatSelectionReport(sources, warnings)}\n\n${result}`;
}

server.registerTool(
  "analyze_images",
  {
    title: "Analyze images with Gemini",
    description:
      "Analyze one to four local images, screenshots, file:// URLs, or HTTP(S) image URLs with Gemini. Non-multimodal models must call this tool instead of guessing from a path, filename, OCR fragment, or text description. Use for visual layout, UI defects, diagrams, objects, and OCR with surrounding visual context. Do not repeat the same source in one turn unless the question or analysis scope changes.",
    inputSchema: {
      sources: z
        .array(z.string().min(1))
        .min(1)
        .max(MAX_SOURCE_COUNT)
        .describe("Absolute path, ~/path, file:// URL, or HTTP(S) URL for each image."),
      prompt: z
        .string()
        .min(1)
        .max(12_000)
        .default("Describe the important visible facts precisely. Quote relevant text and note uncertainty."),
    },
  },
  async ({ sources, prompt }, extra) => {
    const signal = operationSignal(extra?.signal, TOOL_TIMEOUT_MS);
    try {
      return { content: [{ type: "text", text: await runImageTool(sources, prompt, [], signal) }] };
    } catch (error) {
      return { content: [{ type: "text", text: formatToolError("Gemini 图片分析失败", error, sources) }], isError: true };
    }
  },
);

server.registerTool(
  "analyze_recent_screenshots",
  {
    title: "Analyze recent screenshots with Gemini",
    description:
      `When no screenshot is explicitly supplied, call this tool immediately. It selects the most recent supported screenshots from ${DEFAULT_SCREENSHOT_DIR} (unless another directory is supplied), reports the selected sources first, and then asks Gemini to identify the actual screenshot coverage/region before other visual findings. Non-multimodal models must not answer from filenames or paths.`,
    inputSchema: {
      directory: z.string().min(1).default(DEFAULT_SCREENSHOT_DIR),
      count: z.number().int().min(1).max(MAX_SOURCE_COUNT).default(1),
      prompt: z
        .string()
        .min(1)
        .max(12_000)
        .default("第一时间确认截图实际覆盖的区域、可见窗口/UI、关键文字和明显问题；只陈述画面中能确认的内容，并标注不确定之处。"),
    },
  },
  async ({ directory, count, prompt }, extra) => {
    const signal = operationSignal(extra?.signal, TOOL_TIMEOUT_MS);
    let selection;
    try {
      selection = await listRecentMediaSources(directory, MIME_BY_EXTENSION, "截图", count, signal);
      return { content: [{ type: "text", text: await runImageTool(selection.sources, prompt, selection.warnings, signal) }] };
    } catch (error) {
      return {
        content: [{
          type: "text",
          text: formatToolError("Gemini 最近截图分析失败", error, selection?.sources ?? [], selection?.warnings ?? []),
        }],
        isError: true,
      };
    }
  },
);

const videoMetadataInputSchema = {
  fps: z.number().positive().max(24).optional().describe("Frames per second sampled by Gemini, from >0 to 24."),
  startOffset: z.string().regex(/^\d+(?:\.\d+)?s$/).optional().describe("Start offset, for example 10s or 2.5s."),
  endOffset: z.string().regex(/^\d+(?:\.\d+)?s$/).optional().describe("End offset, for example 30s or 45.5s."),
};

server.registerTool(
  "analyze_videos",
  {
    title: "Analyze videos with Gemini",
    description:
      "Analyze one or two local videos, file:// URLs, or HTTP(S) video URLs with Gemini File API. Non-multimodal models must call this tool for video content, time order, actions, or scene changes instead of guessing. Supports optional FPS and start/end offsets, then deletes temporary remote uploads after analysis. Do not repeat the same source in one turn unless the time range or question changes.",
    inputSchema: {
      sources: z
        .array(z.string().min(1))
        .min(1)
        .max(MAX_VIDEO_SOURCE_COUNT)
        .describe("Absolute path, ~/path, file:// URL, or HTTP(S) URL for each video."),
      prompt: z
        .string()
        .min(1)
        .max(12_000)
        .default("概括视频内容，并按时间顺序说明关键动作、场景变化、可见文字和不确定之处；不要臆测画外信息。"),
      ...videoMetadataInputSchema,
    },
  },
  async ({ sources, prompt, fps, startOffset, endOffset }, extra) => {
    const signal = operationSignal(extra?.signal, TOOL_TIMEOUT_MS);
    try {
      const text = await runVideoTool(sources, prompt, { fps, startOffset, endOffset }, [], signal);
      return { content: [{ type: "text", text }] };
    } catch (error) {
      return { content: [{ type: "text", text: formatToolError("Gemini 视频分析失败", error, sources) }], isError: true };
    }
  },
);

server.registerTool(
  "analyze_recent_videos",
  {
    title: "Analyze recent videos with Gemini",
    description:
      `When no video is explicitly supplied, call this tool immediately. It selects the most recent supported video from ${DEFAULT_VIDEO_DIR} (up to the requested small count), analyzes time order and scene changes through Gemini File API, reports the selected sources first, and cleans up temporary remote uploads. Non-multimodal models must not infer video content from filenames or paths.`,
    inputSchema: {
      directory: z.string().min(1).default(DEFAULT_VIDEO_DIR),
      count: z.number().int().min(1).max(MAX_VIDEO_SOURCE_COUNT).default(1),
      prompt: z
        .string()
        .min(1)
        .max(12_000)
        .default("第一时间概括最近视频的场景、关键动作、时间顺序、可见文字和需要注意的变化；只陈述可确认内容。"),
      ...videoMetadataInputSchema,
    },
  },
  async ({ directory, count, prompt, fps, startOffset, endOffset }, extra) => {
    const signal = operationSignal(extra?.signal, TOOL_TIMEOUT_MS);
    let selection;
    try {
      selection = await listRecentMediaSources(directory, VIDEO_MIME_BY_EXTENSION, "视频", count, signal);
      const text = await runVideoTool(selection.sources, prompt, { fps, startOffset, endOffset }, selection.warnings, signal);
      return { content: [{ type: "text", text }] };
    } catch (error) {
      return {
        content: [{
          type: "text",
          text: formatToolError("Gemini 最近视频分析失败", error, selection?.sources ?? [], selection?.warnings ?? []),
        }],
        isError: true,
      };
    }
  },
);

const BRAINSTORM_MODE_INSTRUCTIONS = {
  diverge:
    "Generate genuinely different approaches at the mechanism level. Do not rank or converge yet. Expose the key assumption and distinctive advantage of each option.",
  challenge:
    "Act as a skeptical reviewer. Identify hidden assumptions, counterexamples, failure modes, and evidence that would disconfirm the current direction. Propose targeted tests.",
  converge:
    "Compare the candidates against the stated criteria and constraints. Recommend one direction, explain material tradeoffs, reject weaker options explicitly, and propose the smallest reversible validation.",
  full:
    "Run a compact deliberation: frame the decision, generate distinct candidates, challenge the strongest candidates, then converge on a recommendation and a reversible next test.",
};

const BRAINSTORM_OUTPUT_INSTRUCTIONS = {
  diverge:
    "Output only a decision frame, distinct candidates, and open questions. Do not add challenges, rankings, recommendations, or a preferred option.",
  challenge:
    "Output only assumptions, counterexamples, failure modes, disconfirming evidence, and targeted tests. Do not generate replacement ideas unless needed for a test.",
  converge:
    "Output comparison criteria, a compact candidate comparison, the recommendation, rejected alternatives with reasons, and the next reversible test.",
  full:
    "Output a decision frame, distinct candidates, challenges to the strongest candidates, the recommendation with tradeoffs, and the next reversible test.",
};

server.registerTool(
  "brainstorm",
  {
    title: "Brainstorm with Gemini",
    description:
      "Get an independent Gemini perspective for open-ended ideation, architecture options, pre-mortems, counterarguments, and decision convergence. Returns decision-relevant conclusions rather than hidden chain-of-thought.",
    inputSchema: {
      problem: z.string().min(1).max(12_000).describe("The decision, question, or opportunity to explore."),
      mode: z.enum(["diverge", "challenge", "converge", "full"]).default("full"),
      context: z
        .string()
        .max(12_000)
        .default("")
        .describe("Only the minimum background needed to understand the problem."),
      constraints: z
        .array(z.string().min(1).max(1_000))
        .max(20)
        .default([])
        .describe("Hard constraints and non-goals."),
      candidates: z
        .array(z.string().min(1).max(3_000))
        .max(12)
        .default([])
        .describe("Existing options or a current proposal, mainly for challenge or converge mode."),
      criteria: z
        .array(z.string().min(1).max(1_000))
        .max(12)
        .default([])
        .describe("Decision criteria used to compare options."),
      ideaCount: z.number().int().min(3).max(10).default(6),
    },
  },
  async ({ problem, mode, context, constraints, candidates, criteria, ideaCount }, extra) => {
    const signal = operationSignal(extra?.signal, TOOL_TIMEOUT_MS);
    try {
      const task = {
        problem,
        context,
        constraints,
        candidates,
        criteria,
        desiredIdeaCount: ideaCount,
      };
      const prompt = [
        "You are an independent decision partner, not the final authority.",
        BRAINSTORM_MODE_INSTRUCTIONS[mode],
        BRAINSTORM_OUTPUT_INSTRUCTIONS[mode],
        "Use the same language as the problem. Separate facts, assumptions, and recommendations.",
        "Be concise but specific. Do not reveal private chain-of-thought; provide only decision-relevant reasons, counterevidence, and tests.",
        "Use clear headings in the response language and obey the selected mode's section limits.",
        `Task data (JSON):\n${JSON.stringify(task, null, 2)}`,
      ].join("\n\n");

      const temperature = mode === "diverge" ? 0.8 : mode === "full" ? 0.6 : 0.3;
      const { response, model, usedFallback } = await generateWithFallback(
        [{ role: "user", parts: [{ text: prompt }] }],
        { temperature, maxOutputTokens: 8_192 },
        signal,
      );

      const result = response.text?.trim();
      if (!result) throw new Error("Gemini 返回了空结果");
      return {
        content: [
          {
            type: "text",
            text: usedFallback ? `[主模型额度不足，已回退至 ${model}]\n\n${result}` : result,
          },
        ],
      };
    } catch (error) {
      return {
        content: [{ type: "text", text: `Gemini 头脑风暴失败: ${errorMessage(error)}` }],
        isError: true,
      };
    }
  },
);

if (process.env.GEMINI_ASSISTANT_NO_SERVER !== "1") {
  await server.connect(new StdioServerTransport());
}

export {
  displaySource,
  errorMessage,
  formatMediaPrompt,
  formatSelectionReport,
  formatToolError,
  listRecentMediaSources,
  loadSource,
  operationSignal,
  prepareVideoSource,
  sanitizeErrorText,
  validateVideoMetadata,
  waitForUploadedFile,
};
