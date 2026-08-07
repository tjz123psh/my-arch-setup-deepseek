# KVM 虚拟机优化全记录（archlinux VM）

> 本机 KVM 虚拟机从建机到桌面 3D 渲染修复的完整优化过程。
> 最后更新：2026-08-03（桌面 niri 渲染问题已解决）

---

## 1. 背景与目标

- 起因：在虚拟化环境里跑桌面渲染性能不佳，改用 KVM + virt-manager 追求更高性能。
- 目标 VM：Arch Linux（8 vCPU / 6GB 内存，大页加速），用于部署正式项目。
- 当前 VM 内的 niri + DMS 桌面是**临时搭建**，仅为验证 KVM 下 3D 桌面渲染是否可用；正式要部署的内容尚未上来。
- 首台 VM 阶段不做显卡直通。

---

## 2. 环境基线（宿主机）

| 项目 | 值 |
|---|---|
| 系统 | Arch Linux（linux-zen 内核，GRUB 引导，btrfs） |
| 分区 | `/` → subvol=@，`/home` → subvol=@home |
| CPU | AMD 8C16T（Rembrandt APU 系列） |
| GPU | 核显 Radeon 680M + 独显 RTX 4050 Mobile（IOMMU 已开启，kvm_amd 已加载 nested=1） |
| 内存 | 14Gi 物理 + 14Gi swap（宿主日常占用高：kitty 3.3G、opencode×2 1.5G、chrome 等，swap 曾用到 8.9G） |
| 已装软件 | virt-manager 5.1.0、libvirt 12.5.0、qemu-base/qemu-desktop 11.0.3、dnsmasq、edk2-ovmf、virglrenderer 1.3.0（未装 swtpm / tuned） |

**重要命令习惯**：
- `pang` 用户 `virsh` 默认连 `qemu:///session`，系统级 VM 必须用 `virsh -c qemu:///system`
- 需要 sudo 时用 `~/scripts/desktop/gsudo <命令>`（会弹 fuzzel 密码框，避免非交互 shell 卡在密码提示）

---

## 3. 宿主机（机器级）优化

### 3.1 libvirt 默认网络（NAT）

默认网络文件 `/etc/libvirt/qemu/networks/default.xml` 原先是 root 权限且未注册，需手动注册并激活：

```bash
virsh -c qemu:///system net-define /etc/libvirt/qemu/networks/default.xml
virsh -c qemu:///system net-start default
virsh -c qemu:///system net-autostart default
```

- 网络：`virbr0` NAT `192.168.122.0/24`，VM 走 NAT 上网。

### 3.2 大页（HugePages）

目的：减少 VM 内存的 TLB 开销，提升访存性能；大页数量 = VM 内存 / 2MiB（8GB → 4096 页，6GB → 3072 页），外加少量余量。

**sysctl 配置** `/etc/sysctl.d/40-hugepage.conf`：

```ini
vm.nr_hugepages = 3200
```

（初设 4300 对应 8GB 内存 VM = 4096 页 + 余量；2026-08-03 VM 内存降到 6GB 后同步调为 3200 = 3072 页 + 128 余量，释放约 2.2GB 给宿主）

**fstab 挂载**（官方 wiki 做法，`/etc/fstab` 追加，原文件备份在 `/etc/fstab.bak`）：

```
hugetlbfs /dev/hugepages hugetlbfs mode=01770,gid=kvm 0 0
```

**效果**（重启宿主机后验证）：
- `HugePages_Total=3200`，VM 运行时用 3072 页，`Free=128`

**机制说明**：
- 开机即锁定约 6.4GB 大页池，与 VM 开关无关；VM 关闭时 Free 回到 3200，但池仍被锁定
- **代价**：大页激活后宿主可用内存约 4.5GB，VM 运行时注意宿主侧不要开大程序

**撤销方法**（若不需要了）：
```bash
sudo sysctl -w vm.nr_hugepages=0
# 并删除 /etc/sysctl.d/40-hugepage.conf 及 fstab 里 hugetlbfs 一行
```

