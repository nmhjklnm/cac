# ── mTLS 客户端证书管理 ─────────────────────────────────────────

# 生成自签 CA（setup 时调用，仅生成一次）
_generate_ca_cert() {
    local ca_dir="$CAC_DIR/ca"
    local ca_key="$ca_dir/ca_key.pem"
    local ca_cert="$ca_dir/ca_cert.pem"

    if [[ -f "$ca_cert" ]] && [[ -f "$ca_key" ]]; then
        echo "  CA 证书已存在，跳过生成"
        return 0
    fi

    mkdir -p "$ca_dir"

    # 生成 CA 私钥（4096 位 RSA）
    openssl genrsa -out "$ca_key" 4096 2>/dev/null || {
        echo "错误：生成 CA 私钥失败" >&2; return 1
    }
    chmod 600 "$ca_key"

    # 生成自签 CA 证书（有效期 10 年）
    openssl req -new -x509 \
        -key "$ca_key" \
        -out "$ca_cert" \
        -days 3650 \
        -subj "/CN=cac-privacy-ca/O=cac/OU=mtls" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        2>/dev/null || {
        echo "错误：生成 CA 证书失败" >&2; return 1
    }
    chmod 644 "$ca_cert"
}

# 为指定环境生成客户端证书（cac add 时调用）
_generate_client_cert() {
    local name="$1"
    local env_dir="$ENVS_DIR/$name"
    local ca_key="$CAC_DIR/ca/ca_key.pem"
    local ca_cert="$CAC_DIR/ca/ca_cert.pem"

    if [[ ! -f "$ca_key" ]] || [[ ! -f "$ca_cert" ]]; then
        echo "  警告：CA 证书不存在，跳过客户端证书生成" >&2
        return 1
    fi

    local client_key="$env_dir/client_key.pem"
    local client_csr="$env_dir/client_csr.pem"
    local client_cert="$env_dir/client_cert.pem"

    # 生成客户端私钥（2048 位 RSA）
    openssl genrsa -out "$client_key" 2048 2>/dev/null || {
        echo "错误：生成客户端私钥失败" >&2; return 1
    }
    chmod 600 "$client_key"

    # 生成 CSR
    openssl req -new \
        -key "$client_key" \
        -out "$client_csr" \
        -subj "/CN=cac-client-${name}/O=cac/OU=env-${name}" \
        2>/dev/null || {
        echo "错误：生成 CSR 失败" >&2; return 1
    }

    # 用 CA 签发客户端证书（有效期 1 年）
    openssl x509 -req \
        -in "$client_csr" \
        -CA "$ca_cert" \
        -CAkey "$ca_key" \
        -CAcreateserial \
        -out "$client_cert" \
        -days 365 \
        -extfile <(printf "keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth") \
        2>/dev/null || {
        echo "错误：签发客户端证书失败" >&2; return 1
    }
    chmod 644 "$client_cert"

    # 清理 CSR（不再需要）
    rm -f "$client_csr"
}

# 验证 mTLS 证书状态
_check_mtls() {
    local env_dir="$1"
    local ca_cert="$CAC_DIR/ca/ca_cert.pem"
    local client_cert="$env_dir/client_cert.pem"
    local client_key="$env_dir/client_key.pem"

    # 检查 CA
    if [[ ! -f "$ca_cert" ]]; then
        echo "$(_red "✗") CA 证书不存在"
        return 1
    fi

    # 检查客户端证书
    if [[ ! -f "$client_cert" ]] || [[ ! -f "$client_key" ]]; then
        echo "$(_yellow "⚠") 客户端证书不存在"
        return 1
    fi

    # 验证证书链
    if openssl verify -CAfile "$ca_cert" "$client_cert" >/dev/null 2>&1; then
        # 检查证书有效期
        local expiry
        expiry=$(openssl x509 -in "$client_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
        local cn
        cn=$(openssl x509 -in "$client_cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
        echo "$(_green "✓") mTLS 证书有效 (CN=$cn, 到期: $expiry)"
        return 0
    else
        echo "$(_red "✗") 证书链验证失败"
        return 1
    fi
}
