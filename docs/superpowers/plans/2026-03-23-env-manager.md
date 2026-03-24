# Claude Code Environment Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform cac into a full Claude Code environment manager — like `uv` for Python. `cac claude` manages versions (like `uv python`), `cac env` manages environments (like `uv venv`). Each environment = version + config + identity + proxy, fully isolated.

**Architecture:** Binaries in `~/.cac/versions/<ver>/claude`. Environments in `~/.cac/envs/<name>/` with isolated `.claude/` config dir (via `CLAUDE_CONFIG_DIR`). Two new subcommands: `cac claude` (version mgmt) and `cac env` (environment mgmt, replaces top-level `add/ls`). Wrapper resolves binary from `$_env_dir/version` directly (no global state file).

**Tech Stack:** Bash, curl, sha256sum/shasum

---

## Command Design (uv-inspired)

```
cac claude install [latest|2.1.81]    # like: uv python install 3.12
cac claude uninstall 2.1.81
cac claude ls                          # like: uv python list
cac claude pin 2.1.81                  # pin current env to version

cac env create work -p ip:port:u:p -c 2.1.81   # like: uv venv
cac env ls                                       # like: uv venv list
cac env rm work
cac env activate work                  # or shortcut: cac work

cac stop / cac resume                  # was: cac stop / cac -c
```

---

## File Structure

| File | Action | Role |
|------|--------|------|
| `src/cmd_claude.sh` | **Create** | `cac claude install/uninstall/ls/pin` |
| `src/cmd_env.sh` | **Rewrite** | `cac env create/ls/rm/activate` (replaces old `add/switch/ls`) |
| `src/utils.sh` | **Modify** | Add `_resolve_version`, `_version_binary`, `_detect_platform` |
| `src/templates.sh` | **Modify** | Wrapper: inject `CLAUDE_CONFIG_DIR`, resolve versioned binary |
| `src/cmd_setup.sh` | **Modify** | Auto-install if claude not found |
| `src/cmd_stop.sh` | **Modify** | Change `cac -c` hint → `cac resume` |
| `src/cmd_help.sh` | **Modify** | New help text |
| `src/main.sh` | **Modify** | New dispatch: `claude`, `env`, `resume`; remove `add`, `-c` |
| `build.sh` | **Modify** | Add `cmd_claude.sh` to SOURCES, `VERSIONS_DIR` to header |

---

### Task 1: Version infrastructure (utils.sh + build.sh)

**Files:**
- Modify: `src/utils.sh` (after line 110, `_env_dir()`)
- Modify: `build.sh` (line 34, after `ENVS_DIR`)

- [ ] **Step 1: Add `VERSIONS_DIR` to build.sh global header**

After `echo 'ENVS_DIR="$CAC_DIR/envs"'` (line 34), add:

```bash
echo 'VERSIONS_DIR="$CAC_DIR/versions"'
```

- [ ] **Step 2: Add version helpers to utils.sh**

After `_env_dir()` (line 110), add:

```bash
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
```

- [ ] **Step 3: Rebuild and verify**

```bash
cd /home/project/cac && bash build.sh && grep VERSIONS_DIR cac
```

- [ ] **Step 4: Commit**

```bash
git add src/utils.sh build.sh
git commit -m "feat: add version storage infrastructure and platform detection"
```

---

### Task 2: `cac claude` subcommand (cmd_claude.sh)

**Files:**
- Create: `src/cmd_claude.sh`
- Modify: `build.sh` (SOURCES array)
- Modify: `src/main.sh`

- [ ] **Step 1: Create src/cmd_claude.sh**

