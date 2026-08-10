# 下载模式实验 checkpoint

更新时间：2026-08-08（Asia/Shanghai）

## 当前目标

改善安装下载模式，但先在 `download-mode-lab/` 验证；在用户明确批准前不接入主安装器、
不修改宿主配置、不操作任何 VM。

## 已完成

### 第一步/第二步（主工作树已有 dirty diff）

- 默认不再由 `scripts/01-mirror.sh` 写入外部 `XferCommand`，保留 pacman native
  downloader 与 `ParallelDownloads`；历史提交为 `5964752`。
- 镜像配置先于首次官方同步；`01-mirror.sh` 不负责 pacman sync，`02-system.sh` 负责
  唯一官方 `-Syu`（`FORCE_REFRESH=1` 才 `-Syyu`）；archlinuxcn 配置后只同步一次。
- fzf 缺失时使用无网络依赖的纯文本选择。
- 主项目行为/清单/FlClash/Neovim 回归仍通过（见最终报告）。

### 第三步（仅实验目录）

- `bin/mirror-plan.py`：
  - official 与 archlinuxcn 独立排序；package/database/throughput/latency lane 不混合；
  - package > database-range > throughput > latency，重复样本取中位数；
  - `OK`、`RANGE_UNSUPPORTED`、`UNAVAILABLE`、超时和不完整样本分开；
  - stale、future、invalid、全部不可用和 fallback 不足均 fail closed；
  - `degraded` 默认非零，`--allow-degraded` 也不把 `applyable` 改成 true；
  - 严格 URL/仓库/HTTP/exit/range 字段校验，诊断只输出有限 `error_class`；
  - finite 数值、时间边界、JSON 解码/UTF-8/序列化失败均转成 invalid 报告；
  - 只做原子输出，不调用 pacman、shell 或 root。
- `bin/probe-ranges.py`、`bin/probe-package-ranges.py` 显式输出：
  `206 → OK/range_supported=true`、`200 → RANGE_UNSUPPORTED/false`、其他失败 →
  `UNAVAILABLE/false`。
- `tests/mirror-plan-test.py`：**41/41 PASS**；包含真实两个 probe 函数的 mock contract。
- `03-mirror-plan.md`、`README.md`、`FINAL.md` 已更新当前边界与证据。

## 验证证据

以下均在本工作区内执行，没有安装包、写 `/etc`、改服务或操作 VM：

```text
bash download-mode-lab/run-lab.sh       # 连续两轮均通过
  Python syntax PASS
  download integrity 20/20 PASS
  AUR queue model PASS（jobs=3，约 2.7x 模型收益）
  native stall 非零超时语义 PASS（约 10 秒）
  mirror-plan 41/41 PASS
  source-cache-audit = defects_confirmed（缺陷证据，不是健康 PASS）

第二轮/第三轮真实只读官方 + archlinuxcn HEAD、数据库 Range、实际包 Range：
  第三轮 HEAD 15 OK；database Range 12 OK / 1 UNAVAILABLE / 2 RANGE_UNSUPPORTED；
  package Range 12 OK / 3 UNAVAILABLE；planner dry-run = status=ok, applyable=true；
  当前样本只保留在 fixtures/tmp/final-verification/。

gitleaks --no-git（download-mode-lab）= PASS；git diff --check = PASS；Python AST/syntax = PASS。
```

主项目隔离回归（未触碰宿主）：

```text
pacman-sync-order       17 passed, 0 failed
installer-behavior      36 passed, 0 failed
workstation reconciliation PASS（install=191 verify=12 deferred=8 mappings=231 recipes=15）
flclash migration       PASS
nvim config              PASS
```

独立 reviewer 已完成 blocker-only 复核，结论：**无阻断发现，可进入 integration
review**。reviewer 没有在只读环境独立运行会写临时结果的完整 41 项测试；该检查不记作
PASS，本地两轮完整执行才是 41/41 证据。

## 未完成 / 不可用 / 明确不宣称

- planner 尚未接入 `scripts/01-mirror.sh`，没有 host mirrorlist apply、备份或回滚记录；
- 没有真实 `pacman -Sw`、AUR 全链路、VMware bundle/ISO 断点恢复前后对照；
- 没有 VM、仿物理或物理机实战测试，也没有 Hyprland/DMS 在 VMware 3D/Wayland 下的
  登录/重登验收；
- ShellCheck 选定脚本有 warning/info（SC2034、SC1091 等），全仓仍有既有 SC1087；
  ShellCheck 非全绿不能写成 clean；
- ruff/pyflakes/pylint 未安装，属于 **UNAVAILABLE**，没有用“无输出”解释为通过；
- 当前工作树包含第二步及既有 dirty diff，未提交、未用全局 restore/reset/clean 覆盖。

## 安全与回滚状态

- 未读取、保存或输出密码/token/cookie/private key；未安装 aria2/axel/wget2；
- 未修改宿主 `/etc/pacman.conf`、`/etc/pacman.d/mirrorlist`、服务、网络、内核或 GRUB；
- 未启动/停止/快照/revert/修改/删除任何 KVM/VMware 资产；
- 第三步没有主代码 apply，因此没有宿主回滚需求；实验新增文件可按文件级 diff 回滚，
  不得对当前工作树做全局 reset。

## 唯一下一动作（需用户明确批准）

先展示只涉及 `scripts/01-mirror.sh` 的最小 integration **dry-run/forward+rollback
patch**，只回答：

1. 如何在首次同步前运行受限探测并读取 `status/applyable/expires_at`；
2. 如何在 `ok` 时分别原子写官方/archlinuxcn mirrorlist，在其他状态保留旧配置；
3. 备份位置、权限、失败恢复和不覆盖旧配置的证明；
4. fake-root/pacman mock 回归命令与预期失败注入；
5. 不顺便修改 AUR、keyring、服务、桌面、宿主或 VM。

**不要直接修改主代码或 `/etc`。** 展示 diff、测试和回滚命令后停下，等待用户明确批准
integration；批准前不做任何 apply。

## 工作树与回滚提示

- HEAD：`aa81105`；主工作树已有 dirty diff，至少包含 `install.sh`、`scripts/00-utils.sh`、
  `scripts/01-mirror.sh`、`scripts/02-system.sh`、`scripts/03-packages.sh` 及第二步测试；
  不得用全局 `git restore/reset/clean` 覆盖。
- 第三步实验新增/修改范围：
  `download-mode-lab/bin/mirror-plan.py`、`download-mode-lab/tests/mirror-plan-test.py`、
  `download-mode-lab/bin/probe-ranges.py`、`download-mode-lab/bin/probe-package-ranges.py`、
  `download-mode-lab/03-mirror-plan.md`、`download-mode-lab/README.md`、`download-mode-lab/FINAL.md`、
  `download-mode-lab/CHECKPOINT.md`、`download-mode-lab/NEXT-STEP-PROMPT.txt`，以及
  `results/mirror-plan-test.json`。
- 第三步没有 host mirrorlist 备份、apply 记录或 rollback 需求。若后续获批主代码集成，
  必须先在工作区内保存**只含该步**的 forward/rollback patch 和不含凭据的 fake-root
  证据；不得直接 revert 整个 `5964752` 或当前 dirty diff。
