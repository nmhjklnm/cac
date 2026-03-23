# ── 入口：分发命令 ──────────────────────────────────────────────

[[ $# -eq 0 ]] && { cmd_help; exit 0; }

case "$1" in
    setup)              cmd_setup         ;;
    add)                cmd_add  "${@:2}" ;;
    ls|list)            cmd_ls            ;;
    check)              cmd_check         ;;
    stop)               cmd_stop          ;;
    -c)                 cmd_continue      ;;
    relay)              cmd_relay "${@:2}" ;;
    delete|uninstall)   cmd_delete        ;;
    -v|--version)       cmd_version       ;;
    help|--help|-h)     cmd_help          ;;
    *)                  cmd_switch "$1"   ;;
esac
