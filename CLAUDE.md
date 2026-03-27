# CLAUDE.md

## Build & Release

```bash
bash build.sh          # src/*.sh → single `cac` file (never edit cac directly)
```

Release flow:
1. Bump `CAC_VERSION` in `src/utils.sh`
2. `bash build.sh`
3. Commit & push to master
4. `git tag v1.2.0 && git push origin v1.2.0`
5. CI auto-syncs version to `package.json` + `src/utils.sh`, runs `build.sh`, then `npm publish`

## Source Files

Build order matters (concatenated into single file):

```
utils.sh → dns_block.sh → mtls.sh → templates.sh → cmd_setup.sh → cmd_env.sh →
cmd_relay.sh → cmd_check.sh → cmd_stop.sh → cmd_claude.sh → cmd_self.sh →
cmd_docker.sh → cmd_delete.sh → cmd_version.sh → cmd_help.sh → main.sh
```

Key files:
- `cmd_setup.sh` — `_ensure_initialized()` auto-bootstrap (no user-facing command)
- `cmd_claude.sh` — `cac claude install/ls/pin/uninstall` (version management)
- `cmd_env.sh` — `cac env create/ls/rm/activate/deactivate` (environment management)
- `cmd_self.sh` — `cac self update/delete`
- `templates.sh` — wrapper (`~/.cac/bin/claude`) + shim scripts
- `dns_block.sh` — `cac-dns-guard.js`: DNS telemetry blocking + health check bypass + mTLS injection
- `utils.sh` — `CAC_VERSION`, color helpers, UUID generators, version resolvers

## Command Structure

```
cac claude   install | ls | pin | uninstall      # version management
cac env      create | ls | rm | activate |       # environment management
             deactivate | check
cac self     update | delete                     # self-management
cac docker   setup | start | enter | ...         # containerized mode
cac <name>                                       # shortcut for env activate
```

## Key Design

**Proxy is optional.** `-p` flag on `env create`. Without it: fingerprint isolation + telemetry blocking only. `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL` preserved when no proxy; cleared when proxy is set (force OAuth).

**CLAUDE_CONFIG_DIR** — each env gets `~/.cac/envs/<name>/.claude/`, set via wrapper. Claude Code writes all config (`.credentials.json`, sessions, settings) there.

**Health check bypass** — Cloudflare blocks Node.js TLS fingerprint (JA3/JA4) → 403 on `api.anthropic.com/api/hello`. Bypassed in `dns-guard.js` by intercepting `https.request`/`fetch` for that URL and returning fake 200 in-process. No network traffic, no `/etc/hosts`, no root needed.

**Auto-relay** — TUN interfaces auto-detected (`tun*`/`utun*`). When proxy + TUN both present, relay starts automatically (loopback bypasses TUN).

**Auto-bootstrap** — `_ensure_initialized` runs silently on first command. No manual setup step exists.

## Runtime Data

```
~/.cac/
├── versions/<ver>/claude    # managed binaries
├── bin/claude               # wrapper (must be first in PATH)
├── shim-bin/                # ioreg/hostname/ifconfig/cat shims
├── envs/<name>/
│   ├── .claude/             # CLAUDE_CONFIG_DIR (isolated)
│   ├── proxy                # optional
│   ├── version              # pinned claude version
│   └── uuid, hostname, mac_address, machine_id, stable_id
├── current                  # active env name
└── real_claude              # path to system claude binary
```

## Docs

Mintlify site at `docs/`, deployed to `cac.nextmind.space/docs`. Bilingual (EN + ZH under `docs/zh/`). Config in `docs/docs.json`.
