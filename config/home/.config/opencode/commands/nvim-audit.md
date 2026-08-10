---
description: 检查并完善本机 Neovim 配置，包含 health、LSP、快捷键、格式化和本地文档同步。
agent: sisyphus-prometheus
---

检查本机 Neovim 配置。配置范围为 `~/.config/nvim`，文档范围为 `~/md/nvim`。

要求：

1. 先读取 `config-auditing` 和 `neovim-arch`。只有发现明确报错、快捷键/LSP/UI 症状时加载 `neovim-debugging`；只有用户确认“以前修过/又复发”或症状匹配历史记录时加载 `nvim-troubleshooting`。
2. 检查 `~/.config/nvim` 的结构、插件、LSP、快捷键、health warning 和历史问题。
3. 修改配置后同步 `~/md/nvim`；涉及快捷键、命令或架构时更新对应文档和 skill。
4. 至少运行：
   - `nvim --headless '+checkhealth' '+write! /tmp/nvim-health.txt' '+qa'`
   - `find ~/.config/nvim -type f -name '*.lua' -print0 | xargs -0 ~/.local/share/nvim/mason/bin/stylua --check`
5. 复核 `~/md/nvim` 与当前配置行为一致，不复制整份配置树。
6. 最终说明配置类问题是否清空，剩余 warning 是否只是系统可选依赖。

用户补充要求：

```text
$ARGUMENTS
```
