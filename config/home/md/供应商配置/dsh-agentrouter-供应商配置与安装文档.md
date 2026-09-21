# DSH 接入 AgentRouter（age）供应商 — 安装文档与配置思路

> 适用：DeepSeek Harness（dsh）Web / headless 使用 agentrouter.org（`age`）渠道。
> 环境：Linux（本机为 Arch 系），Clash 监听 `127.0.0.1:7890`，Node >= 24（本机 26.7），DSH 为 npm 全局安装。
> 最后更新：2026-08-27（已在本机完整实测通过）。

---

## 0. 一句话总结配置思路

**供应商在墙后 + WAF 只认官方客户端指纹，DSH 侧做不了这两件事 → 用一层本地反代同时解决"出口走 Clash"和"注入 Codex wire image 请求头"；DSH 侧只需要两件事：一条凭据 ref + 一个指向本地反代的 pi-ai 路由。** 模型元数据（上下文 / 输出上限 / 思考档位）以 pi-ai 内置目录为权威、以中继实测为准，填进路由的 `models` 列表。

三个组成部分（缺一不可）：

| 组件 | 位置 | 作用 |
|---|---|---|
| 本地反代脚本 | `~/.local/bin/agentrouter-proxy.mjs` | 监听 `127.0.0.1:8320`，转发到 `https://agentrouter.org`（路径原样），注入 wire 头，出口走 Clash |
| systemd 用户服务 | `~/.config/systemd/user/agentrouter-proxy.service` | 保证反代常驻、开机自启、崩溃重启 |
| DSH 配置 | `~/.dsh/settings.yaml` + `~/.dsh/.credentials.yaml` | 凭据 ref + pi-ai 路由 + 模型元数据 |

---

## 1. 探路方法论（新供应商通用，务必备份这段）

任何新供应商接入，先回答 5 个问题，全部用 curl/node 实测，**不要凭印象猜**：

1. **连通性**：`curl -m 10 https://<host>/v1/models` 直连是否通？
   - 超时 → 走 Clash：`curl -x http://127.0.0.1:7890 ...`。DSH 服务器进程本身不认 `HTTPS_PROXY`（Node fetch 需 `NODE_USE_ENV_PROXY=1` 才认），所以需要一层本地反代出口。
2. **指纹（WAF）**：状态 401 + `unauthorized client detected` → 网关在做客户端指纹识别。
   - 逐个试：`Originator: codex_cli_rs`、`Version: 0.101.0`、`User-Agent: codex_cli_rs/0.101.0 (...)`
   - 实测结论：`Originator` 单独就够；三个一起发最保险。
3. **协议**：同一域名下挨个试：
   - `GET /v1/models`（列表）
   - `POST /v1/chat/completions`（OpenAI 聊天协议，兼容性最广，**首选**）
   - `POST /v1/responses`（OpenAI 新版，有些网关不支持甚至直接 RST）
   - `POST /v1/messages`（Anthropic 协议，一般要更重的 Claude Code wire image）
4. **参数**（在选定的协议上逐项实测）：
   - `max_tokens` / `max_completion_tokens` 上限：发大值看报错（报错信息往往直接给出范围，如 `限制数值范围[1,131072]`）
   - `reasoning_effort` 档位：`none/minimal/low/medium/high/xhigh/max/off` 每个值真发一次
   - 角色：system 转 `developer` 可能被拒 → pi-ai 路由 `compat.supportsDeveloperRole: false` 强制 system
   - SSE 流式（`stream: true`）：确认增量能透传
5. **元数据**：上下文窗口 / 输出上限 / 思考档位的权威来源：
   - pi-ai 内置目录：`<dsh 安装目录>/node_modules/@earendil-works/pi-ai/dist/providers/data/*.json`（官方规格，**第一权威**）
   - 中继实测兜底（官方目录没有的模型，或中继有硬上限时）

---

## 2. agentrouter 的探路结论（速查表，下次免测）

