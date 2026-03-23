# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

The `cac` binary in the repo root is the built artifact — a single concatenated shell script. **Never edit `cac` directly.**

```bash
# Rebuild after editing src/
bash build.sh
```

`build.sh` concatenates `src/*.sh` files in a fixed order into the single `cac` file, stripping shebangs and prepending the global header. It also copies `fingerprint-hook.js` and `relay.js` to the repo root.

## Architecture

This is a pure Bash project with Node.js runtime components. The `src/` directory is the source of truth:

| File | Role |
|---|---|
| `src/utils.sh` | Shared helpers: color output, UUID/MAC/hostname generators, proxy parsing, `_auto_detect_proxy`, `_update_statsig`, `_update_claude_json_user_id` |
| `src/dns_block.sh` | Writes `cac-dns-guard.js` (DNS/fetch telemetry interception, health check bypass via NO_PROXY) and `blocked_hosts` |
| `src/mtls.sh` | mTLS CA + client cert generation, health bypass cert (`hb_cert.pem` for api.anthropic.com) |
| `src/templates.sh` | Writes runtime files to `~/.cac/`: the claude wrapper (`_write_wrapper`) and all shim scripts (`ioreg`, `cat`, `hostname`, `ifconfig`) |
| `src/fingerprint-hook.js` | Node.js preload hook: monkey-patches `os.hostname()`, `os.networkInterfaces()`, `os.userInfo()`, `fs.readFileSync/readFile` |
| `src/relay.js` | TCP relay server: local HTTP proxy that forwards to upstream HTTP/SOCKS5 proxy (bypass TUN) |
| `src/cmd_setup.sh` | `cac setup` — detects real claude, writes wrapper + shims, deploys JS files and certs |
| `src/cmd_env.sh` | `cac add / switch / ls` — creates/activates profiles under `~/.cac/envs/<name>/` |
| `src/cmd_relay.sh` | `cac relay on/off/status` — relay lifecycle, route management, TUN detection |
| `src/cmd_check.sh` | `cac check` — verifies proxy, security protections, relay status, TUN conflicts |
| `src/cmd_stop.sh` | `cac stop / -c` — toggles `~/.cac/stopped` flag |
| `src/cmd_help.sh` | `cac help` output |
| `src/main.sh` | Entry point: argument dispatch (`case "$1"`) |

Build order: utils → dns_block → mtls → templates → cmd_setup → cmd_env → cmd_relay → cmd_check → cmd_stop → cmd_help → main

## Key Design Points

**Wrapper mechanism**: `cac setup` writes `~/.cac/bin/claude` which takes priority in PATH over the real `claude` binary. The wrapper:
1. Pre-flight TCP check (proxy reachable?)
2. Injects proxy env vars (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`)
3. Starts health check bypass server (local HTTPS on port 443 + `/etc/hosts` + `NO_PROXY`)
4. Prepends `~/.cac/shim-bin` to PATH
5. Sets `NODE_OPTIONS --require` for fingerprint-hook.js and cac-dns-guard.js
6. Sets 12-layer telemetry kill env vars
7. Optionally starts relay (if enabled)
8. Launches real claude binary

**Health check bypass**: Claude Code's interactive startup pings `api.anthropic.com/api/hello`. Through a proxy, Cloudflare returns 403 (Node.js TLS fingerprint rejected). The wrapper starts a local HTTPS server with a cert signed by cac's CA (trusted via `NODE_EXTRA_CA_CERTS`), adds `api.anthropic.com` to `/etc/hosts` pointing to `127.0.0.1`, and adds it to `NO_PROXY` via dns-guard.js. Health check goes to local server → instant 200. After 3 seconds, `NO_PROXY` is restored so API calls go through the real proxy.

**Shim commands**: Platform-specific shims intercept identity-revealing commands:
- macOS: `ioreg` shim returns fake `IOPlatformUUID`
- Linux: `cat` shim intercepts `/etc/machine-id` and `/var/lib/dbus/machine-id`
- Both: `hostname` and `ifconfig` shims

**Node.js fingerprint hook**: Injected via `NODE_OPTIONS --require`, monkey-patches `os.hostname()`, `os.networkInterfaces()`, `os.userInfo()`, and `fs.readFileSync/readFile` for `/etc/machine-id`. On Windows, also patches `child_process.execSync/exec/execFileSync` for `wmic`/`reg` commands.

**Relay**: Local TCP proxy (`relay.js`) on `127.0.0.1` that forwards to upstream HTTP/SOCKS5 proxy. Bypasses TUN-mode proxy software (Clash, Surge) since loopback traffic isn't intercepted by TUN. Managed via `cac relay on/off`.

**Profile data** lives in `~/.cac/envs/<name>/` — plain text files (one value per file): `proxy`, `uuid`, `machine_id`, `hostname`, `mac_address`, `stable_id`, `user_id`, `tz`, `lang`, `relay`.

**Global state files**: `~/.cac/current` (active profile name), `~/.cac/stopped` (presence = protection disabled), `~/.cac/real_claude` (path to real binary).

## Runtime Dependencies

- `bash`, `uuidgen`, `python3`, `curl`, `openssl` — required on target system
- `node` — required (Claude Code itself is Node.js)
- `ioreg` — macOS only (intercepted by shim)
- Root access — needed for health check bypass (`/etc/hosts` + port 443)
- PATH ordering is critical: `~/.cac/bin` must precede the real `claude`; `~/.cac/shim-bin` is prepended inside the wrapper at runtime only
