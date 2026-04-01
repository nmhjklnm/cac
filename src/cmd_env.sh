# ── cmd: env (environment management, like "uv venv") ────────────

_env_cmd_create() {
    _require_setup
    local name="" proxy="" claude_ver="" env_type="local" telemetry_mode="" clone_source="" clone_link=true persona=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--proxy)  [[ $# -ge 2 ]] || _die "$1 requires a value"; proxy="$2"; shift 2 ;;
            -c|--claude) [[ $# -ge 2 ]] || _die "$1 requires a value"; claude_ver="$2"; shift 2 ;;
            --type)      [[ $# -ge 2 ]] || _die "$1 requires a value"; env_type="$2"; shift 2 ;;
            --telemetry) [[ $# -ge 2 ]] || _die "$1 requires a value"; telemetry_mode="$2"; shift 2
                         # Accept both old and new names
                         case "$telemetry_mode" in
                             conservative) telemetry_mode="stealth" ;;
                             aggressive)   telemetry_mode="paranoid" ;;
                             off)          telemetry_mode="transparent" ;;
                         esac
                         [[ "$telemetry_mode" =~ ^(stealth|paranoid|transparent)$ ]] || _die "invalid telemetry mode '$telemetry_mode' (use stealth, paranoid, or transparent)" ;;
            --persona)   [[ $# -ge 2 ]] || _die "$1 requires a value"; persona="$2"; shift 2
                         [[ "$persona" =~ ^(macos-vscode|macos-cursor|macos-iterm|linux-desktop)$ ]] || _die "invalid persona '$persona' (use macos-vscode, macos-cursor, macos-iterm, or linux-desktop)" ;;
            --clone)     shift; if [[ -n "${1:-}" ]] && [[ "${1:-}" != -* ]]; then clone_source="$1"; shift; else clone_source="host"; fi ;;
            --no-link)   clone_link=false; shift ;;
            -*)          _die "unknown option: $1" ;;
            *)           [[ -z "$name" ]] && name="$1" || _die "extra argument: $1"; shift ;;
        esac
    done

    [[ -n "$name" ]] || _die "usage: cac env create <name> [-p <proxy>] [-c <version>] [--telemetry <mode>] [--persona <preset>]"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || _die "invalid name '$name' (use alphanumeric, dash, underscore)"

    local env_dir="$ENVS_DIR/$name"
    [[ -d "$env_dir" ]] && _die "environment $(_cyan "'$name'") already exists"

    _timer_start

    # Auto-install version (just-in-time, like uv)
    # No version specified → use latest
    [[ -z "$claude_ver" ]] && claude_ver="latest"
    claude_ver=$(_ensure_version_installed "$claude_ver") || exit 1

    # Auto-detect proxy protocol
    local proxy_url=""
    if [[ -n "$proxy" ]]; then
        if [[ ! "$proxy" =~ ^(http|https|socks5):// ]]; then
            printf "  $(_dim "Detecting proxy protocol ...") "
            if proxy_url=$(_auto_detect_proxy "$proxy"); then
                echo "$(_cyan "$(echo "$proxy_url" | grep -oE '^[a-z]+' || echo "http")")"
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
        printf "  $(_dim "Detecting timezone ...") "
        local ip_info
        ip_info=$(curl -s --proxy "$proxy_url" --connect-timeout 8 "http://ip-api.com/json/?fields=timezone,countryCode" 2>/dev/null || true)
        if [[ -n "$ip_info" ]]; then
            local detected_tz country_code
            read -r detected_tz country_code < <(echo "$ip_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timezone',''), d.get('countryCode',''))" 2>/dev/null || echo "")
            [[ -n "$detected_tz" ]] && tz="$detected_tz"
            if [[ -n "$country_code" ]]; then
                case "$country_code" in
                    US) lang="en_US.UTF-8" ;;
                    GB) lang="en_GB.UTF-8" ;;
                    AU) lang="en_AU.UTF-8" ;;
                    CA) lang="en_CA.UTF-8" ;;
                    SG) lang="en_SG.UTF-8" ;;
                    HK) lang="zh_HK.UTF-8" ;;
                    TW) lang="zh_TW.UTF-8" ;;
                    JP) lang="ja_JP.UTF-8" ;;
                    KR) lang="ko_KR.UTF-8" ;;
                    DE) lang="de_DE.UTF-8" ;;
                    FR) lang="fr_FR.UTF-8" ;;
                    ES) lang="es_ES.UTF-8" ;;
                    IT) lang="it_IT.UTF-8" ;;
                    PT|BR) lang="pt_BR.UTF-8" ;;
                    RU) lang="ru_RU.UTF-8" ;;
                    NL) lang="nl_NL.UTF-8" ;;
                    IN) lang="en_IN.UTF-8" ;;
                    *)  lang="en_US.UTF-8" ;;
                esac
            fi
            echo "$(_cyan "$tz") $(_dim "($country_code)")"
        else
            echo "$(_dim "default $tz")"
        fi
    fi

    mkdir -p "$env_dir"
    [[ -n "$proxy_url" ]] && echo "$proxy_url" > "$env_dir/proxy"
    echo "$(_new_uuid)"       > "$env_dir/uuid"
    touch "$env_dir/user_id"
    echo "$(_new_machine_id)" > "$env_dir/machine_id"
    echo "$(_new_hostname)"   > "$env_dir/hostname"
    echo "$(_new_mac)"        > "$env_dir/mac_address"
    echo "$tz"                > "$env_dir/tz"
    echo "$lang"              > "$env_dir/lang"
    [[ -n "$claude_ver" ]]    && echo "$claude_ver" > "$env_dir/version"
    echo "$env_type"          > "$env_dir/type"
    echo "$(_new_git_remote)" > "$env_dir/fake_git_remote"
    echo "$(_new_git_email)"  > "$env_dir/git_email"
    echo "$(_new_device_token)" > "$env_dir/device_token"
    date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$env_dir/first_start_time"
    [[ -n "$persona" ]] && echo "$persona" > "$env_dir/persona"

    # Telemetry mode: stealth (default), paranoid, or transparent
    [[ -z "$telemetry_mode" ]] && telemetry_mode=$(_cac_setting telemetry_mode stealth)
    echo "$telemetry_mode" > "$env_dir/telemetry_mode"

    mkdir -p "$env_dir/.claude"

    # Initialize settings.json, statusline, and CLAUDE.md
    _write_env_settings "$env_dir/.claude"
    _write_statusline_script "$env_dir/.claude"
    _write_env_claude_md "$env_dir/.claude" "$name"

    # Clone config from source
    if [[ -n "$clone_source" ]]; then
        local src_claude_dir
        if [[ "$clone_source" == "host" ]]; then
            src_claude_dir="$HOME/.claude"
        elif [[ -d "$ENVS_DIR/$clone_source/.claude" ]]; then
            src_claude_dir="$ENVS_DIR/$clone_source/.claude"
        else
            echo "  $(_yellow "⚠") clone source '$clone_source' not found, skipping" >&2
            clone_source=""
        fi

        if [[ -n "$clone_source" ]] && [[ -d "$src_claude_dir" ]]; then
            local clone_dirs="commands hooks skills plugins"
            for d in $clone_dirs; do
                if [[ -d "$src_claude_dir/$d" ]]; then
                    rm -rf "$env_dir/.claude/$d"
                    if [[ "$clone_link" == "true" ]]; then
                        ln -sf "$src_claude_dir/$d" "$env_dir/.claude/$d"
                    else
                        cp -r "$src_claude_dir/$d" "$env_dir/.claude/$d"
                    fi
                fi
            done
            if [[ -f "$src_claude_dir/CLAUDE.md" ]]; then
                if [[ "$clone_link" == "true" ]]; then
                    ln -sf "$src_claude_dir/CLAUDE.md" "$env_dir/.claude/CLAUDE.md"
                else
                    cp "$src_claude_dir/CLAUDE.md" "$env_dir/.claude/CLAUDE.md"
                    _write_env_claude_md "$env_dir/.claude" "$name" --append
                fi
            fi
            if [[ -f "$src_claude_dir/settings.json" ]]; then
                cp "$env_dir/.claude/settings.json" "$env_dir/.claude/settings.override.json"
                python3 - "$src_claude_dir/settings.json" "$env_dir/.claude/settings.override.json" "$env_dir/.claude/settings.json" << 'MERGE_EOF'
