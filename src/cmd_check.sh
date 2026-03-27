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

    # ── header (neutral, no pass/fail yet) ──
    echo
    echo "  $(_bold "$current") $(_dim "(claude $ver)")"
    echo

    # ── wrapper check (instant) ──
    local claude_path; claude_path="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$claude_path" ]] || [[ "$claude_path" != *"/.cac/bin/claude" ]]; then
        local _rc; _rc=$(_detect_rc_file)
        if [[ -n "$_rc" ]] && grep -q '# >>> cac' "$_rc" 2>/dev/null; then
            echo "    $(_green "✓") wrapper    configured in ${_rc/#$HOME/~}"
        else
            _write_path_to_rc "$_rc" >/dev/null 2>&1 || true
            echo "    $(_green "✓") wrapper    $(_dim "added to ${_rc/#$HOME/~}")"
        fi
    else
        echo "    $(_green "✓") wrapper    active"
    fi

    # ── telemetry shield (instant) ──
    local wrapper_file="$CAC_DIR/bin/claude"
    local wrapper_content=""
    [[ -f "$wrapper_file" ]] && wrapper_content=$(<"$wrapper_file")
    local telemetry_mode; telemetry_mode=$(_read "$env_dir/telemetry_mode" "conservative")
    if [[ "$telemetry_mode" == "off" ]]; then
        echo "    $(_dim "○") telemetry  off (no protection)"
    elif [[ "$telemetry_mode" == "aggressive" ]]; then
        local env_vars=(
            "CLAUDE_CODE_ENABLE_TELEMETRY" "DO_NOT_TRACK"
            "OTEL_SDK_DISABLED" "OTEL_TRACES_EXPORTER" "OTEL_METRICS_EXPORTER" "OTEL_LOGS_EXPORTER"
            "SENTRY_DSN" "DISABLE_ERROR_REPORTING" "DISABLE_BUG_COMMAND"
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "TELEMETRY_DISABLED" "DISABLE_TELEMETRY"
            "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"
        )
        local env_ok=0 env_total=${#env_vars[@]}
        for var in "${env_vars[@]}"; do
            [[ "$wrapper_content" == *"$var"* ]] && (( env_ok++ )) || true
        done
        if [[ "$env_ok" -eq "$env_total" ]]; then
            echo "    $(_green "✓") telemetry  aggressive ${env_ok}/${env_total} blocked"
        else
            echo "    $(_red "✗") telemetry  aggressive ${env_ok}/${env_total} blocked"
            problems+=("telemetry shield ${env_ok}/${env_total}")
        fi
    else
        # Conservative: just check the 2 essential vars
        local cons_ok=0
        [[ "$wrapper_content" == *"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"* ]] && (( cons_ok++ )) || true
        [[ "$wrapper_content" == *"CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"* ]] && (( cons_ok++ )) || true
        if [[ "$cons_ok" -eq 2 ]]; then
            echo "    $(_green "✓") telemetry  conservative (non-essential blocked)"
        else
            echo "    $(_red "✗") telemetry  conservative ($cons_ok/2)"
            problems+=("telemetry shield incomplete")
        fi
    fi

    # ── fingerprint hook runtime verification ──
    if [[ -f "$CAC_DIR/fingerprint-hook.js" ]] && [[ -f "$env_dir/hostname" ]]; then
        local expected_hn; expected_hn=$(_read "$env_dir/hostname")
        local actual_hn
        actual_hn=$(NODE_OPTIONS="--require $CAC_DIR/fingerprint-hook.js" CAC_HOSTNAME="$expected_hn" \
            node -e "process.stdout.write(require('os').hostname())" 2>/dev/null || true)
        if [[ "$actual_hn" == "$expected_hn" ]]; then
            echo "    $(_green "✓") fingerprint spoofed ($(_dim "$expected_hn"))"
        else
            echo "    $(_red "✗") fingerprint NOT spoofed (got: $actual_hn)"
            problems+=("fingerprint hook not working")
        fi
    fi

    # ── IPv6 leak detection ──
    local os; os=$(_detect_os)
    local ipv6_leak=false
    if [[ "$os" == "macos" ]]; then
        local ipv6_addrs
        ipv6_addrs=$(ifconfig 2>/dev/null | grep -c "inet6 [2-3]" || true)
        [[ "$ipv6_addrs" -gt 0 ]] && ipv6_leak=true
    elif [[ "$os" == "linux" ]]; then
        local ipv6_addrs
        ipv6_addrs=$(ip -6 addr show scope global 2>/dev/null | grep -c "inet6" || true)
        [[ "$ipv6_addrs" -gt 0 ]] && ipv6_leak=true
    fi
    if [[ "$ipv6_leak" == "true" ]]; then
        echo "    $(_yellow "⚠") IPv6      global address detected (potential leak)"
    else
        echo "    $(_green "✓") IPv6      no global address"
    fi

    # ── residual telemetry files ──
    if [[ -d "$HOME/.claude/telemetry" ]]; then
        local tel_files
        tel_files=$(find "$HOME/.claude/telemetry" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$tel_files" -gt 0 ]]; then
            echo "    $(_yellow "⚠") residual  $tel_files telemetry files in ~/.claude/telemetry/"
            echo "              $(_dim "hint: rm -rf ~/.claude/telemetry/")"
        fi
    fi

    # ── concurrent sessions ──
    local _claude_count
    _claude_count=$(pgrep -cf "claude" 2>/dev/null || true)
    [[ -z "$_claude_count" ]] && _claude_count=0
    local _max_sessions; _max_sessions=$(_cac_setting max_sessions 10)
    if [[ "$_claude_count" -gt "$_max_sessions" ]]; then
        echo "    $(_yellow "⚠") sessions  $_claude_count running (threshold: $_max_sessions)"
    fi

    # ── network check (slow — streaming output) ──
    local proxy_ip=""
    if [[ -n "$proxy" ]]; then
        if ! _proxy_reachable "$proxy"; then
            echo "    $(_red "✗") proxy      unreachable"
            problems+=("proxy unreachable: $proxy")
        else
            # Fast retry with dots: each attempt adds a dot
            local _ip_url _dots=""
            local _urls="https://api.ip.sb/ip https://ip.3322.net https://api.ipify.org https://ipinfo.io/ip https://api.ip.sb/ip"
            for _ip_url in $_urls; do
                _dots="${_dots}."
                printf "\r    · exit IP    $(_dim "detecting${_dots}")"
                proxy_ip=$(curl --proxy "$proxy" --connect-timeout 3 --max-time 6 "$_ip_url" 2>/dev/null || true)
                [[ "$proxy_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
                proxy_ip=""
            done
            # Overwrite the "detecting..." line
            if [[ -n "$proxy_ip" ]]; then
                printf "\r    $(_green "✓") exit IP    $(_cyan "$proxy_ip")\033[K\n"
                # TZ vs exit IP consistency check
                local env_tz; env_tz=$(_read "$env_dir/tz" "")
                if [[ -n "$env_tz" ]] && [[ -n "$proxy_ip" ]]; then
                    local ip_tz
                    ip_tz=$(curl -s --proxy "$proxy" --connect-timeout 5 "http://ip-api.com/json/$proxy_ip?fields=timezone" 2>/dev/null | \
                        python3 -c "import sys,json; print(json.load(sys.stdin).get('timezone',''))" 2>/dev/null || true)
                    if [[ -n "$ip_tz" ]] && [[ "$ip_tz" != "$env_tz" ]]; then
                        echo "    $(_yellow "⚠") TZ        mismatch: env=$env_tz, IP=$ip_tz"
                        problems+=("TZ mismatch: env=$env_tz vs IP=$ip_tz")
                    fi
                fi
            else
                printf "\r    $(_green "✓") exit IP    $(_dim "run again to detect exit IP")\033[K\n"
            fi

            # TUN conflict detection
            if [[ -n "$proxy_ip" ]]; then
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
                local relay_ok=false
                if _relay_is_running 2>/dev/null; then
                    local rport; rport=$(_read "$CAC_DIR/relay.port" "")
                    local relay_ip; relay_ip=$(curl --proxy "http://127.0.0.1:$rport" --connect-timeout 8 --max-time 12 https://api.ipify.org 2>/dev/null || true)
                    [[ -n "$relay_ip" ]] && relay_ok=true
                elif [[ -f "$CAC_DIR/relay.js" ]]; then
                    local _test_env; _test_env=$(_current_env)
                    if _relay_start "$_test_env" 2>/dev/null; then
                        local rport; rport=$(_read "$CAC_DIR/relay.port" "")
                        local relay_ip; relay_ip=$(curl --proxy "http://127.0.0.1:$rport" --connect-timeout 8 --max-time 12 https://api.ipify.org 2>/dev/null || true)
                        _relay_stop 2>/dev/null || true
                        [[ -n "$relay_ip" ]] && relay_ok=true
                    fi
                fi

                if [[ "$relay_ok" == "true" ]]; then
                    echo "    $(_green "✓") TUN        relay bypass active"
                else
                    local proxy_hp; proxy_hp=$(_proxy_host_port "$proxy")
                    local proxy_host="${proxy_hp%%:*}"
                    echo "    $(_red "✗") TUN        conflict — add DIRECT rule for $proxy_host"
                    problems+=("TUN conflict: add DIRECT rule for $proxy_host in proxy software")
                fi
            fi
            fi
        fi
    else
        echo "    $(_green "✓") mode       API Key (no proxy)"
    fi

    # ── summary ──
    echo
    if [[ ${#problems[@]} -eq 0 ]]; then
        echo "  $(_green "✓") all good"
    else
        for p in "${problems[@]}"; do
            echo "  $(_red "✗") $p"
        done
    fi
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
        echo "  $(_bold "Telemetry") ($telemetry_mode mode)"
        if [[ "$telemetry_mode" == "off" ]]; then
            echo "    $(_dim "  no telemetry protection active")"
        fi
        local verbose_vars=(
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"
        )
        if [[ "$telemetry_mode" == "aggressive" ]]; then
            verbose_vars=(
                "CLAUDE_CODE_ENABLE_TELEMETRY" "DO_NOT_TRACK"
                "OTEL_SDK_DISABLED" "OTEL_TRACES_EXPORTER" "OTEL_METRICS_EXPORTER" "OTEL_LOGS_EXPORTER"
                "SENTRY_DSN" "DISABLE_ERROR_REPORTING" "DISABLE_BUG_COMMAND"
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "TELEMETRY_DISABLED" "DISABLE_TELEMETRY"
                "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"
            )
        fi
        for var in "${verbose_vars[@]}"; do
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