```bash
# ── cmd: claude (version management, like "uv python") ──────────

_GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

_download_version() {
    local ver="$1" platform="$2"
    local dest_dir="$VERSIONS_DIR/$ver"
    local dest="$dest_dir/claude"

    if [[ -x "$dest" ]]; then
        echo "  已安装：$ver"
        return 0
    fi

    mkdir -p "$dest_dir"

    printf "  下载 manifest ... "
    local manifest
    manifest=$(curl -fsSL "$_GCS_BUCKET/$ver/manifest.json" 2>/dev/null) || {
        echo "$(_red "失败")"
        echo "错误：版本 $ver 不存在或网络不可达" >&2
        rm -rf "$dest_dir"
        return 1
    }
    echo "$(_green "✓")"

    local checksum=""
    if command -v jq >/dev/null 2>&1; then
        checksum=$(echo "$manifest" | jq -r ".platforms[\"$platform\"].checksum // empty")
    else
        local json; json=$(echo "$manifest" | tr -d '\n\r\t' | sed 's/ \+/ /g')
        if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
            checksum="${BASH_REMATCH[1]}"
        fi
    fi

    if [[ -z "$checksum" ]] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
        echo "错误：平台 $platform 不在 manifest 中" >&2
        rm -rf "$dest_dir"
        return 1
    fi

    printf "  下载 claude $ver ($platform) ... "
    if ! curl -fsSL -o "$dest" "$_GCS_BUCKET/$ver/$platform/claude" 2>/dev/null; then
        echo "$(_red "失败")"
        rm -rf "$dest_dir"
        return 1
    fi
    echo "$(_green "✓")"

    printf "  校验 SHA256 ... "
    local actual
    case "$(uname -s)" in
        Darwin) actual=$(shasum -a 256 "$dest" | cut -d' ' -f1) ;;
        *)      actual=$(sha256sum "$dest" | cut -d' ' -f1) ;;
    esac
    if [[ "$actual" != "$checksum" ]]; then
        echo "$(_red "失败")"
        echo "  期望：$checksum" >&2
        echo "  实际：$actual" >&2
        rm -rf "$dest_dir"
        return 1
    fi
    echo "$(_green "✓")"

    chmod +x "$dest"
    echo "$ver" > "$dest_dir/.version"
}

_fetch_latest_version() {
    curl -fsSL "$_GCS_BUCKET/latest" 2>/dev/null
}

_claude_cmd_install() {
    local target="${1:-latest}"
    local platform
    platform=$(_detect_platform) || { echo "错误：不支持的平台" >&2; exit 1; }

    local ver
    if [[ "$target" == "latest" ]]; then
        printf "查询最新版本 ... "
        ver=$(_fetch_latest_version) || { echo "$(_red "失败")"; exit 1; }
        echo "$(_green "$ver")"
    else
        ver="$target"
    fi

    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]; then
        echo "错误：无效版本号 '$ver'" >&2; exit 1
    fi

    mkdir -p "$VERSIONS_DIR"
    echo "安装 Claude Code $ver ..."
    if _download_version "$ver" "$platform"; then
        echo "$ver" > "$VERSIONS_DIR/.latest"
        echo
        echo "$(_green "✓") Claude Code $ver 已安装"
        echo "  绑定到环境：cac env create <name> -p <proxy> -c $ver"
    fi
}

_claude_cmd_uninstall() {
    local ver="${1:?用法：cac claude uninstall <version>}"
    local ver_dir="$VERSIONS_DIR/$ver"
    [[ -d "$ver_dir" ]] || { echo "错误：版本 $ver 未安装" >&2; exit 1; }

    local in_use=""
    for env_dir in "$ENVS_DIR"/*/; do
        [[ -d "$env_dir" ]] || continue
        [[ "$(_read "$env_dir/version" "")" == "$ver" ]] && in_use="$in_use $(basename "$env_dir")"
    done
    if [[ -n "$in_use" ]]; then
        echo "错误：版本 $ver 正在使用：$in_use" >&2; exit 1
    fi

    rm -rf "$ver_dir"
    echo "$(_green "✓") 已卸载 Claude Code $ver"
}

_claude_cmd_ls() {
    echo "$(_bold "已安装的 Claude Code 版本：")"
    echo
    if [[ ! -d "$VERSIONS_DIR" ]] || [[ -z "$(ls -A "$VERSIONS_DIR" 2>/dev/null)" ]]; then
        echo "  （暂无，用 'cac claude install' 安装）"
        return
    fi

    local latest; latest=$(_read "$VERSIONS_DIR/.latest" "")
    for ver_dir in "$VERSIONS_DIR"/*/; do
        [[ -d "$ver_dir" ]] || continue
        local ver; ver=$(basename "$ver_dir")
        local tag=""; [[ "$ver" == "$latest" ]] && tag=" $(_green "(latest)")"
        local count=0
        for env_dir in "$ENVS_DIR"/*/; do
            [[ -d "$env_dir" ]] || continue
            [[ "$(_read "$env_dir/version" "")" == "$ver" ]] && (( count++ ))
        done
        local usage=""; [[ $count -gt 0 ]] && usage=" ($count 个环境)"
        printf "  %s%s%s\n" "$ver" "$tag" "$usage"
    done

    local sys; sys=$(_read "$CAC_DIR/real_claude" "")
    if [[ -n "$sys" ]] && [[ -x "$sys" ]]; then
        local sv; sv=$("$sys" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
        echo
        echo "  系统：$sys ($sv)"
    fi
}

_claude_cmd_pin() {
    local ver="${1:?用法：cac claude pin <version>}"
    ver=$(_resolve_version "$ver")
    [[ -x "$(_version_binary "$ver")" ]] || { echo "错误：版本 $ver 未安装" >&2; exit 1; }

    local current; current=$(_current_env)
    [[ -n "$current" ]] || { echo "错误：未激活环境" >&2; exit 1; }

    echo "$ver" > "$ENVS_DIR/$current/version"
    echo "$(_green "✓") $(_bold "$current") → Claude Code $ver"
}

cmd_claude() {
    case "${1:-help}" in
        install)    _claude_cmd_install "${@:2}" ;;
        uninstall)  _claude_cmd_uninstall "${@:2}" ;;
        ls|list)    _claude_cmd_ls ;;
        pin)        _claude_cmd_pin "${@:2}" ;;
        help|-h|--help)
            echo "$(_bold "cac claude") — Claude Code 版本管理"
            echo
            echo "  install [latest|<ver>]  安装"
            echo "  uninstall <ver>         卸载"
            echo "  ls                      列出已安装版本"
            echo "  pin <ver>               当前环境绑定版本"
            ;;
        *) echo "未知：cac claude $1" >&2; exit 1 ;;
    esac
}
```

