package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type ProxyServer struct {
	auth      *Authenticator
	store     *Store
	oauth     *OAuthHandler
	authRelay *AuthRelayHandler
}

func NewProxyServer(auth *Authenticator, store *Store, oauth *OAuthHandler, authRelay *AuthRelayHandler) *ProxyServer {
	return &ProxyServer{auth: auth, store: store, oauth: oauth, authRelay: authRelay}
}

func (ps *ProxyServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Handle API endpoints (non-proxy requests)
	if r.URL.Path == "/api/oauth" && r.Method == http.MethodGet {
		ps.oauth.ServeHTTP(w, r)
		return
	}
	if r.URL.Path == "/api/auth-relay" && r.Method == http.MethodPost {
		ps.authRelay.ServeHTTP(w, r)
		return
	}
	if r.URL.Path == "/api/auth-relay/poll" && r.Method == http.MethodGet {
		ps.authRelay.PollHandler(w, r)
		return
	}
	if r.URL.Path == "/api/heartbeat" && r.Method == http.MethodPost {
		ps.handleHeartbeat(w, r)
		return
	}

	backend, token := ps.auth.Authenticate(r)
	if backend == nil {
		w.Header().Set("Proxy-Authenticate", `Basic realm="anideaai-proxy"`)
		http.Error(w, "Proxy authentication required", http.StatusProxyAuthRequired)
		log.Printf("[AUTH FAIL] %s %s", r.RemoteAddr, r.Host)
		return
	}

	ps.store.ConnOpen(token)
	defer ps.store.ConnClose(token)

	if r.Method == http.MethodConnect {
		ps.handleConnect(w, r, backend)
	} else {
		ps.handleHTTP(w, r, backend)
	}
}

func (ps *ProxyServer) handleConnect(w http.ResponseWriter, r *http.Request, backend *url.URL) {
	log.Printf("[CONNECT] %s -> %s via %s", r.RemoteAddr, r.Host, backend.Host)

	var backendConn net.Conn
	var err error

	if backend.Scheme == "socks5" {
		backendConn, err = connectViaSOCKS5(backend, r.Host)
		if err != nil {
			http.Error(w, "Backend proxy unreachable", http.StatusBadGateway)
			log.Printf("[ERROR] socks5 backend %s: %v", backend.Host, err)
			return
		}
	} else {
		backendConn, err = net.DialTimeout("tcp", backend.Host, 10*time.Second)
		if err != nil {
			http.Error(w, "Backend proxy unreachable", http.StatusBadGateway)
			log.Printf("[ERROR] dial backend %s: %v", backend.Host, err)
			return
		}

		connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n", r.Host, r.Host)
		if backend.User != nil {
			creds := backend.User.String()
			encoded := base64.StdEncoding.EncodeToString([]byte(creds))
			connectReq += fmt.Sprintf("Proxy-Authorization: Basic %s\r\n", encoded)
		}
		connectReq += "\r\n"

		if _, err := backendConn.Write([]byte(connectReq)); err != nil {
			backendConn.Close()
			http.Error(w, "Failed to connect via backend", http.StatusBadGateway)
			log.Printf("[ERROR] write to backend: %v", err)
			return
		}

		br := bufio.NewReader(backendConn)
		resp, err := http.ReadResponse(br, nil)
		if err != nil {
			backendConn.Close()
			http.Error(w, "Invalid backend response", http.StatusBadGateway)
			log.Printf("[ERROR] read backend response: %v", err)
			return
		}
		if resp.StatusCode != http.StatusOK {
			backendConn.Close()
			http.Error(w, "Backend proxy rejected CONNECT", http.StatusBadGateway)
			log.Printf("[ERROR] backend returned %d", resp.StatusCode)
			return
		}
	}
	defer backendConn.Close()

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "Hijacking not supported", http.StatusInternalServerError)
		return
	}
	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		log.Printf("[ERROR] hijack: %v", err)
		return
	}
	defer clientConn.Close()

	clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))

	done := make(chan struct{}, 2)
	go func() {
		io.Copy(backendConn, clientConn)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(clientConn, backendConn)
		done <- struct{}{}
	}()
	<-done
}

