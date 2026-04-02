# ── vpn_compat: VPN detection and split-routing ──────────────

_vpn_is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    local i
    for i in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( i > 255 )) && return 1
    done
    return 0
}

_vpn_is_loopback() {
    local ip="$1"
    [[ "$ip" == "127."* || "$ip" == "localhost" || "$ip" == "::1" ]]
}

_vpn_resolve_ipv4() {
    local host="$1"
    _vpn_is_ipv4 "$host" && { echo "$host"; return 0; }

    local resolved
    resolved=$(python3 - "$host" <<'PY' 2>/dev/null
import socket, sys

host = sys.argv[1]
try:
    for item in socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM):
        ip = item[4][0]
        if ip:
            print(ip)
            raise SystemExit(0)
except Exception:
    pass
sys.exit(1)
PY
)
    [[ -n "$resolved" ]] && { echo "$resolved"; return 0; }
    return 1
}

_vpn_has_process() {
    local pattern="$1"
    # Use pgrep on macOS/Linux for reliable process matching
    if command -v pgrep &>/dev/null; then
        pgrep -if "$pattern" >/dev/null 2>&1
    # Windows fallback (Git Bash / MSYS2) — strip CSV quotes before matching
    elif [[ "$(_detect_os)" == "windows" ]]; then
        tasklist.exe /FO CSV /NH 2>/dev/null | tr -d '"' | grep -iE "$pattern" >/dev/null 2>&1
    else
        # Fallback: ps + grep, exclude only exact 'grep' and 'apply_patch'
        ps ax -o command= 2>/dev/null | grep -iE "$pattern" | grep -ivE '^grep |apply_patch' >/dev/null 2>&1
    fi
}

