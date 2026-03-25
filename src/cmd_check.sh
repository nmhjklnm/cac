# ── cmd: check ─────────────────────────────────────────────────

cmd_check() {
    _require_setup

    local verbose=false
    [[ "${1:-}" == "-d" || "${1:-}" == "--detail" ]] && verbose=true

    local current; current=$(_current_env)

    if [[ -z "$current" ]]; then
        echo "error: no active environment — run $(_green "cac env create <name>")" >&2; exit 1
    fi

    local env_dir="$ENVS_DIR/$current"
    local proxy; proxy=$(_read "$env_dir/proxy" "")

    # Resolve version
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
    local checks=()

    # ── wrapper check ──
    local claude_path; claude_path="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$claude_path" ]] || [[ "$claude_path" != *"/.cac/bin/claude" ]]; then
        local _rc; _rc=$(_detect_rc_file)
        if [[ -n "$_rc" ]] && grep -q '# >>> cac' "$_rc" 2>/dev/null; then
            # Block exists in rc — will work in next interactive terminal
            checks+=("$(_green "✓") wrapper    configured in ${_rc/#$HOME/~}")
        else
            # Missing — fix it now
            _write_path_to_rc "$_rc" >/dev/null 2>&1 || true
            checks+=("$(_green "✓") wrapper    $(_dim "added to ${_rc/#$HOME/~}")")
        fi
    else
        checks+=("$(_green "✓") wrapper    active")
    fi

    # ── network check ──
    local proxy_ip=""
    if [[ -n "$proxy" ]]; then
        if ! _proxy_reachable "$proxy"; then
            problems+=("proxy unreachable: $proxy")
        else
            local _ip_url
            for _ip_url in https://ifconfig.me https://api.ipify.org https://ipinfo.io/ip; do
                proxy_ip=$(curl -s --proxy "$proxy" --connect-timeout 5 "$_ip_url" 2>/dev/null || true)
                # Validate: should look like an IP address
                [[ "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
                proxy_ip=""
            done
            if [[ -n "$proxy_ip" ]]; then
                checks+=("$(_green "✓") exit IP    $(_cyan "$proxy_ip")")
            else
                problems+=("failed to get exit IP")
            fi
        fi

        # TUN conflict detection (only meaningful when proxy is reachable)
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
            # Test relay
            local relay_ok=false
            if _relay_is_running 2>/dev/null; then
                local rport; rport=$(_read "$CAC_DIR/relay.port" "")
                local relay_ip; relay_ip=$(curl -s --proxy "http://127.0.0.1:$rport" --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
                [[ -n "$relay_ip" ]] && relay_ok=true
            elif [[ -f "$CAC_DIR/relay.js" ]]; then
                local _test_env; _test_env=$(_current_env)
                if _relay_start "$_test_env" 2>/dev/null; then
                    local rport; rport=$(_read "$CAC_DIR/relay.port" "")
                    local relay_ip; relay_ip=$(curl -s --proxy "http://127.0.0.1:$rport" --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
                    _relay_stop 2>/dev/null || true
                    [[ -n "$relay_ip" ]] && relay_ok=true
                fi
            fi

            if [[ "$relay_ok" == "true" ]]; then
                checks+=("$(_green "✓") TUN        relay bypass active")
            else
                local proxy_hp; proxy_hp=$(_proxy_host_port "$proxy")
                local proxy_host="${proxy_hp%%:*}"
                problems+=("TUN conflict: add DIRECT rule for $proxy_host in proxy software")
            fi
        fi
        fi
    else
        checks+=("$(_green "✓") mode       API Key (no proxy)")
    fi

    # ── telemetry shield ──
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
        checks+=("$(_green "✓") telemetry  ${env_ok}/${env_total} blocked")
    else
        problems+=("telemetry shield ${env_ok}/${env_total}")
    fi

    # ── output ──
    echo
    if [[ ${#problems[@]} -eq 0 ]]; then
        echo "  $(_green "✓") $(_bold "$current") $(_dim "(claude $ver)") — all good"
    else
        echo "  $(_red "✗") $(_bold "$current") $(_dim "(claude $ver)") — ${#problems[@]} issue(s)"
    fi
    echo

    for c in "${checks[@]}"; do
        echo "    $c"
    done
    for p in "${problems[@]}"; do
        echo "    $(_red "✗") $p"
    done
    echo

    # ── verbose mode ──
    if [[ "$verbose" == "true" ]]; then
        echo "  $(_bold "Details")"
        echo "    $(_dim "UUID")       $(_read "$env_dir/uuid")"
        echo "    $(_dim "stable_id")  $(_read "$env_dir/stable_id")"
        echo "    $(_dim "user_id")    $(_read "$env_dir/user_id" "—")"
        echo "    $(_dim "TZ")         $(_read "$env_dir/tz" "—")"
        echo "    $(_dim "LANG")       $(_read "$env_dir/lang" "—")"
        echo "    $(_dim "env")        ${env_dir/#$HOME/~}/.claude/"
        echo
        echo "  $(_bold "Telemetry") ${env_ok}/${env_total}"
        for var in "${env_vars[@]}"; do
            if [[ "$wrapper_content" == *"$var"* ]]; then
                printf "    $(_green "✓") %s\n" "$var"
            else
                printf "    $(_red "✗") %s\n" "$var"
            fi
        done
        echo
        printf "  $(_bold "DNS block")  "
        if [[ -f "$CAC_DIR/cac-dns-guard.js" ]]; then
            _check_dns_block "statsig.anthropic.com"
        else
            echo "$(_red "✗")"
        fi
        printf "  $(_bold "mTLS")       "
        _check_mtls "$env_dir"
        echo
    fi
}
