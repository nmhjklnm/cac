package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/imroc/req/v3"
)

const (
	oauthClientID    = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	oauthRedirectURI = "https://platform.claude.com/oauth/code/callback"
	// Internal API scope (org:create_api_key not supported in server-side API calls)
	oauthScope    = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
	oauthTokenURL = "https://platform.claude.com/v1/oauth/token"
)

// ── Browser Persona ─────────────────────────────────────────────
// Deterministically derived from token hash so that:
//   - same token → same fingerprint every time
//   - different tokens → different fingerprints

type browserPersona struct {
	ChromeMajor    int    // 130..136
	Platform       string // "macOS", "Windows", "Linux"
	SecChPlatform  string // quoted: `"macOS"`, `"Windows"`, `"Linux"`
	AcceptLanguage string
	SecChUa        string
}

// Pool of realistic values
var (
	chromeVersions = []int{131, 132, 133, 134, 135, 136}
	platforms      = []struct {
		name  string
		secCh string
	}{
		{"macOS", `"macOS"`},
		{"Windows", `"Windows"`},
		{"macOS", `"macOS"`}, // weighted: macOS more common among Claude users
		{"Windows", `"Windows"`},
		{"Linux", `"Linux"`},
	}
	acceptLanguages = []string{
		"en-US,en;q=0.9",
		"en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
		"en-GB,en;q=0.9,en-US;q=0.8",
		"en-US,en;q=0.9,ja;q=0.8",
		"en-US,en;q=0.9,de;q=0.8",
		"en-US,en;q=0.9,fr;q=0.8",
		"en-US,en;q=0.9,ko;q=0.8",
		"en-US,en;q=0.9,es;q=0.8",
	}
)

// derivePersona generates a stable browser persona from a seed string (token or sk).
func derivePersona(seed string) browserPersona {
	h := sha256.Sum256([]byte("anideaai-persona:" + seed))

	// Use different bytes of the hash to pick each attribute
	chromeVer := chromeVersions[int(h[0])%len(chromeVersions)]
	plat := platforms[int(h[1])%len(platforms)]
	lang := acceptLanguages[int(h[2])%len(acceptLanguages)]

	// Build Sec-Ch-Ua with the chosen Chrome version
	// Not.A/Brand version varies by Chrome version (real behavior)
	brandVersion := 8 + int(h[3])%16 // 8..23
	secChUa := fmt.Sprintf(
		`"Chromium";v="%d", "Google Chrome";v="%d", "Not_A Brand";v="%d"`,
		chromeVer, chromeVer, brandVersion,
	)

	return browserPersona{
		ChromeMajor:    chromeVer,
		Platform:       plat.name,
		SecChPlatform:  plat.secCh,
		AcceptLanguage: lang,
		SecChUa:        secChUa,
	}
}

// ── OAuth Handler ───────────────────────────────────────────────

type OAuthHandler struct {
	auth  *Authenticator
	store *Store
}

func NewOAuthHandler(auth *Authenticator, store *Store) *OAuthHandler {
	return &OAuthHandler{auth: auth, store: store}
}

func truncToken(t string) string {
	if len(t) <= 6 {
		return t
	}
	return t[:6]
}

func (h *OAuthHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_, token := h.auth.Authenticate(r)
	if token == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusProxyAuthRequired)
		json.NewEncoder(w).Encode(map[string]string{"error": "authentication required"})
		return
	}

	sk, backend, err := h.store.GetTokenInfo(token)
	if err != nil {
		jsonError(w, "token not found", http.StatusNotFound)
		return
	}
	if sk == "" {
		jsonError(w, "no sessionKey configured for this token", http.StatusBadRequest)
		return
	}

	proxyURL, _ := url.Parse(normalizeBackend(backend))
	// Derive a stable persona from the token so each account has a unique fingerprint
	persona := derivePersona(token)
	log.Printf("[OAUTH] token %s persona: Chrome/%d %s lang=%s",
		truncToken(token), persona.ChromeMajor, persona.Platform, persona.AcceptLanguage)

	result, err := doOAuthFlow(sk, proxyURL, &persona)
	if err != nil {
		log.Printf("[OAUTH] failed for token %s: %v", truncToken(token), err)
		jsonError(w, err.Error(), http.StatusBadGateway)
		return
	}

	log.Printf("[OAUTH] success for token %s", truncToken(token))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