_vpn_http_status() {
    local url="$1" secret="${2:-}" code
    if [[ -n "$secret" ]]; then
        code=$(curl -sS --connect-timeout 3 --max-time 5 -H "Authorization: Bearer $secret" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || code="000"
    else
        code=$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || code="000"
    fi
    echo "$code"
}

_vpn_port_from_controller() {
    local controller="$1" port
    port=$(printf '%s' "$controller" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#.*:([0-9]+)$#\1#')
    [[ "$port" =~ ^[0-9]+$ ]] && echo "$port"
}

_vpn_yaml_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    # Compatible with macOS default awk (no capture arrays)
    grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | sed -E "s/[[:space:]]*#.*$//" | tr -d "\"'" | tr -d '[:space:]'
}

_vpn_clash_known_configs() {
    local os; os=$(_detect_os)
    # macOS paths first (preferred on macOS)
    if [[ "$os" == "macos" ]]; then
        printf '%s\n' \
            "$HOME/Library/Application Support/io.github.niceneasy.ClashX/config.yaml" \
            "$HOME/Library/Application Support/clash-verge-rev/clash/config.yaml" \
            "$HOME/Library/Application Support/clash-verge/clash/config.yaml" \
            "$HOME/Library/Application Support/mihomo/config.yaml" \
            "$HOME/Library/Application Support/clash/config.yaml"
    fi
    if [[ "$os" == "windows" ]]; then
        local appdata="${APPDATA:-$HOME/AppData/Roaming}"
        printf '%s\n' \
            "$appdata/clash-verge-rev/clash/config.yaml" \
            "$appdata/clash-verge/clash/config.yaml" \
            "$appdata/Clash for Windows/config.yaml" \
            "$HOME/.config/mihomo/config.yaml" \
            "$HOME/.config/clash/config.yaml"
    fi
    # XDG paths (Linux primary, macOS fallback)
    printf '%s\n' \
        "$HOME/.config/mihomo/config.yaml" \
        "$HOME/.config/clash/config.yaml" \
        "$HOME/.config/clash-verge-rev/clash/config.yaml" \
        "$HOME/.config/clash-verge/clash/config.yaml"
}

_vpn_clash_detect_port() {
    local controller port file status

    controller="${CLASH_EXTERNAL_CONTROLLER:-}"
    if [[ -n "$controller" ]]; then
        port=$(_vpn_port_from_controller "$controller")
        [[ -n "$port" ]] && { echo "$port"; return 0; }
    fi

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        controller=$(_vpn_yaml_value "$file" 'external-controller')
        if [[ -n "$controller" ]]; then
            port=$(_vpn_port_from_controller "$controller")
            [[ -n "$port" ]] && { echo "$port"; return 0; }
        fi
    done < <(_vpn_clash_known_configs)

    for port in 9090 9097; do
        status=$(_vpn_http_status "http://127.0.0.1:$port/configs")
        [[ "$status" != "000" ]] && { echo "$port"; return 0; }
    done

    return 1
}

_vpn_clash_secret() {
    local file secret="${CLASH_API_SECRET:-${CLASH_SECRET:-}}"
    [[ -n "$secret" ]] && { echo "$secret"; return 0; }

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        secret=$(_vpn_yaml_value "$file" 'secret')
        [[ -n "$secret" ]] && { echo "$secret"; return 0; }
    done < <(_vpn_clash_known_configs)

    return 1
}

_vpn_sing_box_detect_port() {
    local port status
    local config_paths=(
        "$HOME/.config/sing-box/config.json"
        "/usr/local/etc/sing-box/config.json"
        "/etc/sing-box/config.json"
    )
    if [[ "$(_detect_os)" == "macos" ]]; then
        config_paths=("$HOME/Library/Application Support/sing-box/config.json" "${config_paths[@]}")
    fi

    local config
    for config in "${config_paths[@]}"; do
        [[ -f "$config" ]] || continue
        port=$(python3 - "$config" <<'PY' 2>/dev/null || true
import json, sys

path = sys.argv[1]
try:
    data = json.load(open(path, 'r'))
except Exception:
    raise SystemExit(0)

controller = ''
experimental = data.get('experimental') or {}
clash_api = experimental.get('clash_api') or {}
controller = clash_api.get('external_controller') or clash_api.get('external-controller') or ''

if isinstance(controller, str) and controller:
    value = controller.split('://', 1)[-1].split('/', 1)[0]
    if ':' in value:
        print(value.rsplit(':', 1)[1])
PY
)
        [[ -n "$port" ]] && { echo "$port"; return 0; }
    done

    status=$(_vpn_http_status "http://127.0.0.1:9090")
    [[ "$status" != "000" ]] && { echo "9090"; return 0; }
    return 1
}

_vpn_detect_surge_port() {
    local status
    status=$(_vpn_http_status "http://127.0.0.1:6171")
    [[ "$status" != "000" ]] && { echo "6171"; return 0; }
    return 1
}

_detect_vpn() {
    local port

    # Shadowrocket (macOS) — check first since it's common on macOS
    if _vpn_has_process 'Shadowrocket'; then
        echo "shadowrocket:"
        return 0
    fi

    # Clash family: mihomo, clash-meta, ClashX, Clash Verge, Stash
    if _vpn_has_process '(mihomo|clash-meta|clash-verge|ClashX|Clash\.Meta)([ /]|$)' || _vpn_has_process '(^|[ /])Stash([ .]|$)'; then
        port=$(_vpn_clash_detect_port 2>/dev/null || true)
        echo "clash:${port:-}"
        return 0
    fi
    # Plain 'clash' checked separately to avoid false positives
    if _vpn_has_process '(^|[ /])clash([[:space:]]|$)'; then
        port=$(_vpn_clash_detect_port 2>/dev/null || true)
        echo "clash:${port:-}"
        return 0
    fi

    # sing-box
    if _vpn_has_process 'sing-box'; then
        port=$(_vpn_sing_box_detect_port 2>/dev/null || true)
        echo "sing-box:${port:-}"
        return 0
    fi

    # Surge
    if _vpn_has_process '(^|[ /])(Surge|surge-cli)([ .]|$)'; then
        port=$(_vpn_detect_surge_port 2>/dev/null || true)
        echo "surge:${port:-6171}"
        return 0
    fi

    # v2rayN (Windows)
    if _vpn_has_process '(^|[ /])v2rayN([ .]|$)'; then
        echo "v2rayN:"
        return 0
    fi

    # V2Ray / Xray
    if _vpn_has_process '(^|[ /])(v2ray|xray|v2rayN)([[:space:]]|$)'; then
        echo "v2ray:"
        return 0
    fi

    # tun2socks
    if _vpn_has_process 'tun2socks'; then
        echo "tun2socks:"
        return 0
    fi

    return 1
}

_vpn_generate_rule() {
    local proxy_ip="$1" vpn_type="$2"
    case "$vpn_type" in
        clash)
            printf '%s\n' "- IP-CIDR,${proxy_ip}/32,DIRECT,no-resolve"
            ;;
        shadowrocket|surge)
            printf '%s\n' "IP-CIDR,${proxy_ip}/32,DIRECT"
            ;;
        sing-box)
            printf '%s\n' "{\"ip_cidr\":[\"${proxy_ip}/32\"],\"outbound\":\"direct\"}"
            ;;
        v2ray|v2rayN)
            printf '%s\n' "{\"type\":\"field\",\"ip\":[\"${proxy_ip}/32\"],\"outboundTag\":\"direct\"}"
            ;;
        *)
            return 1
            ;;
    esac
}

_vpn_clash_api_get_configs() {
    local port="$1" secret="${2:-}"
    if [[ -n "$secret" ]]; then
        curl -fsS --connect-timeout 3 --max-time 5 -H "Authorization: Bearer $secret" "http://127.0.0.1:$port/configs" 2>/dev/null || true
    else
        curl -fsS --connect-timeout 3 --max-time 5 "http://127.0.0.1:$port/configs" 2>/dev/null || true
    fi
}

