#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    [[ "$actual" == "$expected" ]] && pass "$label" || fail "$label (expected '$expected', got '$actual')"
}

assert_file() {
    local path="$1" label="$2"
    [[ -e "$path" ]] && pass "$label" || fail "$label"
}

assert_no_file() {
    local path="$1" label="$2"
    [[ ! -e "$path" ]] && pass "$label" || fail "$label"
}

echo "════════════════════════════════════════════════════════"
echo "  Claude auto-update smoke test"
echo "════════════════════════════════════════════════════════"

source "$PROJECT_DIR/src/utils.sh"
source "$PROJECT_DIR/src/cmd_claude.sh"
source "$PROJECT_DIR/src/cmd_env.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export CAC_DIR="$tmpdir/.cac"
export ENVS_DIR="$CAC_DIR/envs"
export VERSIONS_DIR="$CAC_DIR/versions"
mkdir -p "$ENVS_DIR" "$VERSIONS_DIR"

_require_setup() {
    mkdir -p "$CAC_DIR" "$ENVS_DIR" "$VERSIONS_DIR"
}

_make_version() {
    local ver="$1" bin
    bin=$(_version_binary "$ver")
    mkdir -p "$(dirname "$bin")"
    printf '#!/usr/bin/env bash\n' > "$bin"
    chmod +x "$bin"
    printf '%s\n' "$ver" > "$VERSIONS_DIR/$ver/.version"
}

_make_env() {
    local name="$1" ver="${2:-}"
    mkdir -p "$ENVS_DIR/$name"
    [[ -n "$ver" ]] && printf '%s\n' "$ver" > "$ENVS_DIR/$name/version"
}

_download_count() {
    [[ -f "$CAC_DIR/downloads" ]] && wc -l < "$CAC_DIR/downloads" | tr -d '[:space:]' || echo 0
}

_fetch_latest_version() {
    [[ "${TEST_FETCH_FAIL:-0}" == "1" ]] && return 1
    printf '%s\n' "${TEST_LATEST:-2.0.0}"
}

_download_version() {
    local ver="$1"
    [[ "${TEST_DOWNLOAD_FAIL:-0}" == "1" ]] && return 1
    printf '%s\n' "$ver" >> "$CAC_DIR/downloads"
    _make_version "$ver"
}

_make_env alpha 1.0.0
TEST_LATEST=2.0.0 TEST_FETCH_FAIL=0 TEST_DOWNLOAD_FAIL=0 _claude_cmd_update alpha >/dev/null 2>&1
assert_eq "$(_read "$ENVS_DIR/alpha/version")" "2.0.0" "manual update pins remote latest"
assert_file "$(_version_binary "2.0.0")" "manual update downloads missing version"
assert_eq "$(_download_count)" "1" "manual update downloaded once"

TEST_LATEST=2.0.0 TEST_FETCH_FAIL=0 TEST_DOWNLOAD_FAIL=0 _claude_cmd_update alpha >/dev/null 2>&1
assert_eq "$(_download_count)" "1" "manual update skips download when already current"

_make_env beta 1.0.0
printf 'beta\n' > "$CAC_DIR/current"
TEST_LATEST=2.1.0 TEST_FETCH_FAIL=0 TEST_DOWNLOAD_FAIL=0 _claude_cmd_update >/dev/null 2>&1
assert_eq "$(_read "$ENVS_DIR/beta/version")" "2.1.0" "manual update targets active env"

rm -f "$CAC_DIR/current"
if ( TEST_LATEST=2.2.0 TEST_FETCH_FAIL=0 TEST_DOWNLOAD_FAIL=0 _claude_cmd_update >/dev/null 2>&1 ); then
    fail "manual update without active env fails"
else
    pass "manual update without active env fails"
fi

_env_cmd_set alpha autoupdate on >/dev/null
assert_eq "$(_read "$ENVS_DIR/alpha/claude_auto_update")" "on" "env set autoupdate on writes flag"
_env_cmd_set alpha autoupdate off >/dev/null
assert_no_file "$ENVS_DIR/alpha/claude_auto_update" "env set autoupdate off removes flag"

printf '1.0.0\n' > "$ENVS_DIR/alpha/version"
printf 'on\n' > "$ENVS_DIR/alpha/claude_auto_update"
printf 'beta\n' > "$CAC_DIR/current"
TEST_LATEST=3.0.0 TEST_FETCH_FAIL=1 TEST_DOWNLOAD_FAIL=0 _env_cmd_activate alpha >/dev/null 2>&1
assert_eq "$(_read "$CAC_DIR/current")" "alpha" "activation continues when latest lookup fails"
assert_eq "$(_read "$ENVS_DIR/alpha/version")" "1.0.0" "failed latest lookup does not repin env"

_claude_prompt_yes_no() {
    local prompt="$1" default="$2" answer
    printf '%s [%s]\n' "$prompt" "$default" >> "$CAC_DIR/prompts"
    answer="${TEST_PROMPT_ANSWERS%%,*}"
    if [[ "$TEST_PROMPT_ANSWERS" == *","* ]]; then
        TEST_PROMPT_ANSWERS="${TEST_PROMPT_ANSWERS#*,}"
    else
        TEST_PROMPT_ANSWERS=""
    fi
    case "$answer" in
        yes) return 0 ;;
        no) return 1 ;;
        *) return 2 ;;
    esac
}

printf '1.0.0\n' > "$ENVS_DIR/alpha/version"
printf 'beta\n' > "$CAC_DIR/current"
if ( TEST_LATEST=3.0.0 TEST_FETCH_FAIL=0 TEST_DOWNLOAD_FAIL=1 TEST_PROMPT_ANSWERS="yes,no" _env_cmd_activate alpha >/dev/null 2>&1 ); then
    fail "activation can fail after update failure fallback"
else
    pass "activation can fail after update failure fallback"
fi
assert_eq "$(_read "$CAC_DIR/current")" "beta" "failed activation preserves previous env"

TEST_LATEST=3.0.0 TEST_FETCH_FAIL=0 TEST_DOWNLOAD_FAIL=1 TEST_PROMPT_ANSWERS="yes,yes" _env_cmd_activate alpha >/dev/null 2>&1
assert_eq "$(_read "$CAC_DIR/current")" "alpha" "fallback continue completes activation"
assert_eq "$(_read "$ENVS_DIR/alpha/version")" "1.0.0" "fallback continue keeps current pinned version"

_make_version 1.0.0
_make_version 2.1.0
_make_version 9.0.0
_make_version 9.1.0
printf '1.0.0\n' > "$ENVS_DIR/alpha/version"
printf '2.1.0\n' > "$ENVS_DIR/beta/version"

_claude_cmd_prune > "$CAC_DIR/prune.log"
grep -q '9.0.0' "$CAC_DIR/prune.log" && pass "prune lists unused versions" || fail "prune lists unused versions"
assert_file "$VERSIONS_DIR/9.0.0" "prune without --yes keeps unused version"

_claude_cmd_prune --yes >/dev/null
assert_no_file "$VERSIONS_DIR/9.0.0" "prune --yes removes unused version"
assert_no_file "$VERSIONS_DIR/9.1.0" "prune --yes removes all unused versions"
assert_file "$VERSIONS_DIR/1.0.0" "prune --yes keeps used version"
assert_file "$VERSIONS_DIR/2.1.0" "prune --yes keeps second used version"

echo
echo "════════════════════════════════════════════════════════"
echo "  Result: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
