#!/usr/bin/env bash

if [[ -n "${MAINTENANCE_CONFIG_LIB_LOADED:-}" ]]; then
  return 0
fi
MAINTENANCE_CONFIG_LIB_LOADED=1

declare -gA MAINTENANCE_CONFIG_VALUES=()
MAINTENANCE_CONFIG_LOADED=0

maintenance_config_error() {
  printf 'maintenance 配置错误: %s\n' "$*" >&2
}

maintenance_config_key_allowed() {
  case "$1" in
    BACKUP_TARGET|BACKUP_KEEP|MIRROR_BACKUP_KEEP|MIRROR_MAX_AGE_DAYS|\
    MIRROR_THREADS|UPDATE_QUERY_TIMEOUT|UPDATE_LOCK_WAIT|\
    ROOT_MIN_FREE_MIB|BOOT_MIN_FREE_MIB|JOURNAL_RETENTION|THUMBNAIL_MAX_AGE_DAYS|\
    BACKUP_ON_CALENDAR|BACKUP_RANDOM_DELAY)
      return 0
      ;;
    *) return 1 ;;
  esac
}

maintenance_config_validate() {
  local key="$1" value="$2"
  case "$key" in
    MIRROR_THREADS)
      # reflector 测速并发；过高只会互相抢带宽，把测速结果压得没有区分度。
      { [[ "$value" =~ ^[1-9][0-9]*$ ]] && (( value <= 32 )); } \
        || { maintenance_config_error "MIRROR_THREADS 必须是 1 到 32 的整数"; return 1; }
      ;;
    BACKUP_KEEP|MIRROR_BACKUP_KEEP|MIRROR_MAX_AGE_DAYS|ROOT_MIN_FREE_MIB|\
    BOOT_MIN_FREE_MIB|THUMBNAIL_MAX_AGE_DAYS|UPDATE_QUERY_TIMEOUT|UPDATE_LOCK_WAIT)
      [[ "$value" =~ ^[1-9][0-9]*$ ]] \
        || { maintenance_config_error "$key 必须是正整数"; return 1; }
      ;;
    JOURNAL_RETENTION)
      [[ "$value" =~ ^[1-9][0-9]*(s|min|h|d|w|week|weeks|month|months)$ ]] \
        || { maintenance_config_error "JOURNAL_RETENTION 格式无效，例如 14d 或 2weeks"; return 1; }
      ;;
    BACKUP_ON_CALENDAR)
      [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || { maintenance_config_error "BACKUP_ON_CALENDAR 不能为空或包含换行"; return 1; }
      ;;
    BACKUP_RANDOM_DELAY)
      [[ "$value" =~ ^[0-9]+(s|min|h|d|w)$ ]] \
        || { maintenance_config_error "BACKUP_RANDOM_DELAY 格式无效，例如 1h"; return 1; }
      ;;
    BACKUP_TARGET)
      [[ -n "$value" ]] \
        || { maintenance_config_error "BACKUP_TARGET 不能为空"; return 1; }
      ;;
  esac
}

maintenance_config_load() {
  local file="${MAINTENANCE_CONFIG_FILE:-$HOME/.config/maintenance/config}"
  local line trimmed key value line_no=0
  [[ "$MAINTENANCE_CONFIG_LOADED" -eq 0 ]] || return 0
  MAINTENANCE_CONFIG_LOADED=1
  [[ -e "$file" ]] || return 0
  [[ -f "$file" && -r "$file" ]] \
    || { maintenance_config_error "无法读取普通文件: $file"; return 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    if [[ ! "$trimmed" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      maintenance_config_error "$file:$line_no 不是 KEY=VALUE 格式"
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    maintenance_config_key_allowed "$key" \
      || { maintenance_config_error "$file:$line_no 未知键 $key"; return 1; }
    [[ ! -v "MAINTENANCE_CONFIG_VALUES[$key]" ]] \
      || { maintenance_config_error "$file:$line_no 重复键 $key"; return 1; }
    if [[ "$value" == \"* || "$value" == \'* ]]; then
      if [[ ${#value} -lt 2 || "${value: -1}" != "${value:0:1}" ]]; then
        maintenance_config_error "$file:$line_no 引号不匹配"
        return 1
      fi
      value="${value:1:${#value}-2}"
    fi
    if [[ "$key" == "BACKUP_TARGET" && "${value:0:1}" == "~" && "${value:1:1}" == "/" ]]; then
      value="$HOME/${value:2}"
    fi
    maintenance_config_validate "$key" "$value" || return 1
    MAINTENANCE_CONFIG_VALUES["$key"]="$value"
  done < "$file"
}

maintenance_config_get() {
  local key="$1" default_value="${2:-}" env_name="${3:-}"
  if [[ -n "$env_name" && -v "$env_name" ]]; then
    # 环境变量覆盖同样要过校验：旧实现直接返回，绕过了
    # maintenance_config_validate，非法值会进入 $(( )) 等求值上下文
    # （bash 算术会把非法下标里的 $(...) 当命令展开）。
    local env_value="${!env_name}"
    if ! maintenance_config_validate "$key" "$env_value"; then
      maintenance_config_error "环境变量 $env_name 的值无效，已改用默认值 $default_value"
      printf '%s' "$default_value"
      return 0
    fi
    printf '%s' "$env_value"
  elif [[ -v "MAINTENANCE_CONFIG_VALUES[$key]" ]]; then
    printf '%s' "${MAINTENANCE_CONFIG_VALUES[$key]}"
  else
    printf '%s' "$default_value"
  fi
}
