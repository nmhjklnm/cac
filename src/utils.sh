# ── utils: colors, read/write, UUID, proxy parsing ───────────────────────

# shellcheck disable=SC2034  # used in build-concatenated cac script
CAC_VERSION="1.5.2"

_read()   { [[ -f "$1" ]] && tr -d '[:space:]' < "$1" || echo "${2:-}"; }
_die()    { printf '%b\n' "$(_red "error:") $*" >&2; exit 1; }

# Read a value from ~/.cac/settings.json
# Usage: _cac_setting "key" "default"
_cac_setting() {
    local key="$1" default="${2:-}"
    local settings="$CAC_DIR/settings.json"
    [[ -f "$settings" ]] || { echo "$default"; return; }
    local val
    val=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],''))" "$settings" "$key" 2>/dev/null || true)
    val="${val:-$default}"
    # Sync hot-path keys as plain files (avoids python3 spawn in wrapper)
    [[ "$key" == "max_sessions" ]] && echo "$val" > "$CAC_DIR/max_sessions"
    echo "$val"
}
_bold()   { printf '\033[1m%s\033[0m' "$*"; }
_green()  { printf '\033[32m%s\033[0m' "$*"; }
_red()    { printf '\033[31m%s\033[0m' "$*"; }
_yellow() { printf '\033[33m%s\033[0m' "$*"; }
_cyan()   { printf '\033[36m%s\033[0m' "$*"; }
_dim()    { printf '\033[2m%s\033[0m' "$*"; }
_green_bold() { printf '\033[1;32m%s\033[0m' "$*"; }

_detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

_gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(uuid.uuid4())" || _die "python3 required for UUID generation (install python3 or uuidgen)"
    fi
}
_new_uuid()    { _gen_uuid | tr '[:lower:]' '[:upper:]'; }
_new_user_id() { python3 -c "import os; print(os.urandom(32).hex())" || _die "python3 required"; }
_new_machine_id() { _gen_uuid | tr -d '-' | tr '[:upper:]' '[:lower:]'; }
_new_hostname() {
    local -a _first_names=(
        "James" "John" "Robert" "Michael" "William" "David" "Richard" "Joseph"
        "Thomas" "Charles" "Daniel" "Matthew" "Anthony" "Donald" "Mark" "Paul"
        "Steven" "Andrew" "Kenneth" "Joshua" "Kevin" "Brian" "George" "Timothy"
        "Emma" "Olivia" "Sophia" "Isabella" "Mia" "Charlotte" "Amelia" "Harper"
        "Evelyn" "Abigail" "Emily" "Elizabeth" "Sofia" "Avery" "Ella" "Scarlett"
        "Liam" "Noah" "Oliver" "Elijah" "Lucas" "Mason" "Ethan" "Aiden"
        "Alex" "Ryan" "Tyler" "Jordan" "Taylor" "Morgan" "Casey" "Riley"
    )
    local -a _models=("MacBook-Pro" "MacBook-Air" "MacBook-Pro" "MacBook-Pro")
    local _name="${_first_names[$((RANDOM % ${#_first_names[@]}))]}"
    local _model="${_models[$((RANDOM % ${#_models[@]}))]}"
    echo "${_name}s-${_model}.local"
}
_new_mac() { printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }
_new_git_remote() { echo "https://github.com/user-$(_gen_uuid | cut -d- -f1)/project-$(_gen_uuid | cut -d- -f2).git"; }
_new_git_email() { echo "user-$(_gen_uuid | cut -d- -f1 | tr '[:upper:]' '[:lower:]')@users.noreply.github.com"; }
_new_device_token() { _new_user_id; }

# Get real command path (bypass shim)
_get_real_cmd() {
    local cmd="$1"
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/shim-bin" | tr '\n' ':') \
        command -v "$cmd" 2>/dev/null || true
}

