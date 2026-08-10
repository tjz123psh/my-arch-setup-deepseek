#!/usr/bin/env bash
# check-extend.sh — 提交前一键总检（增改安全网 L1 闸门）。
#
# 聚合所有"加东西必须过"的检查；任一环节失败即退出非零，禁止提交。
# 模型/操作者每次增改后、commit 前运行：
#   ./check-extend.sh            # 默认全量（13 节，含慢速行为套件 + 宿主部署漂移提示）
#   ./check-extend.sh --fast     # 快速闸门（8 节核心，跳过慢速套件）
#   ./check-extend.sh --only=syntax,secret   # 只跑指定节（调试用）
#   ./check-extend.sh --skip=behavior        # 跳过指定节
#
# 节：
#   bash-n     所有 shell 脚本 bash -n
#   SC-check  对核心脚本跑 shellcheck -S error（注释行不能以 shellcheck 开头，会被当作指令）
#   reconcile  tests/workstation-package-reconciliation-test.sh（清单一致性）
#   syntax     tests/validate-config-syntax.sh（配置内容语法，含 QML 结构配平）
#   refs       recipe 目录 <-> aur-recipes.tsv 双向引用 + PKGBUILD 存在性
#   secret     config/ 载荷 + staged diff 高置信凭据模式
#   numbers    README 过期数字字面量 + 打印权威数字
#   behavior   tests/installer-behavior-test.sh（快速行为套件）
#   session-lifecycle / pacman-order / flclash / nvim-config：慢速行为套件（默认跑，--fast 跳过）
#   deploy-sync 宿主副本 vs 仓库 diff（信息性：提示"改动没部署到宿主"，不阻断提交）
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$root"

fast=0
only=""
skip=""
declare -a SECTIONS=(bash-n shellcheck reconcile syntax refs secret numbers behavior session-lifecycle pacman-order flclash nvim-config deploy-sync)
declare -a CORE=(bash-n shellcheck reconcile syntax refs secret numbers behavior)

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (( $# > 0 )); do
  case "$1" in
    --fast)      fast=1 ;;
    --full)      fast=0 ;;  # 兼容旧语义：全量本来就是默认
    --only=*)    only="${1#--only=}" ;;
    --skip=*)    skip="${1#--skip=}" ;;
    -h|--help)   usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift
done

status=0
section_count=0

run() { # run <name>
  local name="$1"
  if [[ -n "$only" ]]; then
    [[ ",$only," == *",$name,"* ]] || return
  elif [[ -n "$skip" ]]; then
    [[ ",$skip," == *",$name,"* ]] && return
  fi
  section_count=$((section_count + 1))
  echo "== $name =="
  if "$name"; then
    echo "   PASS $name"
  else
    echo "   FAIL $name"
    status=1
  fi
}

# ---------- 节实现 ----------

bash-n() {
  local rc=0 f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if ! bash -n "$f" 2>&1; then
      echo "  bash -n FAIL: $f"
      rc=1
    fi
  done < <(find scripts tests -name '*.sh' -type f; echo install.sh; echo strap.sh; echo fetch-aur-sources.sh; echo sync-scripts.sh; find config -type f -name '*.sh')
  return $rc
}

shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  SKIP shellcheck（未安装）"
    return 0
  fi
  # 注意：函数名与命令同名，必须用 `command` 调用，否则无限递归
  if ! command shellcheck -S error scripts/*.sh install.sh strap.sh fetch-aur-sources.sh sync-scripts.sh tests/*.sh; then
    return 1
  fi
  return 0
}

reconcile() {
  local out
  if ! out=$(bash tests/workstation-package-reconciliation-test.sh 2>&1); then
    echo "$out" | tail -6
    return 1
  fi
  echo "  $out"
  return 0
}

syntax() {
  bash tests/validate-config-syntax.sh
}

refs() {
  local rc=0 d name
  for d in third_party/aur/*/; do
    [[ -d "$d" ]] || continue
    name=${d%/}; name=${name##*/}
    if ! grep -qx "$name" manifests/aur-recipes.tsv; then
      echo "  FAIL 孤儿 recipe 目录不在 aur-recipes.tsv：$name"
      rc=1
    fi
    if [[ ! -f "$d/PKGBUILD" ]]; then
      echo "  FAIL recipe 缺少 PKGBUILD：$name"
      rc=1
    fi
  done
  return $rc
}