_vpn_clash_api_config_path() {
    local port="$1" secret="${2:-}" body path
    body=$(_vpn_clash_api_get_configs "$port" "$secret")
    [[ -n "$body" ]] || return 1

    path=$(printf '%s' "$body" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("path", ""))' 2>/dev/null || true)
    [[ -n "$path" ]] || return 1
    # Validate: no traversal, yaml extension
    [[ "$path" == *..* ]] && return 1
    [[ "$path" == *.yaml || "$path" == *.yml ]] || return 1
    # Must be absolute: Unix (/) or Windows (C:/ D:\)
    if [[ "$(_detect_os)" == "windows" ]]; then
        [[ "$path" =~ ^[A-Za-z]:[/\\] ]] || return 1
    else
        [[ "$path" == /* ]] || return 1
        # Unix: restrict to safe directories
        case "$path" in
            "$HOME"/*|/etc/*|/usr/local/*|/opt/*) ;;
            *) return 1 ;;
        esac
    fi
    [[ -f "$path" ]] && echo "$path"
}

_vpn_clash_insert_rule() {
    local file="$1" proxy_ip="$2" rule tmp
    [[ -f "$file" ]] || return 1

    # Already exists
    if grep -F "IP-CIDR,${proxy_ip}/32,DIRECT" "$file" >/dev/null 2>&1; then
        return 0
    fi

    rule=$(_vpn_generate_rule "$proxy_ip" clash) || return 1
    tmp=$(mktemp "${file}.cac.XXXXXX") || return 1

    python3 - "$file" "$tmp" "$rule" <<'PY' || { rm -f "$tmp"; return 1; }
import sys

src, dst, rule = sys.argv[1:4]

with open(src, 'r') as f:
    text = f.read()

newline = '\r\n' if '\r\n' in text else '\n'
lines = text.splitlines()
inserted = False
out = []

for line in lines:
    out.append(line)
    if not inserted and line.rstrip() in ('rules:', 'rules: '):
        out.append('  ' + rule)
        inserted = True

if not inserted:
    if out and out[-1] != '':
        out.append('')
    out.append('rules:')
    out.append('  ' + rule)

with open(dst, 'w') as f:
    f.write(newline.join(out) + newline)
PY

    # Backup with timestamp
    cp "$file" "${file}.cac.bak.$(date +%s)" 2>/dev/null || true
    cat "$tmp" > "$file" && rm -f "$tmp"
}

_vpn_clash_reload() {
    local port="$1" config_path="$2" secret="${3:-}" payload
    payload=$(python3 - "$config_path" <<'PY'
import json, sys
print(json.dumps({"path": sys.argv[1]}))
PY
)

    if [[ -n "$secret" ]]; then
        curl -fsS --connect-timeout 3 --max-time 5 -X PUT \
            -H "Authorization: Bearer $secret" \
            -H 'Content-Type: application/json' \
            --data "$payload" \
            "http://127.0.0.1:$port/configs?force=true" >/dev/null 2>&1
    else
        curl -fsS --connect-timeout 3 --max-time 5 -X PUT \
            -H 'Content-Type: application/json' \
            --data "$payload" \
            "http://127.0.0.1:$port/configs?force=true" >/dev/null 2>&1
    fi
}

_vpn_try_auto_inject_clash() {
    local proxy_ip="$1" api_port="$2" secret config_path file
    [[ -n "$api_port" ]] || api_port=$(_vpn_clash_detect_port 2>/dev/null || true)
    [[ -n "$api_port" ]] || return 1

    secret=$(_vpn_clash_secret 2>/dev/null || true)
    config_path=$(_vpn_clash_api_config_path "$api_port" "" 2>/dev/null || true)
    [[ -z "$config_path" && -n "$secret" ]] && config_path=$(_vpn_clash_api_config_path "$api_port" "$secret" 2>/dev/null || true)

    if [[ -z "$config_path" ]]; then
        while IFS= read -r file; do
            [[ -f "$file" ]] || continue
            config_path="$file"
            break
        done < <(_vpn_clash_known_configs)
    fi

    [[ -n "$config_path" && -f "$config_path" ]] || return 1
    _vpn_clash_insert_rule "$config_path" "$proxy_ip" || return 1
    _vpn_clash_reload "$api_port" "$config_path" "$secret" || return 1
}

_vpn_try_auto_inject() {
    local proxy_ip="$1" vpn_type="$2" api_port="${3:-}"

    case "$vpn_type" in
        clash) _vpn_try_auto_inject_clash "$proxy_ip" "$api_port" ;;
        *) return 1 ;;
    esac
}

_vpn_show_manual_guide() {
    local proxy_ip="$1" vpn_type="$2"

    echo "  $(_yellow "!") VPN/TUN detected. Add a direct rule for proxy IP $(_cyan "$proxy_ip") to avoid traffic being hijacked by local VPN software."

    case "$vpn_type" in
        shadowrocket)
            echo "  $(_dim "Shadowrocket:") open the app and add a rule manually:"
            echo
            echo "    $(_bold "Config") → $(_bold "Rules") → $(_bold "Add Rule")"
            echo "    Type:   $(_cyan "IP-CIDR")"
            echo "    IP:     $(_cyan "${proxy_ip}/32")"
            echo "    Policy: $(_cyan "DIRECT")"
            echo
            echo "  $(_dim "Make sure the rule is near the top of your rule list.")"
            ;;
        clash)
            echo "  $(_dim "Clash / mihomo:") add this near the top of the $(_bold "rules:") section:"
            echo "    $(_cyan "$(_vpn_generate_rule "$proxy_ip" clash)")"
            local os; os=$(_detect_os)
            if [[ "$os" == "macos" ]]; then
                echo "  $(_dim "Common config paths:")"
                echo "    $(_dim "ClashX:       ~/Library/Application Support/io.github.niceneasy.ClashX/config.yaml")"
                echo "    $(_dim "Clash Verge:  ~/Library/Application Support/clash-verge-rev/clash/config.yaml")"
                echo "    $(_dim "mihomo:       ~/.config/mihomo/config.yaml")"
            else
                echo "  $(_dim "Common config paths: ~/.config/clash/config.yaml, ~/.config/mihomo/config.yaml")"
            fi
            ;;
        sing-box)
            echo "  $(_dim "sing-box:") add this object to $(_bold "route.rules") with outbound $(_bold "direct"):"
            echo "    $(_cyan "$(_vpn_generate_rule "$proxy_ip" sing-box)")"
            echo "  $(_dim "Common config path: ~/.config/sing-box/config.json")"
            ;;
        v2ray|v2rayN)
            echo "  $(_dim "V2Ray / Xray / v2rayN:") add this object to $(_bold "routing.rules") with outbound tag $(_bold "direct"):"
            echo "    $(_cyan "$(_vpn_generate_rule "$proxy_ip" v2ray)")"
            if [[ "$(_detect_os)" == "windows" ]]; then
                local appdata="${APPDATA:-$HOME/AppData/Roaming}"
                echo "  $(_dim "v2rayN config: ${appdata}/v2rayN/guiNConfig.json")"
            fi
            ;;
        surge)
            echo "  $(_dim "Surge:") add this line under the $(_bold "[Rule]") section:"
            echo "    $(_cyan "$(_vpn_generate_rule "$proxy_ip" surge)")"
            ;;
        *)
            echo "  $(_dim "If your VPN client uses Clash-compatible rules, add:")"
            echo "    $(_cyan "$(_vpn_generate_rule "$proxy_ip" clash)")"
            echo "  $(_dim "If it uses Surge rules, add:")"
            echo "    $(_cyan "$(_vpn_generate_rule "$proxy_ip" surge)")"
            ;;
    esac

    echo
}

# Main entry: ensure VPN won't hijack cac proxy traffic
# Always returns 0 — VPN compat is best-effort, never fatal
_vpn_ensure_compatible() {
    local proxy_url="$1" hp host proxy_ip detected vpn_type api_port
    [[ -n "$proxy_url" ]] || return 0

    hp=$(_proxy_host_port "$proxy_url")
    host="${hp%%:*}"
    [[ -n "$host" ]] || return 0

    # Skip loopback — no VPN bypass needed
    if _vpn_is_loopback "$host"; then
        return 0
    fi

    # Resolve to IPv4
    proxy_ip=$(_vpn_resolve_ipv4 "$host") || true
    if [[ -z "$proxy_ip" ]]; then
        echo "  $(_dim "skipped VPN check: could not resolve $host")"
        return 0
    fi

    # Skip loopback IPs
    if _vpn_is_loopback "$proxy_ip"; then
        return 0
    fi

    # Detect VPN
    detected=$(_detect_vpn 2>/dev/null || true)
    [[ -n "$detected" ]] || return 0

    vpn_type="${detected%%:*}"
    api_port="${detected#*:}"
    [[ "$api_port" == "$detected" ]] && api_port=""

    echo "  $(_yellow "!") detected local VPN/TUN: $(_cyan "$vpn_type")"
    if _vpn_try_auto_inject "$proxy_ip" "$vpn_type" "$api_port" 2>/dev/null; then
        echo "  $(_green "+") added DIRECT rule for $(_cyan "$proxy_ip") in $(_cyan "$vpn_type")"
    else
        _vpn_show_manual_guide "$proxy_ip" "$vpn_type"
    fi
    return 0
}