| 项目 | 实测结果 |
|---|---|
| 直连 | 超时（GFW）→ 必须 Clash `127.0.0.1:7890` |
| WAF | 无 wire 头 → 401 `unauthorized client detected`；`Originator` 单独即可通过 |
| `GET /v1/models` | ✅ 200（需 wire 头），返回 `claude-opus-4-8 / claude-opus-5 / deepseek-v4-flash / glm-5.3 / gpt-5.6-sol` |
| `POST /v1/chat/completions` | ✅ 200，SSE 流式正常（deepseek 有 `reasoning_content` 增量） |
| `POST /v1/responses` | ❌ 连接被 RST（上游丢弃）→ **不要用 responses 协议** |
| system 角色 | ✅ 可接受；`developer` 未测（配置强制 system，最稳） |
| `max_completion_tokens` | claude 系 128000 ✅ / deepseek 384000 ✅ / glm-5.3 **131072 封顶**（262144 报错）/ gpt-5.6-sol 128000 ✅ |
| `reasoning_effort` | claude 系 high/max/xhigh ✅（流式不暴露思考增量）；deepseek minimal..max ✅（有思考增量）；glm-5.3 **只认 low/high/max**（400 报错原文：*"该模型始终思考，不支持关闭思考；请使用 low、high 或 max"*）；gpt-5.6-sol 全档位 ✅（`none` 即关闭思考） |
| **图片输入（16×16 绿图实测）** | ✅ `gpt-5.6-sol`、`claude-opus-5`、`claude-opus-4-8` 都能收图并正确答"绿色"（**是多模态**）；❌ `deepseek-v4-flash`（400 `This model does not support image`）、`glm-5.3`（400 `type 参数非法，取值范围 ['text']`）为纯文本 |
| 备注 | gpt-5.6-sol + xhigh 偶发长时间挂起（上游慢），重试即可 |

---

## 3. 安装步骤

### 3.1 本地反代脚本

文件：`~/.local/bin/agentrouter-proxy.mjs`（完整源码，直接复制保存）：

```javascript
#!/usr/bin/env node
/**
 * agentrouter-proxy — local reverse proxy for the AgentRouter (agentrouter.org)
 * gateway.
 *
 * Why this exists:
 *   1. agentrouter.org is only reachable from this machine through the Clash
 *      proxy (127.0.0.1:7890); direct connections time out (GFW).
 *   2. AgentRouter's WAF rejects requests that do not carry the "Codex wire
 *      image": it requires `Originator` / `Version` / `User-Agent` headers of
 *      an official client. The harness's own HTTP client cannot set a custom
 *      User-Agent (it is always attributed), so this proxy injects the three
 *      headers and forwards everything else unchanged.
 *
 * Egress goes through Clash via Node's env-proxy support: run this process
 * with `NODE_USE_ENV_PROXY=1` and `HTTPS_PROXY=http://127.0.0.1:7890`.
 *
 * Upstream base: https://agentrouter.org — the incoming request path is
 * appended verbatim, so the configured baseURL for DSH is
 * `http://127.0.0.1:{PORT}/v1` and the paths line up one-to-one.
 */
import http from "node:http";
import { Readable } from "node:stream";

const UPSTREAM = "https://agentrouter.org";
const PORT = Number(process.env.AGENTROUTER_PROXY_PORT ?? 8320);
const BIND = process.env.AGENTROUTER_PROXY_BIND ?? "127.0.0.1";

// The Codex wire image headers AgentRouter's WAF requires.
const WIRE_HEADERS = {
  Originator: "codex_cli_rs",
  Version: "0.101.0",
  "User-Agent": "codex_cli_rs/0.101.0 (Mac OS 26.0.1; arm64) Apple_Terminal/464",
};

const REPLACED = new Set(["host", "originator", "version", "user-agent"]);

