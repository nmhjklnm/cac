#!/usr/bin/env bash
# setup-dns.sh — DNS direct-connect mode one-click installer for cac
# Usage:
#   bash setup-dns.sh <server_ip> [token]
#   Linux:  curl -fsSL <url>/setup-dns.sh | bash -s -- <server_ip> [token]
#   macOS:  curl -fsSL <url>/setup-dns.sh | bash -s -- <server_ip> [token]
# Requires: socat (auto-installed)
set -euo pipefail

# ── Config ─────────────────────────────────────────────────
RELAY_SERVER="${1:-}"
TOKEN="${2:-}"
RELAY_PORT="443"
DOMAINS="api.anthropic.com platform.claude.com"
CAC_DIR="$HOME/.cac"

# ── Colors ─────────────────────────────────────────────────
_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

info()    { printf '[info] %s\n' "$*"; }
success() { _green "[done] $*"; }
warn()    { _yellow "[warn] $*"; }
die()     { _red "[error] $*"; exit 1; }

# ── Validation ─────────────────────────────────────────────

[[ -n "$RELAY_SERVER" ]] || die "Usage: setup-dns.sh <server_ip> [token]"
[[ "$RELAY_SERVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid IP: $RELAY_SERVER (must be IP address)"

printf '========================================\n'
printf '  cac DNS direct-connect setup\n'
printf '========================================\n\n'

OS_NAME=$(uname -s)
case "$OS_NAME" in
    Linux|Darwin) ;;
    *) die "Only Linux and macOS are supported" ;;
esac

# Permission check
if [[ "$OS_NAME" == "Linux" ]]; then
    [[ "$(id -u)" == "0" ]] || die "Linux requires root (modifies /etc/hosts, installs systemd service)"
elif [[ "$OS_NAME" == "Darwin" ]] && [[ "$(id -u)" == "0" ]]; then
    die "macOS: do not run with sudo. Run directly: bash setup-dns.sh <server_ip>\n  The script will ask for sudo when needed"
fi

# Install socat if missing
if ! command -v socat >/dev/null 2>&1; then
    info "Installing socat ..."
    if [[ "$OS_NAME" == "Darwin" ]]; then
        command -v brew >/dev/null 2>&1 || die "Please install Homebrew first (https://brew.sh)"
        brew install socat
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq socat
    elif command -v yum >/dev/null 2>&1; then
        yum install -y socat
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y socat
    elif command -v apk >/dev/null 2>&1; then
        apk add socat
    else
        die "Cannot auto-install socat. Please install manually."
    fi
    success "socat installed"
fi

# ── Step 1: Configure /etc/hosts ──────────────────────────

_bold "Step 1: Configure /etc/hosts"

HOSTS_CHANGED=false
_sudo=""
[[ "$(id -u)" != "0" ]] && _sudo="sudo"

if [[ -n "$_sudo" ]]; then
    info "Some operations require admin privileges"
    sudo -v || die "sudo access required"
fi

for domain in $DOMAINS; do
    if grep -qE "^\s*127\.0\.0\.1\s+${domain}" /etc/hosts 2>/dev/null; then
        info "$domain → 127.0.0.1 (already configured)"
    else
        if [[ "$OS_NAME" == "Darwin" ]]; then
            $_sudo sed -i '' "/${domain}/d" /etc/hosts 2>/dev/null || true
        else
            $_sudo sed -i "/${domain}/d" /etc/hosts 2>/dev/null || true
        fi
        echo "127.0.0.1 ${domain}" | $_sudo tee -a /etc/hosts >/dev/null
        HOSTS_CHANGED=true
        success "$domain → 127.0.0.1 (added)"
    fi
done

if [[ "$OS_NAME" == "Darwin" ]] && $HOSTS_CHANGED; then
    $_sudo dscacheutil -flushcache 2>/dev/null || true
    $_sudo killall -HUP mDNSResponder 2>/dev/null || true
    info "Flushed macOS DNS cache"
fi

