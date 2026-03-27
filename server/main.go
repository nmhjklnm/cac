package main

import (
	"flag"
	"log"
	"net/http"
	"time"
)

func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	flag.Parse()

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	store, err := NewStore(cfg.DBPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer store.Close()

	auth := NewAuthenticator(store)
	oauth := NewOAuthHandler(auth, store)
	authRelay := NewAuthRelayHandler(auth, store)
	proxy := NewProxyServer(auth, store, oauth, authRelay)
	admin := NewAdminServer(store, cfg.AdminPass)

	// Start admin UI server
	go func() {
		log.Printf("Admin UI starting on %s", cfg.AdminListen)
		if err := http.ListenAndServe(cfg.AdminListen, admin); err != nil {
			log.Fatalf("Admin server failed: %v", err)
		}
	}()

	// Start reverse proxy (DNS direct-connect mode)
	if cfg.Reverse != nil && cfg.Reverse.Enabled {
		tlsCfg, err := buildReverseTLSConfig(cfg.Reverse)
		if err != nil {
			log.Fatalf("Failed to build reverse TLS config: %v", err)
		}

		reverseProxy := NewReverseProxyServer(cfg.Reverse, store)
		revServer := &http.Server{
			Addr:      cfg.Reverse.Listen,
			Handler:   reverseProxy,
			TLSConfig: tlsCfg,
			// WriteTimeout 必须为 0：SSE 流式响应可持续数分钟
			ReadHeaderTimeout: 10 * time.Second,
		}

		go func() {
			log.Printf("Reverse proxy (DNS mode) starting on %s", cfg.Reverse.Listen)
			if err := revServer.ListenAndServeTLS("", ""); err != nil {
				log.Fatalf("Reverse proxy failed: %v", err)
			}
		}()
	}

	// Start proxy server
	log.Printf("Proxy server starting on %s", cfg.Listen)
	if err := http.ListenAndServe(cfg.Listen, proxy); err != nil {
		log.Fatalf("Proxy server failed: %v", err)
	}
}