const server = http.createServer((req, res) => {
  const url = UPSTREAM + req.url; // query string included
  const headers = { ...WIRE_HEADERS };
  for (const [name, value] of Object.entries(req.headers)) {
    if (REPLACED.has(name)) continue; // inject our wire image instead
    headers[name] = value;
  }

  const controller = new AbortController();
  // Abort the upstream call only when the client connection goes away before
  // the response finished. (req "close" fires as soon as the request body has
  // been read — that must NOT cancel the call.)
  res.on("close", () => {
    if (!res.writableEnded) controller.abort();
  });
  const timeout = setTimeout(() => controller.abort(), 10 * 60 * 1000);
  timeout.unref();

  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  fetch(url, {
    method: req.method,
    headers,
    body: hasBody ? req : undefined,
    duplex: "half",
    signal: controller.signal,
  })
    .then((upstream) => {
      clearTimeout(timeout);
      res.writeHead(upstream.status, Object.fromEntries(upstream.headers));
      const body = Readable.fromWeb(upstream.body);
      // Aborted upstreams (client hung up, watchdog) emit here — swallow the
      // error instead of crashing the process; the response is already dead.
      body.on("error", (error) => {
        console.error(`[agentrouter-proxy] ${req.method} ${req.url} -> stream error: ${error?.message ?? error}`);
        res.destroy();
      });
      body.pipe(res);
    })
    .catch((error) => {
      clearTimeout(timeout);
      const reason = error?.cause?.code ?? error?.message ?? String(error);
      console.error(`[agentrouter-proxy] ${req.method} ${req.url} -> upstream failed: ${reason}`);
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "application/json; charset=utf-8" });
        res.end(
          JSON.stringify({
            success: false,
            error: {
              message:
                `agentrouter-proxy cannot reach ${UPSTREAM}: ${reason}. ` +
                "Is Clash (127.0.0.1:7890) running?",
            },
          }),
        );
      } else {
        res.destroy();
      }
    });
});

server.listen(PORT, BIND, () => {
  console.log(`[agentrouter-proxy] listening on http://${BIND}:${PORT} -> ${UPSTREAM}`);
});
```

要点（都是踩过的坑）：

- **`req.on("close")` 不能用来中止上游**——请求体读完后它就会触发，会把正常请求当成客户端断开杀掉（表现为"上游被 abort"）。正确姿势是 `res.on("close")` + 判断 `res.writableEnded`。
- 上行流（SSE）必须挂 `error` 处理器，否则客户端提前断开（如 `head -c` 截断）会让整个进程崩溃。
- 退出通过 `NODE_USE_ENV_PROXY=1` + `HTTPS_PROXY` 环境变量走 Clash，脚本里零网络依赖。

### 3.2 systemd 用户服务

文件：`~/.config/systemd/user/agentrouter-proxy.service`：

```ini
[Unit]
Description=AgentRouter wire-image reverse proxy for DSH (egress via Clash 127.0.0.1:7890)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/node /home/pang/.local/bin/agentrouter-proxy.mjs
Environment=NODE_USE_ENV_PROXY=1
Environment=HTTPS_PROXY=http://127.0.0.1:7890
Environment=HTTP_PROXY=http://127.0.0.1:7890
Environment=NO_PROXY=127.0.0.1,localhost
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

启用：

```bash
chmod +x ~/.local/bin/agentrouter-proxy.mjs
systemctl --user daemon-reload
systemctl --user enable --now agentrouter-proxy.service
systemctl --user status agentrouter-proxy.service
```

冒烟测试（应 200 且带 wire 头；**key 放占位符，实际用你 .credentials.yaml 里的**）：

```bash
curl -sS -m 30 -H "Authorization: Bearer sk-<你的key>" http://127.0.0.1:8320/v1/models | head -c 300
```

### 3.3 凭据（DSH 侧）

`~/.dsh/.credentials.yaml` 的 `refs` 下新增（**key 只存在这里，settings.yaml 永不出现明文**）：

```yaml
version: 1
refs:
  # ...其他已有项...
  AGENTROUTER_API_KEY: sk-<你的key>
```

### 3.4 DSH 路由（settings.yaml）

`~/.dsh/settings.yaml` 的 `llm-pi-ai.providers` 下新增 `agentrouter` 段（本机最终生效版）：

```yaml
      agentrouter:
        {
          displayName: AgentRouter (age),
          apiKeyEnv: AGENTROUTER_API_KEY,
          api: openai-completions,
          baseURL: http://127.0.0.1:8320/v1,
          headers: { Originator: codex_cli_rs, Version: 0.101.0 },
          compat: { supportsDeveloperRole: false },
          models:
            [
              {
                  id: claude-opus-4-8,
                  name: Claude Opus 4.8,
                  contextWindow: 1000000,
                  maxTokens: 128000,
                  input: [ text, image ],
                  reasoningEfforts: { xhigh: xhigh, max: max }
                },
              {
                  id: claude-opus-5,
                  name: Claude Opus 5,
                  contextWindow: 1000000,
                  maxTokens: 128000,
                  input: [ text, image ],
                  reasoningEfforts: { xhigh: xhigh, max: max }
                },
              {
                  id: deepseek-v4-flash,
                  name: DeepSeek V4 Flash,
                  contextWindow: 1000000,
                  maxTokens: 384000,
                  reasoningEfforts: { off: null, minimal: minimal, low: low, medium: medium, high: high, max: max }
                },
              {
                  id: glm-5.3,
                  name: GLM 5.3,
                  contextWindow: 1000000,
                  maxTokens: 131072,
                  reasoningEfforts: { low: low, high: high, max: max }
                },
              {
                  id: gpt-5.6-sol,
                  name: GPT-5.6 Sol,
                  contextWindow: 272000,
                  maxTokens: 128000,
                  input: [ text, image ],
                  reasoningEfforts: { off: none, minimal: minimal, low: low, medium: medium, high: high, xhigh: xhigh, max: max }
                }
            ]
        }
```

