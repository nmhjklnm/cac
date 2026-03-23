# ── cmd: login ─────────────────────────────────────────────────

cmd_login() {
    _require_setup
    local current; current=$(_current_env)
    if [[ -z "$current" ]]; then
        echo "错误：未激活环境，先运行 'cac <name>'" >&2; exit 1
    fi

    local env_dir="$ENVS_DIR/$current"
    local proxy; proxy=$(_read "$env_dir/proxy")
    local real_claude; real_claude=$(_read "$CAC_DIR/real_claude")

    [[ -x "$real_claude" ]] || {
        echo "错误：$real_claude 不可执行，运行 'cac setup'" >&2; exit 1
    }

    # 检查是否已登录
    if [[ -f "$HOME/.claude/.credentials.json" ]]; then
        echo "$(_green "✓") 已登录，可直接运行 claude"
        return
    fi

    echo "$(_bold "cac login") — 首次登录"
    echo "  环境：$current"
    echo "  代理：$proxy"
    echo

    # 注入与 wrapper 完全相同的环境变量（所有保护生效）
    export HTTPS_PROXY="$proxy" HTTP_PROXY="$proxy" ALL_PROXY="$proxy"
    export NO_PROXY="localhost,127.0.0.1"
    export CLAUDE_CODE_ENABLE_TELEMETRY= DO_NOT_TRACK=1
    export OTEL_SDK_DISABLED=true SENTRY_DSN=
    export OTEL_TRACES_EXPORTER=none OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none
    export DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export TELEMETRY_DISABLED=1 DISABLE_TELEMETRY=1
    unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY

    [[ -f "$env_dir/hostname" ]]    && export CAC_HOSTNAME=$(_read "$env_dir/hostname")
    [[ -f "$env_dir/mac_address" ]] && export CAC_MAC=$(_read "$env_dir/mac_address")
    [[ -f "$env_dir/machine_id" ]]  && export CAC_MACHINE_ID=$(_read "$env_dir/machine_id")
    export CAC_USERNAME="user-$(echo "$current" | cut -c1-8)"

    local node_opts=""
    [[ -f "$CAC_DIR/fingerprint-hook.js" ]] && node_opts="--require $CAC_DIR/fingerprint-hook.js"
    [[ -f "$CAC_DIR/cac-dns-guard.js" ]]    && node_opts="$node_opts --require $CAC_DIR/cac-dns-guard.js"
    [[ -n "$node_opts" ]] && export NODE_OPTIONS="$node_opts"

    # statsig stable_id
    _update_statsig "$(_read "$env_dir/stable_id")"
    _update_claude_json_user_id "$(_read "$env_dir/user_id")"

    echo "  ⏳ 启动后可能需要等待 30-60 秒通过连接检查"
    echo "  📋 进入界面后输入 $(_bold "/login") 完成 OAuth 授权"
    echo "  ✅ 登录成功后输入 $(_bold "/exit") 退出，之后直接运行 claude 即可"
    echo
    exec "$real_claude" "$@"
}

# ── cmd: stop / continue ───────────────────────────────────────

cmd_stop() {
    touch "$CAC_DIR/stopped"
    local current; current=$(_current_env)
    echo "$(_yellow "⚠ cac 已停用") — claude 将裸跑（无代理、无伪装）"
    echo "  恢复：cac -c"
}

cmd_continue() {
    if [[ ! -f "$CAC_DIR/stopped" ]]; then
        echo "cac 当前未停用，无需恢复"
        return
    fi

    local current; current=$(_current_env)
    if [[ -z "$current" ]]; then
        echo "错误：没有已激活的环境，运行 'cac <name>'" >&2; exit 1
    fi

    rm -f "$CAC_DIR/stopped"
    echo "$(_green "✓") cac 已恢复 — 当前环境：$(_bold "$current")"
}
