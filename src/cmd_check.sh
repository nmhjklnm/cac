# ── cmd: check ─────────────────────────────────────────────────

cmd_check() {
    _require_setup

    local verbose=false
    [[ "${1:-}" == "-d" || "${1:-}" == "--detail" ]] && verbose=true

    local current; current=$(_current_env)

    if [[ -f "$CAC_DIR/stopped" ]]; then
        echo "$(_red "✗") cac 已停用 — 运行 'cac <name>' 恢复"
        return
    fi
    if [[ -z "$current" ]]; then
        echo "错误：未激活任何环境，运行 'cac <name>'" >&2; exit 1
    fi

    local env_dir="$ENVS_DIR/$current"
    local proxy; proxy=$(_read "$env_dir/proxy" "")

    # 解析版本号
    local ver; ver=$(_read "$env_dir/version" "")
    if [[ -z "$ver" ]] || [[ "$ver" == "system" ]]; then
        local _real; _real=$(_read "$CAC_DIR/real_claude" "")
        if [[ -n "$_real" ]] && [[ -x "$_real" ]]; then
            ver=$("$_real" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
        else
            ver="?"
        fi
    fi

    local problems=()
    local summary_parts=()

    # ── wrapper 检查 ──
    local claude_path; claude_path="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$claude_path" ]] || [[ "$(readlink -f "$claude_path" 2>/dev/null || echo "$claude_path")" != *"/.cac/bin/claude"* ]]; then
        if [[ "$claude_path" != *"/.cac/bin/claude" ]]; then
            problems+=("claude 未指向 wrapper — 运行 source ~/.zshrc 或重开终端")
        fi
    fi

    # ── 网络检查 ──
    local proxy_ip=""
    if [[ -n "$proxy" ]]; then
        if ! _proxy_reachable "$proxy"; then
            problems+=("代理不通: $proxy")
        else
            proxy_ip=$(curl -s --proxy "$proxy" --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
            if [[ -n "$proxy_ip" ]]; then
                summary_parts+=("出口 $proxy_ip")
            else
                problems+=("出口 IP 获取失败")
            fi
        fi

        # 冲突检测（仅代理连通时才有意义）
        if [[ -n "$proxy_ip" ]]; then
        local os; os=$(_detect_os)
        local has_conflict=false
        local tun_procs="clash|mihomo|sing-box|surge|shadowrocket|v2ray|xray|hysteria|tuic|nekoray"
        local running
        if [[ "$os" == "macos" ]]; then
            running=$(ps aux 2>/dev/null | grep -iE "$tun_procs" | grep -v grep || true)
        else
            running=$(ps -eo comm 2>/dev/null | grep -iE "$tun_procs" || true)
        fi
        [[ -n "$running" ]] && has_conflict=true
        if [[ "$os" == "macos" ]]; then
            local tun_count; tun_count=$(ifconfig 2>/dev/null | grep -cE '^utun[0-9]+' || echo 0)
            [[ "$tun_count" -gt 3 ]] && has_conflict=true
        elif [[ "$os" == "linux" ]]; then
            ip link show tun0 >/dev/null 2>&1 && has_conflict=true
        fi

        if [[ "$has_conflict" == "true" ]]; then
            # 检查直连路由是否到位（不依赖 relay 连通性）
            if _relay_route_ok "$proxy"; then
                summary_parts+=("TUN 直连路由 ✓")
            else
                # 尝试自动修复
                if _relay_ensure_route "$proxy"; then
                    summary_parts+=("TUN 直连路由 ✓（已自动修复）")
                else
                    problems+=("TUN 活跃但直连路由缺失 — 运行 'cac check' 时加 sudo 或手动执行 'cac relay on --route'")
                fi
            fi
        fi
        fi
    else
        summary_parts+=("API Key 模式")
    fi

    # ── 防护检查 ──
    local wrapper_file="$CAC_DIR/bin/claude"
    local wrapper_content=""
    [[ -f "$wrapper_file" ]] && wrapper_content=$(<"$wrapper_file")
    local env_vars=(
        "CLAUDE_CODE_ENABLE_TELEMETRY" "DO_NOT_TRACK"
        "OTEL_SDK_DISABLED" "OTEL_TRACES_EXPORTER" "OTEL_METRICS_EXPORTER" "OTEL_LOGS_EXPORTER"
        "SENTRY_DSN" "DISABLE_ERROR_REPORTING" "DISABLE_BUG_COMMAND"
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "TELEMETRY_DISABLED" "DISABLE_TELEMETRY"
    )
    local env_ok=0 env_total=${#env_vars[@]}
    for var in "${env_vars[@]}"; do
        [[ "$wrapper_content" == *"$var"* ]] && (( env_ok++ )) || true
    done

    if [[ "$env_ok" -eq "$env_total" ]]; then
        summary_parts+=("遥测屏蔽 ${env_ok}/${env_total}")
    else
        problems+=("遥测屏蔽 ${env_ok}/${env_total}")
    fi

    # ── 输出结论 ──
    if [[ ${#problems[@]} -eq 0 ]]; then
        echo "$(_green "✓") $(_bold "$current") (claude $(_cyan "$ver")) — 一切正常"
        echo "  $(IFS=' | '; echo "${summary_parts[*]}")"
    else
        echo "$(_red "✗") $(_bold "$current") (claude $(_cyan "$ver")) — 发现 ${#problems[@]} 个问题"
        for p in "${problems[@]}"; do
            echo "  $(_red "✗") $p"
        done
    fi

    # ── 详细模式 ──
    if [[ "$verbose" == "true" ]]; then
        echo
        echo "  UUID      : $(_read "$env_dir/uuid")"
        echo "  stable_id : $(_read "$env_dir/stable_id")"
        echo "  user_id   : $(_read "$env_dir/user_id" "—")"
        echo "  TZ        : $(_read "$env_dir/tz" "—")"
        echo "  LANG      : $(_read "$env_dir/lang" "—")"
        echo "  遥测屏蔽  : ${env_ok}/${env_total}"
        for var in "${env_vars[@]}"; do
            printf "    %-36s" "$var"
            [[ "$wrapper_content" == *"$var"* ]] && echo "$(_green "✓")" || echo "$(_red "✗")"
        done
        printf "  DNS 拦截  : "
        if [[ -f "$CAC_DIR/cac-dns-guard.js" ]]; then
            _check_dns_block "statsig.anthropic.com"
        else
            echo "$(_red "✗")"
        fi
        printf "  mTLS      : "
        _check_mtls "$env_dir"
    fi
}