# Verify
for domain in $DOMAINS; do
    resolved=""
    if command -v getent >/dev/null 2>&1; then
        resolved=$(getent hosts "$domain" | awk '{print $1}')
    elif command -v dscacheutil >/dev/null 2>&1; then
        resolved=$(dscacheutil -q host -a name "$domain" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')
    fi
    [[ -z "$resolved" ]] && resolved=$(grep -E "^\s*[0-9].*\s${domain}" /etc/hosts | awk '{print $1}' | head -1)
    if [[ "$resolved" == "127.0.0.1" ]]; then
        success "Verified: $domain → $resolved"
    else
        die "Verification failed: $domain → ${resolved:-unresolved} (expected 127.0.0.1)"
    fi
done

echo

# ── Step 2: Configure socat relay service ─────────────────

_bold "Step 2: Configure socat relay service"

SOCAT_BIN=$(command -v socat)

if [[ "$OS_NAME" == "Linux" ]]; then
    cat > /etc/systemd/system/claude-relay.service <<EOF
[Unit]
Description=Claude API Relay (socat TCP forward to ${RELAY_SERVER}:${RELAY_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SOCAT_BIN} TCP-LISTEN:${RELAY_PORT},fork,reuseaddr TCP:${RELAY_SERVER}:${RELAY_PORT}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable claude-relay
    systemctl restart claude-relay
    sleep 1

    if systemctl is-active --quiet claude-relay; then
        success "claude-relay systemd service started"
    else
        die "claude-relay failed to start: $(journalctl -u claude-relay --no-pager -n 5)"
    fi

elif [[ "$OS_NAME" == "Darwin" ]]; then
    _plist="/Library/LaunchDaemons/com.cac.claude-relay.plist"
    $_sudo tee "$_plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cac.claude-relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SOCAT_BIN}</string>
        <string>TCP-LISTEN:${RELAY_PORT},fork,reuseaddr</string>
        <string>TCP:${RELAY_SERVER}:${RELAY_PORT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-relay.err</string>
</dict>
</plist>
EOF
    $_sudo launchctl unload "$_plist" 2>/dev/null || true
    $_sudo launchctl load -w "$_plist"
    sleep 1

    if $_sudo launchctl list 2>/dev/null | grep -q "claude-relay"; then
        success "claude-relay launchd service started"
    else
        die "claude-relay failed to start, check /tmp/claude-relay.err"
    fi
fi

sleep 1
if (echo >/dev/tcp/127.0.0.1/${RELAY_PORT}) 2>/dev/null; then
    success "Port ${RELAY_PORT} listening"
else
    die "Port ${RELAY_PORT} not listening"
fi

echo

# ── Step 3: Verify server connectivity ────────────────────

_bold "Step 3: Verify server connectivity"

_tls_timeout=""
command -v timeout >/dev/null 2>&1 && _tls_timeout="timeout 10"
command -v gtimeout >/dev/null 2>&1 && _tls_timeout="gtimeout 10"
if echo | $_tls_timeout openssl s_client -connect 127.0.0.1:443 -servername api.anthropic.com 2>/dev/null | grep -q "CONNECTED"; then
    success "TLS handshake OK (127.0.0.1:443 → ${RELAY_SERVER}:443)"
else
    warn "TLS handshake failed — server may not have reverse proxy running yet"
fi

echo

# ── Step 4: Install cac ──────────────────────────────────

_bold "Step 4: Install cac"

if command -v cac >/dev/null 2>&1; then
    info "cac already installed"
else
    info "Installing cac via npm ..."
    if command -v npm >/dev/null 2>&1; then
        npm install -g claude-cac 2>/dev/null || {
            info "npm install failed, trying manual install ..."
            curl -fsSL https://raw.githubusercontent.com/nmhjklnm/cac/master/install.sh | bash
        }
    else
        curl -fsSL https://raw.githubusercontent.com/nmhjklnm/cac/master/install.sh | bash
    fi
    export PATH="$HOME/.cac/bin:$HOME/.local/bin:$PATH"
    command -v cac >/dev/null 2>&1 || die "cac installation failed"
    success "cac installed"
fi

echo

# ── Step 5: Install Claude Code ──────────────────────────

_bold "Step 5: Install Claude Code"

# Use cac to install Claude Code
cac claude install latest 2>/dev/null || info "Claude Code install skipped (may already exist)"

echo

# ── Step 6: Create DNS environment ───────────────────────

_bold "Step 6: Create DNS environment"

ENV_NAME="dns"
_token_flag=""
[[ -n "$TOKEN" ]] && _token_flag="-t $TOKEN"

if [[ -d "$CAC_DIR/envs/$ENV_NAME" ]]; then
    info "Environment '$ENV_NAME' already exists, skipping creation"
    cac "$ENV_NAME" 2>/dev/null || true
else
    cac env create "$ENV_NAME" -d "${RELAY_SERVER}" $_token_flag 2>/dev/null || {
        warn "cac env create failed — creating manually"
        mkdir -p "$CAC_DIR/envs/$ENV_NAME"
        echo "${RELAY_SERVER}:${RELAY_PORT}" > "$CAC_DIR/envs/$ENV_NAME/dns_server"
        [[ -n "$TOKEN" ]] && echo "$TOKEN" > "$CAC_DIR/envs/$ENV_NAME/token"
        echo "$ENV_NAME" > "$CAC_DIR/current"
    }
fi
success "DNS environment '$ENV_NAME' ready (server: ${RELAY_SERVER}:${RELAY_PORT})"

echo

# ── Step 7: Install CA cert ─────────────────────────────

_bold "Step 7: Install CA cert to system trust store"

CA_CERT="$CAC_DIR/ca/ca_cert.pem"
if [[ -f "$CA_CERT" ]]; then
    if [[ "$OS_NAME" == "Darwin" ]]; then
        if ! security verify-cert -c "$CA_CERT" >/dev/null 2>&1; then
            info "Installing CA to macOS system trust store (requires admin password)..."
            $_sudo security add-trusted-cert -d -r trustRoot \
                -k /Library/Keychains/System.keychain "$CA_CERT" 2>/dev/null && \
                success "CA cert added to system trust store" || \
                warn "CA cert install failed. Manual: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CA_CERT"
        else
            info "CA cert already trusted"
        fi
    elif [[ "$OS_NAME" == "Linux" ]]; then
        cp "$CA_CERT" /usr/local/share/ca-certificates/cac-ca.crt 2>/dev/null || true
        update-ca-certificates 2>/dev/null && \
            success "CA cert added to system trust store" || \
            warn "CA cert install failed"
    fi
else
    warn "CA cert not found ($CA_CERT)"
fi

echo

# ── Step 8: Configure PATH ──────────────────────────────

_bold "Step 8: Configure PATH"

pick_rc_file() {
    local shell_name
    shell_name=$(basename "${SHELL:-bash}")
    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *)    echo "$HOME/.bashrc" ;;
    esac
}

RC_FILE=$(pick_rc_file)
touch "$RC_FILE"

if ! grep -Fq '/.cac/bin' "$RC_FILE"; then
    cat >> "$RC_FILE" <<'PATHEOF'

# cac DNS direct-connect mode
export PATH="$HOME/.cac/bin:$PATH"
PATHEOF
    success "PATH added to $RC_FILE"
else
    info "PATH already in $RC_FILE"
fi

echo

# ── Step 9: Final verification ───────────────────────────

_bold "Step 9: Final verification"

echo "  /etc/hosts:"
for domain in $DOMAINS; do
    _resolved=""
    if command -v getent >/dev/null 2>&1; then
        _resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}')
    elif command -v dscacheutil >/dev/null 2>&1; then
        _resolved=$(dscacheutil -q host -a name "$domain" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')
    fi
    [[ -z "$_resolved" ]] && _resolved=$(grep -E "^\s*[0-9].*\s${domain}" /etc/hosts | awk '{print $1}' | head -1)
    printf "    %s → %s\n" "$domain" "${_resolved:-unknown}"
done

echo "  socat relay:"
if [[ "$OS_NAME" == "Linux" ]]; then
    printf "    claude-relay: %s\n" "$(systemctl is-active claude-relay 2>/dev/null || echo 'unknown')"
else
    printf "    claude-relay: %s\n" "$($_sudo launchctl list 2>/dev/null | grep -q claude-relay && echo 'active' || echo 'inactive')"
fi
printf "    port 443: %s\n" "$((echo >/dev/tcp/127.0.0.1/443) 2>/dev/null && echo 'listening' || echo 'not listening')"

echo "  cac:"
printf "    env: %s\n" "$(cat "$CAC_DIR/current" 2>/dev/null || echo 'none')"
printf "    dns_server: %s\n" "$(cat "$CAC_DIR/envs/$ENV_NAME/dns_server" 2>/dev/null || echo 'not configured')"
[[ -n "$TOKEN" ]] && printf "    token: %s...\n" "${TOKEN:0:8}"

echo

# ── Done ─────────────────────────────────────────────────

_green '========================================'
_green '  DNS direct-connect setup complete!'
_green '========================================'
echo
echo "Traffic flow:"
echo "  Claude Code → 127.0.0.1:443 (hosts) → socat → ${RELAY_SERVER}:443 (reverse proxy) → api.anthropic.com"
echo
echo "Next steps:"
echo "  source $RC_FILE"
echo "  claude              # start Claude Code (first time: /login)"
echo
echo "Verify zero leakage:"
if [[ "$OS_NAME" == "Darwin" ]]; then
    echo "  sudo tcpdump -i en0 -n 'tcp port 443' | grep -v ${RELAY_SERVER}"
else
    echo "  tcpdump -i eth0 -n 'tcp port 443' | grep -v ${RELAY_SERVER}"
fi
echo "  # No output = zero leakage"
echo
echo "Troubleshooting:"
if [[ "$OS_NAME" == "Darwin" ]]; then
    echo "  sudo launchctl list | grep claude    # check relay status"
    echo "  cat /tmp/claude-relay.err            # relay logs"
    echo "  cac env check                        # full diagnostics"
else
    echo "  systemctl status claude-relay    # check relay status"
    echo "  journalctl -u claude-relay -f    # relay logs"
    echo "  cac env check                    # full diagnostics"
fi
echo
