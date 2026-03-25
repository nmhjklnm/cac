# ── cmd: delete（卸载）────────────────────────────────────────

cmd_delete() {
    echo "=== cac delete ==="
    echo

    local rc_file
    rc_file=$(_detect_rc_file)

    _remove_path_from_rc "$rc_file"

    # 停止 relay 进程和路由
    if [[ -d "$CAC_DIR" ]]; then
        _relay_stop 2>/dev/null || true

        # 停止 docker port-forward 进程
        if [[ -d /tmp/cac-docker-ports ]]; then
            for _pf in /tmp/cac-docker-ports/*.pid; do
                [[ -f "$_pf" ]] || continue
                kill "$(cat "$_pf")" 2>/dev/null || true
                rm -f "$_pf"
            done
            echo "  ✓ 已停止 docker port-forward 进程"
        fi

        # 兜底：清理可能残留的 relay 孤儿进程
        pkill -f "node.*\.cac/relay\.js" 2>/dev/null || true

        rm -rf "$CAC_DIR"
        echo "  ✓ 已删除 $CAC_DIR"
    else
        echo "  - $CAC_DIR 不存在，跳过"
    fi

    local method
    method=$(_install_method)
    echo
    if [[ "$method" == "npm" ]]; then
        echo "  ✓ 已清除所有 cac 数据和配置"
        echo
        echo "要完全卸载 cac 命令，请执行："
        echo "  npm uninstall -g claude-cac"
    else
        if [[ -f "$HOME/bin/cac" ]]; then
            rm -f "$HOME/bin/cac"
            echo "  ✓ 已删除 $HOME/bin/cac"
        fi
        echo "  ✓ 卸载完成"
    fi

    echo
    if [[ -n "$rc_file" ]]; then
        echo "请重开终端或执行 source $rc_file 使变更生效。"
    else
        echo "请重开终端使变更生效。"
    fi
}
