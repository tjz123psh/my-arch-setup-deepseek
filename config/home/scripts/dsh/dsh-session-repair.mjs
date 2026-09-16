#!/usr/bin/env node
// dsh 会话日志修复工具：把"首帧包含整个会话"的 session.jsonl.zstd 无损重排为
// 标准布局（frame1 = header 一行，frame2+ = 事件），并使首帧校验通过。
// 用法: node ~/scripts/dsh/dsh-session-repair.mjs [会话根目录, 默认 ~/.dsh/sessions]
import { readFileSync, writeFileSync, renameSync, readdirSync, statSync, chmodSync, mkdirSync, rmSync } from "node:fs";
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
		if (buffer.length - offset < 4) return { frames, tornStart: start };
		if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`invalid frame magic at byte ${offset}`);
		offset += 4;
		if (offset === buffer.length) return { frames, tornStart: start };
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
		if (buffer.length - offset < remainingHeaderBytes) return { frames, tornStart: start };
		offset += remainingHeaderBytes;
		for (;;) {
			if (buffer.length - offset < 3) return { frames, tornStart: start };
			const blockHeader = buffer.readUIntLE(offset, 3);
			offset += 3;
			const lastBlock = (blockHeader & 1) !== 0;
			const blockType = blockHeader >>> 1 & 3;
			const blockSize = blockHeader >>> 3;
			if (blockType === 3) throw new Error(`reserved block type at byte ${offset - 3}`);
			const payloadBytes = blockType === 1 ? 1 : blockSize;
			if (buffer.length - offset < payloadBytes) return { frames, tornStart: start };
			offset += payloadBytes;
			if (lastBlock) break;
		}
		if (checksum) {
			if (buffer.length - offset < 4) return { frames, tornStart: start };
			offset += 4;
		}
		frames.push({ start, end: offset });
	}
	return { frames, tornStart: -1 };
}

function firstFrameIsSingleLine(frames, buffer) {
	if (frames.length === 0) return false;
	try {
		const plaintext = zstdDecompressSync(buffer.subarray(frames[0].start, frames[0].end));
		return plaintext.length > 0 && plaintext.indexOf(10) === plaintext.length - 1;
	} catch {
		return false;
	}
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

let repaired = 0, skipped = 0, failed = 0;
assertNoLiveDshWriter();
for (const f of currentGenerationLogs(walk(ROOT))) {
	try {
		const buffer = readFileSync(f);
		const { frames, tornStart } = scanFrames(buffer);
		if (firstFrameIsSingleLine(frames, buffer)) { skipped++; continue; }
		if (frames.length === 0) { console.log(`跳过(无完整帧, tornStart=${tornStart}): ${f}`); failed++; continue; }
		// 逐帧解压拼接 → 完整 JSONL 明文
		let plaintext = Buffer.alloc(0);
		for (const frame of frames) plaintext = Buffer.concat([plaintext, zstdDecompressSync(buffer.subarray(frame.start, frame.end))]);
		// 第一行 = header；其余 = 事件
		const nl = plaintext.indexOf(10);
		if (nl === -1 || nl === plaintext.length - 1) { console.log(`跳过(结构无法拆分): ${f}`); failed++; continue; }
		const header = plaintext.subarray(0, nl + 1);
		const rest = plaintext.subarray(nl + 1);
		const headerFrame = zstdCompressSync(header, CHECKSUM_OPTIONS);
		const eventFrame = zstdCompressSync(rest, CHECKSUM_OPTIONS);
		const tmp = f + ".repair-tmp";
		writeFileSync(tmp, Buffer.concat([headerFrame, eventFrame]), { mode: 0o600 });
		chmodSync(tmp, 0o600);
		renameSync(tmp, f);
		// 复核
		const check = readFileSync(f);
		const { frames: f2 } = scanFrames(check);
		if (!firstFrameIsSingleLine(f2, check)) throw new Error("复核失败");
		console.log(`已修复: ${f} (${plaintext.length} 字节明文 → ${rest.length} 行事件)`);
		repaired++;
	} catch (e) {
		console.log(`失败: ${f} -> ${e.message}`);
		failed++;
	}
}
console.log(`\n结果: 修复 ${repaired}, 保持原样 ${skipped}, 失败 ${failed}`);