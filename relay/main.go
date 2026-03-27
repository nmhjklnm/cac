package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"time"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "tls" {
		runTLSMode()
		return
	}

	if len(os.Args) < 4 {
		fmt.Fprintf(os.Stderr, "Usage: cac-relay <local-port> <server-addr> <token>\n")
		fmt.Fprintf(os.Stderr, "       cac-relay tls <port> <server:port> <token> <cert> <key> <ca>\n")
		os.Exit(1)
	}

	localPort := os.Args[1]
	serverAddr := os.Args[2]
	token := os.Args[3]

	creds := base64.StdEncoding.EncodeToString([]byte("token:" + token))

	listenAddr := "127.0.0.1:" + localPort

	proxy := &relayProxy{
		serverAddr: serverAddr,
		authHeader: "Basic " + creds,
	}

	log.Printf("cac-relay listening on %s -> %s", listenAddr, serverAddr)

	if err := http.ListenAndServe(listenAddr, proxy); err != nil {
		log.Fatalf("Failed to start: %v", err)
	}
}

// runTLSMode — TLS 透明代理模式
// 本地监听 127.0.0.1:<port>，TLS 终止后注入 X-Cac-Token，再 TLS 转发到 server
func runTLSMode() {
	if len(os.Args) < 8 {
		fmt.Fprintf(os.Stderr, "Usage: cac-relay tls <port> <server:port> <token> <cert> <key> <ca>\n")
		os.Exit(1)
	}

	port := os.Args[2]
	serverAddr := os.Args[3]
	token := os.Args[4]
	certFile := os.Args[5]
	keyFile := os.Args[6]
	caFile := os.Args[7]

	// 加载本地 TLS 证书（SAN: api.anthropic.com, platform.claude.com）
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("Failed to load TLS cert: %v", err)
	}

	// 加载 CA 证书（验证服务器证书）
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		log.Fatalf("Failed to read CA cert: %v", err)
	}
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		log.Fatalf("Failed to parse CA cert")
	}

	upstreamURL := &url.URL{
		Scheme: "https",
		Host:   serverAddr,
	}

	// 上游 TLS：信任我们的 CA，ServerName 设为 api.anthropic.com
	upstreamTransport := &http.Transport{
		DisableCompression: true,
		TLSClientConfig: &tls.Config{
			RootCAs:    caPool,
			ServerName: "api.anthropic.com",
		},
		MaxIdleConns:        50,
		MaxIdleConnsPerHost: 50,
		IdleConnTimeout:     90 * time.Second,
	}

	director := func(req *http.Request) {
		req.URL.Scheme = upstreamURL.Scheme
		req.URL.Host = upstreamURL.Host
		req.Header.Set("X-Cac-Token", token)
		// Host 保持客户端原始值（api.anthropic.com / platform.claude.com）
	}

	proxy := &httputil.ReverseProxy{
		Director:      director,
		Transport:     upstreamTransport,
		FlushInterval: -1, // SSE 即时 flush
	}

	listenAddr := "127.0.0.1:" + port
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
	}

	server := &http.Server{
		Addr:      listenAddr,
		Handler:   proxy,
		TLSConfig: tlsConfig,
	}

	log.Printf("cac-relay TLS listening on %s -> %s (token=%s...)", listenAddr, serverAddr, token[:min(8, len(token))])

	// TLS listener（证书已在 TLSConfig 中，不需要再传文件）
	if err := server.ListenAndServeTLS("", ""); err != nil {
		log.Fatalf("TLS server failed: %v", err)
	}
}

type relayProxy struct {
	serverAddr string
	authHeader string
}

func (rp *relayProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		rp.handleConnect(w, r)
	} else {
		rp.handleHTTP(w, r)
	}
}

func (rp *relayProxy) handleConnect(w http.ResponseWriter, r *http.Request) {
	serverConn, err := net.DialTimeout("tcp", rp.serverAddr, 10*time.Second)
	if err != nil {
		http.Error(w, "Cannot reach anideaai-server", http.StatusBadGateway)
		return
	}
	defer serverConn.Close()

	connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: %s\r\n\r\n",
		r.Host, r.Host, rp.authHeader)

	if _, err := serverConn.Write([]byte(connectReq)); err != nil {
		http.Error(w, "Failed to connect via server", http.StatusBadGateway)
		return
	}

	br := bufio.NewReader(serverConn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		http.Error(w, "Invalid server response", http.StatusBadGateway)
		return
	}
	if resp.StatusCode != http.StatusOK {
		http.Error(w, "Server rejected CONNECT", http.StatusBadGateway)
		return
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "Hijacking not supported", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		return
	}
	defer clientConn.Close()

	clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))

	done := make(chan struct{}, 2)
	go func() { io.Copy(serverConn, clientConn); done <- struct{}{} }()
	go func() { io.Copy(clientConn, serverConn); done <- struct{}{} }()
	<-done
}

func (rp *relayProxy) handleHTTP(w http.ResponseWriter, r *http.Request) {
	serverConn, err := net.DialTimeout("tcp", rp.serverAddr, 10*time.Second)
	if err != nil {
		http.Error(w, "Cannot reach anideaai-server", http.StatusBadGateway)
		return
	}
	defer serverConn.Close()

	// Forward the request with auth header
	r.Header.Set("Proxy-Authorization", rp.authHeader)
	if err := r.WriteProxy(serverConn); err != nil {
		http.Error(w, "Failed to forward request", http.StatusBadGateway)
		return
	}

	br := bufio.NewReader(serverConn)
	resp, err := http.ReadResponse(br, r)
	if err != nil {
		http.Error(w, "Invalid server response", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}
