# ── cmd: claude (version management, like "uv python") ──────────

_GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

_manifest_checksum() {
    local platform="$1"
    node -e "
let json = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { json += chunk; });
process.stdin.on('end', () => {
  const d = JSON.parse(json);
  const entry = ((d.platforms || {})[process.argv[1]]) || {};
  process.stdout.write(entry.checksum || '');
});
" "$platform"
}

_download_version() {
    local ver="$1"
    local platform; platform=$(_detect_platform) || _die "unsupported platform"
    local dest_dir="$VERSIONS_DIR/$ver"
    local dest=$(_version_binary "$ver")

    if [[ -x "$dest" ]]; then
        echo "  Already installed: $(_cyan "$ver")"
        return 0
    fi

    mkdir -p "$dest_dir"
    _timer_start

    printf "  Downloading manifest ... "
    local manifest
    manifest=$(curl -fsSL "$_GCS_BUCKET/$ver/manifest.json" 2>/dev/null) || {
        echo "$(_red "failed")"
        rm -rf "$dest_dir"
        _die "version $(_cyan "$ver") not found or network unreachable"
    }
    echo "done"

    local checksum=""
    checksum=$(printf '%s' "$manifest" | _manifest_checksum "$platform" 2>/dev/null || true)

    if [[ -z "$checksum" ]] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
        rm -rf "$dest_dir"
        _die "platform $(_cyan "$platform") not in manifest"
    fi

    local binary_name="claude"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) binary_name="claude.exe" ;;
    esac

    echo "  Downloading $(_cyan "claude $ver") ($(_dim "$platform"))"
    if ! curl -fL --progress-bar -o "$dest" "$_GCS_BUCKET/$ver/$platform/$binary_name" 2>&1; then
        rm -rf "$dest_dir"
        _die "download failed"
    fi

    printf "  Verifying SHA256 checksum ... "
    local actual; actual=$(_sha256 "$dest")
    if [[ "$actual" != "$checksum" ]]; then
        echo "$(_red "failed")"
        rm -rf "$dest_dir"
        _die "checksum mismatch (expected: $checksum, actual: $actual)"
    fi
    echo "done"

    chmod +x "$dest"
    echo "$ver" > "$dest_dir/.version"
    local elapsed; elapsed=$(_timer_elapsed)
    echo "$(_green_bold "Installed") Claude Code $(_cyan "$ver") $(_dim "in $elapsed")"
}

_fetch_latest_version() {
    curl -fsSL "$_GCS_BUCKET/latest" 2>/dev/null
}

_claude_fetch_remote_latest() {
    local ver
    ver=$(_fetch_latest_version) || return 1
    ver=$(printf '%s' "$ver" | tr -d '[:space:]')
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]] || return 1
    echo "$ver"
}

