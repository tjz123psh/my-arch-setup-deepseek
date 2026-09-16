#!/usr/bin/env node
// dsh 会话格式迁移（第二步）：把 sourceEventSeqs 中的区间表示 [start,end] 展开为
// 扁平稠密列表，适配 0.1.1-rc.2 读器（官方 npm 最新版；对应数据的写入构建未发布）。
// 用法: node ~/scripts/dsh/dsh-session-expand-ranges.mjs [会话根目录, 默认 ~/.dsh/sessions]
// 语义：区间 [[a,b]] ≡ 稠密列表 [a..b]，仅改表示不改语义；行数校验 + 零区间残留校验。
import { readFileSync, writeFileSync, renameSync, readdirSync, statSync, chmodSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";

const ROOT = process.argv[2] || join(homedir(), ".dsh", "sessions");
const ZSTD_MAGIC = 4247762216;
const CHECKSUM_OPTIONS = { params: { [constants.ZSTD_c_checksumFlag]: 1 } };

function scanFrames(buffer) {
	const frames = [];
	let offset = 0;
	while (offset < buffer.length) {
		const start = offset;
		if (buffer.length - offset < 4) return frames;
		if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`invalid frame magic at byte ${offset}`);
		offset += 4;
		if (offset === buffer.length) return frames;
		const descriptor = buffer.readUInt8(offset);
		offset += 1;
		if ((descriptor & 24) !== 0) throw new Error(`reserved frame-header bit at byte ${offset - 1}`);
		const contentSizeFlag = descriptor >>> 6;
		const singleSegment = (descriptor & 32) !== 0;
		const checksum = (descriptor & 4) !== 0;
		const dictionaryFlag = descriptor & 3;
		const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
		const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
		const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
		if (buffer.length - offset < remainingHeaderBytes) return frames;
		offset += remainingHeaderBytes;
		for (;;) {
			if (buffer.length - offset < 3) return frames;
			const blockHeader = buffer.readUIntLE(offset, 3);
			offset += 3;
			const lastBlock = (blockHeader & 1) !== 0;
			const blockType = blockHeader >>> 1 & 3;
			const blockSize = blockHeader >>> 3;
			if (blockType === 3) throw new Error(`reserved block type at byte ${offset - 3}`);
			const payloadBytes = blockType === 1 ? 1 : blockSize;
			if (buffer.length - offset < payloadBytes) return frames;
			offset += payloadBytes;
			if (lastBlock) break;
		}
		if (checksum) {
			if (buffer.length - offset < 4) return frames;
			offset += 4;
		}
		frames.push({ start, end: offset });
	}
	return frames;
}

// 区间/混合 → 扁平稠密去重列表（保持出现顺序）
function expandSourceSeqs(value) {
	const out = [];
	const seen = new Set();
	for (const item of value) {
		if (Array.isArray(item) && item.length === 2 && item.every((x) => Number.isSafeInteger(x)) && item[0] >= 0 && item[1] >= 0) {
			const [a, b] = item; 
			for (let i = Math.min(a, b); i <= Math.max(a, b); i++) { if (!seen.has(i)) { seen.add(i); out.push(i); } }
		} else if (Number.isSafeInteger(item) && item >= 0 && !seen.has(item)) {
			seen.add(item); out.push(item);
		}
	}
	return out;
}

function processLine(line) {
	if (!line.includes("sourceEventSeqs")) return line;
	try {
		const obj = JSON.parse(line);
		if (obj && typeof obj === "object" && Array.isArray(obj.sourceEventSeqs) && obj.sourceEventSeqs.some((x) => Array.isArray(x))) {
			obj.sourceEventSeqs = expandSourceSeqs(obj.sourceEventSeqs);
			return JSON.stringify(obj);
		}
	} catch { /* 非 JSON 行保持原样 */ }
	return line;
}

function walk(dir, out = []) {
	for (const entry of readdirSync(dir)) {
		const p = join(dir, entry);
		if (statSync(p).isDirectory()) walk(p, out);
		else if (SESSION_LOG_RE.test(entry)) out.push(p);
	}
	return out;
}

