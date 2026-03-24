# ── cmd: env (environment management, like "uv venv") ────────────

_env_cmd_create() {
    _require_setup
    local name="" proxy="" claude_ver="" env_type="local"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--proxy)  [[ $# -ge 2 ]] || _die "$1 requires a value"; proxy="$2"; shift 2 ;;
            -c|--claude) [[ $# -ge 2 ]] || _die "$1 requires a value"; claude_ver="$2"; shift 2 ;;
            --type)      [[ $# -ge 2 ]] || _die "$1 requires a value"; env_type="$2"; shift 2 ;;
            -*)          _die "unknown option: $1" ;;
            *)           [[ -z "$name" ]] && name="$1" || _die "extra argument: $1"; shift ;;
        esac
    done

    [[ -n "$name" ]] || _die "usage: cac env create <name> [-p <proxy>] [-c <version>] [--type local|container]"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || _die "invalid name '$name' (use alphanumeric, dash, underscore)"

    local env_dir="$ENVS_DIR/$name"
    [[ -d "$env_dir" ]] && _die "environment $(_cyan "'$name'") already exists"

    _timer_start

    # Auto-install version (just-in-time, like uv)
    if [[ -n "$claude_ver" ]]; then
        claude_ver=$(_ensure_version_installed "$claude_ver") || exit 1
    fi

    # Auto-detect proxy protocol
    local proxy_url=""
    if [[ -n "$proxy" ]]; then
        if [[ ! "$proxy" =~ ^(http|https|socks5):// ]]; then
            printf "Detecting proxy protocol ... "
            if proxy_url=$(_auto_detect_proxy "$proxy"); then
                echo "$(_cyan "$(echo "$proxy_url" | grep -oE '^[a-z]+')")"
            else
                echo "$(_yellow "failed, defaulting to http")"
            fi
        else
            proxy_url=$(_parse_proxy "$proxy")
        fi
    fi

    # Geo-detect timezone (single request via proxy)
    local tz="America/New_York" lang="en_US.UTF-8"
    if [[ -n "$proxy_url" ]]; then
        printf "Detecting timezone ... "
        local ip_info
        ip_info=$(curl -s --proxy "$proxy_url" --connect-timeout 8 "http://ip-api.com/json/?fields=timezone,countryCode" 2>/dev/null || true)
        if [[ -n "$ip_info" ]]; then
            local detected_tz
            detected_tz=$(echo "$ip_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timezone',''))" 2>/dev/null || true)
            [[ -n "$detected_tz" ]] && tz="$detected_tz"
            echo "$(_cyan "$tz")"
        else
            echo "$(_dim "default $tz")"
        fi
    fi

    mkdir -p "$env_dir"
    [[ -n "$proxy_url" ]] && echo "$proxy_url" > "$env_dir/proxy"
    echo "$(_new_uuid)"       > "$env_dir/uuid"
    echo "$(_new_sid)"        > "$env_dir/stable_id"
    echo "$(_new_user_id)"    > "$env_dir/user_id"
    echo "$(_new_machine_id)" > "$env_dir/machine_id"
    echo "$(_new_hostname)"   > "$env_dir/hostname"
    echo "$(_new_mac)"        > "$env_dir/mac_address"
    echo "$tz"                > "$env_dir/tz"
    echo "$lang"              > "$env_dir/lang"
    [[ -n "$claude_ver" ]]    && echo "$claude_ver" > "$env_dir/version"
    echo "$env_type"          > "$env_dir/type"
    mkdir -p "$env_dir/.claude"

    _generate_client_cert "$name" >/dev/null 2>&1 || true

    local elapsed; elapsed=$(_timer_elapsed)
    echo "$(_green_bold "Created") environment $(_cyan "$name") $(_dim "in $elapsed")"
    [[ -n "$proxy_url" ]] && echo "  $(_green "+") proxy: $proxy_url"
    [[ -n "$claude_ver" ]] && echo "  $(_green "+") claude: $(_cyan "$claude_ver")"
    echo "  $(_green "+") type: $env_type"
    echo
    echo "Activate with: $(_green "cac $name")"
}

_env_cmd_ls() {
    if [[ ! -d "$ENVS_DIR" ]] || [[ -z "$(ls -A "$ENVS_DIR" 2>/dev/null)" ]]; then
        echo "$(_dim "(no environments — create with 'cac env create <name>')")"
        return
    fi

    local current; current=$(_current_env)
    local stopped_tag=""
    [[ -f "$CAC_DIR/stopped" ]] && stopped_tag=" $(_red "[stopped]")"

    for env_dir in "$ENVS_DIR"/*/; do
        [[ -d "$env_dir" ]] || continue
        local name; name=$(basename "$env_dir")
        local proxy; proxy=$(_read "$env_dir/proxy" "")
        local ver; ver=$(_read "$env_dir/version" "system")
        local etype; etype=$(_read "$env_dir/type" "local")

        if [[ "$name" == "$current" ]]; then
            printf "  %s %s%s\n" "$(_green "▶")" "$(_bold "$name")" "$stopped_tag"
        else
            printf "    %s\n" "$name"
        fi
        local details="claude: $(_cyan "$ver")  type: $etype"
        [[ -n "$proxy" ]] && details="proxy: $proxy  $details"
        printf "      %s\n" "$details"
    done
}

_env_cmd_rm() {
    [[ -n "${1:-}" ]] || _die "usage: cac env rm <name>"
    local name="$1"
    _require_env "$name"

    local current; current=$(_current_env)
    [[ "$name" != "$current" ]] || _die "cannot remove active environment $(_cyan "'$name'")\n  switch to another environment first"

    rm -rf "$ENVS_DIR/$name"
    echo "$(_green_bold "Removed") environment $(_cyan "$name")"
}

_env_cmd_activate() {
    _require_setup
    local name="$1"
    _require_env "$name"

    _timer_start

    echo "$name" > "$CAC_DIR/current"
    rm -f "$CAC_DIR/stopped"

    if [[ -d "$ENVS_DIR/$name/.claude" ]]; then
        export CLAUDE_CONFIG_DIR="$ENVS_DIR/$name/.claude"
    fi

    _update_statsig "$(_read "$ENVS_DIR/$name/stable_id")"
    _update_claude_json_user_id "$(_read "$ENVS_DIR/$name/user_id")"

    # Relay lifecycle
    _relay_stop 2>/dev/null || true
    if [[ -f "$ENVS_DIR/$name/relay" ]] && [[ "$(_read "$ENVS_DIR/$name/relay")" == "on" ]]; then
        if _relay_start "$name" 2>/dev/null; then
            local rport; rport=$(_read "$CAC_DIR/relay.port")
            echo "  $(_green "+") relay: 127.0.0.1:$rport"
        fi
    fi

    local elapsed; elapsed=$(_timer_elapsed)
    echo "$(_green_bold "Activated") $(_bold "$name") $(_dim "in $elapsed")"
}

_env_cmd_deactivate() {
    if [[ ! -f "$CAC_DIR/current" ]]; then
        echo "$(_dim "no active environment")"
        return
    fi
    local current; current=$(_current_env)
    rm -f "$CAC_DIR/current"
    touch "$CAC_DIR/stopped"
    _relay_stop 2>/dev/null || true
    echo "$(_green_bold "Deactivated") $(_bold "$current") — claude runs unprotected"
}

cmd_env() {
    case "${1:-help}" in
        create)       _env_cmd_create "${@:2}" ;;
        ls|list)      _env_cmd_ls ;;
        rm|remove)    _env_cmd_rm "${@:2}" ;;
        activate)     _env_cmd_activate "${@:2}" ;;
        deactivate)   _env_cmd_deactivate ;;
        check)        cmd_check ;;
        help|-h|--help)
            echo "$(_bold "cac env") — environment management"
            echo
            echo "  $(_bold "create") <name> [-p <proxy>] [-c <ver>] [--type local|container]"
            echo "  $(_bold "ls")              List all environments"
            echo "  $(_bold "rm") <name>       Remove an environment"
            echo "  $(_bold "activate") <name> Activate (shortcut: cac <name>)"
            echo "  $(_bold "deactivate")      Deactivate — claude runs unprotected"
            echo "  $(_bold "check")           Verify current environment"
            ;;
        *) _die "unknown: cac env $1" ;;
    esac
}
