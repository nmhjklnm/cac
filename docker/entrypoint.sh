#!/usr/bin/env bash
set -euo pipefail

SINGBOX_ENABLE="${SINGBOX_ENABLE:-1}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
HEALTHCHECK="${HEALTHCHECK:-1}"
CAC_PROFILE="${CAC_PROFILE:-default}"

unset ALL_PROXY HTTP_PROXY HTTPS_PROXY all_proxy http_proxy https_proxy \
      NO_PROXY no_proxy 2>/dev/null || true

if [[ "$DISABLE_IPV6" == "1" ]]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
fi

_SINGBOX_PID=""

if [[ "$SINGBOX_ENABLE" == "1" ]]; then
  mkdir -p /etc/sing-box
  python3 -m ccimage > /etc/sing-box/config.json \
    || { echo "Failed to generate sing-box config" >&2; exit 1; }

  sing-box run -c /etc/sing-box/config.json &
  _SINGBOX_PID=$!

  for _ in $(seq 1 150); do
    ip -o link show tun0 2>/dev/null && break
    kill -0 "$_SINGBOX_PID" 2>/dev/null || { echo "sing-box exited before TUN came up" >&2; exit 1; }
    sleep 0.05
  done

  _net="${TUN_ADDRESS:-172.19.0.1/30}"
  _base="${_net%/*}"
  _prefix="${_base%.*}"
  _last="${_base##*.}"
  TUN_DNS="${_prefix}.$(( _last + 1 ))"
  printf 'nameserver %s\noptions ndots:0\n' "$TUN_DNS" > /etc/resolv.conf

  # ── Auto-detect timezone and locale from exit IP ──────────────
  _GEO_TZ="" _GEO_LANG=""
  if python3 -m ccimage.geo 2>/dev/null > /tmp/cac-geo.sh; then
    source /tmp/cac-geo.sh
    _GEO_TZ="${TZ:-}"
    _GEO_LANG="${LANG:-}"
    echo "Geo: ${TZ} / ${LANG}"
    {
      echo "export TZ=\"$TZ\""
      echo "export LANG=\"$LANG\""
      echo "export LANGUAGE=\"$LANGUAGE\""
      echo "export LC_ALL=\"$LC_ALL\""
      echo "export ACCEPT_LANGUAGE=\"$ACCEPT_LANGUAGE\""
    } >> /root/.bashrc
  fi
  rm -f /tmp/cac-geo.sh

  # ── Auto-setup cac: install + create profile + activate ───────
  export HOME=/root
  export CAC_DIR="$HOME/.cac"
  export ENVS_DIR="$CAC_DIR/envs"

  if [[ ! -d "$CAC_DIR" ]]; then
    echo "Setting up cac..."
    cac setup 2>/dev/null || true
  fi

  # Create and activate profile if not complete
  _env_dir="$ENVS_DIR/$CAC_PROFILE"
  if [[ ! -f "$_env_dir/uuid" ]]; then
    echo "Creating cac profile: $CAC_PROFILE"
    mkdir -p "$_env_dir"

    _proxy_for_cac=""
    if [[ -n "${PROXY_URI:-}" ]] && [[ "$PROXY_URI" != *"://"* ]]; then
      IFS=: read -r _h _p _u _pw <<< "$PROXY_URI"
      _proxy_for_cac="socks5://${_u:+$_u:$_pw@}$_h:$_p"
    elif [[ -n "${PROXY_URI:-}" ]]; then
      _proxy_for_cac="$PROXY_URI"
    fi
    echo "${_proxy_for_cac:-none}" > "$_env_dir/proxy"

    # Generate identity
    uuidgen | tr '[:lower:]' '[:upper:]'           > "$_env_dir/uuid"
    uuidgen | tr '[:upper:]' '[:lower:]'           > "$_env_dir/stable_id"
    python3 -c "import os; print(os.urandom(32).hex())" > "$_env_dir/user_id"
    uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'    > "$_env_dir/machine_id"
    echo "host-$(uuidgen | cut -d- -f1 | tr '[:upper:]' '[:lower:]')" > "$_env_dir/hostname"
    printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) > "$_env_dir/mac_address"

    # Timezone and language from geo detection
    echo "${_GEO_TZ:-America/New_York}"     > "$_env_dir/tz"
    echo "${_GEO_LANG:-en_US.UTF-8}"        > "$_env_dir/lang"

    # Generate mTLS client certificate
    if [[ -f "$CAC_DIR/ca/ca_key.pem" ]]; then
      openssl genrsa -out "$_env_dir/client_key.pem" 2048 2>/dev/null
      openssl req -new -key "$_env_dir/client_key.pem" \
        -subj "/CN=cac-client-${CAC_PROFILE}" \
        -out /tmp/cac-csr.pem 2>/dev/null
      openssl x509 -req -in /tmp/cac-csr.pem \
        -CA "$CAC_DIR/ca/ca_cert.pem" -CAkey "$CAC_DIR/ca/ca_key.pem" \
        -CAcreateserial -days 365 \
        -out "$_env_dir/client_cert.pem" 2>/dev/null
      rm -f /tmp/cac-csr.pem
    fi

    echo "  Profile: $CAC_PROFILE"
    echo "  Hostname: $(cat "$_env_dir/hostname")"
    echo "  UUID: $(cat "$_env_dir/uuid")"
  fi

  # Activate profile
  echo "$CAC_PROFILE" > "$CAC_DIR/current"
  rm -f "$CAC_DIR/stopped"

  # Export identity env vars for current session (so cac-check sees them)
  export CAC_HOSTNAME="$(cat "$_env_dir/hostname" 2>/dev/null)"
  export CAC_MAC="$(cat "$_env_dir/mac_address" 2>/dev/null)"
  export CAC_MACHINE_ID="$(cat "$_env_dir/machine_id" 2>/dev/null)"
  export CAC_USERNAME="cac-user"

  # Persist for interactive shells
  {
    echo "export CAC_HOSTNAME=\"$CAC_HOSTNAME\""
    echo "export CAC_MAC=\"$CAC_MAC\""
    echo "export CAC_MACHINE_ID=\"$CAC_MACHINE_ID\""
    echo "export CAC_USERNAME=\"$CAC_USERNAME\""
  } >> /root/.bashrc

  if [[ "$HEALTHCHECK" == "1" ]]; then
    echo "Running startup checks..."
    cac-check || echo "Warning: some checks failed (container will start anyway)" >&2
  fi

elif [[ "$SINGBOX_ENABLE" == "0" ]]; then
  if [[ -z "${PROXY_URI:-}" ]]; then
    echo "SINGBOX_ENABLE=0 but PROXY_URI not set" >&2
    exit 1
  fi
  if [[ "$PROXY_URI" == *"://"* ]]; then
    echo "SINGBOX_ENABLE=0 does not support share links. Use SINGBOX_ENABLE=1 or compact format." >&2
    exit 1
  fi
  IFS=: read -r h p u pw <<< "$PROXY_URI"
  PROXY_URL="socks5h://${u:+$u:$pw@}$h:$p"
  export ALL_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  export all_proxy="$PROXY_URL" http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
  echo "SINGBOX_ENABLE=0: using env SOCKS only (not leak-safe)." >&2
else
  echo "SINGBOX_ENABLE must be 0 or 1" >&2
  exit 1
fi

_cleanup() {
  [[ -n "$_SINGBOX_PID" ]] && kill -TERM "$_SINGBOX_PID" 2>/dev/null && wait "$_SINGBOX_PID" 2>/dev/null || true
}
trap _cleanup EXIT INT TERM

exec "$@"
