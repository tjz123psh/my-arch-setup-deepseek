# 物理机离线安装操作指南

适用：ASUS 工作站重装 Arch 后，**无海外网络（GitHub/codeberg 直连不通）**
环境下一条命令恢复完整桌面。镜像走国内源，AUR 全离线构建。

## 需要准备的文件（重装前，拷进 U 盘）

| 文件 | 说明 |
|---|---|
| `my-arch-setup.tar` | 仓库代码（含安装器 + AUR 离线缓存支持） |
| `aur-sources.tar.gz` | AUR 离线源码缓存（14 个 AUR 的源码 + Go/cargo 依赖，约 1GB） |

获取方式：
- 代码：GitHub clone 或本机 `tar --exclude='.git' -czf my-arch-setup.tar my-arch-setup-deepseek`
- 缓存：在能联网的机器上跑仓库里的 `fetch-aur-sources.sh`（生成 `~/Downloads/aur-sources/`），再
  `cd ~/Downloads && tar -czf aur-sources.tar.gz --transform 's/^aur-sources/.aur-sources/' aur-sources`

## 重装后的操作（tty）

### 1. 挂载 U 盘并确认设备名

```bash
lsblk -f        # 看 U 盘设备名（如 /dev/sdb1，vfat/ext4 都行）
mount /dev/sdb1 /mnt
```

### 2. 解包代码和 AUR 缓存

```bash
tar -xf /mnt/my-arch-setup.tar -C ~                 # 得到 ~/my-arch-setup-deepseek/
tar -xzf /mnt/aur-sources.tar.gz -C ~/my-arch-setup-deepseek/   # 得到 .aur-sources/
```

### 3. 联网（只连国内，AUR 不依赖网络）

archinstall 交接点已含网络（NetworkManager / dhcpcd），确认能访问国内镜像即可：

```bash
curl -m 5 -s -o /dev/null -w "%{http_code}\n" https://mirrors.aliyun.com   # 期望 200
```

### 4. 运行安装器

```bash
cd ~/my-arch-setup-deepseek && ./install.sh -d niri -t physical
```

- 全程**只需输一次 sudo 密码**（安装器临时授权，装完自动恢复）
- 镜像 2GB 走国内源；AUR 阶段显示 `Using local AUR source cache ... (offline mode)`
  = 离线缓存生效，14 个 AUR 全部本地构建
- 结束后按提示重启

### 5. 装完验收

- 登录 greetd（dms-greeter）进入 niri/DMS 桌面
- 显卡：`supergfxctl -m Hybrid`（重启生效，之后可切）
- 蓝牙 / 音频 / 挂起唤醒 / ASUS 控制中心（rog-control-center）
- GRUB 引导菜单应显示 Elegant 主题

## 常见问题

- **U 盘挂不上**：先 `lsblk -f` 确认格式；vfat 直接 mount，ntfs 需要 `ntfs-3g`。
- **AUR 没走缓存**：确认 `aur-sources.tar.gz` 解到了仓库内的 `.aur-sources/`
  （`ls ~/my-arch-setup-deepseek/.aur-sources/` 应有 cargo、go-mod 等）；06 日志应出现
  `Using local AUR source cache`。
- **某 AUR 构建失败**：06 会自动重试一次；仍失败则报错退出，网络环境恢复后重跑
  `./install.sh` 会从失败步骤续跑（已装的不会重装）。
- **重新生成缓存**：在能联网的机器 `fetch-aur-sources.sh`（需 go/cargo 工具链）。
- **strap.sh 不可用**：它是 https clone 私有仓库入口，无海外网络时用本指南的 U 盘方式。

## 不需要担心的事

- 传代码不走 GitHub（U 盘）✓
- AUR 源码不联网（预缓存）✓
- 镜像下载只连国内源（aliyun/ustc/清华/腾讯/华为/网易/兰大/浙大）✓
- 一次密码、服务自启、dms 插件等已在本仓库 batch18/20/21 验证