- [ ] **Step 2: Add to build.sh SOURCES** (after `cmd_stop.sh`, before `cmd_docker.sh`)

- [ ] **Step 3: Add `claude)  cmd_claude "${@:2}" ;;` to main.sh**

- [ ] **Step 4: Rebuild and verify**

- [ ] **Step 5: Commit**

```bash
git add src/cmd_claude.sh src/main.sh build.sh
git commit -m "feat: add 'cac claude' subcommand (install/uninstall/ls/pin)"
```

---

### Task 3: `cac env` subcommand (rewrite cmd_env.sh)

**Files:**
- Rewrite: `src/cmd_env.sh`
- Modify: `src/main.sh`

Replace old top-level `add/ls/switch` with `cac env create/ls/rm/activate`. Keep `cac <name>` shortcut for activate.

- [ ] **Step 1: Rewrite cmd_env.sh**

```bash
# ── cmd: env (environment management, like "uv venv") ───────────

_env_cmd_create() {
    _require_setup
    local name="" proxy="" claude_ver="" env_type="local"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--proxy)  proxy="$2"; shift 2 ;;
            -c|--claude) claude_ver="$2"; shift 2 ;;
            --type)      env_type="$2"; shift 2 ;;
            -*)          echo "未知选项：$1" >&2; exit 1 ;;
            *)           [[ -z "$name" ]] && name="$1" || { echo "多余参数：$1" >&2; exit 1; }; shift ;;
        esac
    done

    if [[ -z "$name" ]]; then
        echo "用法：cac env create <name> -p <proxy> [-c <版本>] [--type local|container]" >&2
        exit 1
    fi
    if [[ -z "$proxy" ]]; then
        echo "错误：需要 -p <proxy>" >&2; exit 1
    fi

    local env_dir="$ENVS_DIR/$name"
    [[ -d "$env_dir" ]] && { echo "错误：环境 '$name' 已存在" >&2; exit 1; }

    # Resolve version
    if [[ -n "$claude_ver" ]]; then
        claude_ver=$(_resolve_version "$claude_ver")
        [[ -x "$(_version_binary "$claude_ver")" ]] || {
            echo "错误：版本 $claude_ver 未安装，先运行 'cac claude install $claude_ver'" >&2; exit 1
        }
    fi

    # Auto-detect proxy protocol
    local proxy_url
    if [[ ! "$proxy" =~ ^(http|https|socks5):// ]]; then
        printf "  自动检测代理协议 ... "
        if proxy_url=$(_auto_detect_proxy "$proxy"); then
            echo "$(_green "$(echo "$proxy_url" | grep -oE '^[a-z]+')")"
        else
            echo "$(_yellow "检测失败，默认 http://")"
        fi
    else
        proxy_url=$(_parse_proxy "$proxy")
    fi

    echo "即将创建环境：$(_bold "$name")"
    echo "  代理：$proxy_url"
    [[ -n "$claude_ver" ]] && echo "  Claude Code：$claude_ver"
    echo "  类型：$env_type"
    echo

    printf "  检测代理 ... "
    if _proxy_reachable "$proxy_url"; then
        echo "$(_green "✓ 可达")"
    else
        echo "$(_red "✗ 不通")"
        echo "  警告：代理当前不可达"
    fi

    # Geo-detect timezone
    printf "  检测时区 ... "
    local tz="America/New_York" lang="en_US.UTF-8"
    local exit_ip
    exit_ip=$(curl -s --proxy "$proxy_url" --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)
    if [[ -n "$exit_ip" ]]; then
        local ip_info
        ip_info=$(curl -s --connect-timeout 8 "http://ip-api.com/json/${exit_ip}?fields=timezone,countryCode" 2>/dev/null || true)
        local detected_tz
        detected_tz=$(echo "$ip_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timezone',''))" 2>/dev/null || true)
        [[ -n "$detected_tz" ]] && tz="$detected_tz"
        echo "$(_green "✓ $tz")"
    else
        echo "$(_yellow "⚠ 默认 $tz")"
    fi
    echo

    printf "确认创建？[yes/N] "
    read -r confirm
    [[ "$confirm" == "yes" ]] || { echo "已取消。"; exit 0; }

    mkdir -p "$env_dir"
    echo "$proxy_url"         > "$env_dir/proxy"
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

    printf "  生成 mTLS 证书 ... "
    if _generate_client_cert "$name"; then
        echo "$(_green "✓")"
    else
        echo "$(_yellow "⚠ 跳过")"
    fi

    echo
    echo "$(_green "✓") 环境 '$(_bold "$name")' 已创建"
    echo "  UUID：$(cat "$env_dir/uuid")"
    [[ -n "$claude_ver" ]] && echo "  Claude：$claude_ver"
    echo "  类型：$env_type"
    echo
    echo "激活：cac $name"
}

_env_cmd_ls() {
    _require_setup
    if [[ ! -d "$ENVS_DIR" ]] || [[ -z "$(ls -A "$ENVS_DIR" 2>/dev/null)" ]]; then
        echo "（暂无环境，用 'cac env create <name> -p <proxy>' 创建）"
        return
    fi

    local current; current=$(_current_env)
    local stopped_tag=""
    [[ -f "$CAC_DIR/stopped" ]] && stopped_tag=" $(_red "[stopped]")"

    for env_dir in "$ENVS_DIR"/*/; do
        [[ -d "$env_dir" ]] || continue
        local name; name=$(basename "$env_dir")
        local proxy; proxy=$(_read "$env_dir/proxy" "—")
        local ver; ver=$(_read "$env_dir/version" "system")
        local etype; etype=$(_read "$env_dir/type" "local")

        if [[ "$name" == "$current" ]]; then
            printf "  %s %s%s\n" "$(_green "▶")" "$(_bold "$name")" "$stopped_tag"
        else
            printf "    %s\n" "$name"
        fi
        printf "      proxy: %s  claude: %s  type: %s\n" "$proxy" "$ver" "$etype"
    done
}

_env_cmd_rm() {
    local name="${1:?用法：cac env rm <name>}"
    _require_env "$name"

    local current; current=$(_current_env)
    if [[ "$name" == "$current" ]]; then
        echo "错误：不能删除当前激活的环境 '$name'" >&2
        echo "  先切换到其他环境" >&2
        exit 1
    fi

    printf "确认删除环境 '$name'？[yes/N] "
    read -r confirm
    [[ "$confirm" == "yes" ]] || { echo "已取消。"; exit 0; }

    rm -rf "$ENVS_DIR/$name"
    echo "$(_green "✓") 环境 '$name' 已删除"
}

_env_cmd_activate() {
    _require_setup
    local name="$1"
    _require_env "$name"

    local proxy; proxy=$(_read "$ENVS_DIR/$name/proxy")

    printf "检测 [%s] 代理 ... " "$name"
    if _proxy_reachable "$proxy"; then
        echo "$(_green "✓ 可达")"
    else
        echo "$(_yellow "⚠ 不通")"
        echo "警告：代理不可达，仍切换"
    fi

    echo "$name" > "$CAC_DIR/current"
    rm -f "$CAC_DIR/stopped"

    # Set config dir for this environment
    if [[ -d "$ENVS_DIR/$name/.claude" ]]; then
        export CLAUDE_CONFIG_DIR="$ENVS_DIR/$name/.claude"
    fi

    _update_statsig "$(_read "$ENVS_DIR/$name/stable_id")"
    _update_claude_json_user_id "$(_read "$ENVS_DIR/$name/user_id")"

    # Relay lifecycle
    _relay_stop 2>/dev/null || true
    if [[ -f "$ENVS_DIR/$name/relay" ]] && [[ "$(_read "$ENVS_DIR/$name/relay")" == "on" ]]; then
        printf "  启动 relay ... "
        if _relay_start "$name"; then
            local rport; rport=$(_read "$CAC_DIR/relay.port")
            echo "$(_green "✓") 127.0.0.1:$rport"
        else
            echo "$(_yellow "⚠ 启动失败")"
        fi
    fi

    echo "$(_green "✓") 已切换到 $(_bold "$name")"
}

cmd_env() {
    case "${1:-help}" in
        create)     _env_cmd_create "${@:2}" ;;
        ls|list)    _env_cmd_ls ;;
        rm|remove)  _env_cmd_rm "${@:2}" ;;
        activate)   _env_cmd_activate "${@:2}" ;;
        help|-h|--help)
            echo "$(_bold "cac env") — 环境管理"
            echo
            echo "  create <name> -p <proxy> [-c <ver>] [--type local|container]"
            echo "  ls              列出所有环境"
            echo "  rm <name>       删除环境"
            echo "  activate <name> 激活环境（快捷：cac <name>）"
            ;;
        *) echo "未知：cac env $1" >&2; exit 1 ;;
    esac
}

# Backward compat: keep cmd_ls for 'cac ls'
cmd_ls() { _env_cmd_ls; }
```

