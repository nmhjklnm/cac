package main

import (
	"database/sql"
	"fmt"
	"net/url"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Token struct {
	ID            int64  `json:"id"`
	Token         string `json:"token"`
	Backend       string `json:"backend"`
	Note          string `json:"note"`
	SK            string `json:"sk"`
	Enabled       bool   `json:"enabled"`
	CreatedAt     string `json:"created_at"`
	LastUsedAt    string `json:"last_used_at,omitempty"`
	LastHeartbeat string `json:"last_heartbeat,omitempty"`
	CredStatus    string `json:"cred_status,omitempty"`
	CredExpiresAt string `json:"cred_expires_at,omitempty"`
	ProxyStatus   string `json:"proxy_status,omitempty"`
	ProxyExitIP   string `json:"proxy_exit_ip,omitempty"`
}

type TokenStats struct {
	Token       string `json:"token"`
	ActiveConns int    `json:"active_conns"`
	TotalConns  int64  `json:"total_conns"`
}

type Store struct {
	db    *sql.DB
	mu    sync.RWMutex
	cache map[string]*url.URL // token -> parsed backend URL (enabled only)

	// runtime stats
	statsMu     sync.Mutex
	activeConns map[string]int   // token -> active connection count
	totalConns  map[string]int64 // token -> total connection count
}

func NewStore(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite3", dbPath+"?_journal_mode=WAL")
	if err != nil {
		return nil, err
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS tokens (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			token TEXT UNIQUE NOT NULL,
			backend TEXT NOT NULL,
			note TEXT DEFAULT '',
			sk TEXT DEFAULT '',
			enabled INTEGER DEFAULT 1,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			last_used_at DATETIME
		)
	`)
	if err == nil {
		// migrate: add sk column if missing
		db.Exec("ALTER TABLE tokens ADD COLUMN sk TEXT DEFAULT ''")
		// migrate: heartbeat columns
		db.Exec("ALTER TABLE tokens ADD COLUMN last_heartbeat DATETIME")
		db.Exec("ALTER TABLE tokens ADD COLUMN cred_status TEXT DEFAULT ''")
		db.Exec("ALTER TABLE tokens ADD COLUMN cred_expires_at TEXT DEFAULT ''")
		db.Exec("ALTER TABLE tokens ADD COLUMN proxy_status TEXT DEFAULT ''")
		db.Exec("ALTER TABLE tokens ADD COLUMN proxy_exit_ip TEXT DEFAULT ''")
	}

	// auth_requests table
	_, err2 := db.Exec(`
		CREATE TABLE IF NOT EXISTS auth_requests (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			token TEXT NOT NULL,
			auth_url TEXT NOT NULL,
			machine_info TEXT DEFAULT '',
			status TEXT DEFAULT 'pending',
			auth_code TEXT DEFAULT '',
			error TEXT DEFAULT '',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			resolved_at DATETIME
		)
	`)
	if err2 != nil {
		return nil, fmt.Errorf("create auth_requests table: %w", err2)
	}

	if err != nil {
		return nil, fmt.Errorf("create table: %w", err)
	}

	s := &Store{
		db:          db,
		cache:       make(map[string]*url.URL),
		activeConns: make(map[string]int),
		totalConns:  make(map[string]int64),
	}

	if err := s.reloadCache(); err != nil {
		return nil, err
	}

	return s, nil
}

func (s *Store) reloadCache() error {
	rows, err := s.db.Query("SELECT token, backend FROM tokens WHERE enabled = 1")
	if err != nil {
		return err
	}
	defer rows.Close()

	cache := make(map[string]*url.URL)
	for rows.Next() {
		var token, backend string
		if err := rows.Scan(&token, &backend); err != nil {
			return err
		}
		u, err := url.Parse(backend)
		if err != nil {
			continue
		}
		cache[token] = u
	}

	s.mu.Lock()
	s.cache = cache
	s.mu.Unlock()
	return nil
}

// LookupToken returns the backend URL for a valid, enabled token.
func (s *Store) LookupToken(token string) *url.URL {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cache[token]
}

// TouchToken updates last_used_at.
func (s *Store) TouchToken(token string) {
	go func() {
		s.db.Exec("UPDATE tokens SET last_used_at = ? WHERE token = ?", time.Now().UTC().Format(time.RFC3339), token)
	}()
}

// ConnOpen tracks a new connection for stats.
func (s *Store) ConnOpen(token string) {
	s.statsMu.Lock()
	s.activeConns[token]++
	s.totalConns[token]++
	s.statsMu.Unlock()
}

// ConnClose tracks connection close.
func (s *Store) ConnClose(token string) {
	s.statsMu.Lock()
	s.activeConns[token]--
	if s.activeConns[token] < 0 {
		s.activeConns[token] = 0
	}
	s.statsMu.Unlock()
}

// GetStats returns stats for all tokens.
func (s *Store) GetStats() map[string]TokenStats {
	s.statsMu.Lock()
	defer s.statsMu.Unlock()
	result := make(map[string]TokenStats)
	for t, active := range s.activeConns {
		result[t] = TokenStats{Token: t, ActiveConns: active, TotalConns: s.totalConns[t]}
	}
	// Also include tokens with totalConns but 0 active
	for t, total := range s.totalConns {
		if _, ok := result[t]; !ok {
			result[t] = TokenStats{Token: t, ActiveConns: 0, TotalConns: total}
		}
	}
	return result
}

// --- CRUD ---

func (s *Store) ListTokens() ([]Token, error) {
	rows, err := s.db.Query(`SELECT id, token, backend, note, COALESCE(sk,''), enabled, created_at, COALESCE(last_used_at,''),
		COALESCE(last_heartbeat,''), COALESCE(cred_status,''), COALESCE(cred_expires_at,''), COALESCE(proxy_status,''), COALESCE(proxy_exit_ip,'')
		FROM tokens ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tokens []Token
	for rows.Next() {
		var t Token
		var enabled int
		if err := rows.Scan(&t.ID, &t.Token, &t.Backend, &t.Note, &t.SK, &enabled, &t.CreatedAt, &t.LastUsedAt,
			&t.LastHeartbeat, &t.CredStatus, &t.CredExpiresAt, &t.ProxyStatus, &t.ProxyExitIP); err != nil {
			return nil, err
		}
		t.Enabled = enabled == 1
		tokens = append(tokens, t)
	}
	return tokens, nil
}

// UpdateHeartbeat updates heartbeat fields for a given token.
func (s *Store) UpdateHeartbeat(token, credStatus, credExpiresAt, proxyStatus, proxyExitIP string) error {
	_, err := s.db.Exec(`UPDATE tokens SET last_heartbeat = ?, cred_status = ?, cred_expires_at = ?, proxy_status = ?, proxy_exit_ip = ? WHERE token = ?`,
		time.Now().UTC().Format(time.RFC3339), credStatus, credExpiresAt, proxyStatus, proxyExitIP, token)
	return err
}

func (s *Store) AddToken(token, backend, note, sk string) error {
	_, err := s.db.Exec("INSERT INTO tokens (token, backend, note, sk) VALUES (?, ?, ?, ?)", token, backend, note, sk)
	if err != nil {
		return err
	}
	return s.reloadCache()
}

func (s *Store) UpdateToken(id int64, backend, note, sk string, enabled bool) error {
	enabledInt := 0
	if enabled {
		enabledInt = 1
	}
	_, err := s.db.Exec("UPDATE tokens SET backend = ?, note = ?, sk = ?, enabled = ? WHERE id = ?", backend, note, sk, enabledInt, id)
	if err != nil {
		return err
	}
	return s.reloadCache()
}

func (s *Store) DeleteToken(id int64) error {
	_, err := s.db.Exec("DELETE FROM tokens WHERE id = ?", id)
	if err != nil {
		return err
	}
	return s.reloadCache()
}

// GetTokenInfo returns sk and backend for a given token string.
func (s *Store) GetTokenInfo(token string) (sk, backend string, err error) {
	err = s.db.QueryRow("SELECT COALESCE(sk,''), backend FROM tokens WHERE token = ? AND enabled = 1", token).Scan(&sk, &backend)
	return
}

// --- Auth Requests ---

type AuthRequest struct {
	ID          int64  `json:"id"`
	Token       string `json:"token"`
	AuthURL     string `json:"auth_url"`
	MachineInfo string `json:"machine_info,omitempty"`
	Status      string `json:"status"` // pending, approved, failed, expired
	AuthCode    string `json:"auth_code,omitempty"`
	Error       string `json:"error,omitempty"`
	CreatedAt   string `json:"created_at"`
	ResolvedAt  string `json:"resolved_at,omitempty"`
}

func (s *Store) CreateAuthRequest(token, authURL, machineInfo string) (int64, error) {
	res, err := s.db.Exec(
		"INSERT INTO auth_requests (token, auth_url, machine_info) VALUES (?, ?, ?)",
		token, authURL, machineInfo,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) ListPendingAuthRequests() ([]AuthRequest, error) {
	rows, err := s.db.Query(
		"SELECT id, token, auth_url, COALESCE(machine_info,''), status, COALESCE(auth_code,''), COALESCE(error,''), created_at, COALESCE(resolved_at,'') FROM auth_requests ORDER BY id DESC LIMIT 50",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var reqs []AuthRequest
	for rows.Next() {
		var r AuthRequest
		if err := rows.Scan(&r.ID, &r.Token, &r.AuthURL, &r.MachineInfo, &r.Status, &r.AuthCode, &r.Error, &r.CreatedAt, &r.ResolvedAt); err != nil {
			return nil, err
		}
		reqs = append(reqs, r)
	}
	return reqs, nil
}

func (s *Store) GetAuthRequest(id int64) (*AuthRequest, error) {
	var r AuthRequest
	err := s.db.QueryRow(
		"SELECT id, token, auth_url, COALESCE(machine_info,''), status, COALESCE(auth_code,''), COALESCE(error,''), created_at, COALESCE(resolved_at,'') FROM auth_requests WHERE id = ?", id,
	).Scan(&r.ID, &r.Token, &r.AuthURL, &r.MachineInfo, &r.Status, &r.AuthCode, &r.Error, &r.CreatedAt, &r.ResolvedAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (s *Store) ApproveAuthRequest(id int64, authCode string) error {
	_, err := s.db.Exec(
		"UPDATE auth_requests SET status = 'approved', auth_code = ?, resolved_at = ? WHERE id = ? AND status = 'pending'",
		authCode, time.Now().UTC().Format(time.RFC3339), id,
	)
	return err
}

func (s *Store) FailAuthRequest(id int64, errMsg string) error {
	_, err := s.db.Exec(
		"UPDATE auth_requests SET status = 'failed', error = ?, resolved_at = ? WHERE id = ? AND status = 'pending'",
		errMsg, time.Now().UTC().Format(time.RFC3339), id,
	)
	return err
}

func (s *Store) ExpireOldAuthRequests() {
	s.db.Exec(
		"UPDATE auth_requests SET status = 'expired' WHERE status = 'pending' AND created_at < datetime('now', '-60 minutes')",
	)
}

func (s *Store) Close() error {
	return s.db.Close()
}