路由字段语义（照着写不会错）：

| 字段 | 含义 / 注意 |
|---|---|
| `apiKeyEnv` | 凭据 **ref 名**（不是值），对不上 `.credentials.yaml` 会 MISSING_CREDENTIAL |
| `api` | 协议：`openai-completions`（兼容最广）。agentrouter 上 `openai-responses` 会被 RST |
| `baseURL` | **指向本地反代** `http://127.0.0.1:8320/v1`（路径与上游一一对应） |
| `headers` | 路由级请求头。**别写 `User-Agent`** —— DSH 的 attribution 头会把它过滤并覆盖（`requestHeaders` 里 `user-agent` 是保留名）；`Originator`/`Version` 会真正透传，属双保险（反代已注入） |
| `compat.supportsDeveloperRole: false` | 让 pi-ai 发 `system` 角色而不是 `developer`（DTO 级别的中继最稳） |
| `models[].input` | 模态声明。**多模态（能收图）的模型必须写 `input: [ text, image ]`**，否则 DSH 按纯文本处理、发图会失败；纯文本模型（deepseek / glm）不写即可 |
| `models[].reasoningEfforts` | 键=UI 档位，值=线上拼写。**只有 `off` 允许空值/null**，其他档位必须给值，否则整段被校验拒绝 |

默认模型（可选，新会话生效）：`agent-default-model` 改为 `provider: agentrouter` + 想要的模型 + 可选 `reasoningEffort`。

---

## 4. 模型元数据速查（本次实测，来源：pi-ai 官方目录 + 中继验证）

| 模型 | 上下文 | 最大输出 | 模态 | 思考档位 |
|---|---|---|---|---|
| claude-opus-4-8 | 1M | 128000 | text+image | xhigh / max |
| claude-opus-5 | 1M | 128000 | text+image | xhigh / max |
| deepseek-v4-flash | 1M | 384000 | text | off / minimal / low / medium / high / max |
| glm-5.3 | 1M | 131072（中继硬上限） | text | low / high / max（始终思考） |
| gpt-5.6-sol | 272000（OpenAI 官方） | 128000 | text+image | off(none) / minimal / low / medium / high / xhigh / max |

> ⚠️ **多模态模型必须在条目里写 `input: [ text, image ]`**，否则 DSH 按纯文本对待、发图会失败（gpt-5.6-sol 就是"能收图但没声明 input → 发不进图"的典型案例）。三个能收图的（sol / opus-5 / opus-4-8）已补上。

目录权威数据在哪：`<npm-global>/node_modules/@deepseek-ai/dsh/node_modules/@earendil-works/pi-ai/dist/providers/data/{anthropic,deepseek,openai,...}.json`，字段 `contextWindow / maxTokens / thinkingLevelMap`。（dev 源码版在 `<repo>/node_modules/.pnpm/@earendil-works+pi-ai@*/node_modules/@earendil-works/pi-ai/dist/providers/data/`，结构相同。）

---

## 5. 验证闭环（改完跑一遍，全部通过才算完成）

> **注意**：本机当前跑的是 **dev 源码版**（`/home/pang/.npm-global/bin/dsh` → `~/Projects/deepseek-harness/apps/cli`，自带 token 鉴权，HTTP API 已改为 connection RPC）。新版的编程式验证 = 第 3 步的**源码同源校验脚本**；旧版 HTTP API 命令保留在第 6 步，仅当回到 npm 安装版（≤ 0.1.1）时用。

1. **YAML 合法**：

```bash
node -e "const y=require('<dsh>/node_modules/js-yaml');const fs=require('fs');y.load(fs.readFileSync(process.env.HOME+'/.dsh/settings.yaml','utf8'));console.log('YAML OK')"
```