- [ ] **Step 2: Update main.sh dispatcher**

Replace entire dispatcher:

```bash
[[ $# -eq 0 ]] && { cmd_help; exit 0; }

case "$1" in
    setup)              cmd_setup         ;;
    env)                cmd_env  "${@:2}" ;;
    claude)             cmd_claude "${@:2}" ;;
    ls|list)            cmd_ls            ;;
    check)              cmd_check         ;;
    stop)               cmd_stop          ;;
    resume)             cmd_continue      ;;
    relay)              cmd_relay "${@:2}" ;;
    docker)             cmd_docker "${@:2}" ;;
    delete)             cmd_delete        ;;
    -v|--version)       cmd_version       ;;
    help|--help|-h)     cmd_help          ;;
    *)                  _env_cmd_activate "$1" ;;
esac
```

Note: `cac <name>` shortcut calls `_env_cmd_activate` directly. `cac ls` kept as top-level shortcut. Old `add` removed (use `cac env create`). `-c` freed for `--claude` flag.

- [ ] **Step 3: Rebuild and verify**

- [ ] **Step 4: Commit**

```bash
git add src/cmd_env.sh src/main.sh
git commit -m "feat: add 'cac env' subcommand (create/ls/rm/activate), -p proxy, -c claude version"
```

---

