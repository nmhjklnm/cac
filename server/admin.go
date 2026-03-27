package main

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
)

type AdminServer struct {
	store    *Store
	password string
}

func NewAdminServer(store *Store, password string) *AdminServer {
	return &AdminServer{store: store, password: password}
}

func (a *AdminServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Auth check for API routes (except login)
	if strings.HasPrefix(r.URL.Path, "/api/") && r.URL.Path != "/api/login" {
		if !a.checkAuth(r) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
	}

	switch {
	case r.URL.Path == "/" || r.URL.Path == "/index.html":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(adminHTML))
	case r.URL.Path == "/api/login" && r.Method == http.MethodPost:
		a.handleLogin(w, r)
	case r.URL.Path == "/api/tokens" && r.Method == http.MethodGet:
		a.handleListTokens(w, r)
	case r.URL.Path == "/api/tokens" && r.Method == http.MethodPost:
		a.handleAddToken(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/tokens/") && r.Method == http.MethodPut:
		a.handleUpdateToken(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/tokens/") && r.Method == http.MethodDelete:
		a.handleDeleteToken(w, r)
	case r.URL.Path == "/api/stats" && r.Method == http.MethodGet:
		a.handleStats(w, r)
	case r.URL.Path == "/api/check-proxy" && r.Method == http.MethodPost:
		a.handleCheckProxy(w, r)
	case r.URL.Path == "/api/auth-requests" && r.Method == http.MethodGet:
		a.handleListAuthRequests(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/auth-requests/") && r.Method == http.MethodPost:
		a.handleApproveAuthRequest(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (a *AdminServer) checkAuth(r *http.Request) bool {
	// Check Authorization header: Bearer <password>
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(auth, "Bearer ") {
		token := auth[7:]
		return subtle.ConstantTimeCompare([]byte(token), []byte(a.password)) == 1
	}
	return false
}

func (a *AdminServer) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Password), []byte(a.password)) != 1 {
		jsonError(w, "wrong password", http.StatusUnauthorized)
		return
	}
	jsonOK(w, map[string]string{"token": a.password})
}

func (a *AdminServer) handleListTokens(w http.ResponseWriter, r *http.Request) {
	tokens, err := a.store.ListTokens()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if tokens == nil {
		tokens = []Token{}
	}

	// Merge runtime stats
	stats := a.store.GetStats()
	type TokenWithStats struct {
		Token
		ActiveConns int   `json:"active_conns"`
		TotalConns  int64 `json:"total_conns"`
	}
	result := make([]TokenWithStats, len(tokens))
	for i, t := range tokens {
		result[i] = TokenWithStats{Token: t}
		if s, ok := stats[t.Token]; ok {
			result[i].ActiveConns = s.ActiveConns
			result[i].TotalConns = s.TotalConns
		}
	}
	jsonOK(w, result)
}

func (a *AdminServer) handleAddToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token   string `json:"token"`
		Backend string `json:"backend"`
		Note    string `json:"note"`
		SK      string `json:"sk"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if req.Backend == "" {
		jsonError(w, "backend is required", http.StatusBadRequest)
		return
	}
	// Auto-generate token if empty
	if req.Token == "" {
		req.Token = generateToken()
	}
	// Normalize backend URL
	req.Backend = normalizeBackend(req.Backend)

	if err := a.store.AddToken(req.Token, req.Backend, req.Note, req.SK); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[ADMIN] token added: %s -> %s", req.Token, req.Backend)
	jsonOK(w, map[string]interface{}{"status": "ok", "token": req.Token})
}

func (a *AdminServer) handleCheckProxy(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Backend string `json:"backend"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	if req.Backend == "" {
		jsonError(w, "backend is required", http.StatusBadRequest)
		return
	}
	result := checkProxy(req.Backend)
	jsonOK(w, result)
}

func (a *AdminServer) handleUpdateToken(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/tokens/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	var req struct {
		Backend string `json:"backend"`
		Note    string `json:"note"`
		SK      string `json:"sk"`
		Enabled bool   `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request", http.StatusBadRequest)
		return
	}
	req.Backend = normalizeBackend(req.Backend)
	if err := a.store.UpdateToken(id, req.Backend, req.Note, req.SK, req.Enabled); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[ADMIN] token #%d updated", id)
	jsonOK(w, map[string]string{"status": "ok"})
}

func (a *AdminServer) handleDeleteToken(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/tokens/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	if err := a.store.DeleteToken(id); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[ADMIN] token #%d deleted", id)
	jsonOK(w, map[string]string{"status": "ok"})
}

func (a *AdminServer) handleListAuthRequests(w http.ResponseWriter, r *http.Request) {
	a.store.ExpireOldAuthRequests()
	reqs, err := a.store.ListPendingAuthRequests()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if reqs == nil {
		reqs = []AuthRequest{}
	}
	jsonOK(w, reqs)
}

func (a *AdminServer) handleApproveAuthRequest(w http.ResponseWriter, r *http.Request) {
	// Path: /api/auth-requests/:id/approve
	path := strings.TrimPrefix(r.URL.Path, "/api/auth-requests/")
	idStr := strings.TrimSuffix(path, "/approve")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.Code == "" {
		jsonError(w, "code is required", http.StatusBadRequest)
		return
	}

	authReq, err := a.store.GetAuthRequest(id)
	if err != nil {
		jsonError(w, "request not found", http.StatusNotFound)
		return
	}
	if authReq.Status != "pending" {
		jsonError(w, "request is not pending (status: "+authReq.Status+")", http.StatusBadRequest)
		return
	}

	if err := a.store.ApproveAuthRequest(id, req.Code); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[ADMIN] auth request #%d approved for token %s", id, truncToken(authReq.Token))
	jsonOK(w, map[string]string{"status": "ok"})
}

func (a *AdminServer) handleStats(w http.ResponseWriter, r *http.Request) {
	stats := a.store.GetStats()
	jsonOK(w, stats)
}

func jsonOK(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
