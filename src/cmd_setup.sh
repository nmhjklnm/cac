# ── cmd: setup (auto-bootstrap, no manual step needed) ─────────

# Silent, idempotent initialization — called automatically by any command
_ensure_initialized() {
    # Already initialized?
    [[ -f "$CAC_DIR/bin/claude" ]] && [[ -d "$ENVS_DIR" ]] && [[ -d "$VERSIONS_DIR" ]] && return 0

    mkdir -p "$ENVS_DIR" "$VERSIONS_DIR"

    # Find real claude (system-installed or managed)
    local real_claude
    real_claude=$(_find_real_claude)
    if [[ -z "$real_claude" ]]; then
        # Check managed versions
        local latest_ver; latest_ver=$(_read "$VERSIONS_DIR/.latest" "")
        if [[ -n "$latest_ver" ]]; then
            real_claude="$VERSIONS_DIR/$latest_ver/claude"
        fi
    fi
    # If still not found, we can still initialize — env create will handle it
    if [[ -n "$real_claude" ]] && [[ -x "$real_claude" ]]; then
        echo "$real_claude" > "$CAC_DIR/real_claude"
    fi

    local os; os=$(_detect_os)
    _write_wrapper

    # Copy JS hooks from source location (build.sh puts them alongside cac)
    local _self_dir
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "$_self_dir/fingerprint-hook.js" ]] && cp "$_self_dir/fingerprint-hook.js" "$CAC_DIR/fingerprint-hook.js"
    [[ -f "$_self_dir/relay.js" ]] && cp "$_self_dir/relay.js" "$CAC_DIR/relay.js"

    # Shims
    _write_hostname_shim
    _write_ifconfig_shim
    if [[ "$os" == "macos" ]]; then
        _write_ioreg_shim
    elif [[ "$os" == "linux" ]]; then
        _write_machine_id_shim
    fi

    # DNS guard + blocked hosts
    _write_dns_guard_js 2>/dev/null || true
    _write_blocked_hosts 2>/dev/null || true

    # mTLS CA
    _generate_ca_cert 2>/dev/null || true

    # PATH (idempotent)
    local rc_file; rc_file=$(_detect_rc_file)
    _write_path_to_rc "$rc_file" >/dev/null 2>&1 || true
}

# Explicit setup command — runs initialization with verbose output
cmd_setup() {
    echo "$(_bold "cac setup")"
    echo

    _ensure_initialized

    # Find or install Claude Code
    local real_claude; real_claude=$(_read "$CAC_DIR/real_claude" "")
    if [[ -z "$real_claude" ]] || [[ ! -x "$real_claude" ]]; then
        echo "  Claude Code not found"
        printf "  Install latest version? [Y/n] "
        read -r _ans
        if [[ "$_ans" != "n" && "$_ans" != "N" ]]; then
            _claude_cmd_install latest
            local latest_ver; latest_ver=$(_read "$VERSIONS_DIR/.latest" "")
            if [[ -n "$latest_ver" ]]; then
                real_claude="$VERSIONS_DIR/$latest_ver/claude"
                echo "$real_claude" > "$CAC_DIR/real_claude"
            fi
        fi
    fi

    if [[ -n "$real_claude" ]] && [[ -x "$real_claude" ]]; then
        echo "  Claude Code: $(_cyan "$real_claude")"
    fi
    echo "  Wrapper: $(_cyan "$CAC_DIR/bin/claude")"
    echo "  Shims: $(_cyan "$CAC_DIR/shim-bin/")"
    echo

    local rc_file; rc_file=$(_detect_rc_file)
    if [[ -n "$rc_file" ]]; then
        echo "  Run to activate: $(_green "source $rc_file")"
    fi
    echo
    echo "  Create environment: $(_green "cac env create <name> [-p <proxy>]")"
}
