# ── cmd: setup ─────────────────────────────────────────────────

cmd_setup() {
    echo "=== cac setup ==="

    local real_claude
    real_claude=$(_find_real_claude)
    if [[ -z "$real_claude" ]]; then
        echo "错误：找不到 claude 命令，请先安装 Claude CLI" >&2
        echo "  npm install -g @anthropic-ai/claude-code" >&2
        exit 1
    fi
    echo "  真实 claude：$real_claude"

    mkdir -p "$ENVS_DIR"
    echo "$real_claude" > "$CAC_DIR/real_claude"

    local os; os=$(_detect_os)
    _write_wrapper

    # 复制 Node.js 指纹钩子
    local _hook_src
    _hook_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fingerprint-hook.js"
    if [[ -f "$_hook_src" ]]; then
        cp "$_hook_src" "$CAC_DIR/fingerprint-hook.js"
        echo "  ✓ fingerprint hook → $CAC_DIR/fingerprint-hook.js"
    elif [[ -f "$CAC_DIR/fingerprint-hook.js" ]]; then
        echo "  ✓ fingerprint hook（已存在）"
    else
        echo "  ⚠ fingerprint-hook.js 未找到，Node.js 级指纹拦截不可用" >&2
    fi

    # 复制 relay.js
    local _relay_src
    _relay_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relay.js"
    if [[ -f "$_relay_src" ]]; then
        cp "$_relay_src" "$CAC_DIR/relay.js"
        echo "  ✓ relay → $CAC_DIR/relay.js"
    elif [[ -f "$CAC_DIR/relay.js" ]]; then
        echo "  ✓ relay（已存在）"
    fi

    _write_hostname_shim
    _write_ifconfig_shim

    if [[ "$os" == "macos" ]]; then
        _write_ioreg_shim
        echo "  ✓ ioreg shim → $CAC_DIR/shim-bin/ioreg"
    elif [[ "$os" == "linux" ]]; then
        _write_machine_id_shim
        echo "  ✓ machine-id shim → $CAC_DIR/shim-bin/cat"
    fi

    echo "  ✓ wrapper → $CAC_DIR/bin/claude"
    echo "  ✓ hostname shim → $CAC_DIR/shim-bin/hostname"
    echo "  ✓ ifconfig shim → $CAC_DIR/shim-bin/ifconfig"

    # DNS guard (NS 层级遥测拦截 + DoH)
    _write_dns_guard_js
    _write_blocked_hosts
    echo "  ✓ DNS guard → $CAC_DIR/cac-dns-guard.js"
    echo "  ✓ blocked hosts → $CAC_DIR/blocked_hosts"

    # mTLS CA 证书
    _generate_ca_cert
    echo "  ✓ mTLS CA → $CAC_DIR/ca/ca_cert.pem"

    # 健康检查 bypass 证书
    if _generate_health_bypass_cert; then
        echo "  ✓ health bypass cert → $CAC_DIR/ca/hb_cert.pem"
    fi

    # 自动写入 PATH 到 shell rc 文件
    local rc_file
    rc_file=$(_detect_rc_file)
    _write_path_to_rc "$rc_file"

    echo
    echo "── 下一步 ──────────────────────────────────────────────"
    if [[ -n "$rc_file" ]]; then
        echo "1. 执行以下命令使配置生效（或重开终端）："
        echo "   source $rc_file"
    fi
    echo
    echo "2. 添加第一个环境（二选一）："
    echo "   有代理：cac add <名字> <host:port:user:pass>"
    echo "   无代理：cac add <名字>                      # 仅指纹隔离，配合第三方中转使用"
    echo "   切换：  cac <名字>"
}
