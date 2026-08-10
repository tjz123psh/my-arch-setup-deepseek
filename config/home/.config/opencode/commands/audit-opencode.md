---
description: 只读审计全局 opencode 配置、agents、skills、commands、provider 凭据引用和验证命令。
agent: sisyphus-prometheus
---

只读审计本机全局 opencode 配置。范围固定为 `~/.config/opencode`，不要修改用户项目代码或 OpenCode 配置。

要求：

1. 先读取 `~/.config/opencode/opencode.json` 与 `~/.config/opencode/docs/` 下的 `README.md`、`instructions.md`、`changelog.md`。
2. 检查 `agents/`、`commands/`、`skills/` 的结构是否符合当前 opencode 规范。
3. 检查配置中是否有明文密钥；允许 `{env:...}` 和 `{file:...}`，不要打印 secret 文件内容。
4. 运行：
   - `node -e "JSON.parse(require('fs').readFileSync('/home/pang/.config/opencode/opencode.json','utf8'))"`
   - `~/.config/opencode/scripts/check-config.sh`
   - `~/.config/opencode/scripts/check-skills.sh`
   - `opencode agent list --pure`
5. findings 优先按严重度排序；每项注明位置、触发条件、证据和建议的最小修复。除非用户在后续消息明确要求修复，否则不要修改文件、安装依赖或改变认证/配置。

用户补充要求：

```text
$ARGUMENTS
```