# host:port:user:pass → http://user:pass@host:port
# or pass a full URL directly (http://, https://, socks5://)
_parse_proxy() {
    local raw="$1"
    # Already a full URL, return as-is
    if [[ "$raw" =~ ^(http|https|socks5):// ]]; then
        echo "$raw"
        return
    fi
    # Parse host:port:user:pass format
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

# Auto-detect proxy protocol (when user didn't specify http/socks5/https)
# Usage: _auto_detect_proxy "host:port:user:pass" → returns a working full URL
_auto_detect_proxy() {
    local raw="$1"
    # Has protocol prefix, return as-is
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

    # Try in order: http → socks5 → https
    local proto try_url
    for proto in http socks5 https; do
        try_url="${proto}://${auth_part}${host}:${port}"
        if curl --proxy "$try_url" -fsSL --connect-timeout 8 -o /dev/null https://api.ipify.org 2>/dev/null; then
            echo "$try_url"
            return 0
        fi
    done

    # All failed, fallback to http
    if [[ -n "$user" ]]; then
        echo "http://${auth_part}${host}:${port}"
    else
        echo "http://${host}:${port}"
    fi
    return 1
}

_current_env()  { _read "$CAC_DIR/current"; }
_env_dir()      { echo "$ENVS_DIR/$1"; }

# ── Version management helpers ────────────────────────────────────

# Find the highest installed version by semver sort
_update_latest() {
    local highest=""
    for d in "$VERSIONS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local v
        v=$(basename "$d")
        [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || continue
        if [[ -z "$highest" ]] || [[ "$(printf '%s\n%s\n' "$highest" "$v" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$v" ]]; then
            highest="$v"
        fi
    done
    if [[ -n "$highest" ]]; then
        echo "$highest" > "$VERSIONS_DIR/.latest"
    else
        rm -f "$VERSIONS_DIR/.latest"
    fi
}

_resolve_version() {
    local v="$1"
    if [[ "$v" == "latest" || -z "$v" ]]; then
        _read "$VERSIONS_DIR/.latest" ""
    else
        echo "$v"
    fi
}

_version_binary() {
    echo "$VERSIONS_DIR/$1/claude"
}

_detect_platform() {
    local os arch platform
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *) echo "unsupported" ; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   arch="x64" ;;
        arm64|aarch64)  arch="arm64" ;;
        *) echo "unsupported" ; return 1 ;;
    esac
    if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
        [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]] && arch="arm64"
    fi
    if [[ "$os" == "linux" ]]; then
        if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || ldd /bin/ls 2>&1 | grep -q musl; then
            platform="linux-${arch}-musl"
        else
            platform="linux-${arch}"
        fi
    else
        platform="${os}-${arch}"
    fi
    echo "$platform"
}

_sha256() {
    case "$(uname -s)" in
        Darwin) shasum -a 256 "$1" | cut -d' ' -f1 ;;
        *)      sha256sum "$1" | cut -d' ' -f1 ;;
    esac
}

# Ensure a Claude Code version is installed (just-in-time, like uv)
# Usage: _ensure_version_installed <version>
# Resolves "latest", auto-downloads if missing, writes .latest
_ensure_version_installed() {
    local ver="$1"
    ver=$(_resolve_version "$ver")
    if [[ -z "$ver" ]]; then
        printf "Fetching latest version ... " >&2
        ver=$(_fetch_latest_version) || _die "failed to fetch latest version"
        echo "$(_cyan "$ver")" >&2
    fi
    if [[ ! -x "$(_version_binary "$ver")" ]]; then
        echo "Version $(_cyan "$ver") not installed, downloading ..." >&2
        mkdir -p "$VERSIONS_DIR"
        _download_version "$ver" >&2 || return 1
        _update_latest
        echo >&2
    fi
    echo "$ver"
}

