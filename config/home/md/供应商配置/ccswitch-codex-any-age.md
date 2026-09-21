# cc-switch Codex（any / age）可用方案

> 更新：2026-08-17（最终可用版，已实测）

## 现状

- **两个供应商均已配置并验证可用**，前提：Clash 代理（`127.0.0.1:7890`）保持运行。
- 当前供应商：**any**（在 cc-switch GUI 内切换）。
- 上游现状：age 正常回答；any 的 `gpt-5.6-sol` 通道偶尔回 `500 负载已经达到上限`（上游限流），等通道恢复即可，非配置问题。

## 方案构成（3 个部分，均已就位）

1. **cc-switch 数据库模板已修正**（`~/.cc-switch/cc-switch.db` → `providers` 表）：any / age 均为 `env_key` + 带 `/v1` 的 `base_url`，切换供应商时不会被旧模板覆盖。
2. **fish 环境变量**（`~/.config/fish/conf.d/`）：
   - `age-env.fish` → `AGE_API_KEY`
   - `anyrouter-env.fish` → `ANYROUTER_API_KEY`
   - `proxy-env.fish` → 仅当 7890 有监听时注入 `HTTPS_PROXY` / `HTTP_PROXY`
3. **codex 包装脚本**（`~/.local/bin/codex`，PATH 最前）：任何终端、任何方式启动 codex 都自动注入代理环境变量，再执行真正的 codex。**这是兜底，日常不需要手动 export。**

## 日常使用

```fish
# 保持 Clash 运行 → 直接启动
codex
# 切换供应商
#   在 cc-switch GUI 切换，config.toml 会自动按模板重写，无需手动改
```

预期：age 直接回答；any 若遇上游限流会看到明确的"负载达到上限"提示（codex 会重试几次后显示），等待上游恢复即可。

## Grok 部分（tabi + seek 供应商的 claude-opus 模型）

**tabi**（`claude-opus-5-thinking` / `claude-opus-4-8-thinking`）与 **seek**（`claude-opus-5` / `claude-opus-4-8`）均**可用，已实测**（2026-08-18，grok headless 返回 OK）。配置在 `~/.grok/config.toml`，结构相同：

```toml
[model.claude-opus-5-thinking]        # tabi 例
model = "claude-opus-5-thinking"
base_url = "https://tabitoken.com/v1"
name = "Claude Opus 5 Thinking (tabi)"
api_backend = "messages"              # 必须 messages：两家上游的 openai/responses 协议都不可用
auth_provider = "tabi"
extra_headers = { "anthropic-version" = "2023-06-01" }
context_window = 1000000              # 1M

[auth_provider.tabi]
command = "bash"
args = ["/home/pang/.grok/libexec/secret-file-auth-provider.sh", "/home/pang/.local/share/grok/secrets/tabi-api-key"]
timeout_secs = 5
# seek 同结构：base_url = https://seekai.cc/v1，auth_provider = "seek"，key 文件 secrets/seek-api-key，
# model = claude-opus-5 / claude-opus-4-8
```

鉴权方式与 deepseek 相同（key 不在环境变量/配置明文里）：key 存 `~/.local/share/grok/secrets/{tabi-api-key,seek-api-key}`（0600 权限），由通用脚本 `~/.grok/libexec/secret-file-auth-provider.sh <key路径>` 读取输出。已实测清空相关环境变量后四个模型仍正常返回。

现状说明：
- **tabi**：快（2s），视觉已实测可用（两个 thinking 模型均正确识别图片颜色）；Cloudflare 防护对 grok 无影响（curl 需浏览器 UA 才有 JSON）。
- **seek**：可用但**慢**（单轮 12~19s，grok 实测两条各返回 OK）；视觉未单独实测（同为 messages 通道，预计可用）。
- 模型目录里还有 `claude-opus-4-8`（非 thinking），`supported_endpoint_types = ["anthropic","openai"]`。
- 代理兜底 `~/.local/bin/grok` 保留（自动注入 7890 代理）。
- age（agentrouter）的 opus 模型因上游客户端指纹限制，grok 不可用，配置已删除不再重复。

## 维护注意事项

- **供应商配置以 cc-switch DB 模板为准**：修改必须落进 `settings_config.config`，只改 `~/.codex/config.toml` 会在下次切换时被覆盖。
- 改完模板后**重启 cc-switch**（GUI 启动时缓存模板）。
- 两个不要：不要改回 `requires_openai_auth = true`（会拿错 key → 401）；不要去掉 `base_url` 的 `/v1`（会打到 `/responses` → 上游不认）。
- codex 代理只认环境变量，config.toml 里的 proxy 键（`network_proxy` 等）无效，改用包装脚本或环境变量。