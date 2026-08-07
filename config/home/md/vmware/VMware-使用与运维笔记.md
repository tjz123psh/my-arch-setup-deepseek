# VMware Workstation 使用与运维笔记（Arch Linux）

> 记录 2026-08-07 从 KVM 转战 VMware 的安装、踩坑与运维要点。
> 系统：Arch Linux（linux-zen 7.1.6），AMD Ryzen 7 7735H + Radeon 680M + RTX 4050，内存 14Gi。

---

## 0. 背景：为什么从 KVM 转到 VMware

- **KVM 无直通时图形体验差**：virgl = GL 命令双层翻译（guest Mesa → virglrenderer → host GPU），加上 SPICE 通路延迟，桌面"卡"是结构性的；
- **host AMD 680M 核显内核级不稳定**（gfxhub page fault → ring timeout → GPU reset），导致 host 的 niri 和 KVM 的 QEMU 成对崩溃——这是 host 显卡驱动问题（与 Mesa 26.1.5/26.1.6 版本无关），不是 KVM 的错；已升内核 7.1.6，持续观察；
- VMware 的 SVGA3D 是专有、为桌面调优多年的路径，图形体验更好（代价是 CPU/IO 略逊 KVM）。

## 1. 安装

```bash
paru -S vmware-workstation   # AUR 包，当前 26H1-3，活跃维护
```

- 依赖（gtkmm3、gcr、libxcrypt-compat 等）paru 自动补装；需已装 `linux-headers` / `linux-zen-headers`（模块编译用，均已装）；
- **Workstation Pro 个人免费**：安装时按提示注册免费许可即可。

## 2. 内核模块与系统服务

```bash
sudo modprobe vmmon vmnet          # 基本模块
```

⚠️ **单元名注意**（踩过坑）：
```bash
sudo systemctl enable --now vmware-networks.service vmware-usbarbitrator.service
```
- **没有 `vmware-vmnet.service` 这个单元**！正确是 `vmware-networks.service`；
- `vmware-networks-configuration.service` 是 static（oneshot），不用单独 enable；
- AUR 包的 dkms 只编译 **vmmon + vmnet**（`/usr/src/vmware-workstation-26H1_*/dkms.conf` 只有这两个）；
- `vmware-modconfig --console --install-all` 在本环境**不可用**（AppLoader 报 GLib 无 GSettings 支持 + 无 vmware.service），别依赖它。

## 3. vmci 报错与修复（重点踩坑）

**现象**：开机报
```
Unable to change virtual machine power state: Failed to open device "/dev/vmci"
Please make sure that the kernel module 'vmci' is loaded.
```

**原因**：AUR 包**没带 vmci 模块**（dkms 只编 vmmon/vmnet），而新建的 VM 默认 `vmci0.present = "TRUE"`。

**修复步骤**（顺序很重要）：
1. **先关闭 VMware GUI**（或关掉该 VM 的标签页）——否则 VMware 会把你的文件修改**回写覆盖**（实测：开着界面改文件，改完 1 分钟被覆盖回 TRUE）；
2. 编辑 VMX 文件，把 `vmci0.present = "TRUE"` 改成 `"FALSE"`；
3. 重新打开 VMware → 开机。

本机 VMX 路径：`~/Public/虚拟机1/Other Linux 6.x kernel 64-bit/Other Linux 6.x kernel 64-bit.vmx`

**影响**：VMCI 主要用于 vSockets 通信，关掉对桌面 VM 无实际影响。

备份：`.vmx.bak`、`.vmx.bak2`。

## 4. 语言问题（界面不支持中文）

- VMware Workstation **Linux 版界面是英语-only**：包里 0 个翻译文件（`.mo`/`.qm`/`.msg` 全无），UI 字符串编译在二进制里；
- **没有可用的 Linux 版第三方汉化包**（汉化需要改二进制，网上汉化只做 Windows 版改 DLL 资源）；
- 方案：接受英文界面；guest 内中文不受影响（guest 自己的 locale + fcitx5 照常）。

## 5. AI/脚本自主管理（vmrun）

