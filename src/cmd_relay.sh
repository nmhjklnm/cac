# ── cmd: relay（本地中转，绕过 TUN）──────────────────────────────

_relay_start() {
    local name="${1:-$(_current_env)}"
    local env_dir="$ENVS_DIR/$name"
    local proxy; proxy=$(_read "$env_dir/proxy")
    [[ -z "$proxy" ]] && return 1

    local relay_js="$CAC_DIR/relay.js"
    [[ -f "$relay_js" ]] || { echo "错误：relay.js 未找到，请运行 'cac setup'" >&2; return 1; }

    # 寻找可用端口（17890-17999）
    local port=17890
    while (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; do
        (( port++ ))
        if [[ $port -gt 17999 ]]; then
            echo "错误：端口 17890-17999 全部被占用" >&2
            return 1
        fi
    done

    local pid_file="$CAC_DIR/relay.pid"
    node "$relay_js" "$port" "$proxy" "$pid_file" </dev/null >"$CAC_DIR/relay.log" 2>&1 &
    disown

    # 等待 relay 就绪
    local _i
    for _i in {1..30}; do
        (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null && break
        sleep 0.1
    done

    if ! (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
        echo "错误：relay 启动超时" >&2
        return 1
    fi

    echo "$port" > "$CAC_DIR/relay.port"
    return 0
}

_relay_stop() {
    local pid_file="$CAC_DIR/relay.pid"
    if [[ -f "$pid_file" ]]; then
        local pid; pid=$(tr -d '[:space:]' < "$pid_file")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            # 等待进程退出
            local _i
            for _i in {1..20}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
        fi
        rm -f "$pid_file"
    fi
    rm -f "$CAC_DIR/relay.port"

    # 清理路由
    _relay_remove_route 2>/dev/null || true
}

_relay_is_running() {
    local pid_file="$CAC_DIR/relay.pid"
    [[ -f "$pid_file" ]] || return 1
    local pid; pid=$(tr -d '[:space:]' < "$pid_file")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ── 路由管理（绕过 TUN 的直连路由）──────────────────────────────

_relay_add_route() {
    local proxy="$1"
    local proxy_host; proxy_host=$(_proxy_host_port "$proxy")
    proxy_host="${proxy_host%%:*}"

    # 跳过已是 IP 的回环地址
    [[ "$proxy_host" == "127."* || "$proxy_host" == "localhost" ]] && return 0

    # 解析为 IP
    local proxy_ip
    proxy_ip=$(python3 -c "import socket; print(socket.gethostbyname('$proxy_host'))" 2>/dev/null || echo "$proxy_host")

    local os; os=$(_detect_os)
    if [[ "$os" == "macos" ]]; then
        local gateway
        gateway=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
        [[ -z "$gateway" ]] && return 1

        # 检查是否已有直连路由
        local current_gw
        current_gw=$(route -n get "$proxy_ip" 2>/dev/null | awk '/gateway:/{print $2}')
        [[ "$current_gw" == "$gateway" ]] && return 0

        echo "  添加直连路由：$proxy_ip → $gateway（需要 sudo）"
        sudo route delete -host "$proxy_ip" 2>/dev/null || true
        if ! sudo route add -host "$proxy_ip" "$gateway" 2>&1; then
            echo "  route add 失败（proxy_ip=$proxy_ip gateway=$gateway）" >&2
            return 1
        fi
        echo "$proxy_ip" > "$CAC_DIR/relay_route_ip"

    elif [[ "$os" == "linux" ]]; then
        local gateway iface
        gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
        [[ -z "$gateway" ]] && return 1

        echo "  添加直连路由：$proxy_ip → $gateway dev $iface（需要 sudo）"
        sudo ip route del "$proxy_ip/32" 2>/dev/null || true
        if ! sudo ip route add "$proxy_ip/32" via "$gateway" dev "$iface" 2>&1; then
            echo "  ip route add 失败（proxy_ip=$proxy_ip gateway=$gateway iface=$iface）" >&2
            return 1
        fi
        echo "$proxy_ip" > "$CAC_DIR/relay_route_ip"
    fi
}

_relay_remove_route() {
    local route_file="$CAC_DIR/relay_route_ip"
    [[ -f "$route_file" ]] || return 0

    local proxy_ip; proxy_ip=$(tr -d '[:space:]' < "$route_file")
    [[ -z "$proxy_ip" ]] && return 0

    local os; os=$(_detect_os)
    if [[ "$os" == "macos" ]]; then
        sudo route delete -host "$proxy_ip" >/dev/null 2>&1 || true
    elif [[ "$os" == "linux" ]]; then
        sudo ip route del "$proxy_ip/32" 2>/dev/null || true
    fi
    rm -f "$route_file"
}

# 检测 TUN 网卡是否活跃
_detect_tun_active() {
    local os; os=$(_detect_os)
    if [[ "$os" == "macos" ]]; then
        local tun_count
        tun_count=$(ifconfig 2>/dev/null | grep -cE '^utun[0-9]+' || echo 0)
        [[ "$tun_count" -gt 3 ]]
    elif [[ "$os" == "linux" ]]; then
        ip link show tun0 >/dev/null 2>&1
    else
        return 1
    fi
}

# 检查上游代理路由是否正确（不需要 sudo）
# 返回 0=正确, 1=缺失/过期, 2=非 TUN 环境无需路由
_relay_route_ok() {
    local proxy="$1"
    local proxy_host; proxy_host=$(_proxy_host_port "$proxy")
    proxy_host="${proxy_host%%:*}"

    [[ "$proxy_host" == "127."* || "$proxy_host" == "localhost" ]] && return 0

    local proxy_ip
    proxy_ip=$(python3 -c "import socket; print(socket.gethostbyname('$proxy_host'))" 2>/dev/null || echo "$proxy_host")

    local os; os=$(_detect_os)
    if [[ "$os" == "macos" ]]; then
        local default_gw route_gw
        default_gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
        route_gw=$(route -n get "$proxy_ip" 2>/dev/null | awk '/gateway:/{print $2}')
        [[ -z "$default_gw" ]] && return 2
        [[ "$route_gw" == "$default_gw" ]] && return 0
        return 1
    elif [[ "$os" == "linux" ]]; then
        local default_gw
        default_gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        [[ -z "$default_gw" ]] && return 2
        # 检查是否有精确的 /32 路由
        ip route show "$proxy_ip/32" 2>/dev/null | grep -q via && return 0
        return 1
    fi
    return 2
}

# 检测 TUN 并自动确保路由正确（wrapper 和 activate 调用）
_relay_ensure_route() {
    local proxy="$1"
    [[ -z "$proxy" ]] && return 0

    # 无 TUN 风险则跳过
    _detect_tun_active || return 0

    # 路由已正确则跳过
    _relay_route_ok "$proxy" && return 0

    # 需要修复路由
    _relay_add_route "$proxy"
}