# Count environments using a specific version
_envs_using_version() {
    local ver="$1" count=0
    for env_dir in "$ENVS_DIR"/*/; do
        [[ -d "$env_dir" ]] || continue
        [[ "$(_read "$env_dir/version" "")" == "$ver" ]] && (( count++ )) || true
    done
    echo "$count"
}

# Elapsed time helper: call _timer_start, then _timer_elapsed
_timer_start() { _TIMER_START=$(date +%s%N 2>/dev/null || date +%s); }
_timer_elapsed() {
    local now; now=$(date +%s%N 2>/dev/null || date +%s)
    if [[ ${#now} -gt 10 ]]; then
        # nanoseconds available
        local ms=$(( (now - _TIMER_START) / 1000000 ))
        if [[ $ms -ge 1000 ]]; then
            printf '%d.%ds' $((ms/1000)) $(( (ms%1000)/100 ))
        else
            printf '%dms' "$ms"
        fi
    else
        printf '%ds' $(( now - _TIMER_START ))
    fi
}

_require_setup() {
    _ensure_initialized
}

_require_env() {
    [[ -d "$ENVS_DIR/$1" ]] || {
        echo "error: environment '$1' not found, use 'cac ls' to list" >&2; exit 1
    }
}

_find_real_claude() {
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CAC_DIR/bin" | tr '\n' ':') \
        command -v claude 2>/dev/null || true
}

_detect_rc_file() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")
    case "$shell_name" in
        zsh)
            [[ -f "$HOME/.zshrc" ]] && { echo "$HOME/.zshrc"; return; }
            ;;
        bash)
            [[ -f "$HOME/.bashrc" ]] && { echo "$HOME/.bashrc"; return; }
            [[ -f "$HOME/.bash_profile" ]] && { echo "$HOME/.bash_profile"; return; }
            ;;
    esac
    # Fallback: try common rc files
    [[ -f "$HOME/.bashrc" ]] && { echo "$HOME/.bashrc"; return; }
    [[ -f "$HOME/.zshrc" ]] && { echo "$HOME/.zshrc"; return; }
    [[ -f "$HOME/.bash_profile" ]] && { echo "$HOME/.bash_profile"; return; }
    echo ""
}

_install_method() {
    local self="$0"
    local resolved="$self"
    if [[ -L "$self" ]]; then
        resolved=$(readlink "$self" 2>/dev/null || echo "$self")
        # Handle relative symlinks
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
        echo "  $(_yellow '⚠') shell config file not found, please add PATH manually:"
        echo '    export PATH="$HOME/bin:$PATH"'
        echo '    export PATH="$HOME/.cac/bin:$PATH"'
        return 0
    fi

    if grep -q '# >>> cac >>>' "$rc_file" 2>/dev/null; then
        echo "  ✓ PATH already exists in $rc_file, skipping"
        return 0
    fi

    # Compat: remove old format if present
    if grep -q '\.cac/bin' "$rc_file" 2>/dev/null; then
        _remove_path_from_rc "$rc_file"
    fi

    cat >> "$rc_file" << 'CACEOF'

# >>> cac — Claude Code Cloak >>>
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.cac/bin' | tr '\n' ':' | sed 's/:$//')
export PATH="$HOME/.cac/bin:$PATH"
cac() {
    local _cac_bin
    _cac_bin=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.cac/bin' | tr '\n' ':') command -v cac 2>/dev/null)
    [[ -z "$_cac_bin" ]] && { echo "[cac] error: cac binary not found in PATH" >&2; return 1; }
    command "$_cac_bin" "$@"
    local _rc=$?
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.cac/bin' | tr '\n' ':' | sed 's/:$//')
    export PATH="$HOME/.cac/bin:$PATH"
    return $_rc
}
# <<< cac — Claude Code Cloak <<<
CACEOF
    echo "  ✓ PATH written to $rc_file"
    return 0
}

_remove_path_from_rc() {
    local rc_file="${1:-$(_detect_rc_file)}"
    [[ -z "$rc_file" ]] && return 0

    # Remove marked block (new format)
    if grep -q '# >>> cac' "$rc_file" 2>/dev/null; then
        local tmp="${rc_file}.cac-tmp"
        awk '/# >>> cac/{skip=1; next} /# <<< cac/{skip=0; next} !skip' "$rc_file" > "$tmp"
        cat -s "$tmp" > "$rc_file"
        rm -f "$tmp"
        echo "  ✓ Removed PATH config from $rc_file"
        return 0
    fi

    # Compat: old format
    if grep -qE '(\.cac/bin|# cac —)' "$rc_file" 2>/dev/null; then
        local tmp="${rc_file}.cac-tmp"
        grep -vE '(# cac — Claude Code Cloak|\.cac/bin|# cac 命令|# claude wrapper)' "$rc_file" > "$tmp" || true
        cat -s "$tmp" > "$rc_file"
        rm -f "$tmp"
        echo "  ✓ Removed PATH config from $rc_file (old format)"
        return 0
    fi
}

_update_claude_json_user_id() {
    local user_id="$1"
    local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local claude_json="$config_dir/.claude.json"
    [[ -f "$claude_json" ]] || claude_json="$HOME/.claude.json"
    [[ -f "$claude_json" ]] || return 0

    # Find firstStartTime from current env
    local fst=""
    local current_env; current_env=$(_current_env)
    if [[ -n "$current_env" ]] && [[ -f "$ENVS_DIR/$current_env/first_start_time" ]]; then
        fst=$(tr -d '[:space:]' < "$ENVS_DIR/$current_env/first_start_time")
    fi

    python3 - "$claude_json" "$user_id" "$fst" << 'PYEOF'
import json, sys, uuid
fpath, uid, fst = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
with open(fpath) as f:
    d = json.load(f)
d['userID'] = uid
d['anonymousId'] = 'claudecode.v1.' + str(uuid.uuid4())
d.pop('numStartups', None)
if fst:
    d['firstStartTime'] = fst
else:
    d.pop('firstStartTime', None)
d.pop('cachedGrowthBookFeatures', None)
d.pop('cachedStatsigGates', None)
with open(fpath, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF
    [[ $? -eq 0 ]] || echo "warning: failed to update claude.json userID" >&2
}
