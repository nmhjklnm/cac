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
    # ── deprecated (shims with warnings) ──
    add)                echo "$(_yellow "warning:") 'cac add' → 'cac env create <name> -p <proxy>'" >&2; exit 1 ;;
    setup)              echo "$(_yellow "warning:") 'cac setup' is no longer needed — cac auto-initializes" >&2 ;;
    check)              echo "$(_yellow "warning:") 'cac check' → 'cac env check'" >&2; cmd_check ;;
    stop)               echo "$(_yellow "warning:") 'cac stop' → 'cac env deactivate'" >&2; _env_cmd_deactivate ;;
    resume|-c)          echo "$(_yellow "warning:") 'cac resume' removed — use 'cac env activate <name>'" >&2; exit 1 ;;
    relay)              echo "$(_yellow "warning:") relay is now automatic (TUN auto-detected)" >&2 ;;
    delete|uninstall)   echo "$(_yellow "warning:") 'cac delete' → 'cac self delete'" >&2; cmd_delete ;;
    *)                  _env_cmd_activate "$1" ;;
esac