---

## 4. 虚拟机创建与配置

### 4.1 创建历程

- 用户用 virt-manager 建 VM（XML 写入 `/etc/libvirt/qemu/archlinux.xml` 但**未注册**，用 `virsh define` 修复）。
- 之后 VM 全部修改都走：`virsh dumpxml` → 修改 → `virsh define` 流程。

### 4.2 最终关键配置（XML 摘录）

```xml
<domain type='kvm'>
  <name>archlinux</name>
  <memory unit='KiB'>6291456</memory>        <!-- 6GiB（2026-08-03 由 8GiB 下调，缓解宿主内存压力） -->
  <vcpu placement='static'>8</vcpu>

  <!-- CPU：直通宿主 CPU 特性 -->
  <cpu mode='host-passthrough' check='none' migratable='on'/>

  <!-- 时钟 -->
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='kvmclock' present='yes'/>
  </clock>

  <!-- vCPU 绑定：0-7 绑到宿主 CORE1-4 的兄弟线程（2-9），QEMU 主线程绑 CORE0（0-1） -->
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
    <vcpupin vcpu='4' cpuset='6'/>
    <vcpupin vcpu='5' cpuset='7'/>
    <vcpupin vcpu='6' cpuset='8'/>
    <vcpupin vcpu='7' cpuset='9'/>
    <emulatorpin cpuset='0-1'/>
  </cputune>

  <!-- 内存：禁用气球（避免内存交换抖动），用大页 -->
  <memoryBacking>
    <hugepages/>
  </memoryBacking>
  <devices>
    <memballoon model='none'/>

    <!-- 磁盘：virtio-blk，qcow2 链：活动层 archlinux.snapshot1 → backing archlinux.qcow2 -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none'/>
      <source file='/home/pang/Public/虚拟机1/archlinux.snapshot1'/>
      <target dev='vda' bus='virtio'/>
    </disk>

    <!-- 网卡：virtio -->
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>

    <!-- 显示：virtio-vga-gl + VirGL 3D 加速（关键！见第 6 节） -->
    <video>
      <model type='virtio' heads='1' primary='yes' device='virtio-vga-gl'>
        <acceleration accel3d='yes'/>
      </model>
    </video>

    <!-- SPICE：必须开 GL 并指向宿主渲染节点，listen 必须 none -->
    <graphics type='spice'>
      <listen type='none'/>
      <image compression='off'/>
      <gl enable='yes' rendernode='/dev/dri/by-path/pci-0000:35:00.0-render'/>
    </graphics>

    <!-- 声音 ich9、鼠标 tablet usb、spicevmc 剪贴板通道 -->
    <sound model='ich9'/>
    <input type='tablet' bus='usb'/>
    <channel type='spicevmc'/>
  </devices>

  <!-- 引导顺序：硬盘优先（修复装完系统后又回到 archiso 的问题） -->
  <os>
    <boot dev='hd'/>
    <boot dev='cdrom'/>
  </os>
</domain>
```

要点说明：
- **SeaBIOS 传统 BIOS**（非 UEFI，无 OVMF）；安装系统时引导方式选 BIOS/GRUB，不要选 EFI
- 宿主导入的 ISO：`/home/pang/Public/镜像文件/archlinux-2026.07.01-x86_64.iso`
- 磁盘链：`/home/pang/Public/虚拟机1/archlinux.snapshot1`（196K overlay）→ `archlinux.qcow2`（20GiB 虚拟 / 2.9GiB 已用）

### 4.3 XML 修改标准流程

```bash
virsh -c qemu:///system dumpxml --inactive archlinux > /tmp/opencode/vm.xml
# 修改 vm.xml（python 字符串替换）
virsh -c qemu:///system define /tmp/opencode/vm.xml
```

**坑**：`virsh dumpxml` 默认显示的是 **live 配置**，看持久配置要加 `--inactive`。

---

## 5. 系统安装

