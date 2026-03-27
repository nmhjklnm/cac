package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type CheckResult struct {
	OK       bool   `json:"ok"`
	Protocol string `json:"protocol,omitempty"`
	ExitIP   string `json:"exit_ip,omitempty"`
	Error    string `json:"error,omitempty"`
}

// normalizeBackend converts flexible input formats to a standard proxy URL.
// Supported formats:
//   - http://user:pass@host:port (returned as-is)
//   - socks5://user:pass@host:port (returned as-is)
//   - host:port:user:pass → http://user:pass@host:port
//   - host:port → http://host:port
func normalizeBackend(input string) string {
	input = strings.TrimSpace(input)
	if strings.HasPrefix(input, "http://") || strings.HasPrefix(input, "https://") || strings.HasPrefix(input, "socks5://") {
		return input
	}

	parts := strings.SplitN(input, ":", 4)
	switch len(parts) {
	case 4:
		// host:port:user:pass
		host, port, user, pass := parts[0], parts[1], parts[2], parts[3]
		if _, err := strconv.Atoi(port); err == nil {
			return fmt.Sprintf("http://%s:%s@%s:%s", user, pass, host, port)
		}
	case 2:
		// host:port
		host, port := parts[0], parts[1]
		if _, err := strconv.Atoi(port); err == nil {
			return fmt.Sprintf("http://%s:%s", host, port)
		}
	}

	// Fallback: return as-is with http prefix
	return "http://" + input
}

// checkProxy tests a backend proxy by trying HTTP then SOCKS5.
// Returns the first protocol that works with the exit IP.
func checkProxy(rawBackend string) CheckResult {
	normalized := normalizeBackend(rawBackend)
	u, err := url.Parse(normalized)
	if err != nil {
		return CheckResult{OK: false, Error: "无法解析地址: " + err.Error()}
	}

	host := u.Hostname()
	port := u.Port()
	user := ""
	pass := ""
	if u.User != nil {
		user = u.User.Username()
		pass, _ = u.User.Password()
	}

	// If scheme is explicitly socks5, only try socks5
	if u.Scheme == "socks5" {
		ip, err := trySOCKS5(host, port, user, pass)
		if err != nil {
			return CheckResult{OK: false, Error: "SOCKS5 不通: " + err.Error()}
		}
		return CheckResult{OK: true, Protocol: "socks5", ExitIP: ip}
	}

	// Try HTTP first
	httpURL := fmt.Sprintf("http://%s", net.JoinHostPort(host, port))
	if user != "" {
		httpURL = fmt.Sprintf("http://%s:%s@%s", user, pass, net.JoinHostPort(host, port))
	}
	ip, err := tryHTTPProxy(httpURL)
	if err == nil {
		return CheckResult{OK: true, Protocol: "http", ExitIP: ip}
	}

	// Try SOCKS5
	ip, err = trySOCKS5(host, port, user, pass)
	if err == nil {
		return CheckResult{OK: true, Protocol: "socks5", ExitIP: ip}
	}

	return CheckResult{OK: false, Error: "HTTP 和 SOCKS5 均不通"}
}

func tryHTTPProxy(proxyURL string) (string, error) {
	u, err := url.Parse(proxyURL)
	if err != nil {
		return "", err
	}
	transport := &http.Transport{
		Proxy: http.ProxyURL(u),
		DialContext: (&net.Dialer{
			Timeout: 10 * time.Second,
		}).DialContext,
	}
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second}

	resp, err := client.Get("https://api.ipify.org")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(body)), nil
}

func trySOCKS5(host, port, user, pass string) (string, error) {
	if port == "" {
		port = "1080"
	}

	// Build a socks5 URL and use connectViaSOCKS5 from proxy.go
	socks5URL := &url.URL{
		Scheme: "socks5",
		Host:   net.JoinHostPort(host, port),
	}
	if user != "" {
		socks5URL.User = url.UserPassword(user, pass)
	}

	// Connect to api.ipify.org:443 via SOCKS5
	conn, err := connectViaSOCKS5(socks5URL, "api.ipify.org:443")
	if err != nil {
		return "", err
	}
	defer conn.Close()

	// Do TLS + HTTP manually is complex, try plain HTTP instead
	conn.Close()

	// Use api.ipify.org:80 (plain HTTP) through SOCKS5
	conn, err = connectViaSOCKS5(socks5URL, "api.ipify.org:80")
	if err != nil {
		return "", err
	}
	defer conn.Close()

	conn.SetDeadline(time.Now().Add(10 * time.Second))
	_, err = conn.Write([]byte("GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n"))
	if err != nil {
		return "", err
	}

	body, err := io.ReadAll(conn)
	if err != nil {
		return "", err
	}

	// Parse HTTP response body (after headers)
	parts := strings.SplitN(string(body), "\r\n\r\n", 2)
	if len(parts) < 2 {
		return "", fmt.Errorf("invalid HTTP response")
	}
	return strings.TrimSpace(parts[1]), nil
}

// generateToken creates a random 12-char hex token.
func generateToken() string {
	b := make([]byte, 6)
	rand.Read(b)
	return hex.EncodeToString(b)
}
