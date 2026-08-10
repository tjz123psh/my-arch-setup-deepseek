# share —— 共享资源

## 一、是什么

供其他脚本复用的共享资源目录（当前主要是 package/paru-ui 使用的提示词文件）。

## 二、有什么作用

| 路径 | 作用 |
|---|---|
| `prompts/aur-review.md` | paru-ui 的 AUR 安全审查提示词：让 opencode 按严格清单逐行审查 PKGBUILD 及 .install / patch / systemd unit 等配套文件，输出风险等级与 `PAC_DECISION` 机器可读决策，安装前拦截中高风险 AUR 包 |
