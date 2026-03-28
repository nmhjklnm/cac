# ── mTLS client certificate management ─────────────────────────────────────────

# generate self-signed CA (called during setup, generated only once)
_generate_ca_cert() {
    local ca_dir="$CAC_DIR/ca"
    local ca_key="$ca_dir/ca_key.pem"
    local ca_cert="$ca_dir/ca_cert.pem"

    if [[ -f "$ca_cert" ]] && [[ -f "$ca_key" ]]; then
        echo "  CA cert exists, skipping"
        return 0
    fi

    mkdir -p "$ca_dir"

    # generate CA private key (4096-bit RSA)
    openssl genrsa -out "$ca_key" 4096 2>/dev/null || {
        echo "error: failed to generate CA private key" >&2; return 1
    }
    chmod 600 "$ca_key"

    # generate self-signed CA cert (valid for 10 years)
    openssl req -new -x509 \
        -key "$ca_key" \
        -out "$ca_cert" \
        -days 3650 \
        -subj "/CN=cac-privacy-ca/O=cac/OU=mtls" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        2>/dev/null || {
        echo "error: failed to generate CA cert" >&2; return 1
    }
    chmod 644 "$ca_cert"
}

# generate client cert for environment (called during cac add)
_generate_client_cert() {
    local name="$1"
    local env_dir="$ENVS_DIR/$name"
    local ca_key="$CAC_DIR/ca/ca_key.pem"
    local ca_cert="$CAC_DIR/ca/ca_cert.pem"

    if [[ ! -f "$ca_key" ]] || [[ ! -f "$ca_cert" ]]; then
        echo "  warning: CA cert not found, skipping client cert generation" >&2
        return 1
    fi

    local client_key="$env_dir/client_key.pem"
    local client_csr="$env_dir/client_csr.pem"
    local client_cert="$env_dir/client_cert.pem"

    # generate client private key (2048-bit RSA)
    openssl genrsa -out "$client_key" 2048 2>/dev/null || {
        echo "error: failed to generate client private key" >&2; return 1
    }
    chmod 600 "$client_key"

    # generate CSR
    openssl req -new \
        -key "$client_key" \
        -out "$client_csr" \
        -subj "/CN=cac-client-${name}/O=cac/OU=env-${name}" \
        2>/dev/null || {
        echo "error: failed to generate CSR" >&2; return 1
    }

    # sign client cert with CA (valid for 1 year)
    openssl x509 -req \
        -in "$client_csr" \
        -CA "$ca_cert" \
        -CAkey "$ca_key" \
        -CAcreateserial \
        -out "$client_cert" \
        -days 365 \
        -extfile <(printf "keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth") \
        2>/dev/null || {
        echo "error: failed to sign client cert" >&2; return 1
    }
    chmod 644 "$client_cert"

    # cleanup CSR (no longer needed)
    rm -f "$client_csr"
}

# verify mTLS certificate status
_check_mtls() {
    local env_dir="$1"
    local ca_cert="$CAC_DIR/ca/ca_cert.pem"
    local client_cert="$env_dir/client_cert.pem"
    local client_key="$env_dir/client_key.pem"

    # check CA
    if [[ ! -f "$ca_cert" ]]; then
        echo "$(_red "✗") CA cert not found"
        return 1
    fi

    # check client cert
    if [[ ! -f "$client_cert" ]] || [[ ! -f "$client_key" ]]; then
        echo "$(_yellow "⚠") client cert not found"
        return 1
    fi

    # verify certificate chain
    if openssl verify -CAfile "$ca_cert" "$client_cert" >/dev/null 2>&1; then
        # check certificate expiry
        local expiry
        expiry=$(openssl x509 -in "$client_cert" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        local cn
        cn=$(openssl x509 -in "$client_cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' || true)
        echo "$(_green "✓") mTLS certificate valid (CN=$cn, expires: $expiry)"
        return 0
    else
        echo "$(_red "✗") certificate chain verification failed"
        return 1
    fi
}