2. **配置树能装载**：`dsh web --dump-config` 退出码 0（不绑端口，可随时跑）。

3. **源码同源校验脚本**（强烈推荐，和运行中的服务器同一套 schema，能精确定位被拒的路由/模型/字段）。脚本就在本目录：`check-settings.mjs`

```bash
cd ~/md/供应商配置
node --experimental-strip-types check-settings.mjs                      # 校验全部 providers
node --experimental-strip-types check-settings.mjs agentrouter qwen     # 只校验指定路由
# 期望输出: PASS: providers [...] 通过运行服务器同源校验
```

   实现：直接调用 `deepseek-harness/packages/llm/llm-pi-ai/src/config.ts` 的 `Config`（Standard Schema 接口）+ `assertServiceable`。校验失败会打印具体原因，例如`reasoningEfforts.minimal needs the wire value dispatch should send; only "off" may leave it empty`。

4. **运行中服务观察**：改完 settings.yaml 后留意 `~/.dsh/web.log`——出现 `settings-file: reload failed ... keeping the last good document` 说明文档被拒，回第 3 步定位；无报错 + GUI 刷新后模型选择器出现思考档位 = 已生效。

5. **真发一轮 + 流式**：curl 反代（见 3.2 冒烟 + `stream:true` 参数）。

6. **旧版 HTTP API 信封（仅 npm 安装版 ≤ 0.1.1 可用；dev 版权限模型改走 connection RPC，这些接口已 404）**：

```bash
# 服务端热加载 + 校验
curl -sS -X POST http://127.0.0.1:3080/api/settings.describe -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v1","method":"settings.describe","payload":{}}' | head -c 2000

# GUI 模型目录（看 failures 必须为空、每个模型有名字/档位）
curl -sS -X POST http://127.0.0.1:3080/api/llm.models -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v2","method":"llm.models","payload":{}}'

# 凭据: credentials.describe payload {"refs":["AGENTROUTER_API_KEY"]} → configured: true

# 抓取模型列表（走 DSH 自身 fetch 路径 → 反代 → 上游）
curl -sS -X POST http://127.0.0.1:3080/api/llm.discoverModels -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"v3","method":"llm.discoverModels","payload":{"settingsNs":"llm-pi-ai","provider":"agentrouter","baseURL":"http://127.0.0.1:8320/v1","api":"openai-completions","apiKey":"sk-<你的key>"}}'
```

   dev 版的 token 鉴权流程（备忘）：启动日志打印 `http://127.0.0.1:3080/?token=...`；浏览器首访该 URL 会 303 种下 HttpOnly cookie（绑定 Host、30 天），后续请求都带 cookie。命令行 curl 需先 `curl -D - "http://127.0.0.1:3080/?token=..."` 抓 `Set-Cookie` 再带 `Cookie:` 头。

---

## 6. 故障排查表

| 症状 | 原因 | 处理 |
|---|---|---|
| GUI 改了不生效 / 显示旧值；模型没有上下文和思考档位 | 写入被 DSH 校验器拒绝（`settings-rejected`），服务保留上一份有效文档 | dev 版：`node --experimental-strip-types ~/md/供应商配置/check-settings.mjs` 直接定位不合法字段（例：`reasoningEfforts.minimal needs the wire value...`）。npm 版：`settings.update` 发空 patch（`{"ns":"llm-pi-ai","patch":{},"expectedRevision":<当前rev>}`），响应里的 `error.message` 给出同样信息 |
| 401 `unauthorized client detected` | 缺 Codex wire 头 | 查反代在不在（`systemctl --user status agentrouter-proxy`）、Clash 是否开着 |
| 502 `Is Clash running?` | 反代在但 Clash 没监听 7890 | 开 Clash |
| `/v1/responses` 连不上（ECONNRESET） | 上游丢弃该路径 | 用 `openai-completions` 协议 |
| glm-5.3 报 `max_tokens参数非法：限制数值范围[1,131072]` | 超出中继上限 | maxTokens 设 131072 |
| glm-5.3 报"该模型始终思考，不支持关闭思考" | 上游不认该档位 | 只用 low/high/max，不配 off |
| 请求长时间无响应（尤其 gpt-5.6-sol + xhigh） | 上游慢 / 限流 | 重试或降档位 |
| 日志里 `reload failed ... keeping the last good document` | 文件被外部改坏/不合法 | 修 YAML，别硬 reload |

