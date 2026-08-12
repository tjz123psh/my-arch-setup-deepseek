#!/usr/bin/env bash
# MusicFree 插件一键恢复脚本
# 用法：双击运行，或终端执行：~/scripts/MusicFree-歌单和插件/一键恢复.sh
# 脚本会自动关闭运行中的 MusicFree，恢复插件，然后提示重新打开
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$HOME/.config/MusicFree/musicfree-plugins"

# 1. 关闭运行中的 MusicFree（运行时会清理插件目录，必须关掉再恢复）
if pgrep -x MusicFree >/dev/null 2>&1; then
  echo "→ 检测到 MusicFree 正在运行，正在关闭..."
  pkill -x MusicFree 2>/dev/null || true
  sleep 3
  if pgrep -x MusicFree >/dev/null 2>&1; then
    pkill -9 -x MusicFree 2>/dev/null || true
    sleep 1
  fi
fi

# 2. 恢复插件
mkdir -p "$DST"
count=0
for f in "$SRC"/*.js; do
  [ -f "$f" ] || continue
  cp "$f" "$DST/"
  count=$((count + 1))
done

echo ""
echo "✅ 已恢复 $count 个插件到 $DST"
echo "现在请重新打开 MusicFree（菜单或 musicfree.sh），插件即可使用。"
echo ""
read -rp "按回车键关闭本窗口..." _
