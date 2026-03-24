# ── 入口：分发命令 ──────────────────────────────────────────────

[[ $# -eq 0 ]] && { cmd_help; exit 0; }

case "$1" in
    env)                cmd_env    "${@:2}" ;;
    claude)             cmd_claude "${@:2}" ;;
    self)               cmd_self   "${@:2}" ;;
    docker)             cmd_docker "${@:2}" ;;
    ls|list)            _env_cmd_ls         ;;
    -v|--version)       cmd_version         ;;
    help|--help|-h)     cmd_help            ;;
    # ── deprecated (shims) ──
    add)                echo "$(_yellow "warning:") 'cac add' is deprecated, use 'cac env create <name> -p <proxy>'" >&2; exit 1 ;;
    setup)              echo "$(_yellow "warning:") 'cac setup' is no longer needed — cac auto-initializes" >&2 ;;
    check)              echo "$(_yellow "warning:") 'cac check' moved to 'cac env check'" >&2; cmd_check ;;
    relay)              echo "$(_yellow "warning:") 'cac relay' moved to 'cac env relay'" >&2; cmd_relay "${@:2}" ;;
    stop)               echo "$(_yellow "warning:") 'cac stop' moved to 'cac env stop'" >&2; cmd_stop ;;
    resume|-c)          echo "$(_yellow "warning:") use 'cac env resume'" >&2; cmd_continue ;;
    delete|uninstall)   echo "$(_yellow "warning:") 'cac delete' moved to 'cac self delete'" >&2; cmd_delete ;;
    *)                  _env_cmd_activate "$1" ;;
esac
