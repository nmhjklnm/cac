# ── utils: 颜色、读写、UUID、proxy 解析 ───────────────────────

CAC_VERSION="1.0.0"

_read()   { [[ -f "$1" ]] && tr -d '[:space:]' < "$1" || echo "${2:-}"; }
_bold()   { printf '\033[1m%s\033[0m' "$*"; }
_green()  { printf '\033[32m%s\033[0m' "$*"; }
_red()    { printf '\033[31m%s\033[0m' "$*"; }
_yellow() { printf '\033[33m%s\033[0m' "$*"; }

_detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

_new_uuid()    { uuidgen | tr '[:lower:]' '[:upper:]'; }
_new_sid()     { uuidgen | tr '[:upper:]' '[:lower:]'; }
_new_user_id() { python3 -c "import os; print(os.urandom(32).hex())"; }
_new_machine_id() { uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'; }
_new_hostname() { echo "host-$(uuidgen | cut -d- -f1 | tr '[:upper:]' '[:lower:]')"; }
_new_mac() { printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }

# 获取真实命令路径（绕过 shim）
_get_real_cmd() {
    local cmd="$1"
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') \
        command -v "$cmd" 2>/dev/null || true
}

# host:port:user:pass → http://user:pass@host:port
# 或直接传入完整 URL（http://、https://、socks5://）
_parse_proxy() {
    local raw="$1"
    # 如果已经是完整 URL，直接返回
    if [[ "$raw" =~ ^(http|https|socks5):// ]]; then
        echo "$raw"
        return
    fi
    # 否则解析 host:port:user:pass 格式
    local host port user pass
    host=$(echo "$raw" | cut -d: -f1)
    port=$(echo "$raw" | cut -d: -f2)
    user=$(echo "$raw" | cut -d: -f3)
    pass=$(echo "$raw" | cut -d: -f4-)
    if [[ -z "$user" ]]; then
        echo "http://${host}:${port}"
    else
        echo "http://${user}:${pass}@${host}:${port}"
    fi
}

# socks5://user:pass@host:port → host:port
_proxy_host_port() {
    echo "$1" | sed 's|.*@||' | sed 's|.*://||'
}

_proxy_reachable() {
    local hp host port
    hp=$(_proxy_host_port "$1")
    host=$(echo "$hp" | cut -d: -f1)
    port=$(echo "$hp" | cut -d: -f2)
    (echo >/dev/tcp/"$host"/"$port") 2>/dev/null
}

# 自动检测代理协议（当用户未指定 http/socks5/https 时）
# 用法：_auto_detect_proxy "host:port:user:pass" → 返回可用的完整 URL
_auto_detect_proxy() {
    local raw="$1"
    # 已有协议前缀，直接返回
    if [[ "$raw" =~ ^(http|https|socks5):// ]]; then
        echo "$raw"
        return 0
    fi

    local host port user pass auth_part
    host=$(echo "$raw" | cut -d: -f1)
    port=$(echo "$raw" | cut -d: -f2)
    user=$(echo "$raw" | cut -d: -f3)
    pass=$(echo "$raw" | cut -d: -f4-)
    if [[ -n "$user" ]]; then
        auth_part="${user}:${pass}@"
    else
        auth_part=""
    fi

    # 依次尝试 http → socks5 → https
    local proto try_url
    for proto in http socks5 https; do
        try_url="${proto}://${auth_part}${host}:${port}"
        if curl --proxy "$try_url" -fsSL --connect-timeout 8 -o /dev/null https://api.ipify.org 2>/dev/null; then
            echo "$try_url"
            return 0
        fi
    done

    # 全部失败，回退 http
    if [[ -n "$user" ]]; then
        echo "http://${auth_part}${host}:${port}"
    else
        echo "http://${host}:${port}"
    fi
    return 1
}

_current_env()  { _read "$CAC_DIR/current"; }
_env_dir()      { echo "$ENVS_DIR/$1"; }

_require_setup() {
    [[ -f "$CAC_DIR/real_claude" ]] || {
        echo "错误：请先运行 'cac setup'" >&2; exit 1
    }
}

_require_env() {
    [[ -d "$ENVS_DIR/$1" ]] || {
        echo "错误：环境 '$1' 不存在，用 'cac ls' 查看" >&2; exit 1
    }
}

_find_real_claude() {
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/bin" | tr '\n' ':') \
        command -v claude 2>/dev/null || true
}

_detect_rc_file() {
    if [[ -f "$HOME/.zshrc" ]]; then
        echo "$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        echo "$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        echo "$HOME/.bash_profile"
    else
        echo ""
    fi
}

_install_method() {
    local self="$0"
    local resolved="$self"
    if [[ -L "$self" ]]; then
        resolved=$(readlink "$self" 2>/dev/null || echo "$self")
        # 处理相对路径的符号链接
        if [[ "$resolved" != /* ]]; then
            resolved="$(dirname "$self")/$resolved"
        fi
    fi
    if [[ "$resolved" == *"node_modules"* ]] || [[ -f "$(dirname "$resolved")/package.json" ]]; then
        echo "npm"
    else
        echo "bash"
    fi
}

_write_path_to_rc() {
    local rc_file="${1:-$(_detect_rc_file)}"
    if [[ -z "$rc_file" ]]; then
        echo "  $(_yellow '⚠') 未找到 shell 配置文件，请手动添加 PATH："
        echo '    export PATH="$HOME/bin:$PATH"'
        echo '    export PATH="$HOME/.cac/bin:$PATH"'
        return 0
    fi

    if grep -q '# >>> cac >>>' "$rc_file" 2>/dev/null; then
        echo "  ✓ PATH 已存在于 $rc_file，跳过"
        return 0
    fi

    # 兼容旧格式：如果存在旧的 cac PATH 行，先移除
    if grep -q '\.cac/bin' "$rc_file" 2>/dev/null; then
        _remove_path_from_rc "$rc_file"
    fi

    cat >> "$rc_file" << 'EOF'

# >>> cac — Claude Code Cloak >>>
export PATH="$HOME/bin:$PATH"          # cac 命令
export PATH="$HOME/.cac/bin:$PATH"     # claude wrapper
# <<< cac — Claude Code Cloak <<<
EOF
    echo "  ✓ PATH 已写入 $rc_file"
    return 0
}

_remove_path_from_rc() {
    local rc_file="${1:-$(_detect_rc_file)}"
    [[ -z "$rc_file" ]] && return 0

    # 移除标记块格式（新格式）
    if grep -q '# >>> cac' "$rc_file" 2>/dev/null; then
        local tmp="${rc_file}.cac-tmp"
        awk '/# >>> cac/{skip=1; next} /# <<< cac/{skip=0; next} !skip' "$rc_file" > "$tmp"
        cat -s "$tmp" > "$rc_file"
        rm -f "$tmp"
        echo "  ✓ 已从 $rc_file 移除 PATH 配置"
        return 0
    fi

    # 兼容旧格式
    if grep -qE '(\.cac/bin|# cac —)' "$rc_file" 2>/dev/null; then
        local tmp="${rc_file}.cac-tmp"
        grep -vE '(# cac — Claude Code Cloak|\.cac/bin|# cac 命令|# claude wrapper)' "$rc_file" > "$tmp" || true
        cat -s "$tmp" > "$rc_file"
        rm -f "$tmp"
        echo "  ✓ 已从 $rc_file 移除 PATH 配置（旧格式）"
        return 0
    fi
}

_update_statsig() {
    local statsig="$HOME/.claude/statsig"
    [[ -d "$statsig" ]] || return 0
    for f in "$statsig"/statsig.stable_id.*; do
        [[ -f "$f" ]] && printf '"%s"' "$1" > "$f"
    done
}

_update_claude_json_user_id() {
    local user_id="$1"
    local claude_json="$HOME/.claude.json"
    [[ -f "$claude_json" ]] || return 0
    python3 - "$claude_json" "$user_id" << 'PYEOF'
import json, sys
fpath, uid = sys.argv[1], sys.argv[2]
with open(fpath) as f:
    d = json.load(f)
d['userID'] = uid
with open(fpath, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF
    [[ $? -eq 0 ]] || echo "警告：更新 ~/.claude.json userID 失败" >&2
}