### Task 4: Wrapper — CLAUDE_CONFIG_DIR + versioned binary (templates.sh)

**Files:**
- Modify: `src/templates.sh` (inside `_write_wrapper`)
- Modify: `src/utils.sh` (`_update_statsig`, `_update_claude_json_user_id`)

- [ ] **Step 1: Add CLAUDE_CONFIG_DIR injection to wrapper**

In the wrapper (inside `_write_wrapper`), after line 25 (`[[ -d "$_env_dir" ]] || ...`), add:

```bash
# Isolated .claude config directory
if [[ -d "$_env_dir/.claude" ]]; then
    export CLAUDE_CONFIG_DIR="$_env_dir/.claude"
fi
```

- [ ] **Step 2: Replace binary resolution in wrapper**

Change wrapper line 119:

```bash
_real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude")
```

To:

```bash
_real=""
if [[ -f "$_env_dir/version" ]]; then
    _ver=$(tr -d '[:space:]' < "$_env_dir/version")
    _ver_bin="$CAC_DIR/versions/$_ver/claude"
    [[ -x "$_ver_bin" ]] && _real="$_ver_bin"
fi
if [[ -z "$_real" ]] || [[ ! -x "$_real" ]]; then
    _real=$(tr -d '[:space:]' < "$CAC_DIR/real_claude")
fi
```