```bash
vmrun list                                   # 列出运行中的 VM
vmrun start <xxx.vmx> nogui                  # 无头启动
vmrun stop <xxx.vmx>                         # 关机
vmrun snapshot <xxx.vmx> <名字>              # 快照
vmrun revertToSnapshot <xxx.vmx> <名字>      # 回滚
vmrun runProgramInGuest -gu <用户> -gp <密码> <xxx.vmx> <程序>   # guest 内执行命令
vmrun copyFileFromHostToGuest / copyFileFromGuestToHost          # 文件进出
```

- guest 内命令/文件操作依赖 **open-vm-tools** + guest 凭据；
- 更顺的方式：guest 内开 **SSH**，直接走 SSH 操作。

## 6. 性能相关设置

| 位置 | 项 | 说明 |
|---|---|---|
| Preferences → Workspace | **Keep VMs running after Workstation closes** | 勾上：关界面 VM 后台继续跑，释放 host 内存（14Gi 机器有用） |
| Preferences → Memory | 内存分配/整理策略 | host 内存紧张时值得看 |
| Preferences → Priority | VM 进程 CPU 优先级 | 默认即可 |
| VM → Settings → Processors/Memory | CPU 核数/内存 | 本机 VM：4 vCPU（2/socket）、4GB |
| VM → Settings → Display | **Accelerate 3D graphics** | 已勾选（3D 加速） |

当前 VM 配置：`numvcpus=4`、`memsize=4096`、`svga.supports3D=1`、1920×1080。

## 7. 已知问题与待办

- [ ] guest 内装 **open-vm-tools**（剪贴板/分辨率自适应/拖拽）
- [ ] 观察 host 核显稳定性（内核 7.1.6 已升，是否还 GPU reset）
- [ ] VMware 今天崩过一次（coredump 里有 `mksSandbox`、`vmware-vmx` 记录）——如后续不稳定再查
- [ ] 如需后台跑 VM：勾 Preferences 里的 "Keep VMs running"

## 8. 附录：今日 KVM 工作归档（供回滚参考）

- **根因**：host AMD 680M 核显内核级不稳定（页错误/ring timeout/GPU reset，无 VM 时也发生），用户态 libgallium abort 只是被重置后的后果；
- **已做的 KVM 优化**（VM 定义在 `/etc/libvirt/qemu/archlinux.xml`）：blob+hostmem（`-global virtio-vga-gl.blob=on,hostmem=1G`）、io_uring+iothread×2+4 队列、内存 6→5Gi、vCPU 拓扑 1×8×1、guest 特效降级（niri 阴影/模糊关闭，备份 `config.kdl.bak-opt`、`settings.json.bak-opt`）；
- **回滚点**：`~/archlinux.xml.bak`（改动前原始配置），`virsh define ~/archlinux.xml.bak` 可还原；
- **清理**：今日临时文件/coredump 已清；`~/KVM-性能与渲染优化计划.md` 保留完整调查记录。

## 9. VM 测试模式（host 快捷键让路给 VM）

> 背景：在 VMware 里测试"一键安装"产出的同款键位系统时，host 的 niri 会在合成器层拦截相同快捷键（如 `Alt+Q`），键到不了 VM。

**方案：手动开关版**（无守护进程、无鼠标检测，纯配置切换）：

| 快捷键 | 作用 |
|---|---|
| `Super+Shift+D` | 进入测试模式 = host 快捷键全关、按键全部透传 VM；再按一次恢复 |

- 机制：两份 niri 配置互相切换——`~/.config/niri/config.kdl`（完整）+ `~/.config/niri/config.kdl.vmtest`（快捷键全禁用，只留开关键），通过 `niri msg action load-config-file --path` 热重载；
- 测试配置由 `~/scripts/desktop/niri-vmtest-gen` 生成，**改过 config.kdl 后需重跑一次刷新**；
- ⚠️ 必须点击 VMware 窗口**中间的屏幕区域**键盘才进 guest（侧边栏/工具栏是 VMware 自己的 UI）；
- ⚠️ VM 全屏时先按 `Ctrl+Alt` 释放键盘，再按 `Super+Shift+D`；
- 备份：`~/.config/niri/config.kdl.bak-vmtoggle`。
