# ── cac docker — 容器化部署管理 ─────────────────────────────────────

_info()  { printf '\033[36m▸\033[0m %b\n' "$*"; }
_ok()    { printf '\033[32m✓\033[0m %b\n' "$*"; }
_warn()  { printf '\033[33m!\033[0m %b\n' "$*"; }
_err()   { printf '\033[31m✗\033[0m %b\n' "$*" >&2; }

_docker_dir() {
  # Find docker/ relative to the cac script location
  local script_path
  script_path="$(command -v cac 2>/dev/null || echo "$0")"
  script_path="$(cd "$(dirname "$script_path")" && pwd)"

  # Check common locations
  for d in \
    "$script_path/docker" \
    "$script_path/../docker" \
    "$PWD/docker" \
    "$HOME/.cac/docker"
  do
    [[ -d "$d" && -f "$d/docker-compose.yml" ]] && { echo "$d"; return 0; }
  done

  echo ""
}

_dk_env_file=""
_dk_compose_base=()
_dk_service="cac"
_dk_shim_if="cac-docker-shim"
_dk_port_dir="/tmp/cac-docker-ports"
_dk_image="ghcr.io/nmhjklnm/cac-docker:latest"

_dk_init() {
  local docker_dir
  docker_dir=$(_docker_dir)
  if [[ -z "$docker_dir" ]]; then
    _err "Cannot find docker/ directory. Run from the cac repo, or clone it first."
    _err "  git clone https://github.com/nmhjklnm/cac.git && cd cac"
    return 1
  fi
  _dk_env_file="${docker_dir}/.env"
  _dk_compose_base=(-f "${docker_dir}/docker-compose.yml")
}

_dk_load_env() {
  # shellcheck disable=SC1090  # dynamic env file path
  [[ -f "$_dk_env_file" ]] && set -a && source "$_dk_env_file" && set +a
}

_dk_read_env() {
  local key="$1"
  [[ -f "$_dk_env_file" ]] && grep -m1 "^${key}=" "$_dk_env_file" 2>/dev/null | cut -d= -f2- || echo ""
}

_dk_write_env() {
  local key="$1" value="$2"
  if [[ -f "$_dk_env_file" ]] && grep -q "^${key}=" "$_dk_env_file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$_dk_env_file"
  else
    echo "${key}=${value}" >> "$_dk_env_file"
  fi
}

_dk_detect_mode() {
  if docker info 2>/dev/null | grep -qi "docker desktop\|operating system:.*docker desktop\|platform.*desktop"; then
    echo "local"
  elif [[ "$(uname -s)" == "Darwin" ]] || [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == CYGWIN* ]]; then
    echo "local"
  else
    echo "remote"
  fi
}

_dk_get_mode() {
  local mode
  mode=$(_dk_read_env DEPLOY_MODE)
  echo "${mode:-$(_dk_detect_mode)}"
}

_dk_compose_files() {
  local docker_dir mode
  docker_dir=$(_docker_dir)
  mode=$(_dk_get_mode)
  if [[ "$mode" == "local" ]]; then
    echo "${_dk_compose_base[@]}" -f "${docker_dir}/docker-compose.local.yml"
  else
    echo "${_dk_compose_base[@]}" -f "${docker_dir}/docker-compose.macvlan.yml"
  fi
}

_dk_compose() {
  local files
  # shellcheck disable=SC2207  # intentional word splitting
  files=($(_dk_compose_files))
  docker compose "${files[@]}" "$@"
}

_dk_detect_network() {
  local iface gw addr ip prefix a b c d bits net_addr subnet container_last container_ip

  iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')

  if [[ -z "$iface" || -z "$gw" ]]; then
    _err "Cannot detect default network interface"
    return 1
  fi

  addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2; exit}') || addr=""
  [[ -z "$addr" ]] && { echo "error: cannot get address for $iface" >&2; return 1; }
  ip="${addr%/*}"
  prefix="${addr#*/}"

  IFS=. read -r a b c d <<< "$ip"
  bits=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
  net_addr="$(( a & (bits >> 24 & 0xFF) )).$(( b & (bits >> 16 & 0xFF) )).$(( c & (bits >> 8 & 0xFF) )).$(( d & (bits & 0xFF) ))"
  subnet="${net_addr}/${prefix}"

  container_last=$(( (d + 100) % 254 + 1 ))
  container_ip="${a}.${b}.${c}.${container_last}"
  local shim_last=$(( container_last % 254 + 1 ))
  local shim_ip="${a}.${b}.${c}.${shim_last}"

  _dk_write_env HOST_INTERFACE "$iface"
  _dk_write_env MACVLAN_SUBNET "$subnet"
  _dk_write_env MACVLAN_GATEWAY "$gw"
  _dk_write_env MACVLAN_IP "$container_ip"
  _dk_write_env SHIM_IP "$shim_ip"

  printf "  Interface:  \033[1m%s\033[0m\n" "$iface"
  printf "  Host IP:    %s\n" "$ip"
  printf "  Gateway:    %s\n" "$gw"
  printf "  Container:  \033[1m%s\033[0m\n" "$container_ip"
}

