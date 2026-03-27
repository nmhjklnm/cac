package main

import (
	"encoding/base64"
	"net/http"
	"net/url"
	"strings"
)

type Authenticator struct {
	store *Store
}

func NewAuthenticator(store *Store) *Authenticator {
	return &Authenticator{store: store}
}

// Authenticate checks Proxy-Authorization header.
// Client sends: http://token:TOKEN_VALUE@server:port
// Returns (backend URL, token string) if auth succeeds.
func (a *Authenticator) Authenticate(r *http.Request) (*url.URL, string) {
	auth := r.Header.Get("Proxy-Authorization")
	if auth == "" {
		return nil, ""
	}
	if !strings.HasPrefix(auth, "Basic ") {
		return nil, ""
	}
	decoded, err := base64.StdEncoding.DecodeString(auth[6:])
	if err != nil {
		return nil, ""
	}
	parts := strings.SplitN(string(decoded), ":", 2)
	if len(parts) != 2 {
		return nil, ""
	}
	token := parts[1]
	backend := a.store.LookupToken(token)
	if backend != nil {
		a.store.TouchToken(token)
		return backend, token
	}
	return nil, ""
}