- 用 archinstall 安装 Arch Linux。
- 装完重启时 virt-manager 报"域没有在运行"属无害提示（VM 实际已暂停），忽略即可。
- 重启宿主机后大页自动激活，VM 正常运行。

---

## 6. 桌面 3D 渲染问题排查与修复（重点）

### 6.1 问题现象

VM 内用 [pang-arch-vm-setup](https://github.com/tjz123psh/pang-arch-vm-setup) 一键脚本装好桌面（niri + DankMaterialShell + SDDM）后：

> SDDM 登录界面正常，但登录后黑屏 —— dms + niri 渲染不出来。

### 6.2 桌面方案背景

- 桌面栈（临时测试用，非正式项目）：niri + DMS（Arch 包 `dms-shell-niri`）+ SDDM（Pixie 主题）+ fcitx5 雾凇 + kitty/fish/starship
- 启动链：SDDM（tty1）→ `niri-session` → `systemctl --user start niri.service`（`niri --session`，外部 session 模式）→ graphical-session.target → `dms.service` → `dms run --session`
- 注意：VM 内当前未装 qemu-guest-agent、无 uwsm；桌面栈来自一键脚本（pang-arch-vm-setup），仅用于验证渲染。**guest 工具（spice-vdagent / qemu-guest-agent）的安装见 6.8 节（待执行）**

### 6.3 排查过程

**手段**：
- 宿主侧用 qemu-nbd 挂载 VM 磁盘改系统（`archlinux.snapshot1` 属主 libvirt-qemu，权限 600，需 gsudo；改完 `umount /mnt/vm` + `qemu-nbd --disconnect /dev/nbd0`）
- VM 磁盘布局：nbd0p1 vfat(boot) + nbd0p2 btrfs（subvol @=root/@home/@log/@pkg）
- 串口控制台：`virsh -c qemu:///system console archlinux`（pty 会话），登录 pang / 123（测试密码，建议正式使用修改）
- 曾经临时改 `default.target → multi-user.target` 绕过 SDDM 直进 TTY 调试

**发现的假象（值得记录）**：
- 在 TTY/串口（无 seat 的会话）里手动跑 niri 报 `Failed to open session: Function not implemented (os error 38)`（ENOSYS）并 panic —— 这是**无 seat 环境的必然失败**，不能证明真实登录也会失败。真实 SDDM 登录是 seat0 graphical session。
- 真实登录后 niri **没有 panic**（active running），但黑屏。日志关键行：
  - `WARN niri::backend::tty: error adding primary node device, display-only devices may not work: no allocator available for device`
  - `error doing early import: Error::DeviceMissing`
  - `layer_shell: no output for new layer surface, closing`
  - dms `Loaded 0 outputs`
- guest EGL/GBM：`libEGL warning: egl: failed to create dri2 screen` + `NEEDS EXTENSION: falling back to kms_swrast`，renderer=llvmpipe → **EGL 无法初始化 virtio_gpu 硬件 3D**
- guest 有 `virtio_gpu_dri.so` / `virtio_gpu_drv_video.so`，mesa 26.1.6；无 vulkan-radeon

**宿主侧证据**：
- qemu 命令行 `-spice port=0,disable-ticketing=on,image-compression=off,gl=on,rendernode=/dev/dri/by-path/pci-0000:35:00.0-render`（SPICE GL 已生效），但 `-device {"driver":"virtio-vga",...}`（**非 GL 设备**）
- 宿主渲染节点：`pci-0000:01:00.0-render → renderD129`（RTX 4050）、`pci-0000:35:00.0-render → renderD128`（AMD 核显 680M）；SPICE GL 用核显节点
- qemu 11 模块化：`/usr/lib/qemu/hw-display-virtio-vga-gl.so` 存在；libvirt capabilities 缓存 `/var/cache/libvirt/qemu/capabilities/*.xml` 里有 spice-gl / virtio-vga-gl / virtio-gpu-gl-pci 等 flag
- libvirt domcaps 的 video modelType 枚举无 GL 变体（vga/cirrus/vmvga/qxl/virtio/none/bochs/ramfb），所以不能指望 virt-manager 界面自动切换

### 6.4 根因（确认）

VM XML 的 video 段**显式写死 `device='virtio-vga'`（非 GL 版本）**，libvirt 因此生成非 GL 设备、不会自动切换成 GL 变体。连锁反应：

```
非 GL 设备 → guest 内核 virtio_gpu 协商出 -virgl（无 3D）
→ EGL 初始化失败回退 llvmpipe 软渲染
→ niri 无 allocator → DeviceMissing → 无输出 → 黑屏
```

### 6.5 修复（两处 XML 改动）

**改动 1：SPICE 开 GL 并指向宿主渲染节点**（参考 niri issue #2570 的成功案例，listen 必须 `type='none'`）：

```xml
<!-- 改前 -->
<graphics type='spice' port='5900' autoport='yes' listen='127.0.0.1'>
  <listen type='address' address='127.0.0.1'/>
  <image compression='off'/>
</graphics>

<!-- 改后 -->
<graphics type='spice'>
  <listen type='none'/>
  <image compression='off'/>
  <gl enable='yes' rendernode='/dev/dri/by-path/pci-0000:35:00.0-render'/>
</graphics>
```

**改动 2：video 设备换成 GL 变体**：

```xml
<model type='virtio' heads='1' primary='yes' device='virtio-vga-gl'>
  <acceleration accel3d='yes'/>
</model>
```

确认方法（libvirt 会据此生成什么 qemu 设备）：

```bash
virsh -c qemu:///system domxml-to-native qemu-argv archlinux.xml
# device='virtio-vga'  → 生成非 GL 设备
# device='virtio-vga-gl' → 生成 virtio-vga-gl
```

改完后 `virsh define`，`virsh destroy` + `start` 重启 VM，确认新 qemu 进程用 `virtio-vga-gl`。

### 6.5b 坑：SPICE GL 报 `invalid video codec` 的替代方案（egl-headless）

> 补充于 2026-08-05（archlinux VM 重建后验证）。6.5 的 SPICE GL 方案在部分环境下
> 会启动失败，此时用 **egl-headless** 输出 + SPICE 仅作显示通道即可。

**现象**：`virsh start` 报错：

```
qemu-system-x86_64: warning: Spice: ../spice-0.16.0/server/reds.cpp:3685:
  reds_set_video_codecs_from_string: spice: unsupported video encoder gstreamer
qemu-system-x86_64: invalid video codec
错误：内部错误：连接监控的过程中进程退出
```

根因：宿主的 spice-server 与 qemu 的 gstreamer 视频编码器不匹配（`spice: unsupported
video encoder gstreamer`），空 codec 串解析失败。与 VM 配置本身无关。

**替代配置**（SPICE 去掉 gl，改为 egl-headless 承载 GL 渲染）：

```xml
<!-- 改前（会报 invalid video codec） -->
<graphics type='spice' ...>
  <gl enable='yes' rendernode='...'/>
</graphics>

<!-- 改后：spice 仅显示，egl-headless 负责 GL -->
<graphics type='spice' autoport='yes' listen='127.0.0.1'>
  <listen type='address' address='127.0.0.1'/>
  <image compression='off'/>
</graphics>
<graphics type='egl-headless'>
  <gl rendernode='/dev/dri/by-path/pci-0000:35:00.0-render'/>
</graphics>
```

video 设备仍用 `virtio-vga-gl` + `accel3d='yes'`（不变）。启动后 qemu 参数含
`virtio-vga-gl` + `gl=on` + `rendernode=.../35:00.0-render`，guest 内 niri 正常渲染
（`using as the render node: /dev/dri/renderD128`，无 ERROR，仅有 VRR/context-priority
无害警告）。

**注意**：`virsh define` 对运行中 VM 只写盘不生效，改完必须 `destroy` + `start`。


### 6.6 修复后验证

- guest 内核 dmesg：`[drm] features: +virgl +edid -resource_blob -host_visible`、`+context_init` —— **virgl 协商成功**（之前是 -virgl）
- EGL 不再回退 llvmpipe（串口会话里报 `failed to open /dev/dri/card1: Permission denied` 只是无 ACL 的假象；真实 seat0 登录会话有 `user:pang:rw-` ACL）
- **virt-manager 真实登录：桌面成功渲染，正常可用** ✅

### 6.7 渲染配置标准步骤（按此操作/交付模型执行）

以下是最小完整步骤，从零配置或核对 VM 的 3D 渲染：

1. **检查 video 设备**：`virsh -c qemu:///system dumpxml --inactive archlinux | grep -A6 '<video>'`，要求：
   ```xml
   <model type='virtio' heads='1' primary='yes' device='virtio-vga-gl'>
     <acceleration accel3d='yes'/>
   </model>
   ```
   ⚠️ `device` 必须是 `virtio-vga-gl`。virt-manager 图形界面勾"3D 加速"只写 `accel3d='yes'`，不会自动变成 GL 变体；若显示 `device='virtio-vga'` 或缺失，需手动改 XML（见 6.5 改动 2）。
2. **检查 SPICE GL**：要求 `<gl enable='yes' rendernode='/dev/dri/by-path/pci-0000:35:00.0-render'/>` 且 `<listen type='none'/>`（见 6.5 改动 1）。
3. **检查通道**：`grep -A3 '<channel'`，应有 `org.qemu.guest_agent.0`（unix）和 `com.redhat.spice.0`（spicevmc）两个。
4. **重启 VM**：`virsh -c qemu:///system destroy archlinux && virsh -c qemu:///system start archlinux`，确认 qemu 进程含 `virtio-vga-gl`。
5. **验证 virgl**：串口或登录后 `dmesg | grep -i 'drm.*features'`，应显示 `+virgl`。
6. **真实登录验证**：virt-manager 里登录桌面，确认渲染正常。

### 6.8 安装 guest 工具（spice-vdagent / qemu-guest-agent）【待执行】

> 状态：2026-08-03 尚未安装，此为明确待办任务，按下面步骤执行。

**目的**：
- `spice-vdagent`：宿主↔VM 剪贴板双向共享、鼠标指针集成、窗口分辨率自动适应（对应 XML 里已有的 `com.redhat.spice.0` spicevmc 通道）
- `qemu-guest-agent`：优雅关机可靠（`virsh shutdown` 不再超时强杀）、宿主可 `virsh qemu-agent-command` 执行 guest 命令、快照文件系统冻结（对应 XML 里已有的 `org.qemu.guest_agent.0` 通道）

XML 通道已就绪（`grep -A3 '<channel'` 可确认），**无需改 VM XML**，只需 guest 侧安装并启用服务。

**步骤（VM 内执行）**：

```bash
# 1. 安装
sudo pacman -S spice-vdagent qemu-guest-agent

# 2. 启用服务（两个都要启用，Arch 默认不自动启动）
sudo systemctl enable --now spice-vdagentd
sudo systemctl enable --now qemu-guest-agent
```

**验证**：
- VM 内：`systemctl status spice-vdagentd qemu-guest-agent` 均为 active (running)
- 宿主侧：`virsh -c qemu:///system qemu-agent-command archlinux '{"execute":"guest-ping"}'` 返回 `{"return":{}}`
- 剪贴板：virt-manager 里复制文本，VM 内粘贴应可用

---

## 7. 调试工具箱（常用命令速查）

```bash
# VM 生命周期
virsh -c qemu:///system list --all
virsh -c qemu:///system start/shutdown/destroy/reboot archlinux

# 配置
virsh -c qemu:///system dumpxml --inactive archlinux > vm.xml   # 持久配置
virsh -c qemu:///system define vm.xml
virsh -c qemu:///system domxml-to-native qemu-argv archlinux.xml  # 看生成的 qemu 参数

# 串口控制台（需 VM 内启用 getty@ttyS0）
virsh -c qemu:///system console archlinux

# 挂载 VM 磁盘（宿主导入 qemu-nbd，需 gsudo）
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 /home/pang/Public/虚拟机1/archlinux.snapshot1
# ... 挂载分区操作 ...
sudo umount /mnt/vm && sudo qemu-nbd --disconnect /dev/nbd0

# VM 内调试 niri（在串口里，fish 提示符有大量 OSC 序列，命令用 bash -c 包裹）
echo 123 | sudo -S systemctl stop getty@tty1
echo 123 | sudo -S openvt -c 1 -f -- sh -c "niri >/tmp/niri.log 2>&1; echo code=\$? >>/tmp/niri.log"

# VM 内日志
journalctl -b -u sddm --no-pager
journalctl --user -u niri.service -b --no-pager
```

---

## 8. 性能基准（2026-08-03 实测）

工具：sysbench（CPU/内存）+ dd（磁盘 direct 1GB），VM 内与宿主同参数对照。
> 注：以下数据在 VM 内存仍为 8GiB 时测得；6GiB 只影响容量，不影响上述各项性能指标的量级。

| 测试 | 宿主（8C16T） | VM（8 vCPU） | VM/宿主 | 说明 |
|---|---|---|---|---|
| CPU 单线程 | 4718 events/s | 4678 events/s | **99%** | host-passthrough 生效，几乎零损耗 |
| CPU 8 线程 | 35721 events/s | 20175 events/s | 56% | 受 vcpupin 绑定影响（见下） |
| 内存 8 线程 | 14181 MiB/s | 17998 MiB/s | **127%** | 大页生效，反而超过宿主 |
| 磁盘写（direct） | 787 MB/s | 468 MB/s | 59% | qcow2 copy-on-write 写放大 |
| 磁盘读（direct） | 2.4 GB/s | 2.0 GB/s | 83% | overlay 链多一层开销 |
| 3D（glmark2） | — | 无法串口量化 | — | 需真实图形会话，用 virt-manager 里跑 |

**结论与解读**：
- **桌面使用体验已达到目的**：单核几乎无损、内存因大页更快；用户实际使用桌面流畅
- **8 线程只有 56% 不是虚拟化损耗**，而是 vcpupin 把 8 个 vCPU 绑到了 **4 个物理核的 SMT 兄弟线程**（CORE1-4，即 cpuset 2-9）——等于 4 个物理核算力；宿主 8 线程测试跑在 8 个物理核上。这是当时的保守策略（给宿主留出 CORE0 + CORE5-7）
- 磁盘写 59% 是 qcow2 写放大的固有开销，读的 17% 差距来自 snapshot1 → archlinux.qcow2 的 overlay 链

**可选的进一步优化（未做，按需）**：
1. **多核吞吐**：vcpupin 改为绑 8 个不同物理核（每核一个线程），8 线程性能可回到接近宿主；代价是宿主可用核数变少，VM 满载时宿主响应下降
2. **磁盘写性能**：磁盘改用 raw 格式（无 COW 写放大）或删除 overlay 快照层；代价是失去 COW 快照特性
3. **3D 量化**：在 virt-manager 图形会话里跑 `glmark2`（无参数），记录 VirGL 实际分数

---

## 9. 已知限制与后续方向

- **VirGL 是转译执行的 OpenGL**，3D 桌面可流畅跑，但性能天花板低于原生驱动；游戏 / Blender 等重度 GPU 负载仍建议走 **RTX 4050 直通**（IOMMU 已开启，条件已具备）
- 宿主内存紧张是主要瓶颈：大页锁定 6.4GB 后宿主可用约 4.5GB，VM 运行时宿主侧少开大程序
- VM 内没有 vulkan-radeon / vulkan-mesa-layer，如需 VM 内 Vulkan 测试可装
- 若 VM 内想重启桌面：`sudo systemctl restart sddm`