func (ps *ProxyServer) handleHTTP(w http.ResponseWriter, r *http.Request, backend *url.URL) {
	log.Printf("[HTTP] %s -> %s via %s", r.RemoteAddr, r.URL, backend.Host)

	transport := &http.Transport{
		Proxy: func(*http.Request) (*url.URL, error) {
			return backend, nil
		},
	}

	r.RequestURI = ""
	r.Header.Del("Proxy-Authorization")
	r.Header.Del("Proxy-Connection")

	resp, err := transport.RoundTrip(r)
	if err != nil {
		http.Error(w, "Backend request failed", http.StatusBadGateway)
		log.Printf("[ERROR] roundtrip: %v", err)
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

func connectViaSOCKS5(backendURL *url.URL, targetHost string) (net.Conn, error) {
	host, port, _ := net.SplitHostPort(backendURL.Host)
	if port == "" {
		port = "1080"
	}

	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 10*time.Second)
	if err != nil {
		return nil, err
	}

	var authMethod byte = 0x00
	if backendURL.User != nil {
		authMethod = 0x02
	}

	conn.Write([]byte{0x05, 0x01, authMethod})
	buf := make([]byte, 2)
	if _, err := io.ReadFull(conn, buf); err != nil {
		conn.Close()
		return nil, fmt.Errorf("socks5 greeting: %w", err)
	}
	if buf[0] != 0x05 || buf[1] != authMethod {
		conn.Close()
		return nil, fmt.Errorf("socks5 method rejected")
	}

	if authMethod == 0x02 {
		username := backendURL.User.Username()
		password, _ := backendURL.User.Password()
		authReq := []byte{0x01, byte(len(username))}
		authReq = append(authReq, []byte(username)...)
		authReq = append(authReq, byte(len(password)))
		authReq = append(authReq, []byte(password)...)
		conn.Write(authReq)
		if _, err := io.ReadFull(conn, buf); err != nil {
			conn.Close()
			return nil, fmt.Errorf("socks5 auth: %w", err)
		}
		if buf[1] != 0x00 {
			conn.Close()
			return nil, fmt.Errorf("socks5 auth failed")
		}
	}

	targetH, targetP, _ := net.SplitHostPort(targetHost)
	if targetP == "" {
		targetP = "443"
	}
	portNum := 0
	fmt.Sscanf(targetP, "%d", &portNum)

	req := []byte{0x05, 0x01, 0x00, 0x03, byte(len(targetH))}
	req = append(req, []byte(targetH)...)
	req = append(req, byte(portNum>>8), byte(portNum&0xff))
	conn.Write(req)

	resp := make([]byte, 4)
	if _, err := io.ReadFull(conn, resp); err != nil {
		conn.Close()
		return nil, fmt.Errorf("socks5 connect: %w", err)
	}
	if resp[1] != 0x00 {
		conn.Close()
		return nil, fmt.Errorf("socks5 connect rejected: %d", resp[1])
	}

	switch resp[3] {
	case 0x01:
		io.ReadFull(conn, make([]byte, 4+2))
	case 0x03:
		lenBuf := make([]byte, 1)
		io.ReadFull(conn, lenBuf)
		io.ReadFull(conn, make([]byte, int(lenBuf[0])+2))
	case 0x04:
		io.ReadFull(conn, make([]byte, 16+2))
	}

	return conn, nil
}

func (ps *ProxyServer) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	// Authenticate via Proxy-Authorization header (same as proxy requests)
	auth := r.Header.Get("Proxy-Authorization")
	if !strings.HasPrefix(auth, "Basic ") {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusProxyAuthRequired)
		return
	}
	decoded, err := base64.StdEncoding.DecodeString(auth[6:])
	if err != nil {
		http.Error(w, `{"error":"bad auth"}`, http.StatusBadRequest)
		return
	}
	parts := strings.SplitN(string(decoded), ":", 2)
	if len(parts) != 2 {
		http.Error(w, `{"error":"bad auth"}`, http.StatusBadRequest)
		return
	}
	token := parts[1]
	if ps.store.LookupToken(token) == nil {
		http.Error(w, `{"error":"invalid token"}`, http.StatusForbidden)
		return
	}

	var req struct {
		CredStatus    string `json:"cred_status"`
		CredExpiresAt string `json:"cred_expires_at"`
		ProxyStatus   string `json:"proxy_status"`
		ProxyExitIP   string `json:"proxy_exit_ip"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"bad body"}`, http.StatusBadRequest)
		return
	}

	shortTok := token
	if len(shortTok) > 8 {
		shortTok = shortTok[:8]
	}

	if err := ps.store.UpdateHeartbeat(token, req.CredStatus, req.CredExpiresAt, req.ProxyStatus, req.ProxyExitIP); err != nil {
		log.Printf("[HEARTBEAT] update error for %s: %v", shortTok, err)
		http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
		return
	}

	log.Printf("[HEARTBEAT] %s cred=%s proxy=%s ip=%s", shortTok, req.CredStatus, req.ProxyStatus, req.ProxyExitIP)
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}