secret() {
  local rc=0 pat
  pat='BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|ghp_[A-Za-z0-9]{35,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}'
  if grep -rInE "$pat" config/ 2>/dev/null; then
    echo "  FAIL config/ 命中高置信凭据模式（见上）"
    rc=1
  fi
  local staged
  staged=$(git diff --cached --name-only 2>/dev/null || true)
  if [[ -n "$staged" ]] && git diff --cached | grep -nE "$pat" >/dev/null 2>&1; then
    echo "  FAIL staged diff 命中高置信凭据模式"
    rc=1
  fi
  return $rc
}

numbers() {
  local rc=0 out stale
  stale='install=191|total=211|191 安装|177 pacman|177/14'
  if grep -nE -- "$stale" README.md >/dev/null 2>&1; then
    echo "  FAIL README 含过期包数字："
    grep -nE -- "$stale" README.md
    rc=1
  fi
  out=$(bash tests/workstation-package-reconciliation-test.sh 2>&1 | tail -1)
  echo "  $out"
  echo "  config 文件数: $(find config -type f | wc -l)"
  return $rc
}

behavior() {
  bash tests/installer-behavior-test.sh
}

session-lifecycle() { bash tests/session-lifecycle-test.sh; }
pacman-order()      { bash tests/pacman-sync-order-test.sh; }
flclash()           { bash tests/flclash-migration-test.sh; }
nvim-config()       { bash tests/nvim-config-test.sh; }

# deploy-sync：宿主部署副本 vs 仓库 diff（信息性——提示"改动没部署到宿主"，不阻断提交）。
# 只比对部署态文件（脚本/插件 QML），不比运行时状态（engine/codec_wf/enc_params_wf 是用户可改的）。
deploy-sync() {
  local -a pairs=(
    "$HOME/.local/bin/shorin-screenrec-menu:config/home/.local/bin/shorin-screenrec-menu"
    "$HOME/.config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecWidget.qml:config/home/.config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecWidget.qml"
    "$HOME/.config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecSettings.qml:config/home/.config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecSettings.qml"
    "$HOME/.config/DankMaterialShell/plugins/ShorinScreenrec/StartupCheck.qml:config/home/.config/DankMaterialShell/plugins/ShorinScreenrec/StartupCheck.qml"
    "$HOME/.config/DankMaterialShell/plugins/ShorinScreenrec/plugin.json:config/home/.config/DankMaterialShell/plugins/ShorinScreenrec/plugin.json"
  )
  local pair host repo synced=0 drifted=0
  for pair in "${pairs[@]}"; do
    host="${pair%%:*}"; repo="${pair#*:}"
    if [[ ! -f "$host" ]]; then
      echo "  提示: 宿主无 $host（非本机/未部署，跳过）"
      continue
    fi
    if cmp -s "$host" "$repo"; then
      synced=$((synced + 1))
    else
      echo "  ⚠ 宿主 $host 与仓库不一致（改动未部署到宿主？）"
      drifted=$((drifted + 1))
    fi
  done
  echo "  部署同步: $synced 一致 / $drifted 漂移（信息性，不阻断提交）"
  return 0
}

# ---------- 执行 ----------

for s in "${SECTIONS[@]}"; do
  if (( fast )); then
    [[ " ${CORE[*]} " == *" $s "* ]] || continue
  fi
  run "$s"
done

echo "======================"
if (( status == 0 )); then
  echo "check-extend: ${section_count} 节全部通过 ✅"
else
  echo "check-extend: 有失败，修复后重跑（红=禁止提交）❌"
fi
exit $status
