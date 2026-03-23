<div align="center">

# cac — Claude Code Cloak

**Privacy cloak + CLI proxy for Claude Code. Zero source invasion.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey.svg)]()

</div>

---

## What it does

Claude Code reads device identifiers at runtime (hardware UUID, MAC, hostname, etc.). **cac** intercepts all `claude` invocations via a wrapper, providing:

- **Privacy isolation** — each profile has independent device fingerprints
- **Process-level proxy** — direct connection to remote proxy, no local proxy tools needed
- **Telemetry blocking** — multi-layer DNS + env var + fetch interception

## Features

| Feature | How |
|:---|:---|
| Hardware UUID isolation | macOS `ioreg` / Linux `machine-id` / Windows `wmic`+`reg` shim |
| Hostname / MAC isolation | Shell shim + Node.js `os.hostname()` / `os.networkInterfaces()` hook |
| Node.js fingerprint hook | `fingerprint-hook.js` via `NODE_OPTIONS --require` |
| Telemetry blocking | DNS guard + 12 env vars + fetch interception + HOSTALIASES |
| Health check bypass | Local HTTPS server + `/etc/hosts` + `NO_PROXY`, skips Cloudflare 403 |
| mTLS client certificates | Self-signed CA + per-profile client certs |
| Process-level proxy | HTTP / HTTPS / SOCKS5, auto-detect protocol |
| Relay (bypass TUN) | Local TCP relay on 127.0.0.1, bypasses Clash/Surge TUN mode |
| Pre-launch check | Proxy connectivity + TUN conflict detection |

## Install

```bash
# npm (recommended)
npm install -g claude-cac
cac setup

# or manual
git clone https://github.com/nmhjklnm/cac.git
cd cac && bash install.sh
```

<details>
<summary>Windows (PowerShell)</summary>

```powershell
git clone https://github.com/nmhjklnm/cac.git
copy cac\cac.ps1 %USERPROFILE%\bin\
copy cac\cac.cmd %USERPROFILE%\bin\
copy cac\fingerprint-hook.js %USERPROFILE%\bin\
# Add ~/bin and ~/.cac/bin to PATH
cac setup
```

</details>

## Quick start

```bash
cac setup                                       # first-time init
cac add us1 1.2.3.4:1080:username:password      # add profile
cac us1                                          # switch
cac login                                        # first-time OAuth login
claude                                           # run Claude Code
```

## Commands

| Command | Description |
|:---|:---|
| `cac setup` | First-time setup |
| `cac add <name> <proxy>` | Add profile (`host:port:user:pass` or full URL) |
| `cac <name>` | Switch to profile |
| `cac login` | First-time OAuth login (with full cac protection) |
| `cac ls` | List profiles |
| `cac check` | Verify proxy, fingerprint, TUN conflicts |
| `cac relay on [--route]` | Enable local relay (bypass TUN) |
| `cac relay off` | Disable relay |
| `cac stop` / `cac -c` | Pause / resume protection |

## How it works

```
              cac wrapper (process-level, zero source invasion)
              ┌──────────────────────────────────────────┐
  claude ────►│  Health check bypass (local HTTPS server) │
              │  Env vars: 12-layer telemetry kill        │
              │  NODE_OPTIONS: DNS guard + fingerprint    │──► Proxy ──► Anthropic API
              │  PATH: device fingerprint shims           │
              │  mTLS: client cert injection              │
              └──────────────────────────────────────────┘
```

When TUN-mode proxy software (Clash, Surge) causes conflicts:

```
  claude ──► wrapper ──► relay (127.0.0.1:17890) ──► remote proxy ──► API
                          ↑ loopback bypasses TUN
```

## File layout

```
~/.cac/
├── bin/claude              # wrapper
├── shim-bin/               # ioreg / hostname / ifconfig / cat shims
├── fingerprint-hook.js     # Node.js fingerprint interception
├── relay.js                # TCP relay server
├── cac-dns-guard.js        # DNS + fetch telemetry interception
├── ca/                     # self-signed CA + health bypass cert
│   ├── ca_cert.pem / ca_key.pem
│   └── hb_cert.pem / hb_key.pem   # api.anthropic.com bypass cert
├── current                 # active profile name
└── envs/<name>/
    ├── proxy               # proxy URL
    ├── uuid / stable_id    # isolated identity
    ├── hostname / mac_address / machine_id
    ├── client_cert.pem     # mTLS cert
    └── relay               # "on" if relay enabled
```

## Notes

- **First login**: Run `cac login` after first `cac setup`. The health check is automatically bypassed.
- **TUN conflicts**: Use `cac relay on` or add DIRECT rule in your TUN software. `cac check` detects this.
- **API env vars**: Wrapper clears `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`.
- **IPv6**: Recommend disabling system-wide to prevent real address exposure.

## License

MIT
