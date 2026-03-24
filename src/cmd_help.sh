# ── cmd: help ──────────────────────────────────────────────────

cmd_help() {
cat <<EOF
$(_bold "cac") — Claude Code environment manager

$(_bold "cac claude") — version management
  install [latest|<ver>]   Install a Claude Code version
  uninstall <ver>           Remove an installed version
  ls                        List installed versions
  pin <ver>                 Pin current environment to a version

$(_bold "cac env") — environment management
  create <name> [-p <proxy>] [-c <ver>] [--type local|container]
  ls                        List all environments
  rm <name>                 Remove an environment
  activate <name>           Activate (shortcut: cac <name>)
  check                     Verify current environment
  relay on|off|status       Local relay (bypass TUN)
  stop / resume             Pause / resume protection

$(_bold "cac self") — self-management
  update                    Update cac to the latest version
  delete                    Uninstall cac completely

$(_bold "cac docker") — containerized mode
  setup|start|enter|check|port|stop|help

$(_bold "Shortcuts:")
  cac <name>                = cac env activate <name>
  cac ls                    = cac env ls

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
  cac env check
  cac self update
EOF
}
