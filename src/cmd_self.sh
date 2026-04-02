# ── cmd: self (cac self-management, like "uv self") ──────────────

_SELF_REPO="https://raw.githubusercontent.com/nmhjklnm/cac/master"

_self_cmd_update() {
    local method; method=$(_install_method)

    echo "Updating cac ..."
    _timer_start

    case "$method" in
        npm)
            echo "  Install method: $(_cyan "npm")"
            npm update -g claude-cac 2>&1 || _die "npm update failed"
            ;;
        bash)
            echo "  Install method: $(_cyan "bash")"
            local bin_dir="$HOME/bin"
            mkdir -p "$bin_dir"
            echo "  Downloading latest cac"
            if curl -fL --progress-bar -o "$bin_dir/cac.tmp" "$_SELF_REPO/cac" 2>&1; then
                chmod +x "$bin_dir/cac.tmp"
                mv "$bin_dir/cac.tmp" "$bin_dir/cac"
            else
                rm -f "$bin_dir/cac.tmp"
                _die "download failed"
            fi
            # Regenerate wrapper and shims from new binary
            _ensure_initialized
            ;;
        *)
            _die "unknown install method\n  Reinstall with: curl -fsSL $_SELF_REPO/install.sh | bash"
            ;;
    esac

    local elapsed; elapsed=$(_timer_elapsed)
    echo "$(_green_bold "Updated") cac $(_dim "in $elapsed")"
}

cmd_self() {
    case "${1:-help}" in
        update)          _self_cmd_update ;;
        delete|remove)   cmd_delete ;;
        vpn-ensure)      _vpn_ensure_compatible "${2:-}" ;;
        help|-h|--help)
            echo "$(_bold "cac self") — cac self-management"
            echo
            echo "  $(_bold "update")    Update cac to the latest version"
            echo "  $(_bold "delete")    Uninstall cac completely"
            ;;
        *) _die "unknown: cac self $1" ;;
    esac
}