- [ ] **Step 3: Fix wrapper statsig to use CLAUDE_CONFIG_DIR**

Change wrapper line 42:

```bash
    for _f in "$HOME/.claude/statsig"/statsig.stable_id.*; do
```

To:

```bash
    _config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    for _f in "$_config_dir/statsig"/statsig.stable_id.*; do
```

- [ ] **Step 4: Update _update_statsig and _update_claude_json_user_id in utils.sh**

Replace lines 213-234 of `src/utils.sh`:

```bash
_update_statsig() {
    local sid="$1"
    local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local statsig="$config_dir/statsig"
    [[ -d "$statsig" ]] || return 0
    for f in "$statsig"/statsig.stable_id.*; do
        [[ -f "$f" ]] && printf '"%s"' "$sid" > "$f"
    done
}

_update_claude_json_user_id() {
    local user_id="$1"
    local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local claude_json="$config_dir/.claude.json"
    [[ -f "$claude_json" ]] || claude_json="$HOME/.claude.json"
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
    [[ $? -eq 0 ]] || echo "警告：更新 claude.json userID 失败" >&2
}
```

- [ ] **Step 5: Rebuild and verify**

```bash
bash build.sh && grep -A2 CLAUDE_CONFIG_DIR cac
```

- [ ] **Step 6: Commit**

```bash
git add src/templates.sh src/utils.sh
git commit -m "feat: wrapper injects CLAUDE_CONFIG_DIR and resolves versioned binary"
```

---

### Task 5: Setup auto-install + stop/resume rename

**Files:**
- Modify: `src/cmd_setup.sh` (lines 4-16)
- Modify: `src/cmd_stop.sh` (line 7)

- [ ] **Step 1: Update cmd_setup to auto-install**

Replace lines 4-16 of `src/cmd_setup.sh`:

