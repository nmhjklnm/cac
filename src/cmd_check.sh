# ── cmd: check ─────────────────────────────────────────────────

# 检测本地代理软件冲突（Clash / Surge / Shadowrocket 等）
_check_proxy_conflict() {
    local proxy="$1" proxy_ip="$2"
    local proxy_hp; proxy_hp=$(_proxy_host_port "$proxy")
    local proxy_host="${proxy_hp%%:*}"

    local os; os=$(_detect_os)
    local conflicts=()

    # ── 1. 检测 TUN 模式进程 ──
    local tun_procs="clash|mihomo|sing-box|surge|shadowrocket|v2ray|xray|hysteria|tuic|nekoray"
    local running
    if [[ "$os" == "macos" ]]; then
        running=$(ps aux 2>/dev/null | grep -iE "$tun_procs" | grep -v grep || true)
    else
        running=$(ps -eo comm 2>/dev/null | grep -iE "$tun_procs" || true)
    fi

    if [[ -n "$running" ]]; then
        local proc_names
        proc_names=$(echo "$running" | grep -ioE "$tun_procs" | sort -u | head -3)
        if [[ -n "$proc_names" ]]; then
            conflicts+=("检测到本地代理进程: $(echo "$proc_names" | tr '\n' ' ')")
        fi
    fi

    # ── 2. 检测 TUN 网卡（utun / tun）──
    if [[ "$os" == "macos" ]]; then
        local tun_count
        tun_count=$(ifconfig 2>/dev/null | grep -cE '^utun[0-9]+' || echo 0)
        if [[ "$tun_count" -gt 3 ]]; then
            conflicts+=("检测到多个 TUN 网卡 (${tun_count} 个)，可能有代理软件启用了 TUN 模式")
        fi
    elif [[ "$os" == "linux" ]]; then
        if ip link show tun0 >/dev/null 2>&1; then
            conflicts+=("检测到 tun0 网卡，可能有代理软件启用了 TUN 模式")
        fi
    fi

    # ── 3. 检测系统代理是否指向本机（macOS）──
    if [[ "$os" == "macos" ]]; then
        local net_service
        net_service=$(networksetup -listallnetworkservices 2>/dev/null | grep -iE 'Wi-Fi|Ethernet|以太网' | head -1 || true)
        if [[ -n "$net_service" ]]; then
            local sys_http_proxy
            sys_http_proxy=$(networksetup -getwebproxy "$net_service" 2>/dev/null || true)
            if echo "$sys_http_proxy" | grep -qi "Enabled: Yes"; then
                local sys_host sys_port
                sys_host=$(echo "$sys_http_proxy" | awk '/^Server:/{print $2}')
                sys_port=$(echo "$sys_http_proxy" | awk '/^Port:/{print $2}')
                [[ -n "$sys_host" ]] && conflicts+=("系统 HTTP 代理已开启: ${sys_host}:${sys_port}")
            fi
        fi
    fi

    # ── 4. 检测代理流量是否被二次转发（复用已获取的 proxy_ip）──
    local direct_ip
    direct_ip=$(curl -s --noproxy '*' --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    if [[ -n "$direct_ip" ]] && [[ -n "$proxy_ip" ]] && [[ "$direct_ip" == "$proxy_ip" ]]; then
        conflicts+=("代理出口 IP ($proxy_ip) 与直连出口 IP 相同，代理流量可能被本地软件拦截")
    fi

    # ── 输出结果 ──
    if [[ ${#conflicts[@]} -eq 0 ]]; then
        echo "$(_green "✓") 未检测到本地代理软件冲突"
        return 0
    fi

    echo "$(_yellow "⚠ 检测到可能的代理冲突")："
    for msg in "${conflicts[@]}"; do
        echo "    $(_yellow "•") $msg"
    done
    echo
    echo "    $(_bold "解决方法")：在本地代理软件中为 cac 代理服务器 IP 添加 DIRECT 规则"
    echo "    代理服务器：$(_bold "$proxy_host")"
    echo
    if [[ "$os" == "macos" ]]; then
        echo "    Clash 示例（添加到规则列表最前面）："
        echo "      - IP-CIDR,${proxy_host}/32,DIRECT"
    fi
    return 1
}

cmd_check() {
    _require_setup

    local current; current=$(_current_env)

    if [[ -f "$CAC_DIR/stopped" ]]; then
        echo "$(_yellow "⚠ cac 已停用（cac stop）") — claude 裸跑中"
        echo "  恢复：cac ${current:-<name>}"
        return
    fi

    if [[ -z "$current" ]]; then
        echo "错误：未激活任何环境，运行 'cac <name>'" >&2; exit 1
    fi

    local env_dir="$ENVS_DIR/$current"
    local proxy; proxy=$(_read "$env_dir/proxy" "")

    echo "当前环境：$(_bold "$current")"
    echo "  代理      ：${proxy:-（无代理）}"
    echo "  UUID      ：$(_read "$env_dir/uuid")"
    echo "  stable_id ：$(_read "$env_dir/stable_id")"
    echo "  user_id   ：$(_read "$env_dir/user_id" "（旧环境，无此字段）")"
    echo "  版本      ：$(_read "$env_dir/version" "system")"
    echo "  TZ        ：$(_read "$env_dir/tz" "（未设置）")"
    echo "  LANG      ：$(_read "$env_dir/lang" "（未设置）")"
    echo

    # ── 网络连通性（仅在有代理时检查）──
    if [[ -n "$proxy" ]]; then
        printf "  TCP 连通  ... "
        if ! _proxy_reachable "$proxy"; then
            echo "$(_red "✗ 不通")"; return
        fi
        echo "$(_green "✓")"

        printf "  出口 IP   ... "
        local proxy_ip
        proxy_ip=$(curl -s --proxy "$proxy" \
             --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
        if [[ -n "$proxy_ip" ]]; then
            echo "$(_green "$proxy_ip")"
        else
            echo "$(_yellow "获取失败")"
        fi
    else
        echo "  $(_dim "（无代理，跳过网络检查）")"
    fi

    # ── 本地代理冲突检测（仅在有代理时）──
    if [[ -n "$proxy" ]]; then
        echo
        echo "── 冲突检测 ────────────────────────────────────────────"
        printf "  代理冲突  ... "
        _check_proxy_conflict "$proxy" "${proxy_ip:-}"
    fi

    echo
    echo "── Relay 中转 ────────────────────────────────────────"
    if _relay_is_running; then
        local rpid; rpid=$(_read "$CAC_DIR/relay.pid")
        local rport; rport=$(_read "$CAC_DIR/relay.port" "未知")
        printf "  Relay 进程 ... %s (PID=%s, 端口=%s)\n" "$(_green "运行中")" "$rpid" "$rport"
    elif [[ -n "$proxy" ]]; then
        # 有代理时临时启动 relay 做连通性测试
        printf "  Relay 测试 ... "
        if _relay_start "$current" 2>/dev/null; then
            local rport; rport=$(_read "$CAC_DIR/relay.port" "")
            local relay_ip
            relay_ip=$(curl -s --proxy "http://127.0.0.1:$rport" --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
            if [[ -n "$relay_ip" ]]; then
                printf "%s (端口=%s, 出口=%s)\n" "$(_green "✓ 连通")" "$rport" "$(_cyan "$relay_ip")"
            else
                printf "%s (端口=%s, 代理不通)\n" "$(_yellow "⚠ 启动成功但无法连通")" "$rport"
            fi
            _relay_stop 2>/dev/null || true
        else
            printf "%s\n" "$(_red "✗ 启动失败")"
        fi
        echo "  $(_dim "（relay 将在 claude 启动时自动启用）")"
    else
        echo "  Relay     ... $(_dim "（无代理，不需要 relay）")"
    fi

    echo
    echo "── 安全防护状态 ──────────────────────────────────────"

    # ── NS 层级 DNS 拦截 ──
    printf "  DNS 拦截  ... "
    _check_dns_block "statsig.anthropic.com"

    # ── 多层环境变量保护（单次读取 wrapper 文件）──
    echo "  环境变量保护："
    local wrapper_file="$CAC_DIR/bin/claude"
    local wrapper_content=""
    [[ -f "$wrapper_file" ]] && wrapper_content=$(<"$wrapper_file")
    local env_vars=(
        "CLAUDE_CODE_ENABLE_TELEMETRY"
        "DO_NOT_TRACK"
        "OTEL_SDK_DISABLED"
        "OTEL_TRACES_EXPORTER"
        "OTEL_METRICS_EXPORTER"
        "OTEL_LOGS_EXPORTER"
        "SENTRY_DSN"
        "DISABLE_ERROR_REPORTING"
        "DISABLE_BUG_COMMAND"
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
        "TELEMETRY_DISABLED"
        "DISABLE_TELEMETRY"
    )
    for var in "${env_vars[@]}"; do
        printf "    %-32s" "$var"
        if [[ "$wrapper_content" == *"$var"* ]]; then
            echo "$(_green "✓ 已配置")"
        else
            echo "$(_red "✗ 未找到")"
        fi
    done

    # ── mTLS 证书 ──
    printf "  mTLS 认证 ... "
    _check_mtls "$env_dir"
}
