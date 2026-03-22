# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

The `cac` binary in the repo root is the built artifact — a single concatenated shell script. **Never edit `cac` directly.**

```bash
# Rebuild after editing src/
bash build.sh
```

`build.sh` concatenates `src/*.sh` files in a fixed order (utils → dns_block → mtls → templates → cmd_setup → cmd_env → cmd_check → cmd_stop → cmd_help → main) into the single `cac` file, stripping shebangs and prepending the global header. It also copies `fingerprint-hook.js` to the repo root.

## Architecture

This is a pure Bash project. The `src/` directory is the source of truth:

| File | Role |
|---|---|
| `src/utils.sh` | Shared helpers: color output, UUID/MAC/hostname generators, proxy parsing, `_update_statsig`, `_update_claude_json_user_id` |
| `src/templates.sh` | Writes runtime files to `~/.cac/`: the claude wrapper (`_write_wrapper`) and all shim scripts (`ioreg`, `cat`, `hostname`, `ifconfig`) |
| `src/cmd_setup.sh` | `cac setup` — detects real claude, writes wrapper + platform-appropriate shims |
| `src/cmd_env.sh` | `cac add / switch / ls` — creates/activates profiles under `~/.cac/envs/<name>/` |
| `src/cmd_check.sh` | `cac check` — verifies proxy reachability and shows active profile info |
| `src/cmd_stop.sh` | `cac stop / -c` — toggles `~/.cac/stopped` flag |
| `src/cmd_help.sh` | `cac help` output |
| `src/main.sh` | Entry point: argument dispatch (`case "$1"`) |

## Key Design Points

**Wrapper mechanism**: `cac setup` writes `~/.cac/bin/claude` which takes priority in PATH over the real `claude` binary. The wrapper injects proxy env vars (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`), prepends `~/.cac/shim-bin` to PATH (so shims intercept system commands), and does a pre-flight TCP connectivity check before launching the real binary.

**Shim commands**: Platform-specific shims intercept identity-revealing commands:
- macOS: `ioreg` shim returns fake `IOPlatformUUID`
- Linux: `cat` shim intercepts `/etc/machine-id` and `/var/lib/dbus/machine-id`
- Both: `hostname` and `ifconfig` shims

**Profile data** lives in `~/.cac/envs/<name>/` — plain text files (one value per file): `proxy`, `uuid`, `machine_id`, `hostname`, `mac_address`, `stable_id`, `user_id`, `tz`, `lang`.

**Global state files**: `~/.cac/current` (active profile name), `~/.cac/stopped` (presence = protection disabled), `~/.cac/real_claude` (path to real binary).

**Identity injection on switch**: `cmd_switch` also writes `stable_id` into `~/.claude/statsig/` files and `userID` into `~/.claude.json` via `_update_statsig` / `_update_claude_json_user_id`.

## Runtime Dependencies

- `bash`, `uuidgen`, `python3`, `curl` — required on target system
- `ioreg` — macOS only (intercepted by shim)
- PATH ordering is critical: `~/.cac/bin` must precede the real `claude`; `~/.cac/shim-bin` is prepended inside the wrapper at runtime only
