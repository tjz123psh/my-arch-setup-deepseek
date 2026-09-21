# Obsidian 自动同步 Google Drive（5TB）配置文档

## 1. 方案概述

* **目标**：实现本地 Obsidian 学习笔记库（`/home/pang/obsidian/学习笔记`）向 Google Drive 5TB 云端（`gdrive:Obsidian/学习笔记`）的全自动、无感、增量同步备份。
* **核心架构**：`rclone` + Linux 原生 `systemd --user` 定时调度 + 本地代理注入（`127.0.0.1:7890`）。
* **同步策略**：
  * **增量备份**：使用 `rclone copy`，只上传本地新增或修改的文件，已存在且无改动的文件秒级跳过。
  * **防误删保护**：采用 `copy` 而非硬镜像 `sync`，即使本地不慎误删某篇笔记，云端依然保留历史副本，安全冗余高。
  * **执行频次**：开机 2 分钟后触发首次检查同步，此后**每隔 15 分钟**在后台静默增量同步一次。
  * **零资源干扰**：无图形客户端常驻窗口，不占用桌面托盘与多余内存。

---

## 2. 配置文件明细

### (1) 同步任务服务单元
* **文件路径**：`~/.config/systemd/user/obsidian-sync.service`
* **配置内容**：

```ini
[Unit]
Description=Obsidian Notes Sync to Google Drive
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# 关键：systemd 服务默认不继承终端 Shell 代理，必须显式注入代理环境变量以直连 Google API
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="ALL_PROXY=socks5://127.0.0.1:7890"

# 同步命令：本地学习笔记目录 ➔ Google Drive 云端对应目录
ExecStart=/usr/bin/rclone copy "/home/pang/obsidian/学习笔记" gdrive:Obsidian/学习笔记
```

---

### (2) 自动化定时器单元
* **文件路径**：`~/.config/systemd/user/obsidian-sync.timer`
* **配置内容**：

```ini
[Unit]
Description=Timer for Obsidian Notes Sync

[Timer]
# 系统启动 / 用户登录后 2 分钟执行首次同步
OnBootSec=2min
# 每次触发后间隔 15 分钟重复执行
OnUnitActiveSec=15min
# 若关机错过时间段，下次开机立即补跑一次
Persistent=true

[Install]
WantedBy=timers.target
```

---

## 3. 服务启用与管理命令

### 首次部署命令
```bash
# 1. 重新加载 systemd 用户守护进程
systemctl --user daemon-reload

# 2. 启用并立即启动定时器（开机自启）
systemctl --user enable --now obsidian-sync.timer
```

### 日常运维与监控
| 操作需求 | 执行命令 |
| :--- | :--- |
| **查看下次触发倒计时** | `systemctl --user list-timers obsidian-sync.timer` |
| **查看最近同步日志** | `journalctl --user -u obsidian-sync.service -n 20 --no-pager` |
| **想立即手动触发一次同步** | `systemctl --user start obsidian-sync.service` |
| **查看定时器当前状态** | `systemctl --user status obsidian-sync.timer` |
| **暂停自动同步服务** | `systemctl --user stop obsidian-sync.timer` |
| **重新启动自动同步服务** | `systemctl --user start obsidian-sync.timer` |

---

## 4. 核心注意事项与排错指南

1. **代理连接依赖**：
   * 同步依赖本地代理客户端（如 Clash/Mihomo，端口 `7890`）。如果代理断开，同步将出现 `i/o timeout`，系统会在下一个 15 分钟周期自动重试，不会影响本地笔记正常编辑。
2. **rclone 凭证位置**：
   * Google Drive 授权配置文件位于：`~/.config/rclone/rclone.conf`。
   * 对应 remote 名称为：`gdrive:`。
3. **查看云端目录**：
   * 可通过终端快速核对云端文件列表：
     ```bash
     rclone lsf gdrive:Obsidian/学习笔记
     ```
   * 也可直接登录网页端 [Google Drive](https://drive.google.com/) 查看 `Obsidian/学习笔记` 文件夹。