type OAuthResult struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

func doOAuthFlow(sk string, proxyURL *url.URL, persona *browserPersona) (*OAuthResult, error) {
	client := makeBrowserClient(proxyURL)

	// Step 1: Get org UUID
	orgUUID, err := getOrgUUID(client, persona, sk)
	if err != nil {
		return nil, fmt.Errorf("get org: %w", err)
	}

	// Step 2: PKCE + get auth code
	verifier, challenge := generatePKCE()
	state := generateRandomState()
	code, err := getAuthCode(client, persona, sk, orgUUID, challenge, state)
	if err != nil {
		return nil, fmt.Errorf("get auth code: %w", err)
	}

	// Step 3: Exchange code for token
	result, err := exchangeToken(client, persona, code, verifier, state)
	if err != nil {
		return nil, fmt.Errorf("exchange token: %w", err)
	}

	return result, nil
}

// makeBrowserClient creates an HTTP client with Chrome TLS fingerprint.
// The TLS-level fingerprint (JA3/JA4, cipher suites, HTTP/2 SETTINGS) is always
// Chrome-like via ImpersonateChrome(); per-account differentiation happens at
// the HTTP header level via browserPersona.
func makeBrowserClient(proxyURL *url.URL) *req.Client {
	client := req.C().
		ImpersonateChrome().
		SetTimeout(60 * time.Second).
		SetCookieJar(nil).
		SetRedirectPolicy(req.NoRedirectPolicy())

	if proxyURL != nil {
		client.SetProxyURL(proxyURL.String())
	}

	return client
}

// applyPersonaHeaders sets per-account browser headers on a request.
func applyPersonaHeaders(r *req.Request, p *browserPersona) *req.Request {
	return r.
		SetHeader("Accept", "application/json, text/plain, */*").
		SetHeader("Accept-Language", p.AcceptLanguage).
		SetHeader("Cache-Control", "no-cache").
		SetHeader("Pragma", "no-cache").
		SetHeader("Sec-Ch-Ua", p.SecChUa).
		SetHeader("Sec-Ch-Ua-Mobile", "?0").
		SetHeader("Sec-Ch-Ua-Platform", p.SecChPlatform).
		SetHeader("Sec-Fetch-Dest", "empty").
		SetHeader("Sec-Fetch-Mode", "cors").
		SetHeader("Sec-Fetch-Site", "same-origin").
		SetHeader("Origin", "https://claude.ai").
		SetHeader("Referer", "https://claude.ai/")
}

func sessionCookie(sk string) *http.Cookie {
	return &http.Cookie{
		Name:     "sessionKey",
		Value:    sk,
		Domain:   "claude.ai",
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
	}
}

func getOrgUUID(client *req.Client, persona *browserPersona, sk string) (string, error) {
	var orgs []struct {
		UUID      string  `json:"uuid"`
		RavenType *string `json:"raven_type"`
	}

	log.Printf("[OAUTH] Step 1: Getting organization UUID")

	r := client.R().
		SetCookies(sessionCookie(sk)).
		SetSuccessResult(&orgs)
	applyPersonaHeaders(r, persona)

	resp, err := r.Get("https://claude.ai/api/organizations")
	if err != nil {
		return "", fmt.Errorf("request failed: %w", err)
	}
	if !resp.IsSuccessState() {
		body := resp.String()
		if len(body) > 200 {
			body = body[:200]
		}
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, body)
	}

	if len(orgs) == 0 {
		return "", fmt.Errorf("no organizations found")
	}

	for _, o := range orgs {
		if o.RavenType != nil && *o.RavenType == "team" {
			log.Printf("[OAUTH] Step 1 SUCCESS - team org: %s", o.UUID)
			return o.UUID, nil
		}
	}
	log.Printf("[OAUTH] Step 1 SUCCESS - org: %s", orgs[0].UUID)
	return orgs[0].UUID, nil
}

