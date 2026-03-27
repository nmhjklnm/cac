package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
)

// buildReverseTLSConfig 构建反向代理的 TLS 配置
// - 加载服务器证书（api.anthropic.com，cac CA 签发）
// - 可选：要求客户端 mTLS 证书验证
func buildReverseTLSConfig(cfg *ReverseConfig) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load server cert: %w", err)
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	// mTLS：要求并验证客户端证书
	if cfg.RequireMTLS && cfg.CAFile != "" {
		caCert, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read CA cert: %w", err)
		}
		caPool := x509.NewCertPool()
		if !caPool.AppendCertsFromPEM(caCert) {
			return nil, fmt.Errorf("failed to parse CA cert")
		}
		tlsConfig.ClientCAs = caPool
		tlsConfig.ClientAuth = tls.RequireAndVerifyClientCert
	}

	return tlsConfig, nil
}
