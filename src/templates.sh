# ── templates: 写入 wrapper、shim、环境初始化 ──────────────────

# 写入 statusline-command.sh 到环境 .claude 目录
_write_statusline_script() {
    local config_dir="$1"
    cat > "$config_dir/statusline-command.sh" << 'STATUSLINE_EOF'
#!/usr/bin/env bash
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
version=$(echo "$input" | jq -r '.version // empty')
session_name=$(echo "$input" | jq -r '.session_name // empty')

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // empty')

five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')
worktree_branch=$(echo "$input" | jq -r '.worktree.branch // empty')

reset='\033[0m'; bold='\033[1m'; dim='\033[2m'
cyan='\033[36m'; yellow='\033[33m'; green='\033[32m'; red='\033[31m'
magenta='\033[35m'; blue='\033[34m'

parts=()

[ -n "$model" ] && parts+=("$(printf "${cyan}${bold}%s${reset}" "$model")")
[ -n "$version" ] && parts+=("$(printf "${dim}v%s${reset}" "$version")")
[ -n "$session_name" ] && parts+=("$(printf "${magenta}[%s]${reset}" "$session_name")")

if [ -n "$cwd" ]; then
  short_cwd="${cwd/#$HOME/~}"
  parts+=("$(printf "${blue}%s${reset}" "$short_cwd")")
fi

if [ -n "$used_pct" ] && [ -n "$ctx_size" ]; then
  ctx_int=$(printf "%.0f" "$used_pct")
  if [ "$ctx_int" -ge 80 ]; then ctx_color="$red"
  elif [ "$ctx_int" -ge 50 ]; then ctx_color="$yellow"
  else ctx_color="$green"; fi
  ctx_k=$(echo "$ctx_size" | awk '{printf "%.0fk", $1/1000}')
  if [ -n "$input_tokens" ]; then
    tokens_k=$(echo "$input_tokens" | awk '{printf "%.1fk", $1/1000}')
    parts+=("$(printf "${ctx_color}ctx:%.0f%% %s/%s${reset}" "$used_pct" "${tokens_k}" "${ctx_k}")")
  else
    parts+=("$(printf "${ctx_color}ctx:%.0f%% (%s)${reset}" "$used_pct" "${ctx_k}")")
  fi
fi

rate_parts=()
if [ -n "$five_pct" ]; then
  five_int=$(printf "%.0f" "$five_pct")
  if [ "$five_int" -ge 80 ]; then rc="$red"
  elif [ "$five_int" -ge 50 ]; then rc="$yellow"
  else rc="$green"; fi
  rs="$(printf "${rc}5h:%.0f%%${reset}" "$five_pct")"
  if [ -n "$five_reset" ] && [ "$five_int" -ge 50 ]; then
    rm=$(( (five_reset - $(date +%s)) / 60 ))
    [ "$rm" -gt 0 ] && rs="$rs$(printf "${dim}(${rm}m)${reset}")"
  fi
  rate_parts+=("$rs")
fi
if [ -n "$week_pct" ]; then
  week_int=$(printf "%.0f" "$week_pct")
  if [ "$week_int" -ge 80 ]; then wc="$red"
  elif [ "$week_int" -ge 50 ]; then wc="$yellow"
  else wc="$green"; fi
  rate_parts+=("$(printf "${wc}7d:%.0f%%${reset}" "$week_pct")")
fi
if [ "${#rate_parts[@]}" -gt 0 ]; then
  rstr="${rate_parts[0]}"
  for i in "${rate_parts[@]:1}"; do rstr="$rstr $i"; done
  parts+=("$rstr")
fi

if [ -n "$worktree_name" ]; then
  wt="wt:$worktree_name"
  [ -n "$worktree_branch" ] && wt="$wt($worktree_branch)"
  parts+=("$(printf "${cyan}%s${reset}" "$wt")")
fi

if [ "${#parts[@]}" -eq 0 ]; then printf "${dim}claude${reset}\n"; exit 0; fi
sep="$(printf " ${dim}|${reset} ")"
result="${parts[0]}"
for p in "${parts[@]:1}"; do result="$result$sep$p"; done
printf "%b\n" "$result"
STATUSLINE_EOF
    chmod +x "$config_dir/statusline-command.sh"
}

