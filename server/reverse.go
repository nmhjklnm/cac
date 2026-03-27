package main

import (
	"io"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// Header 黑名单：只拦截泄露身份/代理信息的 header，其余全部透传
var blockedRequestHeaders = map[string]bool{
	"X-Forwarded-For":    true, // 泄露客户端真实 IP
	"X-Real-Ip":          true, // 泄露客户端真实 IP
	"Forwarded":          true, // RFC 7239，泄露客户端 IP
	"Via":                true, // 暴露代理链
	"Proxy-Authorization": true, // 代理认证凭证
	"Proxy-Connection":   true, // 代理专用
	"X-Cac-Token":        true, // 内部 token 路由，绝不转发到 Anthropic
}

// ReverseProxyServer 反向代理，DNS 直连模式使用
type ReverseProxyServer struct {
	upstream    *url.URL            // 默认上游
	upstreamMap map[string]*url.URL // Host → 上游映射
	transport   *http.Transport     // 默认 transport（cfg.Backend 或直连）
	store       *Store

	// Per-token transport 缓存池
	transportsMu sync.RWMutex
	transports   map[string]*http.Transport // backend URL string → transport
}

func NewReverseProxyServer(cfg *ReverseConfig, store *Store) *ReverseProxyServer {
	upstream, _ := url.Parse("https://api.anthropic.com")

	// 多域名映射
	platformURL, _ := url.Parse("https://platform.claude.com")
	upstreamMap := map[string]*url.URL{
		"api.anthropic.com":  upstream,
		"platform.claude.com": platformURL,
	}

	transport := &http.Transport{
		DisableCompression:  true, // 透传压缩，不自动解压
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 50,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	}

	// 可选：通过上游代理连接 Anthropic API
	if cfg.Backend != "" {
		backendURL, err := url.Parse(cfg.Backend)
		if err == nil {
			transport.Proxy = func(*http.Request) (*url.URL, error) {
				return backendURL, nil
			}
			// 隐藏 Go 指纹：覆盖 CONNECT 请求的默认 User-Agent
			transport.ProxyConnectHeader = http.Header{
				"User-Agent": {"Mozilla/5.0"},
			}
		}
	}

	return &ReverseProxyServer{
		upstream:    upstream,
		upstreamMap: upstreamMap,
		transport:   transport,
		store:       store,
		transports:  make(map[string]*http.Transport),
	}
}

// getTransportForBackend 按 backend URL 获取或创建缓存的 transport
func (rp *ReverseProxyServer) getTransportForBackend(backend string) *http.Transport {
	rp.transportsMu.RLock()
	t, ok := rp.transports[backend]
	rp.transportsMu.RUnlock()
	if ok {
		return t
	}

	backendURL, err := url.Parse(backend)
	if err != nil {
		log.Printf("[REVERSE ROUTE] invalid backend URL %q: %v, using default", backend, err)
		return rp.transport
	}

	t = &http.Transport{
		DisableCompression:  true,
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 50,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
		Proxy: func(*http.Request) (*url.URL, error) {
			return backendURL, nil
		},
		ProxyConnectHeader: http.Header{
			"User-Agent": {"Mozilla/5.0"},
		},
	}

	rp.transportsMu.Lock()
	// 双重检查：可能另一个 goroutine 已经创建
	if existing, ok := rp.transports[backend]; ok {
		rp.transportsMu.Unlock()
		return existing
	}
	rp.transports[backend] = t
	rp.transportsMu.Unlock()

	log.Printf("[REVERSE ROUTE] created transport for backend: %s", backend)
	return t
}

func (rp *ReverseProxyServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// 提取客户端身份（mTLS CN）
	clientCN := ""
	if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
		clientCN = r.TLS.PeerCertificates[0].Subject.CommonName
	}

	log.Printf("[REVERSE] %s %s %s (client: %s) Host: %s", r.Method, r.URL.Path, r.RemoteAddr, clientCN, r.Host)

	// 打印客户端发来的所有请求头
	log.Printf("[REVERSE REQ HEADERS] ── from %s ──", r.RemoteAddr)
	for key, values := range r.Header {
		for _, v := range values {
			blocked := ""
			if blockedRequestHeaders[http.CanonicalHeaderKey(key)] {
				blocked = " [BLOCKED]"
			}
			log.Printf("[REVERSE REQ HEADERS]   %s: %s%s", key, v, blocked)
		}
	}

	// 根据 Host 选择上游（支持多域名）
	upstream := rp.upstream
	host := r.Host
	if h, ok := rp.upstreamMap[host]; ok {
		upstream = h
	}

	upstreamURL := *upstream
	upstreamURL.Path = r.URL.Path
	upstreamURL.RawQuery = r.URL.RawQuery

	upReq, err := http.NewRequestWithContext(r.Context(), r.Method, upstreamURL.String(), r.Body)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		log.Printf("[REVERSE ERROR] create request: %v", err)
		return
	}

	// Header 黑名单过滤：拦截泄露身份的 header，其余全部透传
	for key, values := range r.Header {
		if blockedRequestHeaders[http.CanonicalHeaderKey(key)] {
			log.Printf("[REVERSE HEADERS] ✗ %s (BLOCKED)", key)
			continue
		}
		for _, v := range values {
			upReq.Header.Add(key, v)
		}
	}

	// 强制设置 Host 为上游域名
	upReq.Host = upstream.Host

	// 按 token 选择 transport（出口路由）
	transport := rp.transport // 默认
	token := r.Header.Get("X-Cac-Token")
	if token != "" {
		_, backend, lookupErr := rp.store.GetTokenInfo(token)
		if lookupErr == nil && backend != "" {
			transport = rp.getTransportForBackend(backend)
			log.Printf("[REVERSE ROUTE] token=%s... → backend=%s", token[:min(8, len(token))], backend)
		} else if lookupErr == nil {
			log.Printf("[REVERSE ROUTE] token=%s... → no backend, using default", token[:min(8, len(token))])
		} else {
			log.Printf("[REVERSE ROUTE] token=%s... → lookup failed: %v, using default", token[:min(8, len(token))], lookupErr)
		}
		rp.store.TouchToken(token)
		rp.store.ConnOpen(token)
		defer rp.store.ConnClose(token)
	}

	// 执行上游请求
	resp, err := transport.RoundTrip(upReq)
	if err != nil {
		http.Error(w, "upstream error", http.StatusBadGateway)
		log.Printf("[REVERSE ERROR] upstream: %v", err)
		return
	}
	defer resp.Body.Close()

	// 打印 Anthropic 返回的响应头
	log.Printf("[REVERSE RESP] status=%d", resp.StatusCode)
	log.Printf("[REVERSE RESP HEADERS] ── from upstream ──")
	for key, values := range resp.Header {
		for _, v := range values {
			log.Printf("[REVERSE RESP HEADERS]   %s: %s", key, v)
		}
	}

	// 复制响应 header
	for key, values := range resp.Header {
		for _, v := range values {
			w.Header().Add(key, v)
		}
	}
	w.WriteHeader(resp.StatusCode)

	// 流式返回响应（支持 SSE）
	flushCopy(w, resp.Body)
}

// flushCopy 逐 chunk 复制并 flush，支持 SSE 流式响应
func flushCopy(w http.ResponseWriter, body io.Reader) {
	flusher, canFlush := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	for {
		n, err := body.Read(buf)
		if n > 0 {
			w.Write(buf[:n])
			if canFlush {
				flusher.Flush()
			}
		}
		if err != nil {
			break
		}
	}
}
