# ── cmd: stop / continue ───────────────────────────────────────

cmd_stop() {
    touch "$CAC_DIR/stopped"
    local current; current=$(_current_env)
    echo "$(_yellow "⚠ cac 已停用") — claude 将裸跑（无代理、无伪装）"
    echo "  恢复：cac -c"
}

cmd_continue() {
    if [[ ! -f "$CAC_DIR/stopped" ]]; then
        echo "cac 当前未停用，无需恢复"
        return
    fi

    local current; current=$(_current_env)
    if [[ -z "$current" ]]; then
        echo "错误：没有已激活的环境，运行 'cac <name>'" >&2; exit 1
    fi

    rm -f "$CAC_DIR/stopped"
    echo "$(_green "✓") cac 已恢复 — 当前环境：$(_bold "$current")"
}