func generatePKCE() (verifier, challenge string) {
	const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	const targetLen = 32
	charsetLen := len(charset)
	limit := 256 - (256 % charsetLen)

	result := make([]byte, 0, targetLen)
	randBuf := make([]byte, targetLen*2)

	for len(result) < targetLen {
		rand.Read(randBuf)
		for _, b := range randBuf {
			if int(b) < limit {
				result = append(result, charset[int(b)%charsetLen])
				if len(result) >= targetLen {
					break
				}
			}
		}
	}

	verifier = base64.RawURLEncoding.EncodeToString(result)
	h := sha256.Sum256([]byte(verifier))
	challenge = base64.RawURLEncoding.EncodeToString(h[:])
	return
}

func getAuthCode(client *req.Client, persona *browserPersona, sk, orgUUID, challenge, state string) (string, error) {
	reqBody := map[string]any{
		"response_type":         "code",
		"client_id":             oauthClientID,
		"organization_uuid":     orgUUID,
		"redirect_uri":          oauthRedirectURI,
		"scope":                 oauthScope,
		"state":                 state,
		"code_challenge":        challenge,
		"code_challenge_method": "S256",
	}

	authURL := fmt.Sprintf("https://claude.ai/v1/oauth/%s/authorize", orgUUID)
	log.Printf("[OAUTH] Step 2: Getting auth code from %s", authURL)

	var result struct {
		RedirectURI string `json:"redirect_uri"`
		Code        string `json:"code"`
	}

	r := client.R().
		SetCookies(sessionCookie(sk)).
		SetHeader("Content-Type", "application/json").
		SetBody(reqBody).
		SetSuccessResult(&result)
	applyPersonaHeaders(r, persona)

	resp, err := r.Post(authURL)
	if err != nil {
		return "", fmt.Errorf("request failed: %w", err)
	}
	if !resp.IsSuccessState() {
		body := resp.String()
		if len(body) > 200 {
			body = body[:200]
		}
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, body)
	}

	if result.Code != "" {
		log.Printf("[OAUTH] Step 2 SUCCESS - got direct code")
		return result.Code, nil
	}

	if result.RedirectURI != "" {
		u, err := url.Parse(result.RedirectURI)
		if err == nil {
			code := u.Query().Get("code")
			responseState := u.Query().Get("state")
			if code != "" {
				fullCode := code
				if responseState != "" {
					fullCode = code + "#" + responseState
				}
				log.Printf("[OAUTH] Step 2 SUCCESS - got code from redirect")
				return fullCode, nil
			}
		}
	}

	return "", fmt.Errorf("no authorization code in response")
}

func exchangeToken(client *req.Client, persona *browserPersona, code, verifier, state string) (*OAuthResult, error) {
	authCode := code
	codeState := ""
	if idx := strings.Index(code, "#"); idx != -1 {
		authCode = code[:idx]
		codeState = code[idx+1:]
	}

	reqBody := map[string]any{
		"code":          authCode,
		"grant_type":    "authorization_code",
		"client_id":     oauthClientID,
		"redirect_uri":  oauthRedirectURI,
		"code_verifier": verifier,
	}
	if codeState != "" {
		reqBody["state"] = codeState
	}

	log.Printf("[OAUTH] Step 3: Exchanging code for token")

	var tokenResp struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
	}

	// Token endpoint — use axios-like UA (matches real Claude Code client behavior)
	resp, err := client.R().
		SetHeader("Accept", "application/json, text/plain, */*").
		SetHeader("Content-Type", "application/json").
		SetHeader("User-Agent", "axios/1.8.4").
		SetBody(reqBody).
		SetSuccessResult(&tokenResp).
		Post(oauthTokenURL)

	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	if !resp.IsSuccessState() {
		body := resp.String()
		if len(body) > 200 {
			body = body[:200]
		}
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, body)
	}

	if tokenResp.AccessToken == "" {
		return nil, fmt.Errorf("empty access_token in response")
	}

	log.Printf("[OAUTH] Step 3 SUCCESS - got access token")
	return &OAuthResult{
		AccessToken:  tokenResp.AccessToken,
		RefreshToken: tokenResp.RefreshToken,
		ExpiresIn:    tokenResp.ExpiresIn,
	}, nil
}

