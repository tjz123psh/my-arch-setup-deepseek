#!/usr/bin/env bash
# check-extend.sh — 提交前一键总检（增改安全网 L1 闸门）。
#
# 聚合所有"加东西必须过"的静态/快速检查；任一环节失败即退出非零，禁止提交。
# 模型/操作者每次增改后、commit 前运行：
#   ./check-extend.sh            # 快速闸门（默认 8 节）
#   ./check-extend.sh --full     # 追加慢速套件（session-lifecycle/pacman-order/flclash/nvim-config）
#   ./check-extend.sh --only=syntax,secret   # 只跑指定节（调试用）
#   ./check-extend.sh --skip=behavior        # 跳过指定节
#
# 节：
#   bash-n     所有 shell 脚本 bash -n
#   shellcheck 核心脚本 shellcheck -S error
#   reconcile  tests/workstation-package-reconciliation-test.sh（清单一致性）
#   syntax     tests/validate-config-syntax.sh（配置内容语法）
#   refs       recipe 目录 <-> aur-recipes.tsv 双向引用 + PKGBUILD 存在性
#   secret     config/ 载荷 + staged diff 高置信凭据模式
#   numbers    README 过期数字字面量 + 打印权威数字
#   behavior   tests/installer-behavior-test.sh（快速行为套件）
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$root"

full=0
only=""
skip=""
declare -a SECTIONS=(bash-n shellcheck reconcile syntax refs secret numbers behavior)
declare -a FULL_EXTRA=(session-lifecycle pacman-order flclash nvim-config)

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (( $# > 0 )); do
  case "$1" in
    --full)      full=1 ;;
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

# ---------- 执行 ----------

for s in "${SECTIONS[@]}"; do run "$s"; done
if (( full )); then
  for s in "${FULL_EXTRA[@]}"; do run "$s"; done
fi

echo "======================"
if (( status == 0 )); then
  echo "check-extend: ${section_count} 节全部通过 ✅"
else
  echo "check-extend: 有失败，修复后重跑（红=禁止提交）❌"
fi
exit $status
