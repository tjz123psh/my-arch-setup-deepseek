# DeepSeek Harness (dsh) 已安装插件清单

> profile：`web`　|　dsh 版本：0.1.1-rc.2（npm 最新发布版）　|　记录日期：2026-08-23
> 环境前提见《dsh安装指南》与《dsh记忆系统安装说明》。

---

## 一、当前已安装插件

| 插件 | 版本 | 安装方式 | 功能 | 使用入口 |
|---|---|---|---|---|
| **dshmarket** | ^1.18.1 | npm | 内嵌插件市场：搜索/一键安装/升级/主题切换 | 设置 → 插件市场 |
| **dsh-better-sidebar** | ^0.15.2 | npm | 右侧栏工作台：文件树/编辑器/终端/Git/浏览器，按会话隔离 | 右侧栏（终端依赖 node-pty，已源码编译） |
| **dsh-archive-manager** | 0.1.10 | GitHub（MeSun424） | 归档工作区管理：删除工作区→整体归档（会话不再散落未分组）、整项目/全部一键真删、恢复 | 设置 → Archived chats |
| **dsh-universal-attachments** | ^0.1.1 | npm | 文件上传：任意文件/文件夹拖进窗口即传，发送前预览，文件落当前会话工作区 | 拖放文件到窗口任意位置 |

## 二、安装命令（可复制）

```sh
dsh plugin --profile web add dshmarket
dsh plugin --profile web add dsh-better-sidebar
dsh plugin --profile web add github:MeSun424/dsh-archive-manager
dsh plugin --profile web add dsh-universal-attachments
```

卸载同名包：`dsh plugin --profile web remove <包名>`。

## 三、注意事项

1. **装/卸后必须重启服务**：组合树在进程启动时固化，仅刷新页面无效。
   ```sh
   ~/scripts/dsh/dsh-web.sh --stop && ~/scripts/dsh/dsh-web.sh
   ```
2. **验证挂载**（三件套）：`package.json` dependencies、`dsh.profile.bundles`、`dsh --profile web --dump-config | grep <包名>`。
3. **peer 警告属正常**：@deepseek-ai/* 系列 peer 由核心 bundle 运行时提供，pnpm 检查不到不代表缺失。
4. 插件安装/故障排查 SOP 见《dsh记忆系统安装说明》中的技能 `dsh-plugin-management`；dsh 本体的版本/升级/回滚与平台侧补丁见技能 `dsh-upgrade`。

## 四、历史记录

| 日期 | 操作 |
|---|---|
| 2026-08-23 | 安装 dshmarket、dsh-better-sidebar（含 node-pty 源码编译修复） |
| 2026-08-23 | 安装 dsh-session-delete（xohmai）→ 同日因与 archive-manager 功能重叠**卸载** |
| 2026-08-23 | 安装 dsh-archive-manager（MeSun424，替代 session-delete）、dsh-universal-attachments |
