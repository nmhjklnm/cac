# ── cmd: help ──────────────────────────────────────────────────

cmd_help() {
cat <<EOF
$(_bold "cac") — Claude Code environment manager

$(_bold "Version management:")
  cac claude install [latest|<ver>]   Install a Claude Code version
  cac claude uninstall <ver>           Remove an installed version
  cac claude ls                        List installed versions
  cac claude pin <ver>                 Pin current environment to a version

$(_bold "Environment management:")
  cac env create <name> [-p <proxy>] [-c <ver>] [--type local|container]
  cac env ls                           List all environments
  cac env rm <name>                    Remove an environment
  cac <name>                           Activate environment (shortcut)

$(_bold "Self-management:")
  cac self update                      Update cac to the latest version

$(_bold "Other:")
  cac ls                               List environments (= cac env ls)
  cac check                            Verify current environment
  cac relay [on|off|status]            Local relay (bypass TUN)
  cac stop / resume                    Pause / resume protection
  cac delete                           Uninstall cac
  cac -v                               Show version

$(_bold "Docker:")
  cac docker setup|start|enter|check|port|stop|help

$(_bold "Proxy format:")
  host:port:user:pass       Authenticated (auto-detect protocol)
  host:port                 Unauthenticated
  socks5://u:p@host:port    Explicit protocol

$(_bold "Examples:")
  cac claude install latest
  cac env create work -p 1.2.3.4:1080:u:p -c 2.1.81
  cac env create personal
  cac work
  cac claude pin latest

$(_bold "Files:")
  ~/.cac/versions/<ver>/claude    Claude Code binaries
  ~/.cac/envs/<name>/             Environment data
  ~/.cac/envs/<name>/.claude/     Isolated .claude config
  ~/.cac/envs/<name>/version      Pinned Claude Code version
  ~/.cac/bin/claude               Wrapper (intercepts claude calls)
  ~/.cac/current                  Active environment
EOF
}
