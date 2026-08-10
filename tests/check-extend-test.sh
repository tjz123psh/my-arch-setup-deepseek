#!/usr/bin/env bash
# check-extend-test.sh — 错误注入：证明 check-extend.sh 能抓住每一类错误。
#
# 每次把仓库（不含 .git）复制到临时目录，注入一种缺陷，然后断言
# check-extend.sh 的对应分节以非零退出。全部抓住才算通过。
#
#   0. 干净副本必须通过快速闸门（正向对照）
#   1. 坏 lua 配置       -> --only=syntax   必须失败
#   2. 重复包行          -> --only=reconcile 必须失败
#   3. README 过期数字   -> --only=numbers  必须失败
#   4. 私钥进 config/    -> --only=secret   必须失败
#   5. 孤儿 recipe 目录  -> --only=refs     必须失败
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
pass=0

check_ok()   { pass=$((pass+1)); echo "  ok   $1"; }
check_bad()  { fail=$((fail+1)); echo "  FAIL $1"; }

clone_repo() { # clone_repo <dest>
  mkdir -p "$1"
  tar -C "$root" -cf - --exclude=.git . | tar -C "$1" -xf -
}

expect_fail() { # expect_fail <描述> <副本> <only 节>
  local desc="$1" d="$2" only="$3"
  if "$d/check-extend.sh" --only="$only" >/dev/null 2>&1; then
    check_bad "$desc 未被抓住（gate 退出 0）"
  else
    check_ok "$desc 被抓住"
  fi
}

echo "== 0. 正向对照：干净副本通过快速闸门 + --only 真正执行指定节 =="
d="$tmp/s0"; clone_repo "$d"
if "$d/check-extend.sh" --fast >/dev/null 2>&1; then
  check_ok "干净副本通过快速闸门"
else
  check_bad "干净副本未通过快速闸门"
fi
# 正向断言（2026-08-10）：--only 必须真正执行指定节并输出结果。
# 防 run() 过滤返回非零 + set -e 静默杀脚本那类回归（之前注入测试"假通过"就漏在这）。
out=$("$d/check-extend.sh" --only=reconcile 2>&1) || true
if [[ "$out" == *"Workstation package checks passed"* ]]; then
  check_ok "--only=reconcile 真正执行并输出数字"
else
  check_bad "--only=reconcile 未真正执行（过滤/set -e 回归？）"
fi
out=$("$d/check-extend.sh" --only=syntax 2>&1) || true
if [[ "$out" == *"config syntax:"* ]]; then
  check_ok "--only=syntax 真正执行并输出校验结果"
else
  check_bad "--only=syntax 未真正执行（过滤/set -e 回归？）"
fi

echo "== 1. 配置语法：坏 lua 必须被抓住 =="
d="$tmp/s1"; clone_repo "$d"
printf 'function broken(\n' > "$d/config/home/.config/nvim/zz-broken.lua"
expect_fail "坏 lua 配置" "$d" "syntax"

echo "== 2. 清单一致性：重复包行必须被抓住 =="
d="$tmp/s2"; clone_repo "$d"
line=$(awk '!/^#/ && NF { print; exit }' "$d/manifests/workstation-packages.tsv")
printf '%s\n' "$line" >> "$d/manifests/workstation-packages.tsv"
expect_fail "重复包行" "$d" "reconcile"

echo "== 3. README 数字漂移：过期字面量必须被抓住 =="
d="$tmp/s3"; clone_repo "$d"
# 注：2026-08-10 numbers 检查改为动态比对（README 里 install=N/total=N 必须等于实际值）。
# 注入"回到旧值"的错误数字（当前实际是 191/211）。
printf '\ncheck: install=190 total=210 drift test\n' >> "$d/README.md"
expect_fail "README 过期数字" "$d" "numbers"

echo "== 4. 凭据泄漏：私钥进 config/ 必须被抓住 =="
d="$tmp/s4"; clone_repo "$d"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n' \
  > "$d/config/home/.config/zz-evil-key-test"
expect_fail "私钥进 config/" "$d" "secret"

echo "== 5. 引用完整性：孤儿 recipe 目录必须被抓住 =="
d="$tmp/s5"; clone_repo "$d"
mkdir -p "$d/third_party/aur/zz-orphan-test"
printf 'pkgname=zz-orphan-test\n' > "$d/third_party/aur/zz-orphan-test/PKGBUILD"
expect_fail "孤儿 recipe 目录" "$d" "refs"

echo "======================"
echo "check-extend-test: pass=$pass fail=$fail"
(( fail == 0 ))
