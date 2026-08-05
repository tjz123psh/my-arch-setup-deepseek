# 登录管理器：SDDM 迁移到 DMS greeter（greetd）

> 迁移日期：2026-07-14  
> 结果：已从 SDDM 切换到 DMS greeter（基于 greetd），并卸载清理 SDDM。  
> 当前链路：开机 → `greetd` → DMS Material 登录界面 → `niri`（Wayland）。  
> X11 应用走 `xorg-xwayland`（独立包，未受影响）。

## 背景

DMS（DankMaterialShell，`dms-shell`）自带一个登录界面，本质是 **greetd 的一个 greeter**，和 SDDM 是互斥的两套登录管理方案，不能同时启用。之前一直用 SDDM（pixie 主题），DMS 那个「登录界面」设置面板处于空转状态（greetd 没装）。

顺带解决了一个老问题：SDDM 的 greeter 用 X11，每次登录后关闭 greeter 的 Xorg 时会偶发 `SIGABRT` coredump（`/usr/lib/Xorg`，栈里有 `libgallium`）。切到 DMS greeter 后 greeter 走 Wayland，不再起 X，这个崩溃根除。

## 关键概念

- **greetd**：通用登录守护进程，本身不带界面，靠 greeter 提供 UI。
- **DMS greeter**：`dms-greeter`（AUR 包 `greetd-dms-greeter-git`），跑在 greetd 之上，用 niri 当 compositor 画登录界面。
- **`dms greeter` 子命令**：官方封装，不用手写 greetd toml。
  - `install`：装 greetd + 配置用 DMS greeter
  - `enable`：切 greetd 为显示管理器（会禁用旧 DM）
  - `sync`：同步主题/壁纸/设置，配置 greeter 组权限
  - `uninstall`：**恢复到装 DMS greeter 前的状态**（回退用）
  - `status`：检查配置状态

## 迁移步骤（当时实际执行）

前置：先建快照（`quicksave -d before-greetd`）。

```bash
# 1. 装 greetd + DMS greeter（AUR）
paru -S --needed greetd-dms-greeter-git
# 连带装了 greetd、greetd-agreety（后备 greeter）

# 2. sync（会主动询问是否 enable，一步做完）
dms greeter sync
# 它做了：备份 /etc/greetd/config.toml、配置 DMS greeter、
#         enable greetd.service、disable sddm.service、
#         加入 greeter 组、同步主题/壁纸/会话、配置 PAM

# 3. 验证配置就位（不重启先看）
dms greeter status

# 4. 重启验证 → DMS 登录界面正常，登录进 niri
```

## 卸载 SDDM 与清理

确认切换稳定、长期用 DMS 后：

```bash
# 卸载 SDDM（-Rns 连带清了纯 Wayland 下不再需要的 xorg-server 等）
sudo pacman -Rns sddm
# 实际删除：sddm xorg-server xorg-xauth xf86-input-libinput
```

卸载后手动清理残留（包没带走的）：

```bash
sudo rm -f /etc/sddm.conf          # 手动写的配置（Current=pixie）
sudo rm -rf /usr/lib/sddm          # 包目录残留
sudo rm -rf /usr/share/sddm        # themes/pixie、faces、scripts（pixie 不属于任何包）
sudo userdel sddm                  # 遗留系统用户/组（uid/gid 965）
```

## 卸载后必须确认的点

`xorg-server` 被 `-Rns` 连带删除，但 **X11 应用兼容层是 `xorg-xwayland`，是独立包**，不受影响：

```bash
pacman -Q xorg-xwayland     # 应仍在
pgrep -a Xwayland           # niri 下 X11 应用运行时应有
```

Chrome 等 X11 应用照常运行即证明没问题。

## 当前配置文件

greetd 配置 `/etc/greetd/config.toml`：

```toml
[terminal]
vt = 1

[default_session]
command = "/usr/bin/dms-greeter --command niri --cache-dir /var/cache/dms-greeter -C /etc/greetd/niri/config.kdl"
user = "greeter"
```

- greeter 自己用的 niri compositor 配置：`/etc/greetd/niri/config.kdl`
- greeter 主题/壁纸缓存：`/var/cache/dms-greeter/`
- 旧 greetd 配置备份：`/etc/greetd/config.toml.bak`

## 状态检查

```bash
systemctl is-enabled greetd          # enabled
systemctl is-active greetd           # 登录后 inactive(dead) 正常（已交接给用户会话）
dms greeter status                   # 各项应为 ✓
getent group greeter                 # 应含 pang
loginctl show-session $XDG_SESSION_ID -p Type   # wayland
```

## 登录认证（指纹 / 安全密钥）

DMS 设置面板「登录认证」里的指纹、安全密钥依赖 greetd PAM 配置：

- 指纹：需检测到指纹读取器（本机无 → 不可用，正常）。
- 安全密钥：需装/配置 `pam_u2f` 或配置 greetd PAM。
- 认证配置改动后由 `dms greeter sync` 自动应用（面板底部「Sync to apply」按钮同义）。

## 回退方案

SDDM 已卸载，不再是应急退路。万一 greetd/greeter 出问题：

1. 应急进 TTY：`Ctrl+Alt+F2`，用户名 + 密码登录。
2. 一键回退（恢复到装 DMS greeter 前）：

   ```bash
   dms greeter uninstall
   ```

3. 或重装 SDDM：

   ```bash
   sudo pacman -S sddm
   sudo systemctl disable --now greetd
   sudo systemctl enable sddm
   ```

4. 最彻底：用迁移前建的快照 `quickload` 回滚。

## 设置面板的两个按钮

DMS 设置 → 登录界面：

- **激活**：等于 `dms greeter enable`（启用 greetd + 禁用旧 DM）。迁移已做过，无需再点。
- **同步**：等于 `dms greeter sync`（把当前主题/壁纸/设置推给登录界面）。改了登录界面外观选项后才需要点。