---

## 7. 换供应商（如 any / seek / tabi）速查流程

1. **探路**：按第 1 节五问实测（连通 / 指纹 / 协议 / 参数 / 元数据）。
2. **反代**：复制 `agentrouter-proxy.mjs` 改三处——`UPSTREAM`、端口（或加 `AGENTROUTER_PROXY_PORT` 环境变量）、`WIRE_HEADERS`（若该站不需要指纹可留空对象）；systemd 复制一份改 `ExecStart` 端口。
3. **凭据**：`.credentials.yaml` 加一条 ref。
4. **路由**：settings.yaml 加一段，`baseURL` 指向新反代，`compat`/`headers` 按探路结果填。
5. **元数据**：先查 pi-ai 目录 JSON，缺的按实测填；`reasoningEfforts` 只空 `off`。
6. **验证**：跑第 5 节闭环。
7. **归档**：把探路结论（协议结论 / 上限 / 档位 / WAF 要求）追加到本文档，下次零成本。

---

## 8. 与机器上其他工具的关系（免受误导）

- **codex / cc-switch**（`~/.cc-switch/cc-switch.db`）：age 渠道用的是 `wire_api = "responses"` + `env_key` + `base_url .../v1`。**DSH 不抄这个协议**——实测 `/v1/responses` 在本网络会被 RST，DSH 走 `chat/completions` 全通。cc-switch 模板只是"换了 key 丢环境变量"的参考。
- **grok**（`~/.grok/config.toml`）：tabi/seek 走 `anthropic-messages` + `extra_headers` + `secret-file-auth-provider.sh`。DSH 没有 per-route 明文 key 的需求（key 在 `.credentials.yaml`），grok 那套"key 文件 + 外部脚本注入"不需要照搬；但 tabi/seek 这类供应商若同样有 WAF，思路一样（反代注入或鉴权脚本），协议按探路结果选。
- **通用教训**：这类中转站普遍有客户端指纹 + 硬性输出上限 + 思考档位白名单，三者都必须实测而不是相信文档。

---

## 9. 本机现状备忘（2026-08-27 更新）

- **dsh 运行形态**：dev 源码版（`/home/pang/.npm-global/bin/dsh` 链接到 `~/Projects/deepseek-harness/apps/cli`，0.1.2-alpha 分支），Node 26.8；带 token 鉴权（启动日志打印 `http://127.0.0.1:3080/?token=...`，首访 303 种 HttpOnly cookie 30 天），HTTP API 从旧信封改为 connection RPC
- 反代：`agentrouter-proxy.service` 已 enable，监听 8320，日志 `journalctl --user -u agentrouter-proxy -f`
- 凭据：`AGENTROUTER_API_KEY`、`QWEN_API_KEY` 已写入 `~/.dsh/.credentials.yaml`
- 路由：`agentrouter`（5 个模型，全部带上下文/上限/档位）+ `qwen`（阿里百炼，qwen3.8-flash 带视觉/档位、DeepSeek 用 **`deepseek-v4-flash-0731` 冻结快照**带 7 档含 off）
- 默认模型：`agentrouter / gpt-5.6-sol`（reasoningEffort: high），可在 GUI 模型选择器随时切换
- 验证脚本：`~/md/供应商配置/check-settings.mjs`（dev 版同源校验，见第 5 节）
- DSH 服务器进程不认 `HTTPS_PROXY`，**所有被墙上游统一走本地反代**，不要尝试给 dsh web 进程塞代理环境变量

---

## 10. 阿里百炼 qwen 供应商实测记录（2026-08-27）