_claude_version_is_newer() {
    local candidate="$1" current="$2"
    [[ -n "$candidate" ]] || return 1
    [[ -z "$current" || "$current" == "system" ]] && return 0
    [[ "$candidate" == "$current" ]] && return 1

    # Strip pre-release suffix before numeric comparison
    local cand_base="${candidate%%-*}" curr_base="${current%%-*}"
    local highest
    highest=$(printf '%s\n%s\n' "$curr_base" "$cand_base" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [[ "$highest" == "$cand_base" ]] && [[ "$cand_base" != "$curr_base" || "$candidate" > "$current" ]]
}

_claude_install_version_if_missing() {
    local ver="$1"
    mkdir -p "$VERSIONS_DIR"
    if [[ -x "$(_version_binary "$ver")" ]]; then
        _update_latest 2>/dev/null || true
        return 0
    fi

    echo "Version $(_cyan "$ver") not installed, downloading ..." >&2
    if ( _download_version "$ver" ); then
        _update_latest 2>/dev/null || true
        return 0
    fi
    return 1
}

_claude_pin_env_version() {
    local name="$1" ver="$2"
    printf '%s\n' "$ver" > "$ENVS_DIR/$name/version"
}

_claude_prompt_yes_no() {
    local prompt="$1" default="${2:-no}" answer suffix
    [[ -t 0 && -t 1 ]] || return 2

    if [[ "$default" == "yes" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi
    printf "  %s %s " "$prompt" "$suffix"
    read -r answer || answer=""
    answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')

    if [[ -z "$answer" ]]; then
        [[ "$default" == "yes" ]]
        return
    fi
    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

_claude_env_auto_update_on_activate() {
    local name="$1"
    local env_dir="$ENVS_DIR/$name"
    [[ "$(_read "$env_dir/claude_auto_update" "")" == "on" ]] || return 0

    local latest
    if ! latest=$(_claude_fetch_remote_latest); then
        echo "  $(_yellow "⚠") Claude auto-update check failed; continuing with current version"
        echo "  $(_dim "Run") $(_green "cac claude update $name") $(_dim "to retry manually.")"
        return 0
    fi

    local current; current=$(_read "$env_dir/version" "")
    [[ "$current" == "$latest" ]] && return 0
    _claude_version_is_newer "$latest" "$current" || return 0

    local current_label="${current:-system}"
    local prompt_rc fallback_rc
    _claude_prompt_yes_no "Claude Code $latest is available (current: $current_label). Update now?" "no"
    prompt_rc=$?

    if [[ "$prompt_rc" -eq 0 ]]; then
        if _claude_install_version_if_missing "$latest" && _claude_pin_env_version "$name" "$latest"; then
            echo "  $(_green "+") claude: updated $(_bold "$name") → $(_cyan "$latest")"
            return 0
        fi

        _claude_prompt_yes_no "Claude Code update failed. Continue activating $name with $current_label?" "yes"
        fallback_rc=$?
        if [[ "$fallback_rc" -eq 0 ]]; then
            echo "  $(_yellow "⚠") continuing with Claude Code $current_label"
            return 0
        fi
        if [[ "$fallback_rc" -eq 2 ]]; then
            echo "  $(_yellow "⚠") Claude Code update failed; non-interactive activation will continue with $current_label"
            return 0
        fi
        echo "  $(_red "✗") activation cancelled because Claude Code update failed" >&2
        return 1
    fi

    if [[ "$prompt_rc" -eq 2 ]]; then
        echo "  $(_yellow "⚠") Claude Code $latest is available; non-interactive activation will continue with $current_label"
        return 0
    fi

    echo "  $(_dim "Skipping Claude Code update for $name.")"
    return 0
}

_claude_unused_versions() {
    [[ -d "$VERSIONS_DIR" ]] || return 0
    local ver_dir ver count
    for ver_dir in "$VERSIONS_DIR"/*/; do
        [[ -d "$ver_dir" ]] || continue
        ver=$(basename "$ver_dir")
        [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || continue
        count=$(_envs_using_version "$ver")
        [[ "$count" -eq 0 ]] && echo "$ver"
    done
}

_claude_cmd_install() {
    local target="${1:-latest}"
    local ver
    if [[ "$target" == "latest" ]]; then
        printf "Fetching latest version ... "
        ver=$(_fetch_latest_version) || _die "failed to fetch latest version"
        echo "$(_cyan "$ver")"
    else
        ver="$target"
    fi

    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]] || \
        _die "invalid version $(_cyan "'$ver'")"

    mkdir -p "$VERSIONS_DIR"
    if _download_version "$ver"; then
        _update_latest
        echo
        echo "  Bind to environment: $(_cyan "cac env create <name> -c $ver")"
    fi
}

_claude_cmd_uninstall() {
    [[ -n "${1:-}" ]] || _die "missing version\n  usage: cac claude uninstall <version>"
    local ver="$1"
    [[ -d "$VERSIONS_DIR/$ver" ]] || _die "version $(_cyan "$ver") not installed"

    local count; count=$(_envs_using_version "$ver")
    [[ "$count" -eq 0 ]] || _die "version $(_cyan "$ver") in use by $count environment(s)"

    rm -rf "${VERSIONS_DIR:?}/$ver"
    _update_latest
    echo "$(_green_bold "Uninstalled") Claude Code $(_cyan "$ver")"
}

_claude_cmd_ls() {
    _update_latest 2>/dev/null || true
    if [[ ! -d "$VERSIONS_DIR" ]] || [[ -z "$(ls -A "$VERSIONS_DIR" 2>/dev/null)" ]]; then
        echo "$(_dim "  No versions installed.")"
        echo "  Run $(_green "cac claude install") to get started."
        return
    fi

    local latest; latest=$(_read "$VERSIONS_DIR/.latest" "")

    printf "  $(_dim "%-12s  %-8s  %s")\n" "VERSION" "STATUS" "ENVIRONMENTS"
    for ver_dir in "$VERSIONS_DIR"/*/; do
        [[ -d "$ver_dir" ]] || continue
        local ver; ver=$(basename "$ver_dir")
        local status=""; [[ "$ver" == "$latest" ]] && status="latest"
        local count; count=$(_envs_using_version "$ver")
        local usage="—"; [[ "$count" -gt 0 ]] && usage="$count env(s)"
        if [[ -n "$status" ]]; then
            printf "  $(_cyan "%-12s")  $(_green "%-8s")  %s\n" "$ver" "$status" "$usage"
        else
            printf "  $(_cyan "%-12s")  $(_dim "%-8s")  %s\n" "$ver" "—" "$usage"
        fi
    done
}

_claude_cmd_pin() {
    [[ -n "${1:-}" ]] || _die "missing version\n  usage: cac claude pin <version>"
    local ver="$1"
    ver=$(_resolve_version "$ver")
    [[ -x "$(_version_binary "$ver")" ]] || _die "version $(_cyan "$ver") not installed"

    local current; current=$(_current_env)
    [[ -n "$current" ]] || _die "no active environment"

    echo "$ver" > "$ENVS_DIR/$current/version"
    echo "$(_green_bold "Pinned") $(_bold "$current") -> Claude Code $(_cyan "$ver")"
}

_claude_cmd_update() {
    _require_setup

    [[ "${1:-}" != "-h" && "${1:-}" != "--help" && "${1:-}" != "help" ]] || {
        echo "  $(_bold "update") [env]  Update an environment to the remote latest Claude Code"
        return
    }
    [[ $# -le 1 ]] || _die "usage: cac claude update [env]"

    local name="${1:-}"
    if [[ -z "$name" ]]; then
        name=$(_current_env)
        [[ -n "$name" ]] || _die "no active environment — specify env name"
    fi
    _require_env "$name"

    printf "Fetching latest version ... "
    local latest
    latest=$(_claude_fetch_remote_latest) || {
        echo "$(_red "failed")"
        _die "failed to fetch latest Claude Code version"
    }
    echo "$(_cyan "$latest")"

    local env_dir="$ENVS_DIR/$name"
    local current; current=$(_read "$env_dir/version" "")
    if [[ "$current" == "$latest" ]]; then
        echo "$(_green_bold "Up to date") $(_bold "$name") -> Claude Code $(_cyan "$latest")"
        return
    fi

    if _claude_install_version_if_missing "$latest" && _claude_pin_env_version "$name" "$latest"; then
        echo "$(_green_bold "Updated") $(_bold "$name") -> Claude Code $(_cyan "$latest")"
        return
    fi
    _die "failed to update $(_bold "$name") to Claude Code $(_cyan "$latest")"
}

_claude_cmd_prune() {
    _require_setup

    local yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) yes=true; shift ;;
            -h|--help|help)
                echo "  $(_bold "prune") [--yes]  List or remove Claude Code versions not used by any env"
                return
                ;;
            *) _die "unknown option: $1" ;;
        esac
    done

    local unused=()
    local ver
    while IFS= read -r ver; do
        [[ -n "$ver" ]] && unused+=("$ver")
    done < <(_claude_unused_versions)

    if [[ "${#unused[@]}" -eq 0 ]]; then
        echo "$(_green_bold "Clean") no unused Claude Code versions"
        return
    fi

    if [[ "$yes" != "true" ]]; then
        echo "Unused Claude Code versions:"
        for ver in "${unused[@]}"; do
            echo "  $(_cyan "$ver")"
        done
        echo
        echo "Run $(_green "cac claude prune --yes") to remove them."
        return
    fi

    for ver in "${unused[@]}"; do
        rm -rf "${VERSIONS_DIR:?}/$ver"
        echo "$(_green "-") removed Claude Code $(_cyan "$ver")"
    done
    _update_latest 2>/dev/null || true
}

cmd_claude() {
    case "${1:-help}" in
        install)    _claude_cmd_install "${@:2}" ;;
        uninstall)  _claude_cmd_uninstall "${@:2}" ;;
        ls|list)    _claude_cmd_ls ;;
        pin)        _claude_cmd_pin "${@:2}" ;;
        update)     _claude_cmd_update "${@:2}" ;;
        prune)      _claude_cmd_prune "${@:2}" ;;
        help|-h|--help)
            echo "$(_bold "cac claude") — Claude Code version management"
            echo
            echo "  $(_bold "install") [latest|<ver>]  Install a Claude Code version"
            echo "  $(_bold "uninstall") <ver>         Remove an installed version"
            echo "  $(_bold "ls")                      List installed versions"
            echo "  $(_bold "pin") <ver>               Pin current environment to a version"
            echo "  $(_bold "update") [env]            Update an environment to remote latest"
            echo "  $(_bold "prune") [--yes]           List or remove versions not used by envs"
            ;;
        *) _die "unknown: cac claude $1" ;;
    esac
}
