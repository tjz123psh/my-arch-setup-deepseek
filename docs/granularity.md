# VM vs 物理机 安装颗粒度（代码事实）

两机型共用同一 11 步模块流水线（01-mirror → 09-settings + 99-cleanup），差异
仅在模块内部按 `MACHINE_TYPE` / `module_selected()` 的过滤与模拟标记层。
清单数字随增改变化，**以 `./check-extend.sh` 的 reconcile 输出为准**。

| 颗粒度点 | 虚拟机（`-t vm`） | 物理机（`-t physical`） |
|---|---|---|
| 模块流水线 | 11 步同构；04-drivers 自跳过（exit 0） | 11 步同构 |
| 机型过滤（`module_selected()`） | `virtualization-vmware-guest` 仅 vm（open-vm-tools 等） | `virtualization-vmware-host` 仅 physical（vmware-workstation 等）；硬件包（graphics-*/hardware-tools/asus-hardware）在 03 两机型都排除，归 04-drivers |
| AUR 目标 | 11（不含 vmware-workstation） | 12（含 vmware-workstation）；vmware-keymaps 是构建依赖、非安装目标（offline 引导安装 / online 由 paru 解析） |
| 驱动（04） | 跳过 | 真实安装；`physical-sim-vmware` 模拟时硬件专属效果标 `NOT_APPLICABLE_SIMULATED`（supergfxd enable、GPU mode switching、vmware-networks/usbarbitrator enable） |
| 配置（07） | SCOPE=`physical-v1` 共用；唯一门控例外：`asus-hardware` 行（rog-control-center.cfg）在 vm 被跳过 | 全量部署 |
| 服务（08） | 共享服务集（docker/grub-btrfsd/bluetooth 等，两机型都启用）+ `vmtoolsd`（必需）+ `vmware-vmblock-fuse`（可选） | 共享服务集 + `vmware-networks`/`vmware-usbarbitrator`（VMware host）；supergfxd 归 04-drivers |
| 设置（09） | 软件 GL（`systemd-detect-virt==vmware` 时写 `LIBGL_ALWAYS_SOFTWARE=1`）；录屏 wf-recorder | 同上；`h264_vaapi` 录屏预置仅真实物理机（非 VMware guest）启用 |

验证依据：2026-08-11/12 干净 base（快照恢复）两轮完整安装——离线挂载法
（`mode=offline targets=12`，零网络下载）与在线（`mode=online targets=12`，
paru 最新）均 11/11 步全绿、AUR 12/12、07 部署 253 文件；详见
`docs/physical-offline-install.md` 验证记录。物理机最终确认仍需在真实 ASUS
主机跑一次（仿物理 profile 不能替代硬件验收）。
