#!/usr/bin/env bash
# cleanup-after-install.sh - remove install-time caches that are useless once
# the system is up. Run MANUALLY after the installation succeeded and you have
# verified the desktop works — it deletes data, not just "uninstalls" it.
#
# What it removes (all safe once the install is confirmed good):
#   1. pacman package cache, keeping the newest version of each package
#      (paccache -rk1; the installed packages themselves are untouched)
#   2. ~/.cargo/registry        - Rust build cache (paru/wooz builds)
#   3. ~/.cache/go-build        - Go build cache (greetd-dms-greeter build)
#   4. ~/.cache/paru            - AUR git clones
#   5. <repo>/.aur-sources      - offline AUR source cache (re-extract from
#                                 aur-sources-*.tar.gz if ever needed again)
#   6. <repo>/.install_progress - installer resume state (install is done)
#      <repo>/.install_logs     - installer logs
#
# Everything outside this list is left alone. The script is idempotent: paths
# that are already gone are skipped, so re-running it is harmless.
set -uo pipefail

# refuse to run as root: $HOME would point at /root and the caches to clean
# live in the normal user's home (TARGET_USER).
if [[ "${EUID}" -eq 0 ]]; then
  echo "请以普通用户运行（root 的 \$HOME 不是要清理的缓存所在位置）" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
  echo "无法定位脚本所在目录" >&2
  exit 1
}

# ---- helpers ----------------------------------------------------------------
bytes() { # path -> disk usage in bytes (0 when missing); uses real disk blocks
  # (du -sB1), NOT apparent size (-b), so the freed tally matches what du -sh
  # shows and what the filesystem actually releases.
  local b
  b="$(du -sB1 "$1" 2>/dev/null | cut -f1)"
  echo "${b:-0}"
}

fmt() { # bytes -> human readable
  local b="$1"
  if   (( b >= 1073741824 )); then awk "BEGIN{printf \"%.1fG\", $b/1073741824}"
  elif (( b >= 1048576    )); then awk "BEGIN{printf \"%.1fM\", $b/1048576}"
  elif (( b >= 1024       )); then awk "BEGIN{printf \"%.1fK\", $b/1024}"
  else echo "${b}B"; fi
}

freed=0

rm_path() { # path label
  local p="$1" label="$2" before_h before_bytes
  if [[ ! -e "$p" ]]; then
    echo "SKIP  ${label}（不存在）"
    return 0
  fi
  before_bytes="$(bytes "$p")"
  before_h="$(du -sh "$p" 2>/dev/null | cut -f1)"
  if ! rm -rf -- "$p" 2>/dev/null; then
    # go module cache dirs are 0555 read-only (go's cache hardening): a plain
    # rm -rf cannot unlink their entries, so the whole tree (e.g. .aur-sources
    # with go-mod) fails to delete. Fall back to sudo rm -rf (interactive
    # script; sudo prompts for the password once). Found 2026-08-14 on the
    # physical machine.
    if sudo rm -rf -- "$p"; then
      echo "  （普通权限不足，已用 sudo 删除）"
    else
      echo "WARN  ${label} 删除失败: ${p}"
      return 1
    fi
  fi
  freed=$((freed + before_bytes))
  echo "DEL   ${label}（释放 ${before_h}）"
}

# ---- plan -------------------------------------------------------------------
echo "== 将清理以下安装残留（当前大小）=="
pac_cache="$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)"
cargo_size="$(du -sh "$HOME/.cargo/registry" 2>/dev/null | cut -f1)"
go_size="$(du -sh "$HOME/.cache/go-build" 2>/dev/null | cut -f1)"
paru_size="$(du -sh "$HOME/.cache/paru" 2>/dev/null | cut -f1)"
src_size="$(du -sh "${SCRIPT_DIR}/.aur-sources" 2>/dev/null | cut -f1)"
echo "  pacman 缓存  /var/cache/pacman/pkg  ${pac_cache:-0B}（保留每包最新 1 版）"
echo "  cargo 缓存   ~/.cargo/registry      ${cargo_size:-不存在}"
echo "  go 缓存      ~/.cache/go-build      ${go_size:-不存在}"
echo "  paru 克隆    ~/.cache/paru          ${paru_size:-不存在}"
echo "  离线源缓存   ${SCRIPT_DIR}/.aur-sources  ${src_size:-不存在}"
echo "  安装器状态   .install_progress / .install_logs（几 KB）"
echo

# ---- confirm (the .aur-sources removal is not reversible without re-extracting) --
ans=""
# EOF/非交互下 read 返回非 0，但 ans 可能已读到部分输入（如无换行的 "y"）；
# 不清空它，最终由下面的 [y/N] 判断决定（空 = 取消）。
read -r -p "确认删除以上内容? [y/N] " ans || true
[[ "${ans}" =~ ^[Yy]$ ]] || { echo "已取消，未做任何删除"; exit 0; }

# ---- pacman cache: keep the newest version of each package -------------------
if command -v paccache >/dev/null 2>&1; then
  echo "-- pacman 缓存（paccache -rk1，保留每包最新 1 版）"
  sudo paccache -rk1 || echo "WARN  paccache 执行失败，跳过"
else
  echo "WARN  paccache 未找到（需要 pacman-contrib），跳过 pacman 缓存清理"
fi

# ---- build caches (regenerated automatically on next build) ------------------
echo "-- 构建缓存"
rm_path "$HOME/.cargo/registry"   "cargo 缓存"
rm_path "$HOME/.cache/go-build"   "go 缓存"
rm_path "$HOME/.cache/paru"       "paru AUR 克隆"

# ---- installer leftovers ------------------------------------------------------
echo "-- 安装器残留"
rm_path "${SCRIPT_DIR}/.aur-sources"      "离线 AUR 源缓存"
rm_path "${SCRIPT_DIR}/.install_progress" "安装进度文件"
rm_path "${SCRIPT_DIR}/.install_logs"     "安装日志目录"

echo
echo "完成。脚本清理释放约 $(fmt "$freed")（另有 pacman 缓存释放见上方 paccache 输出）。"
echo "提示：paccache -rk1 已为每个包保留最新版本，之后如需降级/重装无需重新下载。"
