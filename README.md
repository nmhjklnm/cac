<div align="center">

# cac — Claude Code Cloak

**Privacy cloak + CLI proxy for Claude Code. Zero source invasion.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey.svg)]()

</div>

---

## What it does

Claude Code reads device identifiers at runtime (hardware UUID, MAC address, hostname, etc.). **cac** intercepts all `claude` invocations via a wrapper, providing:

- **Privacy isolation** — each profile has independent device fingerprints
- **Process-level proxy** — direct connection to remote proxy, no local proxy tools needed
- **Telemetry blocking** — multi-layer DNS + env var + fetch interception

## Features

| Feature | How |
|:---|:---|
| Hardware UUID isolation | macOS `ioreg` / Linux `machine-id` / Windows `wmic`+`reg` interception |
| Hostname / MAC isolation | Shell shim + Node.js `os.hostname()` / `os.networkInterfaces()` hook |
| Node.js fingerprint hook | `fingerprint-hook.js` via `NODE_OPTIONS --require` |
| Telemetry blocking | DNS guard + 12 env vars + fetch interception + HOSTALIASES |
| mTLS client certificates | Self-signed CA + per-profile client certs |
| Process-level proxy | HTTP / HTTPS / SOCKS5, auto-detect protocol |
| Relay bypass TUN | Local TCP relay on 127.0.0.1, bypasses Clash/Surge TUN mode |
| Pre-launch check | Proxy connectivity + TUN conflict detection |

## Install

```bash
# npm
npm install -g claude-cac
cac setup

# or manual
git clone https://github.com/nmhjklnm/cac.git
cd cac && bash install.sh
```

<details>
<summary>Windows</summary>

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
cac add us1 1.2.3.4:1080:username:password    # add profile
cac us1                                         # switch
cac check                                       # verify
claude                                          # run (first time: /login)
```

## Commands

| Command | Description |
|:---|:---|
| `cac setup` | First-time setup |
| `cac add <name> <proxy>` | Add profile (`host:port:user:pass` or full URL) |
| `cac <name>` | Switch to profile |
| `cac ls` | List profiles |
| `cac check` | Verify proxy, fingerprint, TUN conflicts |
| `cac relay on [--route]` | Enable local relay (bypass TUN) |
| `cac relay off` | Disable relay |
| `cac stop` / `cac -c` | Pause / resume protection |
| `cac delete` | Uninstall, remove all data |
| `cac -v` | Show version |

## How it works

```
              cac wrapper (process-level, zero source invasion)
              ┌─────────────────────────────────────────┐
  claude ────►│  Env vars: 12-layer telemetry kill       │
              │  NODE_OPTIONS: DNS guard + fingerprint   │──► Remote proxy ──► Anthropic API
              │  PATH: device fingerprint shims          │
              │  mTLS: client cert injection             │
              └─────────────────────────────────────────┘
```

When TUN-mode proxy software (Clash, Surge, etc.) causes conflicts, enable **relay mode**:

```
  claude ──► cac wrapper ──► relay (127.0.0.1:17890) ──► remote proxy ──► API
                              ↑ loopback bypasses TUN
```

## File layout

```
~/.cac/
├── bin/claude              # wrapper
├── shim-bin/               # ioreg / hostname / ifconfig / cat shims
├── fingerprint-hook.js     # Node.js fingerprint interception
├── relay.js                # TCP relay server
├── cac-dns-guard.js        # DNS + mTLS + fetch interception
├── current                 # active profile name
└── envs/<name>/
    ├── proxy               # proxy URL
    ├── uuid / stable_id    # isolated identity
    ├── hostname / mac_address / machine_id
    ├── client_cert.pem     # mTLS cert
    └── relay               # "on" if relay enabled
```

## Notes

- **TUN conflicts**: Use `cac relay on` or add DIRECT rule for proxy IP in your TUN software. `cac check` detects this automatically.
- **API env vars**: Wrapper clears `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` on startup.
- **IPv6**: Recommend disabling IPv6 system-wide to prevent real address exposure.

## License

MIT