# 写入 settings.json 到环境 .claude 目录
_write_env_settings() {
    local config_dir="$1"
    cat > "$config_dir/settings.json" << 'SETTINGS_EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "skipDangerousModePermissionPrompt": true,
  "statusLine": {
    "type": "command",
    "command": "bash $CLAUDE_CONFIG_DIR/statusline-command.sh"
  }
}
SETTINGS_EOF
}

# 写入 CLAUDE.md 到环境 .claude 目录
_write_env_claude_md() {
    local config_dir="$1"
    local env_name="$2"
    cat > "$config_dir/CLAUDE.md" << CLAUDEMD_EOF
# cac managed environment

This Claude Code instance is managed by **cac** (Claude Code Cloak).

- Environment name: \`$env_name\`
- Config directory: \`CLAUDE_CONFIG_DIR\` is set to this \`.claude/\` folder
- Your settings, credentials, and sessions are isolated per-environment

Useful commands:
- \`cac env ls\` — list all environments and their config paths
- \`cac env check\` — verify current environment health
- \`cac <name>\` — switch to another environment
CLAUDEMD_EOF
}

_write_wrapper() {
    mkdir -p "$CAC_DIR/bin"
    cat > "$CAC_DIR/bin/claude" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

CAC_DIR="$HOME/.cac"
ENVS_DIR="$CAC_DIR/envs"

# cacstop 状态：直接透传
if [[ -f "$CAC_DIR/stopped" ]]; then
    _real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude" 2>/dev/null || true)
    [[ -x "$_real" ]] && exec "$_real" "$@"
    echo "[cac] 错误：找不到真实 claude，运行 'cac setup'" >&2; exit 1
fi

# 读取当前环境
if [[ ! -f "$CAC_DIR/current" ]]; then
    echo "[cac] 错误：未激活任何环境，运行 'cac <name>'" >&2; exit 1
fi
_name=$(tr -d '[:space:]' < "$CAC_DIR/current")
_env_dir="$ENVS_DIR/$_name"
[[ -d "$_env_dir" ]] || { echo "[cac] 错误：环境 '$_name' 不存在" >&2; exit 1; }

# Isolated .claude config directory
if [[ -d "$_env_dir/.claude" ]]; then
    export CLAUDE_CONFIG_DIR="$_env_dir/.claude"
    # 确保 settings.json 存在，阻止 Claude Code fallback 到 ~/.claude/settings.json
    [[ -f "$_env_dir/.claude/settings.json" ]] || echo '{}' > "$_env_dir/.claude/settings.json"
fi

# Proxy — optional: only if proxy file exists and is non-empty
PROXY=""
if [[ -f "$_env_dir/proxy" ]]; then
    PROXY=$(tr -d '[:space:]' < "$_env_dir/proxy")
fi

if [[ -n "$PROXY" ]]; then
    # pre-flight：代理连通性（纯 bash，无 fork）
    _hp="${PROXY##*@}"; _hp="${_hp##*://}"
    _host="${_hp%%:*}"
    _port="${_hp##*:}"
    if ! (echo >/dev/tcp/"$_host"/"$_port") 2>/dev/null; then
        echo "[cac] 错误：[$_name] 代理 $_hp 不通，拒绝启动。" >&2
        echo "[cac] 提示：运行 'cac check' 排查，或 'cac stop' 临时停用" >&2
        exit 1
    fi
fi

# 注入 statsig stable_id
if [[ -f "$_env_dir/stable_id" ]]; then
    _sid=$(tr -d '[:space:]' < "$_env_dir/stable_id")
    _config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if [[ -d "$_config_dir/statsig" ]]; then
        _sid_found=false
        for _f in "$_config_dir/statsig"/statsig.stable_id.*; do
            [[ -f "$_f" ]] && { printf '"%s"' "$_sid" > "$_f"; _sid_found=true; }
        done
        [[ "$_sid_found" == "false" ]] && printf '"%s"' "$_sid" > "$_config_dir/statsig/statsig.stable_id.local"
    fi
fi

# 注入环境变量 —— 代理（仅在配置了代理时）
if [[ -n "$PROXY" ]]; then
    export _CAC_PROXY="$PROXY"
    export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" ALL_PROXY="$PROXY"
    export NO_PROXY="localhost,127.0.0.1"
fi
export PATH="$CAC_DIR/shim-bin:$PATH"

# ── 多层环境变量遥测保护 ──
# Layer 1: Claude Code 原生开关
export CLAUDE_CODE_ENABLE_TELEMETRY=
# Layer 2: 通用遥测标准 (https://consoledonottrack.com)
export DO_NOT_TRACK=1
# Layer 3: OpenTelemetry SDK 全面禁用
export OTEL_SDK_DISABLED=true
export OTEL_TRACES_EXPORTER=none
export OTEL_METRICS_EXPORTER=none
export OTEL_LOGS_EXPORTER=none
# Layer 4: Sentry DSN 置空，阻止错误上报
export SENTRY_DSN=
# Layer 5: Claude Code 特有开关
export DISABLE_ERROR_REPORTING=1
export DISABLE_BUG_COMMAND=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
# Layer 6: 其他已知遥测标志
export TELEMETRY_DISABLED=1
export DISABLE_TELEMETRY=1

# 有代理时：强制走 OAuth（清除 API 配置防泄露）
# 无代理时：保留用户的 API Key / Base URL
if [[ -n "$PROXY" ]]; then
    unset ANTHROPIC_BASE_URL
    unset ANTHROPIC_AUTH_TOKEN
    unset ANTHROPIC_API_KEY
fi

# ── NS 层级 DNS 拦截 ──
if [[ -f "$CAC_DIR/cac-dns-guard.js" ]]; then
    case "${NODE_OPTIONS:-}" in
        *cac-dns-guard.js*) ;; # 已注入，跳过
        *) export NODE_OPTIONS="${NODE_OPTIONS:-} --require $CAC_DIR/cac-dns-guard.js" ;;
    esac
fi
# 备用层：HOSTALIASES（gethostbyname 级别）
[[ -f "$CAC_DIR/blocked_hosts" ]] && export HOSTALIASES="$CAC_DIR/blocked_hosts"

# ── mTLS 客户端证书 ──
if [[ -f "$_env_dir/client_cert.pem" ]] && [[ -f "$_env_dir/client_key.pem" ]]; then
    export CAC_MTLS_CERT="$_env_dir/client_cert.pem"
    export CAC_MTLS_KEY="$_env_dir/client_key.pem"
    [[ -f "$CAC_DIR/ca/ca_cert.pem" ]] && {
        export CAC_MTLS_CA="$CAC_DIR/ca/ca_cert.pem"
        export NODE_EXTRA_CA_CERTS="$CAC_DIR/ca/ca_cert.pem"
    }
    [[ -n "${_hp:-}" ]] && export CAC_PROXY_HOST="$_hp"
fi

# 确保 CA 证书始终被信任（mTLS 需要）
[[ -f "$CAC_DIR/ca/ca_cert.pem" ]] && export NODE_EXTRA_CA_CERTS="$CAC_DIR/ca/ca_cert.pem"

[[ -f "$_env_dir/tz" ]]   && export TZ=$(tr -d '[:space:]' < "$_env_dir/tz")
[[ -f "$_env_dir/lang" ]] && export LANG=$(tr -d '[:space:]' < "$_env_dir/lang")
if [[ -f "$_env_dir/hostname" ]]; then
    _hn=$(tr -d '[:space:]' < "$_env_dir/hostname")
    export HOSTNAME="$_hn" CAC_HOSTNAME="$_hn"
fi

# Node.js 级指纹拦截（绕过 shell shim 限制）
[[ -f "$_env_dir/mac_address" ]] && export CAC_MAC=$(tr -d '[:space:]' < "$_env_dir/mac_address")
[[ -f "$_env_dir/machine_id" ]]  && export CAC_MACHINE_ID=$(tr -d '[:space:]' < "$_env_dir/machine_id")
export CAC_USERNAME="user-$(echo "$_name" | cut -c1-8)"
if [[ -f "$CAC_DIR/fingerprint-hook.js" ]]; then
    case "${NODE_OPTIONS:-}" in
        *fingerprint-hook.js*) ;; # 已注入，跳过
        *) export NODE_OPTIONS="--require $CAC_DIR/fingerprint-hook.js ${NODE_OPTIONS:-}" ;;
    esac
fi

# 执行真实 claude — versioned binary or system fallback
_real=""
if [[ -f "$_env_dir/version" ]]; then
    _ver=$(tr -d '[:space:]' < "$_env_dir/version")
    _ver_bin="$CAC_DIR/versions/$_ver/claude"
    [[ -x "$_ver_bin" ]] && _real="$_ver_bin"
fi
if [[ -z "$_real" ]] || [[ ! -x "$_real" ]]; then
    _real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude")
fi
[[ -x "$_real" ]] || { echo "[cac] 错误：找不到 claude，运行 'cac setup'" >&2; exit 1; }

# ── Relay 本地中转（有代理时始终启用）──
_relay_active=false
if [[ -n "$PROXY" ]] && [[ -f "$CAC_DIR/relay.js" ]]; then
    _relay_js="$CAC_DIR/relay.js"
    _relay_pid_file="$CAC_DIR/relay.pid"
    _relay_port_file="$CAC_DIR/relay.port"

    # 检查 relay 是否已在运行
    _relay_running=false
    if [[ -f "$_relay_pid_file" ]]; then
        _rpid=$(tr -d '[:space:]' < "$_relay_pid_file")
        kill -0 "$_rpid" 2>/dev/null && _relay_running=true
    fi

    # 未运行则启动
    if [[ "$_relay_running" != "true" ]] && [[ -f "$_relay_js" ]]; then
        _rport=17890
        while (echo >/dev/tcp/127.0.0.1/$_rport) 2>/dev/null; do
            (( _rport++ ))
            [[ $_rport -gt 17999 ]] && break
        done
        node "$_relay_js" "$_rport" "$PROXY" "$_relay_pid_file" </dev/null >"$CAC_DIR/relay.log" 2>&1 &
        disown
        for _ri in {1..30}; do
            (echo >/dev/tcp/127.0.0.1/$_rport) 2>/dev/null && break
            sleep 0.1
        done
        echo "$_rport" > "$_relay_port_file"
    fi

    # 覆盖代理指向本地 relay
    if [[ -f "$_relay_port_file" ]]; then
        _rport=$(tr -d '[:space:]' < "$_relay_port_file")
        export HTTPS_PROXY="http://127.0.0.1:$_rport"
        export HTTP_PROXY="http://127.0.0.1:$_rport"
        export ALL_PROXY="http://127.0.0.1:$_rport"
        _relay_active=true
    fi
fi

# 清理函数
_cleanup_all() {
    # 清理 relay
    if [[ "$_relay_active" == "true" ]] && [[ -f "$CAC_DIR/relay.pid" ]]; then
        local _p; _p=$(cat "$CAC_DIR/relay.pid" 2>/dev/null) || true
        [[ -n "$_p" ]] && kill "$_p" 2>/dev/null || true
        rm -f "$CAC_DIR/relay.pid" "$CAC_DIR/relay.port"
    fi
}

trap _cleanup_all EXIT INT TERM
"$_real" "$@"
_ec=$?
_cleanup_all
exit "$_ec"
WRAPPER_EOF
    chmod +x "$CAC_DIR/bin/claude"
}

_write_ioreg_shim() {
    mkdir -p "$CAC_DIR/shim-bin"
    cat > "$CAC_DIR/shim-bin/ioreg" << 'IOREG_EOF'
#!/usr/bin/env bash
CAC_DIR="$HOME/.cac"

# 非目标调用：透传真实 ioreg
if ! echo "$*" | grep -q "IOPlatformExpertDevice"; then
    _real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') \
            command -v ioreg 2>/dev/null || true)
    [[ -n "$_real" ]] && exec "$_real" "$@"
    exit 0
fi

# 读取当前环境的 UUID
_uuid_file="$CAC_DIR/envs/$(tr -d '[:space:]' < "$CAC_DIR/current" 2>/dev/null)/uuid"
if [[ ! -f "$_uuid_file" ]]; then
    _real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') \
            command -v ioreg 2>/dev/null || true)
    [[ -n "$_real" ]] && exec "$_real" "$@"
    exit 0
fi
FAKE_UUID=$(tr -d '[:space:]' < "$_uuid_file")

cat <<EOF
+-o Root  <class IORegistryEntry, id 0x100000100, retain 11>
  +-o J314sAP  <class IOPlatformExpertDevice, id 0x100000101, registered, matched, active, busy 0 (0 ms), retain 28>
    {
      "IOPlatformUUID" = "$FAKE_UUID"
      "IOPlatformSerialNumber" = "C02FAKE000001"
      "manufacturer" = "Apple Inc."
      "model" = "Mac14,5"
    }
EOF
IOREG_EOF
    chmod +x "$CAC_DIR/shim-bin/ioreg"
}

_write_machine_id_shim() {
    mkdir -p "$CAC_DIR/shim-bin"
    cat > "$CAC_DIR/shim-bin/cat" << 'CAT_EOF'
#!/usr/bin/env bash
CAC_DIR="$HOME/.cac"

# 先获取真实 cat 路径（避免递归调用自身）
_real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') command -v cat 2>/dev/null || true)

# 拦截 /etc/machine-id 和 /var/lib/dbus/machine-id
if [[ "$1" == "/etc/machine-id" ]] || [[ "$1" == "/var/lib/dbus/machine-id" ]]; then
    _mid_file="$CAC_DIR/envs/$(tr -d '[:space:]' < "$CAC_DIR/current" 2>/dev/null)/machine_id"
    if [[ -f "$_mid_file" ]] && [[ -n "$_real" ]]; then
        exec "$_real" "$_mid_file"
    fi
fi

# 非目标调用：透传真实 cat
[[ -n "$_real" ]] && exec "$_real" "$@"
exit 1
CAT_EOF
    chmod +x "$CAC_DIR/shim-bin/cat"
}

_write_hostname_shim() {
    mkdir -p "$CAC_DIR/shim-bin"
    cat > "$CAC_DIR/shim-bin/hostname" << 'HOSTNAME_EOF'
#!/usr/bin/env bash
CAC_DIR="$HOME/.cac"

# 读取伪造的 hostname
_hn_file="$CAC_DIR/envs/$(tr -d '[:space:]' < "$CAC_DIR/current" 2>/dev/null)/hostname"
if [[ -f "$_hn_file" ]]; then
    tr -d '[:space:]' < "$_hn_file"
    exit 0
fi

# 透传真实 hostname
_real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') command -v hostname 2>/dev/null || true)
[[ -n "$_real" ]] && exec "$_real" "$@"
exit 1
HOSTNAME_EOF
    chmod +x "$CAC_DIR/shim-bin/hostname"
}

_write_ifconfig_shim() {
    mkdir -p "$CAC_DIR/shim-bin"
    cat > "$CAC_DIR/shim-bin/ifconfig" << 'IFCONFIG_EOF'
#!/usr/bin/env bash
CAC_DIR="$HOME/.cac"

_real=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') command -v ifconfig 2>/dev/null || true)

_mac_file="$CAC_DIR/envs/$(tr -d '[:space:]' < "$CAC_DIR/current" 2>/dev/null)/mac_address"
if [[ -f "$_mac_file" ]] && [[ -n "$_real" ]]; then
    FAKE_MAC=$(tr -d '[:space:]' < "$_mac_file")
    "$_real" "$@" | sed "s/ether [0-9a-f:]\{17\}/ether $FAKE_MAC/g" && exit 0
fi

[[ -n "$_real" ]] && exec "$_real" "$@"
exit 1
IFCONFIG_EOF
    chmod +x "$CAC_DIR/shim-bin/ifconfig"
}
