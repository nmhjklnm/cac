# ── templates: 写入 wrapper 和 ioreg shim ──────────────────────

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

PROXY=$(tr -d '[:space:]' < "$_env_dir/proxy")

# pre-flight：代理连通性（纯 bash，无 fork）
_hp="${PROXY##*@}"; _hp="${_hp##*://}"
_host="${_hp%%:*}"
_port="${_hp##*:}"
if ! (echo >/dev/tcp/"$_host"/"$_port") 2>/dev/null; then
    echo "[cac] 错误：[$_name] 代理 $_hp 不通，拒绝启动。" >&2
    echo "[cac] 提示：运行 'cac check' 排查，或 'cacstop' 临时停用" >&2
    exit 1
fi

# 注入 statsig stable_id
if [[ -f "$_env_dir/stable_id" ]]; then
    _sid=$(tr -d '[:space:]' < "$_env_dir/stable_id")
    for _f in "$HOME/.claude/statsig"/statsig.stable_id.*; do
        [[ -f "$_f" ]] && printf '"%s"' "$_sid" > "$_f"
    done
fi

# 注入环境变量 —— 代理
export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" ALL_PROXY="$PROXY"
export NO_PROXY="localhost,127.0.0.1"
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

# 清除第三方 API 配置，强制走 OAuth 官方端点
unset ANTHROPIC_BASE_URL
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_API_KEY

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
    export CAC_PROXY_HOST="$_hp"
fi

[[ -f "$_env_dir/tz" ]]   && export TZ=$(tr -d '[:space:]' < "$_env_dir/tz")
[[ -f "$_env_dir/lang" ]] && export LANG=$(tr -d '[:space:]' < "$_env_dir/lang")
[[ -f "$_env_dir/hostname" ]] && export HOSTNAME=$(tr -d '[:space:]' < "$_env_dir/hostname")

# Node.js 级指纹拦截（绕过 shell shim 限制）
[[ -f "$_env_dir/hostname" ]]    && export CAC_HOSTNAME=$(tr -d '[:space:]' < "$_env_dir/hostname")
[[ -f "$_env_dir/mac_address" ]] && export CAC_MAC=$(tr -d '[:space:]' < "$_env_dir/mac_address")
[[ -f "$_env_dir/machine_id" ]]  && export CAC_MACHINE_ID=$(tr -d '[:space:]' < "$_env_dir/machine_id")
export CAC_USERNAME="user-$(echo "$_name" | cut -c1-8)"
if [[ -f "$CAC_DIR/fingerprint-hook.js" ]]; then
    case "${NODE_OPTIONS:-}" in
        *fingerprint-hook.js*) ;; # 已注入，跳过
        *) export NODE_OPTIONS="--require $CAC_DIR/fingerprint-hook.js ${NODE_OPTIONS:-}" ;;
    esac
fi

# 执行真实 claude
_real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude")
[[ -x "$_real" ]] || { echo "[cac] 错误：$_real 不可执行，运行 'cac setup'" >&2; exit 1; }
exec "$_real" "$@"
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
