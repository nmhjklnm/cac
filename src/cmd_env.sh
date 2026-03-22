# ── cmd: add / switch / ls ─────────────────────────────────────

cmd_add() {
    _require_setup
    if [[ $# -lt 2 ]]; then
        echo "用法：cac add <名字> <host:port:user:pass>" >&2
        echo "示例：cac add us1 1.2.3.4:1080:username:password" >&2
        exit 1
    fi

    local name="$1" raw_proxy="$2"
    local env_dir="$ENVS_DIR/$name"

    if [[ -d "$env_dir" ]]; then
        echo "错误：环境 '$name' 已存在，用 'cac ls' 查看" >&2
        exit 1
    fi

    local proxy
    # 如果用户未指定协议，自动探测 http/socks5/https
    if [[ ! "$raw_proxy" =~ ^(http|https|socks5):// ]]; then
        printf "  自动检测代理协议 ... "
        proxy=$(_auto_detect_proxy "$raw_proxy")
        if [[ $? -eq 0 ]]; then
            echo "$(_green "$(echo "$proxy" | grep -oE '^[a-z]+')://")"
        else
            echo "$(_yellow "检测失败，使用默认 http://")"
        fi
    else
        proxy=$(_parse_proxy "$raw_proxy")
    fi

    echo "即将创建环境：$(_bold "$name")"
    echo "  代理：$proxy"
    echo

    printf "  检测代理 ... "
    if _proxy_reachable "$proxy"; then
        echo "$(_green "✓ 可达")"
    else
        echo "$(_red "✗ 不通")"
        echo "  警告：代理当前不可达（代理客户端可能未启动）"
    fi

    # 自动检测出口 IP 的时区和语言
    printf "  检测时区 ... "
    local exit_ip tz lang
    exit_ip=$(curl -s --proxy "$proxy" --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
    if [[ -n "$exit_ip" ]]; then
        local ip_info
        ip_info=$(curl -s --connect-timeout 8 "http://ip-api.com/json/${exit_ip}?fields=timezone,countryCode" 2>/dev/null || true)
        tz=$(echo "$ip_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timezone',''))" 2>/dev/null || true)
        country=$(echo "$ip_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('countryCode',''))" 2>/dev/null || true)
        [[ -z "$tz" ]] && tz="America/New_York"
        [[ "$country" == "US" || "$country" == "GB" || "$country" == "AU" || "$country" == "CA" ]] && lang="en_US.UTF-8" || lang="en_US.UTF-8"
        echo "$(_green "✓ $tz")"
    else
        tz="America/New_York"
        lang="en_US.UTF-8"
        echo "$(_yellow "⚠ 获取失败，默认 $tz")"
    fi
    echo

    printf "确认创建？[yes/N] "
    read -r confirm
    [[ "$confirm" == "yes" ]] || { echo "已取消。"; exit 0; }

    mkdir -p "$env_dir"
    echo "$proxy"            > "$env_dir/proxy"
    echo "$(_new_uuid)"      > "$env_dir/uuid"
    echo "$(_new_sid)"       > "$env_dir/stable_id"
    echo "$(_new_user_id)"   > "$env_dir/user_id"
    echo "$(_new_machine_id)" > "$env_dir/machine_id"
    echo "$(_new_hostname)"  > "$env_dir/hostname"
    echo "$(_new_mac)"       > "$env_dir/mac_address"
    echo "$tz"               > "$env_dir/tz"
    echo "$lang"             > "$env_dir/lang"

    # 生成 mTLS 客户端证书
    printf "  生成 mTLS 证书 ... "
    if _generate_client_cert "$name"; then
        echo "$(_green "✓")"
    else
        echo "$(_yellow "⚠ 跳过")"
    fi

    echo
    echo "$(_green "✓") 环境 '$(_bold "$name")' 已创建"
    echo "  UUID     ：$(cat "$env_dir/uuid")"
    echo "  stable_id：$(cat "$env_dir/stable_id")"
    echo "  mTLS     ：$([ -f "$env_dir/client_cert.pem" ] && echo "已配置" || echo "未配置")"
    echo "  TZ       ：$tz"
    echo "  LANG     ：$lang"
    echo
    echo "切换到该环境：cac $name"
}

cmd_switch() {
    _require_setup
    local name="$1"
    _require_env "$name"

    local proxy; proxy=$(_read "$ENVS_DIR/$name/proxy")

    printf "检测 [%s] 代理 ... " "$name"
    if _proxy_reachable "$proxy"; then
        echo "$(_green "✓ 可达")"
    else
        echo "$(_yellow "⚠ 不通")"
        echo "警告：代理不可达，仍切换（启动 claude 时会拦截）"
    fi

    echo "$name" > "$CAC_DIR/current"
    rm -f "$CAC_DIR/stopped"

    _update_statsig "$(_read "$ENVS_DIR/$name/stable_id")"
    _update_claude_json_user_id "$(_read "$ENVS_DIR/$name/user_id")"

    echo "$(_green "✓") 已切换到 $(_bold "$name")"
}

cmd_ls() {
    _require_setup

    if [[ ! -d "$ENVS_DIR" ]] || [[ -z "$(ls -A "$ENVS_DIR" 2>/dev/null)" ]]; then
        echo "（暂无环境，用 'cac add <名字> <proxy>' 添加）"
        return
    fi

    local current; current=$(_current_env)
    local stopped_tag=""
    [[ -f "$CAC_DIR/stopped" ]] && stopped_tag=" $(_red "[stopped]")"

    for env_dir in "$ENVS_DIR"/*/; do
        local name; name=$(basename "$env_dir")
        local proxy; proxy=$(_read "$env_dir/proxy" "（未配置）")
        if [[ "$name" == "$current" ]]; then
            printf "  %s %s%s\n" "$(_green "▶")" "$(_bold "$name")" "$stopped_tag"
            printf "    %s\n" "$proxy"
        else
            printf "    %s\n" "$name"
            printf "    %s\n" "$proxy"
        fi
    done
}
