#!/usr/bin/env bash
set -euo pipefail

config_dir="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
skill_root="${1:-$config_dir/skills}"
status=0

fail() {
  printf 'FAIL  %s\n' "$*" >&2
  status=1
}

mapfile -t entries < <(find "$skill_root" -type f -name SKILL.md | sort)
[[ ${#entries[@]} -gt 0 ]] || fail "没有找到本地 SKILL.md"

node "$config_dir/scripts/check-skills-frontmatter.mjs" "$skill_root"
if find "$skill_root" -mindepth 3 -type f -name README.md -print -quit | grep -q .; then
  fail "skill 子目录存在重复 README.md"
fi

if rg -n 'allowed-tools|Skillstore|skillstore|Claude Code|\.claude/skills|Obsidian|obsitian|vision\.md' "$skill_root" --glob 'SKILL.md'; then
  fail "SKILL.md 包含迁移残留或禁用引用"
fi

mapfile -t shell_files < <(find "$skill_root" -type f \( -name '*.sh' -o -path '*/templates/*' \) ! -name '*.gz' | sort)
for file in "${shell_files[@]}"; do
  bash -n "$file" || fail "$file 未通过 bash -n"
done
if command -v shellcheck >/dev/null 2>&1 && [[ ${#shell_files[@]} -gt 0 ]]; then
  shellcheck "${shell_files[@]}" || fail "shellcheck 未通过"
fi

mapfile -t node_files < <(find "$skill_root" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) | sort)
for file in "${node_files[@]}"; do
  node --check "$file" || fail "$file 未通过 node --check"
done

# `opencode debug skill` caps output at 64 KiB. Isolate one skill per process so
# the JSON stays complete while still exercising OpenCode's real loader.
runtime_xdg="$(mktemp -d "${TMPDIR:-/tmp}/opencode-skill-runtime-check.XXXXXX")"
trap 'rm -rf -- "$runtime_xdg"' EXIT
for entry in "${entries[@]}"; do
  skill_name="$(basename "$(dirname "$entry")")"
  runtime_config="$(jq -cn --arg path "$(dirname "$entry")" '{skills:{paths:[$path]},plugin:[],formatter:false,lsp:false}')"
  runtime_file="$runtime_xdg/$skill_name.json"
  env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_DIR XDG_CONFIG_HOME="$runtime_xdg" OPENCODE_CONFIG_CONTENT="$runtime_config" \
    opencode debug skill --pure >"$runtime_file" || fail "$skill_name 无法由 OpenCode loader 解析"
  count="$(jq --arg name "$skill_name" '[.[] | select(.name == $name)] | length' "$runtime_file")" || {
    fail "$skill_name 的 OpenCode loader 输出不是完整 JSON"
    continue
  }
  [[ "$count" == "1" ]] || fail "$skill_name 在运行时出现 $count 次"
done

(( status == 0 )) || exit "$status"
printf 'skills: %d local entries loaded; frontmatter, structure and scripts passed\n' "${#entries[@]}"