_dk_shim_up() {
  [[ "$(_dk_get_mode)" != "remote" ]] && return 0
  _dk_load_env
  local parent="${HOST_INTERFACE:-}" cip="${MACVLAN_IP:-}" sip="${SHIM_IP:-}"
  [[ -z "$parent" || -z "$cip" || -z "$sip" ]] && return 0
  ip link show "$_dk_shim_if" &>/dev/null && return 0

  ip link add "$_dk_shim_if" link "$parent" type macvlan mode bridge
  ip addr add "${sip}/32" dev "$_dk_shim_if"
  ip link set "$_dk_shim_if" up
  ip route add "${cip}/32" dev "$_dk_shim_if" 2>/dev/null || true
}

_dk_shim_down() {
  ip link show "$_dk_shim_if" &>/dev/null && ip link del "$_dk_shim_if" 2>/dev/null || true
}

# ── Port forwarding ──────────────────────────────────────────────────

_dk_port_forward() {
  local port="$1" mode
  mode=$(_dk_get_mode)

  mkdir -p "$_dk_port_dir"
  local pidfile="${_dk_port_dir}/${port}.pid"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    _warn "Port $port already forwarded (pid $(cat "$pidfile"))"
    return 0
  fi

  local cip
  if [[ "$mode" == "remote" ]]; then
    _dk_load_env
    cip="${MACVLAN_IP:-}"
    [[ -z "$cip" ]] && { _err "MACVLAN_IP not set. Run: cac docker setup"; return 1; }
    _dk_shim_up
  else
    cip=$(_dk_compose exec -T "$_dk_service" hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$cip" ]] && { _err "Cannot determine container IP"; return 1; }
  fi

  if command -v socat &>/dev/null; then
    socat TCP-LISTEN:"$port",fork,reuseaddr,bind=127.0.0.1 TCP:"${cip}":"$port" &
  elif command -v python3 &>/dev/null; then
    python3 -c "
import socket, threading
def fwd(src, dst):
    try:
        while d := src.recv(4096):
            dst.sendall(d)
    except: pass
    finally: src.close(); dst.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port)); s.listen(8)
while True:
    c, _ = s.accept()
    r = socket.create_connection(('$cip', $port))
    threading.Thread(target=fwd, args=(c,r), daemon=True).start()
    threading.Thread(target=fwd, args=(r,c), daemon=True).start()
" &
  else
    _err "Need socat or python3 for port forwarding"
    return 1
  fi
  local pid=$!
  echo "$pid" > "$pidfile"
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    _ok "localhost:${port} → ${cip}:${port} (pid $pid)"
  else
    _err "Failed to forward port $port"
    rm -f "$pidfile"
    return 1
  fi
}

