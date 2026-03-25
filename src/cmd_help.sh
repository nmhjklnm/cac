# ── cmd: help ──────────────────────────────────────────────────

cmd_help() {
    echo
    echo "  $(_bold "cac") $(_dim "$CAC_VERSION") — Isolate, protect, and manage your Claude Code"
    echo

    echo "  $(_bold "Environment")"
    echo "    $(_green "cac env create") <name> [-p proxy] [-c ver] [--bypass]"
    echo "    $(_green "cac env set") [name] <key> <value>   Modify environment"
    echo "    $(_green "cac env ls")                  List all environments"
    echo "    $(_green "cac env rm") <name>           Remove an environment"
    echo "    $(_green "cac env check")               Verify current environment"
    echo "    $(_green "cac") <name>                  Switch environment"
    echo

    echo "  $(_bold "Version")"
    echo "    $(_green "cac claude install") [latest|ver]   Install Claude Code"
    echo "    $(_green "cac claude ls")                     List installed versions"
    echo "    $(_green "cac claude pin") <ver>              Pin env to a version"
    echo "    $(_green "cac claude uninstall") <ver>        Remove a version"
    echo

    echo "  $(_bold "Self")"
    echo "    $(_green "cac self update")             Update cac"
    echo "    $(_green "cac self delete")             Uninstall cac completely"
    echo

    echo "  $(_bold "Docker")"
    echo "    $(_green "cac docker") setup|start|enter|check|port|stop"
    echo

    echo "  $(_dim "Examples:")"
    echo "    $(_dim "cac env create work -p 1.2.3.4:1080:u:p -c 2.1.81")"
    echo "    $(_dim "cac env create personal --bypass")"
    echo "    $(_dim "cac work")"
    echo
}
