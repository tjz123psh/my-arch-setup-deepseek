# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的、可审计且可恢复的 Arch Linux 桌面配置项目。
它不是通用发行版安装器，而是在手工完成磁盘、基础系统、GRUB、首次启动和首次联网后，
继续恢复软件包、桌面会话、个人配置与受控系统动作。

> **当前状态：规范化生产路径已经通过一次性虚拟机验证；物理主机尚未执行 apply。**
> 项目显式映射 198 个配置文件，其中 `physical-v1` 162 个、`vm-v1` 36 个；
> 经过隐私清理的 Neovim 配置共 42 个文件。生产就绪登记为
> 9 个 `available`、21 个 `planning`、2 个 `unavailable`。

## 项目边界

使用者需要先手工完成：

1. 分区、格式化和挂载；
2. Arch 基础安装；
3. GRUB 与双系统处理；
4. 首次启动；
5. 启动 NetworkManager，并建立可用的网络与 DNS 连接。

项目从上述交接点之后开始工作。它不会：

- 分区、格式化磁盘或执行 `pacstrap`；
- 接管内核选择、initramfs、GRUB 或启动项；
- 复制 Wi-Fi 密码、SSH/GPG 密钥、令牌、Cookie 等凭据；
- 无选择地迁移整个 HOME 或 `~/.config`；
- 执行未经审查的远程脚本；
- 默认安装登录管理器。Greeter 仍为 deferred，且不会回退到 SDDM。

Niri 与 Hyprland 是相互独立的一等会话；物理配置默认选择两者，也可只选择其中一个。
Fcitx5/Rime、DMS、个人脚本和设备相关配置均按模块划分。

## 已实现内容

`installer/full-orchestrator.py` 根据已选 profile/module 生成同一条九阶段 DAG：

1. `privilege-wrapper`
2. `official-update`
3. `official-packages`
4. `archlinuxcn-bootstrap`
5. `archlinuxcn-packages`
6. `aur-source-acquisition`
7. `aur-build-install`
8. `user-config`
9. `system-actions`

当前实现还包括：

- 固定哈希的执行清单、适配器和辅助输入；
- system、archlinuxcn、AUR 三项独立确认；
- 全局只读 preflight，以及私有 retry/resume/rerun 状态；
- 固定 AUR recipe、clean-chroot 构建、产物与来源校验；
- 配置备份、显式恢复和并发写入保护；
- Niri、Hyprland、Fcitx5/Rime 与系统动作的自动化检查。

## 验证结论

一次性 VM 已验证 Niri、Hyprland 和双 WM 三种选择，包括九阶段执行、失败后精确重试、
收敛性 rerun、重启、真实会话检查、离线磁盘检查及干净基线回滚探针。
最终双 WM 验证使用 437-member 受控归档，阶段 effect vector 为
`2,1,58,1,2,3,3,34,29`。

这些结果只证明明确的 VM 边界，不代表物理主机已部署或完成硬件验收。
ASUS 混合显卡与输出、Bluetooth、真实音频、休眠/恢复、启动/恢复流程及特权组决策
仍需在物理主机上单独盘点、评审和批准。

## 安全模型

- `--plan` 是零写入模式：不创建运行状态，只展示精确阶段、effect、摘要和 blocker。
- 生产 apply 必须通过固定清单、阶段开关和模块 readiness gate，并获得三项独立确认。
- 所有只读 preflight 在确认和状态写入之前执行；失败查询不会被描述为“空结果”或“健康”。
- 需要 root 的适配器只使用已审查的 `gsudo`/askpass 边界，没有生产环境 `sudo` fallback。
- 已存在的受管目标会先备份；替换过程检查内容、权限、所有者和 inode，并保留恢复路径。
- 私有状态、日志、来源记录和备份位于 `~/.local/state/my-archlinux-setup/`。
- 物理主机变更前必须重新盘点现状、查看只读计划和回滚方案，并再次获得明确批准。

README 故意不提供物理主机 `--apply` 复制粘贴示例。当前完整物理 profile 仍会因
`planning`/`unavailable` 模块 fail closed。

## 常用只读命令

```bash
# 查看 VM 与物理 profile 的规范化计划
python3 installer/full-orchestrator.py --profile vm --plan --json
python3 installer/full-orchestrator.py --profile asus-amd-nvidia --plan

# 审阅完整工作站软件包策略与 Phase C 事务
python3 installer/workstation-package-plan.py --json
python3 installer/phase-c-transaction-preview.py --profile asus-amd-nvidia --json

# 检查当前会话；结果区分 ready、blocked 与 unavailable
python3 installer/phase-c-session-check.py --session niri --json
python3 installer/phase-c-session-check.py --session hyprland --json
python3 installer/phase-c-session-check.py --session niri --selection both --json

# 查看已有配置备份，不执行恢复
python3 installer/config-stage-apply.py --list-backups

# 文档检查与完整静态/模拟验证
python3 tests/docs-check.py
bash tests/static-check.sh
```

`--modules` 会替换 profile 默认选择；确定性依赖会自动加入并显示。
Neovim 首次启动可能从官方 GitHub 获取 lazy.nvim 和锁定插件，Mason/Tree-sitter 之后也可能联网；
这些是编辑器行为，不是 installer apply 行为。

## 仓库结构

- `installer/`：入口、计划器、适配器和只读检查器；
- `manifests/`：模块、软件包、配置、系统动作和生产就绪清单；
- `config/`：经审查并显式映射的配置与模板；
- `third_party/aur/`：固定 AUR recipe 及逐项审查记录；
- `tests/`：静态、模拟、回归和配置解析测试；
- `docs/`：设计决策、审计、实施状态、恢复与 VM 证据。

## 详细文档

- [已确认的持久决策](docs/confirmed-decisions.md)
- [实施状态与剩余门槛](docs/implementation-status.md)
- [模块与生产就绪状态](docs/modules.md)
- [配置映射、部署和恢复](docs/configuration.md)
- [工作站软件包策略](docs/workstation-packages.md)
- [审计结果与处置](docs/audit.md)
- [VM 验证记录](docs/vm-validation.md)
- [当前交接检查点](docs/handoff-20260730.md)
