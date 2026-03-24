# ── 入口：分发命令 ──────────────────────────────────────────────

[[ $# -eq 0 ]] && { cmd_help; exit 0; }

case "$1" in
    env)                cmd_env  "${@:2}" ;;
    claude)             cmd_claude "${@:2}" ;;
    self)               cmd_self "${@:2}" ;;
    ls|list)            cmd_ls            ;;
    check)              cmd_check         ;;
    stop)               cmd_stop          ;;
    resume)             cmd_continue      ;;
    relay)              cmd_relay "${@:2}" ;;
    docker)             cmd_docker "${@:2}" ;;
    delete|uninstall)   cmd_delete        ;;
    -c)                 echo "$(_yellow "warning:") 'cac -c' is deprecated, use 'cac resume'" >&2; cmd_continue ;;
    -v|--version)       cmd_version       ;;
    help|--help|-h)     cmd_help          ;;
    *)                  _env_cmd_activate "$1" ;;
esac