import json, sys
base = json.load(open(sys.argv[1]))
override = json.load(open(sys.argv[2]))
# Deep merge: override wins
def merge(b, o):
    r = dict(b)
    for k, v in o.items():
        if k in r and isinstance(r[k], dict) and isinstance(v, dict):
            r[k] = merge(r[k], v)
        else:
            r[k] = v
    return r
result = merge(base, override)
with open(sys.argv[3], 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
MERGE_EOF
            fi
            # Store clone source for wrapper merge-on-startup
            echo "$src_claude_dir" > "$env_dir/clone_source"
            local link_mode="symlinked"
            [[ "$clone_link" != "true" ]] && link_mode="copied"
            echo "  $(_green "+") cloned   from ${src_claude_dir/#$HOME/~} ($link_mode)"
        fi
    fi

    _generate_client_cert "$name" >/dev/null 2>&1 || true

    # Auto-activate
    echo "$name" > "$CAC_DIR/current"
    rm -f "$CAC_DIR/stopped"
    if [[ -d "$env_dir/.claude" ]]; then
        export CLAUDE_CONFIG_DIR="$env_dir/.claude"
    fi

    local elapsed; elapsed=$(_timer_elapsed)
    echo
    echo "  $(_green_bold "Created") $(_bold "$name") $(_dim "in $elapsed")"
    echo
    [[ -n "$proxy_url" ]] && echo "  $(_green "+") proxy    $proxy_url"
    [[ -n "$claude_ver" ]] && echo "  $(_green "+") claude   $(_cyan "$claude_ver")"
    echo "  $(_green "+") env      $(_dim "${env_dir/#$HOME/~}/.claude/")"
    echo
    echo "  $(_dim "Environment activated. Run") $(_green "claude") $(_dim "to start.")"
    echo
}

_env_cmd_ls() {
    _require_setup
    if [[ ! -d "$ENVS_DIR" ]] || [[ -z "$(ls -A "$ENVS_DIR" 2>/dev/null)" ]]; then
        echo "$(_dim "  No environments yet.")"
        echo "  Run $(_green "cac env create <name>") to get started."
        return
    fi

    local current; current=$(_current_env)

    # Collect data first to calculate column widths
    local names=() versions=() proxies=() paths=()
    for env_dir in "$ENVS_DIR"/*/; do
        [[ -d "$env_dir" ]] || continue
        names+=("$(basename "$env_dir")")
        versions+=("$(_read "$env_dir/version" "system")")
        local p; p=$(_read "$env_dir/proxy" "")
        if [[ -n "$p" ]] && [[ "$p" == *"://"*"@"* ]]; then
            p=$(echo "$p" | sed 's|://[^@]*@|://***@|')
        fi
        proxies+=("${p:-—}")
        local ep="${env_dir}.claude/"
        paths+=("${ep/#$HOME/~}")
    done

    # Calculate max widths
    local max_name=4 max_ver=6 max_proxy=5
    local i
    for i in "${!names[@]}"; do
        local nl=${#names[$i]} vl=${#versions[$i]} pl=${#proxies[$i]}
        (( nl > max_name )) && max_name=$nl
        (( vl > max_ver )) && max_ver=$vl
        (( pl > max_proxy )) && max_proxy=$pl
    done
    # Cap proxy column
    (( max_proxy > 40 )) && max_proxy=40

    # Header
    printf "  $(_dim "  %-${max_name}s  %-${max_ver}s  %-${max_proxy}s  %s")" "NAME" "CLAUDE" "PROXY" "ENV"
    echo

    # Rows
    for i in "${!names[@]}"; do
        local name="${names[$i]}"
        local ver="${versions[$i]}"
        local proxy="${proxies[$i]}"
        local epath="${paths[$i]}"

        if [[ "$name" == "$current" ]]; then
            printf "  $(_green "▶") $(_bold "%-${max_name}s")  $(_cyan "%-${max_ver}s")  %-${max_proxy}s  $(_dim "%s")\n" "$name" "$ver" "$proxy" "$epath"
        else
            printf "  $(_dim "○") %-${max_name}s  $(_cyan "%-${max_ver}s")  $(_dim "%-${max_proxy}s")  $(_dim "%s")\n" "$name" "$ver" "$proxy" "$epath"
        fi
    done
}

_env_cmd_rm() {
    [[ -n "${1:-}" ]] || _die "usage: cac env rm <name>"
    local name="$1"
    _require_env "$name"

    local current; current=$(_current_env)
    [[ "$name" != "$current" ]] || _die "cannot remove active environment $(_cyan "'$name'")\n  switch to another environment first"

    rm -rf "${ENVS_DIR:?}/$name"
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

_env_cmd_set() {
    _require_setup

    # Parse: cac env set [name] <key> <value|--remove>
    # If first arg is a known key, use current env; otherwise treat as env name
    local name="" key="" value="" remove=false
    local known_keys="proxy version telemetry persona"

    if [[ $# -lt 1 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "help" ]]; then
        echo
        echo "  $(_bold "cac env set") — modify environment configuration"
        echo
        echo "    $(_green "set") [name] proxy <url>                       Set proxy"
        echo "    $(_green "set") [name] proxy --remove                  Remove proxy"
        echo "    $(_green "set") [name] version <ver|latest>            Change Claude version"
        echo "    $(_green "set") [name] telemetry <stealth|paranoid|transparent>"
        echo "                                                          Telemetry blocking: stealth (1p_events only), paranoid (max), transparent (none)"
        echo "    $(_green "set") [name] persona <macos-vscode|macos-cursor|macos-iterm|linux-desktop|--remove>"
        echo "                                                          Terminal preset: inject desktop env vars, hide Docker signals (for containers)"
        echo
        echo "  $(_dim "If name is omitted, uses the current active environment.")"
        echo
        return
    fi

    # Is first arg a known key or an env name?
    if echo "$known_keys" | grep -qw "${1:-}"; then
        name=$(_current_env)
        [[ -n "$name" ]] || _die "no active environment — specify env name"
    else
        name="$1"; shift
    fi

    _require_env "$name"
    local env_dir="$ENVS_DIR/$name"

    [[ $# -ge 1 ]] || _die "usage: cac env set [name] <proxy|version|bypass> <value|--remove>"
    key="$1"; shift

    # Parse value or --remove
    if [[ "${1:-}" == "--remove" ]]; then
        remove=true; shift
    elif [[ $# -ge 1 ]]; then
        value="$1"; shift
    fi

    case "$key" in
        proxy)
            if [[ "$remove" == "true" ]]; then
                rm -f "$env_dir/proxy"
                echo "$(_green_bold "Removed") proxy from $(_bold "$name")"
            else
                [[ -n "$value" ]] || _die "usage: cac env set [name] proxy <url|host:port:user:pass>"
                local proxy_url
                if [[ ! "$value" =~ ^(http|https|socks5):// ]]; then
                    printf "  $(_dim "Detecting proxy protocol ...") "
                    if proxy_url=$(_auto_detect_proxy "$value"); then
                        echo "$(_cyan "$(echo "$proxy_url" | grep -oE '^[a-z]+' || echo "http")")"
                    else
                        echo "$(_yellow "failed, defaulting to http")"
                    fi
                else
                    proxy_url=$(_parse_proxy "$value")
                fi
                echo "$proxy_url" > "$env_dir/proxy"
                echo "$(_green_bold "Set") proxy for $(_bold "$name") → $proxy_url"
            fi
            ;;
        version)
            [[ "$remove" != "true" ]] || _die "cannot remove version — use 'cac env set $name version latest'"
            [[ -n "$value" ]] || _die "usage: cac env set [name] version <ver|latest>"
            local ver
            ver=$(_ensure_version_installed "$value") || exit 1
            echo "$ver" > "$env_dir/version"
            echo "$(_green_bold "Set") version for $(_bold "$name") → $(_cyan "$ver")"
            ;;
        telemetry)
            [[ "$remove" != "true" ]] || _die "cannot remove telemetry mode"
            [[ -n "$value" ]] || _die "usage: cac env set [name] telemetry <stealth|paranoid|transparent>"
            # Accept old names
            case "$value" in
                conservative) value="stealth" ;;
                aggressive)   value="paranoid" ;;
                off)          value="transparent" ;;
            esac
            [[ "$value" =~ ^(stealth|paranoid|transparent)$ ]] || _die "invalid telemetry mode '$value' (use stealth, paranoid, or transparent)"
            echo "$value" > "$env_dir/telemetry_mode"
            echo "$(_green_bold "Set") telemetry for $(_bold "$name") → $(_cyan "$value")"
            ;;
        persona)
            if [[ "$remove" == "true" ]]; then
                rm -f "$env_dir/persona"
                echo "$(_green_bold "Removed") persona from $(_bold "$name")"
            else
                [[ -n "$value" ]] || _die "usage: cac env set [name] persona <macos-vscode|macos-cursor|macos-iterm|linux-desktop>"
                [[ "$value" =~ ^(macos-vscode|macos-cursor|macos-iterm|linux-desktop)$ ]] || _die "invalid persona '$value'"
                echo "$value" > "$env_dir/persona"
                echo "$(_green_bold "Set") persona for $(_bold "$name") → $(_cyan "$value")"
            fi
            ;;
        *)
            _die "unknown key '$key' — use proxy, version, telemetry, or persona"
            ;;
    esac
}

_env_cmd_stop() {
    _relay_stop 2>/dev/null || true
    touch "$CAC_DIR/stopped"
    echo "  $(_green "✓") cac paused — claude will run without any cac injection"
    echo "  $(_dim "resume with:") $(_green "cac <name>")"
}

cmd_env() {
    case "${1:-help}" in
        create)       _env_cmd_create "${@:2}" ;;
        set)          _env_cmd_set "${@:2}" ;;
        ls|list)      _env_cmd_ls ;;
        rm|remove)    _env_cmd_rm "${@:2}" ;;
        activate)     _env_cmd_activate "${@:2}" ;;
        stop)         _env_cmd_stop ;;
        check)        cmd_check "${@:2}" ;;
        deactivate)   echo "$(_yellow "warning:") deactivate has been removed — switch with 'cac <name>' or uninstall with 'cac self delete'" >&2 ;;
        help|-h|--help)
            echo
            echo "  $(_bold "cac env") — environment management"
            echo
            echo "    $(_green "create") <name> [-p proxy] [-c ver] [--telemetry mode] [--persona preset]"
            echo "                             Create isolated environment (auto-activates)"
            echo "    $(_green "set") [name] <key> <value>        Modify environment"
            echo "                             proxy, version, telemetry, or persona"
            echo "    $(_green "ls")              List all environments"
            echo "    $(_green "rm") <name>       Remove an environment"
            echo "    $(_green "check")           Verify current environment"
            echo "    $(_green "stop")            Pause cac (claude runs natively, no injection)"
            echo "    $(_green "cac") <name>      Switch environment (also resumes if stopped)"
            echo
            ;;
        *)
            # If first arg is an existing env name, treat as: cac env set <name> ...
            if [[ -d "$ENVS_DIR/$1" ]] && [[ $# -ge 2 ]]; then
                _env_cmd_set "$@"
            else
                _die "unknown: cac env $1"
            fi
            ;;
    esac
}
