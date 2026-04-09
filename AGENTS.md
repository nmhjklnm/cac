# Repository Guidelines

## Project Structure & Module Organization
`src/` contains the canonical implementation: modular Bash commands such as `cmd_env.sh`, shared helpers in `utils.sh`, and runtime JS hooks in `fingerprint-hook.js` and `relay.js`. `build.sh` concatenates these sources into the generated root executable `cac`; do not edit `cac` directly. `scripts/postinstall.js` handles npm install-time setup and migration. `tests/` contains shell smoke tests (`test-*.sh`). `docker/` holds container assets, and `docs/` stores user-facing documentation, including Windows-specific guides.

## Build, Test, and Development Commands
Use Node.js 14+ and Bash; Windows contributors should run shell tests from Git Bash.

```bash
bash build.sh
shellcheck -s bash -S warning src/utils.sh src/cmd_*.sh src/dns_block.sh src/mtls.sh src/templates.sh src/main.sh build.sh
node --check src/relay.js
node --check src/fingerprint-hook.js
bash tests/test-cmd-entry.sh
bash tests/test-windows.sh
```

`bash build.sh` regenerates `cac`, `relay.js`, `fingerprint-hook.js`, and `cac-dns-guard.js`. Run it after every `src/` change and commit the rebuilt `cac` with the source edit.

## Coding Style & Naming Conventions
Follow existing Bash style: `#!/usr/bin/env bash`, `set -euo pipefail`, small helper functions, and 4-space indentation inside blocks. Name command modules `cmd_<topic>.sh`; internal helpers use `_snake_case`. Keep comments brief and operational. For JS, match the current CommonJS/Node-14-compatible style: `var`, semicolons, and minimal syntax. Prefer extending existing files over adding new entrypoints unless the command surface changes.

## Testing Guidelines
There is no formal coverage gate, but every change should pass the shell and JS checks above. Add or update shell smoke tests in `tests/test-*.sh` when behavior changes, especially for Windows wrappers, path handling, or generated files. If you touch `src/templates.sh`, `cac.cmd`, or install flows, run both test scripts.

## Commit & Pull Request Guidelines
Recent history uses Conventional Commit prefixes such as `fix:`, `feat(utils):`, and `test:`. Keep subjects imperative and scoped when useful. For pull requests targeting `master`, include:

- a short description of the behavior change
- the commands you ran to validate it
- any platform coverage (`macOS`, `Linux`, `Windows`)
- confirmation that `bash build.sh` was run and the generated `cac` is included

Screenshots are only needed for documentation or docs-site changes.
