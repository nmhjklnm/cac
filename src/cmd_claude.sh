# ── cmd: claude (version management, like "uv python") ──────────

_GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

_download_version() {
    local ver="$1"
    local platform; platform=$(_detect_platform) || _die "unsupported platform"
    local dest_dir="$VERSIONS_DIR/$ver"
    local dest="$dest_dir/claude"

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
    checksum=$(echo "$manifest" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('platforms',{}).get(sys.argv[1],{}).get('checksum',''))
" "$platform" 2>/dev/null || true)

    if [[ -z "$checksum" ]] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
        rm -rf "$dest_dir"
        _die "platform $(_cyan "$platform") not in manifest"
    fi

    echo "  Downloading $(_cyan "claude $ver") ($(_dim "$platform"))"
    if ! curl -fL --progress-bar -o "$dest" "$_GCS_BUCKET/$ver/$platform/claude" 2>&1; then
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

cmd_claude() {
    case "${1:-help}" in
        install)    _claude_cmd_install "${@:2}" ;;
        uninstall)  _claude_cmd_uninstall "${@:2}" ;;
        ls|list)    _claude_cmd_ls ;;
        pin)        _claude_cmd_pin "${@:2}" ;;
        help|-h|--help)
            echo "$(_bold "cac claude") — Claude Code version management"
            echo
            echo "  $(_bold "install") [latest|<ver>]  Install a Claude Code version"
            echo "  $(_bold "uninstall") <ver>         Remove an installed version"
            echo "  $(_bold "ls")                      List installed versions"
            echo "  $(_bold "pin") <ver>               Pin current environment to a version"
            ;;
        *) _die "unknown: cac claude $1" ;;
    esac
}