_dk_port_stop() {
  local port="$1"
  local pidfile="${_dk_port_dir}/${port}.pid"
  if [[ -f "$pidfile" ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    _ok "Stopped forwarding port $port"
  else
    _warn "Port $port is not being forwarded"
  fi
}

_dk_port_list() {
  mkdir -p "$_dk_port_dir"
  local found=0
  for pidfile in "$_dk_port_dir"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local port pid
    port=$(basename "$pidfile" .pid)
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      printf "  \033[32m●\033[0m localhost:%-6s (pid %s)\n" "$port" "$pid"
      found=1
    else
      rm -f "$pidfile"
    fi
  done
  [[ "$found" -eq 0 ]] && _info "No ports forwarded. Use: cac docker port <port>"
}

_dk_port_stop_all() {
  mkdir -p "$_dk_port_dir"
  for pidfile in "$_dk_port_dir"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  done
}

# ── Docker subcommands ───────────────────────────────────────────────

_dk_cmd_setup() {
  _dk_init || return 1
  echo ""
  printf "\033[1mcac docker setup\033[0m\n"
  echo ""

  local proxy
  proxy=$(_dk_read_env PROXY_URI)
  if [[ -n "$proxy" ]]; then
    _info "Current proxy: \033[1m${proxy}\033[0m"
    read -rp "  New proxy URI (Enter to keep): " input
    [[ -n "$input" ]] && proxy="$input"
  else
    read -rp "  Proxy URI (e.g. ss://..., ip:port:user:pass): " proxy
  fi
  if [[ -z "$proxy" ]]; then
    _err "Proxy is required"
    return 1
  fi
  _dk_write_env PROXY_URI "$proxy"

  local mode
  mode=$(_dk_detect_mode)
  _dk_write_env DEPLOY_MODE "$mode"

  echo ""
  if [[ "$mode" == "local" ]]; then
    _info "Detected: \033[1mlocal laptop\033[0m (Docker Desktop)"
    _info "Mode: bridge network — container isolated"
  else
    _info "Detected: \033[1mremote server\033[0m (native Linux Docker)"
    _info "Mode: macvlan — container isolated from host"
    echo ""
    _info "Detecting network..."
    _dk_detect_network
  fi

  echo ""
  # Create persistent data directory
  local docker_dir
  docker_dir=$(_docker_dir)
  mkdir -p "${docker_dir}/data/root" "${docker_dir}/data/home"

  _ok "Config saved"
  echo ""
  _info "Next: \033[1mcac docker create\033[0m"
}

_dk_cmd_create() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  echo ""
  _info "Pulling image..."
  docker pull "$_dk_image"
  echo ""
  _ok "Image ready"
  _info "Start with: \033[1mcac docker start\033[0m"
}

_dk_cmd_start() {
  _dk_init || return 1
  [[ ! -f "$_dk_env_file" ]] && { _warn "No config found, running setup first..."; _dk_cmd_setup; }
  _dk_load_env
  _info "Starting container..."
  _dk_compose up -d
  _dk_shim_up
  sleep 2

  local state
  state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "unknown")
  if [[ "$state" == "running" ]]; then
    _ok "Container running"
    _info "Enter with:   \033[1mcac docker enter\033[0m"
    _info "Check with:   \033[1mcac docker check\033[0m"
    _info "Forward port: \033[1mcac docker port <port>\033[0m"
  else
    _err "Container state: $state"
    _info "Logs: cac docker logs"
  fi
}

_dk_cmd_stop() {
  _dk_init || return 1
  _dk_port_stop_all
  _dk_shim_down
  _info "Stopping container..."
  _dk_compose down
  _ok "Stopped"
}

_dk_cmd_restart() {
  _dk_cmd_stop
  _dk_cmd_start
}

_dk_cmd_enter() {
  _dk_init || return 1
  _dk_compose exec "$_dk_service" bash
}

_dk_cmd_check() {
  _dk_init || return 1
  _dk_compose exec "$_dk_service" cac-check

  echo ""
  printf "\033[1mExit IP Comparison\033[0m\n"
  echo ""

  local container_ip
  container_ip=$(_dk_compose exec -T "$_dk_service" timeout 10 curl -sf https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$container_ip" ]]; then
    _ok "Container exit: \033[1m${container_ip}\033[0m"
  else
    _err "Container cannot reach ifconfig.me"
  fi

  local host_ip
  host_ip=$(timeout 10 curl -sf https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$host_ip" ]]; then
    _ok "Host exit:      \033[1m${host_ip}\033[0m"
  else
    _info "Host cannot reach ifconfig.me (blocked or no proxy — this is fine)"
  fi

  echo ""
  if [[ -n "$container_ip" && -n "$host_ip" ]]; then
    if [[ "$container_ip" != "$host_ip" ]]; then
      _ok "Exit IPs differ — container uses a different network path than host"
    else
      _info "Exit IPs are the same — verify \033[1m${container_ip}\033[0m is your proxy's exit IP"
    fi
  elif [[ -n "$container_ip" && -z "$host_ip" ]]; then
    _ok "Container can reach internet, host cannot — proxy is working"
  fi
  echo ""
}

_dk_cmd_port() {
  _dk_init || return 1
  local subcmd="${1:-}" port="${2:-}"
  case "$subcmd" in
    ""|ls|list)   _dk_port_list ;;
    stop)
      if [[ -z "$port" ]]; then
        _dk_port_stop_all; _ok "All port forwarders stopped"
      else
        _dk_port_stop "$port"
      fi ;;
    [0-9]*)       _dk_port_forward "$subcmd" ;;
    *)
      echo "Usage:"
      echo "  cac docker port <port>       Forward localhost:port to container"
      echo "  cac docker port list         List active forwarders"
      echo "  cac docker port stop [port]  Stop forwarder(s)" ;;
  esac
}