func generateRandomState() string {
	b := make([]byte, 32)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// --- Auth Relay: client sends auth_url, server uses sk to get auth code ---

type AuthRelayHandler struct {
	auth  *Authenticator
	store *Store
}

func NewAuthRelayHandler(auth *Authenticator, store *Store) *AuthRelayHandler {
	return &AuthRelayHandler{auth: auth, store: store}
}

// ServeHTTP handles POST /api/auth-relay
// Client sends: {"auth_url": "https://claude.ai/oauth/authorize?..."}
// Server stores the request for admin approval, returns {"request_id": 123}
func (h *AuthRelayHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	_, token := h.auth.Authenticate(r)
	if token == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusProxyAuthRequired)
		json.NewEncoder(w).Encode(map[string]string{"error": "authentication required"})
		return
	}

	var body struct {
		AuthURL     string            `json:"auth_url"`
		MachineInfo map[string]string `json:"machine_info,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if body.AuthURL == "" {
		jsonError(w, "auth_url is required", http.StatusBadRequest)
		return
	}

	// Expire old pending requests
	h.store.ExpireOldAuthRequests()

	machineInfoJSON, _ := json.Marshal(body.MachineInfo)
	reqID, err := h.store.CreateAuthRequest(token, body.AuthURL, string(machineInfoJSON))
	if err != nil {
		log.Printf("[AUTH-RELAY] failed to store request for token %s: %v", truncToken(token), err)
		jsonError(w, "failed to store auth request", http.StatusInternalServerError)
		return
	}

	log.Printf("[AUTH-RELAY] request #%d stored for token %s, awaiting admin approval", reqID, truncToken(token))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"request_id": reqID})
}

// PollHandler handles GET /api/auth-relay/poll?id=X
// Client polls until admin approves or request expires
func (h *AuthRelayHandler) PollHandler(w http.ResponseWriter, r *http.Request) {
	_, token := h.auth.Authenticate(r)
	if token == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusProxyAuthRequired)
		json.NewEncoder(w).Encode(map[string]string{"error": "authentication required"})
		return
	}

	idStr := r.URL.Query().Get("id")
	id, err := fmt.Sscanf(idStr, "%d", new(int64))
	if err != nil || id == 0 {
		jsonError(w, "invalid id", http.StatusBadRequest)
		return
	}
	var reqID int64
	fmt.Sscanf(idStr, "%d", &reqID)

	req, err := h.store.GetAuthRequest(reqID)
	if err != nil {
		jsonError(w, "request not found", http.StatusNotFound)
		return
	}

	// Verify the request belongs to this token
	if req.Token != token {
		jsonError(w, "unauthorized", http.StatusForbidden)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	switch req.Status {
	case "approved":
		json.NewEncoder(w).Encode(map[string]string{"status": "approved", "code": req.AuthCode})
	case "failed":
		json.NewEncoder(w).Encode(map[string]string{"status": "failed", "error": req.Error})
	case "expired":
		json.NewEncoder(w).Encode(map[string]string{"status": "expired"})
	default:
		json.NewEncoder(w).Encode(map[string]string{"status": "pending"})
	}
}
