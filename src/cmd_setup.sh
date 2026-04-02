# ── auto-bootstrap (silent, idempotent) ─────────────────────────

# Called automatically by any command — no manual setup needed
_ensure_initialized() {
    mkdir -p "$CAC_DIR" "$ENVS_DIR" "$VERSIONS_DIR"

    # Always sync JS hooks + dns-guard (they update with cac versions)
    # Find the real package directory — npm creates symlinks:
    #   ~/.nvm/.../bin/cac → ../lib/node_modules/claude-cac/cac
    # relay.js and fingerprint-hook.js live alongside the real cac script
    local _self_dir=""
    local _cac_bin; _cac_bin="$(command -v cac 2>/dev/null || true)"
    if [[ -n "$_cac_bin" ]] && [[ -L "$_cac_bin" ]]; then
        local _link; _link="$(readlink "$_cac_bin")"
        [[ "$_link" != /* ]] && _link="$(dirname "$_cac_bin")/$_link"
        _self_dir="$(cd "$(dirname "$_link")" 2>/dev/null && pwd)" || _self_dir=""
    fi
    # Fallback: directory of the running script
    if [[ -z "$_self_dir" ]] || [[ ! -f "$_self_dir/relay.js" ]]; then
        _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    fi
    # Warn if running as root — files written here become root-owned and break
    # normal-user invocations (wrapper has set -e and will silently exit).
    if [[ $EUID -eq 0 ]]; then
        echo "[cac] warning: running as root may corrupt ~/.cac/ file ownership" >&2
        echo "[cac] hint: run as your normal user instead" >&2
    fi
    # rm -f first: user owns ~/.cac/ dir so can delete root-owned files even if can't overwrite them
    if [[ -f "$_self_dir/fingerprint-hook.js" ]]; then
        rm -f "$CAC_DIR/fingerprint-hook.js" 2>/dev/null || true
        cp "$_self_dir/fingerprint-hook.js" "$CAC_DIR/fingerprint-hook.js" 2>/dev/null || true
    fi
    if [[ -f "$_self_dir/relay.js" ]]; then
        rm -f "$CAC_DIR/relay.js" 2>/dev/null || true
        cp "$_self_dir/relay.js" "$CAC_DIR/relay.js" 2>/dev/null || true
    fi
    rm -f "$CAC_DIR/cac-dns-guard.js" 2>/dev/null || true
    _write_dns_guard_js 2>/dev/null || true
    rm -f "$CAC_DIR/blocked_hosts" 2>/dev/null || true
    _write_blocked_hosts 2>/dev/null || true

    # Patch all existing envs: ensure DISABLE_AUTOUPDATER=1 in settings.json
    local _sf
    for _sf in "$ENVS_DIR"/*/.claude/settings.json; do
        [[ -f "$_sf" ]] || continue
        grep -q '"DISABLE_AUTOUPDATER"' "$_sf" 2>/dev/null && continue
        python3 - "$_sf" << 'PYEOF' 2>/dev/null || true
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
if d.get('env', {}).get('DISABLE_AUTOUPDATER') == '1':
    sys.exit(0)
d.setdefault('env', {})['DISABLE_AUTOUPDATER'] = '1'
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
PYEOF
    done

    # PATH (idempotent — always ensure it's in rc file)
    local rc_file; rc_file=$(_detect_rc_file)
    _write_path_to_rc "$rc_file" >/dev/null 2>&1 || true

    # Keep .latest pointing to highest installed version
    _update_latest 2>/dev/null || true

    # Re-generate wrapper on version upgrade
    if [[ -f "$CAC_DIR/bin/claude" ]]; then
        local _wrapper_ver
        _wrapper_ver=$(grep 'CAC_WRAPPER_VER=' "$CAC_DIR/bin/claude" 2>/dev/null | sed 's/.*CAC_WRAPPER_VER=//' | tr -d '[:space:]' || true)
        if [[ "$_wrapper_ver" != "$CAC_VERSION" ]]; then
            _write_wrapper
        fi
        return 0
    fi

    # Find real claude (system-installed or managed)
    local real_claude
    real_claude=$(_find_real_claude)
    if [[ -z "$real_claude" ]]; then
        local latest_ver; latest_ver=$(_read "$VERSIONS_DIR/.latest" "")
        if [[ -n "$latest_ver" ]]; then
            real_claude="$VERSIONS_DIR/$latest_ver/claude"
        fi
    fi
    if [[ -n "$real_claude" ]] && [[ -x "$real_claude" ]]; then
        echo "$real_claude" > "$CAC_DIR/real_claude"
    fi

    local os; os=$(_detect_os)
    _write_wrapper

    # Shims
    _write_hostname_shim
    _write_ifconfig_shim
    if [[ "$os" == "macos" ]]; then
        _write_ioreg_shim
    elif [[ "$os" == "linux" ]]; then
        _write_machine_id_shim
    fi

    # mTLS CA
    _generate_ca_cert 2>/dev/null || true
}
