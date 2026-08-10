#!/usr/bin/env bash
set -euo pipefail

config_dir="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
config_file="$config_dir/opencode.json"
secret_dir="$HOME/.local/share/opencode/secrets"

jq -e . "$config_file" >/dev/null
node "$config_dir/scripts/check-deepseek-guard-config.mjs"
node "$config_dir/scripts/check-agents.mjs" "$config_dir"

# 凭据字段必须是 {file:...} 或 {env:...} 引用，不能写字面量。
# 按键名匹配而不只匹配 apiKey，避免将来新增 token/secret/password 类字段被静默放过。
# setCacheKey 是布尔开关而非凭据，显式排除。
if ! jq -e '
  [ .. | objects | to_entries[]
    | select(.key | test("(api_?key|access_?token|refresh_?token|token|secret|password|passwd|bearer|credential)$"; "i"))
    | select(.key | test("^setCacheKey$") | not)
    | select(.value | type == "string")
    | select(.value | test("^\\{(file|env):") | not)
    | .key
  ] | length == 0
' "$config_file" >/dev/null; then
  echo "凭据字段必须使用 {file:...} 或 {env:...} 引用，以下键名为字面量：" >&2
  jq -r '
    [ .. | objects | to_entries[]
      | select(.key | test("(api_?key|access_?token|refresh_?token|token|secret|password|passwd|bearer|credential)$"; "i"))
      | select(.key | test("^setCacheKey$") | not)
      | select(.value | type == "string")
      | select(.value | test("^\\{(file|env):") | not)
      | .key
    ] | unique | .[]
  ' "$config_file" >&2
  exit 1
fi

test "$(stat -c %a "$config_file")" = "600"
test "$(stat -c %a "$config_dir/deepseek-guard.json")" = "600"
test "$(stat -c %a "$secret_dir")" = "700"
if find "$secret_dir" -maxdepth 1 -type f -name '*-api-key' ! -perm 600 -print -quit | grep -q .; then
  echo "secret 文件权限必须为 600" >&2
  exit 1
fi

# OpenCode 1.18.11 在 stdout 接管道时可能只写出前 8192 字节却返回 0。
# 先写入权限为 600 的普通临时文件，再让 jq 解析完整输出；不能把截断当成成功空结果。
pure_config_file="$(mktemp "${TMPDIR:-/tmp}/opencode-pure-config.XXXXXX.json")"
cleanup() {
  rm -f -- "$pure_config_file"
}
trap cleanup EXIT

if opencode debug config --pure >"$pure_config_file"; then
  :
else
  opencode_status=$?
  printf 'opencode debug config --pure failed with exit %s\n' "$opencode_status" >&2
  exit "$opencode_status"
fi

set +e
pure_summary="$(jq -e '{
  default_agent,
  model,
  small_model,
  agents: (.agent | keys | sort),
  commands: (.command | keys | sort),
  mcp: (.mcp | keys | sort),
  permission,
  compaction,
  tool_output,
  experimental
}' "$pure_config_file")"
jq_status=$?
set -e
if ((jq_status != 0)); then
  printf 'captured pure config is invalid or incomplete (jq exit %s)\n' "$jq_status" >&2
  exit "$jq_status"
fi

# plugin/MCP 清单直接从源配置读取。不使用 `opencode debug config`（非 --pure）：
# 它会展开 `{file:...}` 凭据引用，把真实 key 推进进程管道。
declared_summary="$(jq -e '{
  plugins: ([.plugin[]? | if type == "array" then .[0] else . end] | sort),
  mcp_declared: (.mcp // {} | keys | sort),
  mcp_disabled: [(.mcp // {}) | to_entries[] | select(.value.enabled == false) | .key] | sort
}' "$config_file")"

printf 'source config and credential references: ok\n'
printf 'pure config summary:\n%s\n' "$pure_summary"
printf 'declared plugin/mcp summary:\n%s\n' "$declared_summary"
