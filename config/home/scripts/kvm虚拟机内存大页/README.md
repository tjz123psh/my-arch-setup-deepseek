# KVM 大页（HugePages）开关工具

管理宿主机 KVM 虚拟机大页内存池的开关与状态查询脚本。

## 文件说明

| 文件 | 说明 |
|---|---|
| `hugepages-toggle` | 主脚本：开启 / 关闭 / 查询大页状态 |
| `README.md` | 本文档 |

## 用法

```bash
~/scripts/kvm虚拟机内存大页/hugepages-toggle [on|off|status]
```

### 命令

| 命令 | 作用 |
|---|---|
| `status`（默认） | 显示当前大页状态：总页数、空闲/占用页数、持久化配置、fstab 挂载行、运行中的 VM |
| `on [页数]` | 开启大页。默认 3200 页（= 6400 MiB ≈ 6.4GB，适配 6GB VM）；可指定页数 |
| `off` | 关闭大页：在线释放池、删除 sysctl 配置、移除 fstab 挂载行 |
| `-h` / `--help` | 显示帮助 |

示例：

```bash
# 查看状态
~/scripts/kvm虚拟机内存大页/hugepages-toggle status
# 等价于不传参数

# 开启（默认 3200 页，适配当前 6GB VM）
~/scripts/kvm虚拟机内存大页/hugepages-toggle on

# 按自定义页数开启（如 8GB VM：4096 页 = 8192 MiB）
~/scripts/kvm虚拟机内存大页/hugepages-toggle on 4096

# 关闭
~/scripts/kvm虚拟机内存大页/hugepages-toggle off
```

## 页数计算公式

VM 内存（MiB）除以 2 即为所需页数（每页 2MiB），再留少量余量：

- 6GB VM → 3072 页 + 128 余量 = **3200 页**
- 8GB VM → 4096 页 + 128 余量 = **4224 页**
- 4GB VM → 2048 页 + 128 余量 = **2176 页**

> 修改 VM 内存后，用 `on <页数>` 重新调整大页池大小。

## 脚本做了什么

### `on`
1. 写入持久化配置 `/etc/sysctl.d/40-hugepage.conf`（`vm.nr_hugepages = N`）
2. 若无挂载行，向 `/etc/fstab` 追加 `hugetlbfs /dev/hugepages hugetlbfs mode=01770,gid=kvm 0 0`
3. 在线生效：`sysctl -w vm.nr_hugepages=N`

### `off`
1. 在线释放：`sysctl -w vm.nr_hugepages=0`
2. 删除 `/etc/sysctl.d/40-hugepage.conf`
3. 从 `/etc/fstab` 移除 hugetlbfs 挂载行

## 注意事项

- **关闭前必须先关闭所有 VM**：脚本会检查并阻止关闭正在占用大页的 VM（内核无法释放被占用的大页）。
- 开启大页后内存池**立即锁定**（约 6.4GB），与 VM 是否运行无关；VM 关闭时池仍保留。
- 大页池占用物理内存：宿主可用内存会相应减少，VM 运行时避免在宿主机开大程序。
- 修改配置需要 root 权限，脚本在**终端交互式提示输入 sudo 密码**（不弹图形框）。
- 大页激活后 VM 重启会自动使用大页（VM 配置的 memoryBacking hugepages 已就绪）。
- 关闭大页**不需要重启宿主**，sysctl 在线立即生效。

## 验证

| 检查项 | 命令 |
|---|---|
| 当前状态 | `hugepages-toggle status` |
| 内核参数 | `sysctl vm.nr_hugepages` |
| 内存池 | `grep Huge /proc/meminfo` |
| 挂载 | `mount \| grep hugetlbfs` |