// 0.1.5 起会话正文按代际存放：v0 为 session.jsonl.zstd，之后为 session.vN.jsonl.zstd。
// runtime 只读最高代，改已退役的旧代会"看似修好、实际无效"，故每个会话目录只选最高代。
const SESSION_LOG_RE = /^session(?:\.v(\d+))?\.jsonl\.zstd$/;

function currentGenerationLogs(files) {
	const byDir = new Map();
	for (const f of files) {
		const m = SESSION_LOG_RE.exec(basename(f));
		if (!m) continue;
		const gen = m[1] === undefined ? 0 : Number(m[1]);
		const dir = dirname(f);
		const cur = byDir.get(dir);
		if (!cur || gen > cur.gen) byDir.set(dir, { f, gen });
	}
	return [...byDir.values()].map((v) => v.f).sort();
}

// 0.1.5 对每个会话只允许一个写者（session.lock + 内核锁）；本脚本绕开该锁直接改文件，
// 因此服务在跑时默认拒绝执行。
function assertNoLiveDshWriter() {
	if (process.argv.includes("--force")) return;
	let pid = null;
	try {
		for (const entry of readdirSync("/proc")) {
			if (!/^\d+$/.test(entry)) continue;
			let cmd = "";
			try { cmd = readFileSync(`/proc/${entry}/cmdline`, "utf8").replace(/\0/g, " "); } catch { continue; }
			if (cmd.includes("@deepseek-ai/dsh") && cmd.includes("web")) { pid = entry; break; }
		}
	} catch { return; }
	if (pid) {
		console.error(`拒绝执行：检测到 dsh web 正在运行 (pid ${pid})。先停服务（~/scripts/dsh/dsh-web.sh --stop），或确认风险后加 --force。`);
		process.exit(3);
	}
}

let expanded = 0, skipped = 0, failed = 0;
assertNoLiveDshWriter();
for (const f of currentGenerationLogs(walk(ROOT))) {
	try {
		const buffer = readFileSync(f);
		const frames = scanFrames(buffer);
		if (frames.length === 0) { skipped++; continue; }
		let plaintext = Buffer.alloc(0);
		for (const frame of frames) plaintext = Buffer.concat([plaintext, zstdDecompressSync(buffer.subarray(frame.start, frame.end))]);
		const text = plaintext.toString("utf8");
		if (!text.includes('"sourceEventSeqs": [[') && !text.includes('"sourceEventSeqs":[')) { skipped++; continue; }
		const linesBefore = text.split("\n").length;
		const rows = text.split("\n");
		for (let i = 0; i < rows.length; i++) rows[i] = processLine(rows[i]);
		const changed = rows.join("\n");
		if (changed.split("\n").length !== linesBefore) throw new Error("行数变化，中止");
		if (/("sourceEventSeqs"\s*:\s*\[)\s*\[/.test(changed)) throw new Error("仍有区间残留");
		const outBuf = Buffer.from(changed, "utf8");
		const nl = outBuf.indexOf(10);
		if (nl === -1) throw new Error("无法定位 header 行");
		const header = outBuf.subarray(0, nl + 1);
		const rest = outBuf.subarray(nl + 1);
		const out = Buffer.concat([zstdCompressSync(header, CHECKSUM_OPTIONS), zstdCompressSync(rest, CHECKSUM_OPTIONS)]);
		const tmp = f + ".range-tmp";
		writeFileSync(tmp, out, { mode: 0o600 });
		chmodSync(tmp, 0o600);
		renameSync(tmp, f);
		console.log(`已展开: ${f} (${linesBefore - 1} 行事件)`);
		expanded++;
	} catch (e) {
		console.log(`失败: ${f} -> ${e.message}`);
		failed++;
	}
}
console.log(`\n结果: 展开 ${expanded}, 未涉及 ${skipped}, 失败 ${failed}`);