_dk_cmd_logs() {
  _dk_init || return 1
  _dk_compose logs --tail=50 -f "$_dk_service"
}

_dk_cmd_status() {
  _dk_init || return 1
  _dk_load_env
  echo ""
  printf "\033[1mcac docker status\033[0m\n"
  echo ""

  printf "  Mode:       %s\n" "$(_dk_get_mode)"

  local proxy
  proxy=$(_dk_read_env PROXY_URI)
  if [[ -n "$proxy" ]]; then
    local dp
    if [[ "$proxy" == *"://"* ]]; then dp="${proxy%%://*}://***"
    else IFS=: read -r _h _p _rest <<< "$proxy"; dp="${_h}:${_p}:***"; fi
    printf "  Proxy:      %s\n" "$dp"
  else
    printf "  Proxy:      \033[33mnot configured\033[0m\n"
  fi

  if [[ "$(_dk_get_mode)" == "remote" ]]; then
    local cip; cip=$(_dk_read_env MACVLAN_IP)
    [[ -n "$cip" ]] && printf "  Container:  %s\n" "$cip"
  fi

  local state
  state=$(_dk_compose ps --format '{{.State}}' "$_dk_service" 2>/dev/null || echo "not created")
  case "$state" in
    running) printf "  Status:     \033[32mrunning\033[0m\n" ;;
    *)       printf "  Status:     \033[33m%s\033[0m\n" "$state" ;;
  esac

  local health
  health=$(_dk_compose ps --format '{{.Health}}' "$_dk_service" 2>/dev/null || echo "")
  [[ -n "$health" ]] && printf "  Health:     %s\n" "$health"

  echo ""
  printf "\033[1mPorts\033[0m\n"
  _dk_port_list
  echo ""
}

_dk_cmd_destroy() {
  _dk_init || return 1
  read -rp "Remove container and image? [y/N]: " confirm
  if [[ "$confirm" == [yY] ]]; then
    _dk_port_stop_all
    _dk_shim_down
    _dk_compose down --rmi local --volumes 2>/dev/null || true
    _ok "Removed"
  fi
}

# ── Docker command dispatcher ────────────────────────────────────────

cmd_docker() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    setup)    _dk_cmd_setup ;;
    create)   _dk_cmd_create ;;
    start)    _dk_cmd_start ;;
    stop)     _dk_cmd_stop ;;
    restart)  _dk_cmd_restart ;;
    enter)    _dk_cmd_enter ;;
    check)    _dk_cmd_check ;;
    port)     _dk_cmd_port "$@" ;;
    status)   _dk_cmd_status ;;
    logs)     _dk_cmd_logs ;;
    destroy)  _dk_cmd_destroy ;;
    help|-h|--help|"")
      echo ""
      printf "\033[1mUsage:\033[0m cac docker <command>\n"
      echo ""
      printf "\033[1mLifecycle:\033[0m\n"
      echo "  setup               Configure proxy (interactive)"
      echo "  create              Pull the Docker image"
      echo "  start               Start the container"
      echo "  stop                Stop the container"
      echo "  restart             Restart the container"
      echo "  destroy             Remove container and image"
      echo ""
      printf "\033[1mUse:\033[0m\n"
      echo "  enter               Open a shell (claude + cac ready)"
      echo "  port <port>         Forward localhost:port to container"
      echo "  port list           List active port forwarders"
      echo "  port stop [port]    Stop port forwarder(s)"
      echo ""
      printf "\033[1mDiagnostics:\033[0m\n"
      echo "  check               Network + identity diagnostics"
      echo "  status              Show config, state, and ports"
      echo "  logs                Follow container logs"
      echo "" ;;
    *)
      _err "Unknown docker command: $subcmd"
      cmd_docker help
      return 1 ;;
  esac
}
