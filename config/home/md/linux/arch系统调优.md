# Arch Linux 系统调优

> 已按当前物理机状态复核：系统盘是 `/dev/nvme0n1`，型号 `WD PC SN740 SDDPNQD-512G-1002`，非旋转盘，当前调度器为 `[kyber]`；`paccache.timer` 已启用并运行；`/etc/makepkg.conf` 已设置 `MAKEFLAGS="-j$(nproc)"`。

## IO 调度器：当前 NVMe 不套用 HDD/BFQ 示例

机械盘可以考虑 bfq（Budget Fair Queueing），交互操作不容易被后台 IO 卡住。当前物理机不是机械盘，不要照搬旧的 `/dev/sda` 示例。

当前检查命令：

```bash
lsblk -ndo NAME,TYPE,ROTA,SIZE,MODEL /dev/nvme0n1
cat /sys/block/nvme0n1/queue/scheduler
```

当前结果：

```text
nvme0n1 disk 0 476.9G WD PC SN740 SDDPNQD-512G-1002
none mq-deadline [kyber] bfq
```

如果以后外接或更换机械盘，再按实际设备名写规则，例如：

```bash
lsblk -ndo NAME,TYPE,ROTA,SIZE,MODEL
```

只有 `ROTA=1` 的机械盘才考虑 BFQ；NVMe/SSD 不按这段处理。

## Pacman 缓存自动清理

保留最近 3 个版本，每周自动清理：

```bash
# 首次手动清理
sudo paccache -rk3

# 启用定时器（每周自动清）
sudo systemctl enable --now paccache.timer
```

查看缓存大小：`du -sh /var/cache/pacman/pkg`

## makepkg 并行编译

```bash
if grep -qE '^#?MAKEFLAGS=' /etc/makepkg.conf; then
  sudo sed -i -E 's/^#?MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
else
  echo 'MAKEFLAGS="-j$(nproc)"' | sudo tee -a /etc/makepkg.conf
fi
```

验证：`grep "^MAKEFLAGS" /etc/makepkg.conf`
