# LinuxQQ Wayland 无窗口修复

## 问题
Wayland 下启动 QQ，进程存在但没有窗口（登录界面/主界面均不显示）。

## 原因
- QQ 基于 Electron，Wayland 下 GPU 硬件加速兼容性差
- X11 连接泄漏导致连接数占满（256上限）

## 修复方法

### 方法一：electron-flags.conf（推荐）
```bash
mkdir -p ~/.config/QQ
cat > ~/.config/QQ/electron-flags.conf << 'EOF'
--ozone-platform=x11
--disable-gpu
--in-process-gpu
EOF
```

### 方法二：修改 desktop 文件
```bash
cp /usr/share/applications/linuxqq.desktop ~/.local/share/applications/qq.desktop
# 编辑 ~/.local/share/applications/qq.desktop
# Exec 行改为：
Exec=env DESKTOPINTEGRATION=false /usr/bin/linuxqq --no-sandbox --ozone-platform=x11 --disable-gpu --in-process-gpu %U
```

## 参数说明
| 参数 | 作用 |
|------|------|
| `--ozone-platform=x11` | 强制走 XWayland，绕过 Wayland 渲染问题 |
| `--disable-gpu` | 禁用 GPU 硬件加速 |
| `--in-process-gpu` | GPU 在进程内运行，防止退出后无法启动 |

## 其他排查
- `find ~/.config/QQ/versions -name "libssh2.so.1" -delete` — 删除冲突库
- `xlsclients | wc -l` — 检查 X11 连接数是否占满