- 端点：`https://ws-<实例id>.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`（compatible-mode = OpenAI 兼容，国内直连无需反代）
- `/v1/models` 清单含：`qwen3.8-flash / qwen3.8-27b / qwen3.8-max / qwen3.8-2.4t-a95b / kimi-k3 / ZHIPU/GLM-5.3 / qwen-image-3.0(pro) / deepseek-v4-pro-0813 / deepseek-v4-flash-0731` 等
- 踩坑结论（全部实测）：
  - **`developer` 角色被拒**（400：`developer is not one of ['system','assistant','user','tool','function']`）→ 路由必须 `compat: { supportsDeveloperRole: false }`，否则带系统提示的请求必挂
  - **qwen3.8-flash 是视觉多模态**：图片识别实测可用（`usage.image_tokens` 计费）；图片最小边长 > 10px（1×1 报 `must be larger than 10`）；DSH 模型条目声明 `input: [ text, image ]`
  - **官方参数（阿里云 Model Studio 文档，2026-08-29 核对）**：上下文长度 **1000000（1M）**、最大输出长度 **131072（128K）**（思考模式下同为 131072）；实测 `max_tokens=200000` 报错 `Range of max_tokens should be [1, 131072]` 印证。**DSH 条目应写 `contextWindow: 1000000` + `maxTokens: 131072`**（曾误填 512000/32000，已修正）
  - **音频不能 base64 直传**（400 URL 无效）：百炼兼容模式音频要走 uploads 接口拿 `audio_id`
  - **思考控制**：`reasoning_effort: "none"` = 关思考（实测无 reasoning_content）；`minimal/low/medium/high/max` 全档位 200 且开思考；默认（不传参）也是开思考
  - 当前配置：`contextWindow: 1000000` + `maxTokens: 131072` + `input: [ text, image ]` + `reasoningEfforts: { off: none, minimal: minimal, low: low, medium: medium, high: high, max: max }` + `compat.supportsReasoningEffort: true`
- 同端点 **DeepSeek V4 Flash 主线 vs 0731 快照**（2026-08-29，阿里云 Model Studio 官方文档 + 端点实测双核）：
  - **版本策略**：不带日期的 `deepseek-v4-flash` = **持续迭代主线版**；`deepseek-v4-flash-0731` = 独立挂名的**冻结快照版**（更贵：主线输入 $0.138/百万 tokens vs 快照 $0.212 起）。模型规格：轻量化 MoE，总参 284B / 激活 13B
  - ⚠️ **思考控制反转（重要，两版白名单不同，实测铁证）**：
    - 主线 `deepseek-v4-flash` 白名单只有 `low/medium/high/xhigh/max` —— **`none`/`minimal` 被 400 拒绝，恒思考、无法关思考**（`enable_thinking:false` 技术上可关，但 pi-ai 默认分支发不了该参数）
    - 快照 `deepseek-v4-flash-0731` 白名单是 `none/minimal/low/medium/high/xhigh/max` —— **支持 off（`reasoning_effort:none` 实测 reasoning_tokens=0）+ minimal**，反而更完整
    - 结论：**要能关思考 / 要可复现就选 `-0731`**（本机 qwen 路由已选它）；用主线名则最少 low 且吃迭代更新
  - **纯文本模型**（两版一致）：图片输入被静默丢弃（usage 无 image_tokens、官方能力表输入/输出模态均 Text），**不要声明 `input: [text, image]`**
  - **官方参数**：上下文长度 **1000000（1M）** / 最大输入 1000000 / **最大输出长度 393216**
  - 当前配置（qwen 路由 → 0731 快照）：`contextWindow: 1000000` + `maxTokens: 393216` + `reasoningEfforts: { off: none, minimal: minimal, low: low, medium: medium, high: high, xhigh: xhigh, max: max }`
- **dsv4 的 vision 版在哪（2026-08-29 实测）**：
  - **百炼端点没有 v4 vision**：deepseek 全系（flash / pro / 0731 / 0813 / vanchin / siliconflow）均为纯文本；`vanchin/deepseek-ocr` 是 OCR 专用模型，不算通用视觉
  - **DeepSeek 官方 API 有**：`deepseek-v4-flash-vision-exp`（官方 `/v1/models` 就 3 个：`deepseek-v4-flash` / `deepseek-v4-pro` / `deepseek-v4-flash-vision-exp`）。实测：16×16 绿图正确答"绿色"；`reasoning_effort` 白名单 7 档 `none/minimal/low/medium/high/xhigh/max`（none 真关思考）；`max_tokens` 384000+ 通过；system 角色 OK；输出侧 usage 无 image_tokens 字段（不影响识别）
  - **DSH 侧开箱即用**：`deepseek-official` 路由（`llm-deepseek` + `DEEPSEEK_API_KEY`）内置目录已含该模型（`inputModalities: ['text','image']`、默认 1M 上下文、effort off/low/high/max 默认 high、图片预算已配），GUI 直接选 **DeepSeek → DeepSeek-V4-Flash-Vision-Exp**，无需改 settings