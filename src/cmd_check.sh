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
        echo "    $(_green "✓") telemetry  ${env_ok}/${env_total} blocked"
    else
        echo "    $(_red "✗") telemetry  ${env_ok}/${env_total} blocked"
        problems+=("telemetry shield ${env_ok}/${env_total}")
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
            else
                printf "\r    $(_green "✓") exit IP    $(_dim "run again to detect exit IP")\033[K\n"
            fi

            # TUN conflict detection — check route instead of relay connectivity
            if _detect_tun_active 2>/dev/null; then
                if _relay_route_ok "$proxy" 2>/dev/null; then
                    echo "    $(_green "✓") TUN        direct route OK"
                else
                    if _relay_add_route "$proxy" 2>/dev/null; then
                        echo "    $(_green "✓") TUN        direct route $(_dim "added")"
                    else
                        echo "    $(_red "✗") TUN        route missing — may need sudo"
                        problems+=("TUN active but direct route missing for proxy")
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
