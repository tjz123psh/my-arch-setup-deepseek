#!/usr/bin/env node
// dsh 会话数据迁移工具：把会话日志中 agentPreset 预设 id 从旧值改写为新值
// （如 0.1.2-alpha.1 把 code 改名 ptc 后，ptc→code 回迁）。
// 用法: node ~/scripts/dsh/dsh-session-migrate.mjs <旧id> <新id> [会话根目录, 默认 ~/.dsh/sessions]
// 依据技能 dsh-plugin-management：日志无哈希链可安全改写；mv 原子替换；行数不变+零残留校验。
import { readFileSync, writeFileSync, renameSync, readdirSync, statSync, chmodSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { homedir } from "node:os";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";

const OLD = process.argv[2];
const NEW = process.argv[3];
if (!OLD || !NEW) { console.error("用法: dsh-session-migrate.mjs <旧id> <新id> [根目录]"); process.exit(2); }
const ROOT = process.argv[4] || join(homedir(), ".dsh", "sessions");
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

// 只改 agentPreset 键的值；保留冒号后的空白风格
const PRESET_RE = (oldId) => new RegExp(`("agentPreset"\\s*:\\s*)"${oldId}"`, "g");

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

let migrated = 0, skipped = 0, failed = 0;
assertNoLiveDshWriter();
for (const f of currentGenerationLogs(walk(ROOT))) {
	try {
		const buffer = readFileSync(f);
		const frames = scanFrames(buffer);
		if (frames.length === 0) { skipped++; continue; }
		let plaintext = Buffer.alloc(0);
		for (const frame of frames) plaintext = Buffer.concat([plaintext, zstdDecompressSync(buffer.subarray(frame.start, frame.end))]);
		const text = plaintext.toString("utf8");
		const re = PRESET_RE(OLD);
		if (!re.test(text)) { skipped++; continue; }
		const linesBefore = text.split("\n").length;
		const replaced = text.replace(PRESET_RE(OLD), (m, pre) => `${pre}"${NEW}"`);
		// 校验：行数不变、旧引用零残留、新引用存在
		if (replaced.split("\n").length !== linesBefore) throw new Error("行数变化，中止");
		if (PRESET_RE(OLD).test(replaced)) throw new Error("仍有旧预设引用残留");
		if (!PRESET_RE(NEW).test(replaced)) throw new Error("新预设引用未写入");
		// 按标准布局重编码：frame1 = header 行, frame2 = 其余事件
		const nl = Buffer.from(replaced, "utf8").indexOf(10);
		if (nl === -1) throw new Error("无法定位 header 行");
		const header = Buffer.from(replaced, "utf8").subarray(0, nl + 1);
		const rest = Buffer.from(replaced, "utf8").subarray(nl + 1);
		const out = Buffer.concat([zstdCompressSync(header, CHECKSUM_OPTIONS), zstdCompressSync(rest, CHECKSUM_OPTIONS)]);
		const tmp = f + ".migrate-tmp";
		writeFileSync(tmp, out, { mode: 0o600 });
		chmodSync(tmp, 0o600);
		renameSync(tmp, f);
		console.log(`已迁移: ${f} (${OLD} → ${NEW}, ${linesBefore - 1} 行事件)`);
		migrated++;
	} catch (e) {
		console.log(`失败: ${f} -> ${e.message}`);
		failed++;
	}
}
console.log(`\n结果: 迁移 ${migrated}, 未涉及 ${skipped}, 失败 ${failed}`);