```bash
    mkdir -p "$ENVS_DIR" "$VERSIONS_DIR"

    local real_claude
    real_claude=$(_find_real_claude)
    if [[ -z "$real_claude" ]]; then
        echo "  未找到 claude 命令"
        printf "  自动安装最新版本？[Y/n] "
        read -r _ans
        if [[ "$_ans" != "n" && "$_ans" != "N" ]]; then
            _claude_cmd_install latest
            local latest_ver; latest_ver=$(_read "$VERSIONS_DIR/.latest" "")
            [[ -n "$latest_ver" ]] && real_claude="$VERSIONS_DIR/$latest_ver/claude"
        fi
        if [[ -z "$real_claude" ]] || [[ ! -x "$real_claude" ]]; then
            echo "错误：安装失败" >&2; exit 1
        fi
    fi
    echo "  Claude Code：$real_claude"
    echo "$real_claude" > "$CAC_DIR/real_claude"
```

- [ ] **Step 2: Update cmd_stop.sh hint**

Change line 7 of `src/cmd_stop.sh`:

```bash
    echo "  恢复：cac -c"
```

To:

```bash
    echo "  恢复：cac resume"
```

- [ ] **Step 3: Rebuild and commit**

```bash
git add src/cmd_setup.sh src/cmd_stop.sh
git commit -m "feat: setup auto-installs Claude Code; rename -c to resume"
```

---

### Task 6: Help text + README

**Files:**
- Modify: `src/cmd_help.sh`
- Modify: `README.md`

- [ ] **Step 1: Replace cmd_help()**

```bash
cmd_help() {
cat <<EOF
$(_bold "cac") — Claude Code 环境管理器

$(_bold "版本管理：")
  cac claude install [latest|<ver>]   安装 Claude Code
  cac claude uninstall <ver>           卸载
  cac claude ls                        列出已安装版本
  cac claude pin <ver>                 当前环境绑定版本

$(_bold "环境管理：")
  cac env create <name> -p <proxy> [-c <ver>] [--type local|container]
  cac env ls                           列出所有环境
  cac env rm <name>                    删除环境
  cac <name>                           激活环境（快捷方式）

$(_bold "其他：")
  cac setup                            首次安装
  cac ls                               列出环境（= cac env ls）
  cac check                            核查当前环境
  cac relay [on|off|status]            本地中转
  cac stop / resume                    停用 / 恢复
  cac delete                           卸载 cac
  cac -v                               版本号

$(_bold "Docker：")
  cac docker setup|start|enter|check|port|stop|help

$(_bold "代理格式：")
  host:port:user:pass       带认证（自动检测协议）
  host:port                 无认证
  socks5://u:p@host:port    指定协议

$(_bold "示例：")
  cac claude install latest
  cac env create work -p 1.2.3.4:1080:u:p -c 2.1.81
  cac work
  cac claude pin latest

$(_bold "文件：")
  ~/.cac/versions/<ver>/claude    Claude Code 二进制
  ~/.cac/envs/<name>/             环境（proxy/uuid/version/...）
  ~/.cac/envs/<name>/.claude/     隔离的 .claude 配置
  ~/.cac/bin/claude               wrapper
  ~/.cac/current                  当前环境
EOF
}
```

- [ ] **Step 2: Update README.md**

Add version management + environment sections. Update examples to use `cac claude` and `cac env create -p ... -c ...`.

- [ ] **Step 3: Rebuild and commit**

```bash
git add src/cmd_help.sh README.md
git commit -m "docs: update help and README for cac claude/env subcommands"
```

---

### Task 7: Final build + verification

- [ ] **Step 1: Rebuild**

```bash
cd /home/project/cac && bash build.sh
```

- [ ] **Step 2: Verify dispatch**

```bash
./cac help
./cac claude help
./cac env help
```

- [ ] **Step 3: Test `cac claude install latest`**

```bash
./cac claude install latest
./cac claude ls
```

- [ ] **Step 4: Verify wrapper**

```bash
grep -c 'CLAUDE_CONFIG_DIR' cac     # should be > 0
grep 'versions.*claude' cac | head -5  # version binary resolution
grep 'resume' cac                     # resume replaces -c
```

- [ ] **Step 5: Commit built artifact**

```bash
git add cac
git commit -m "build: rebuild cac with claude/env subcommands and config isolation"
```
