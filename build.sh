#!/usr/bin/env bash
# build.sh — 将 src/ 拼接成单文件 cac
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJ_DIR/src"
OUT="$PROJ_DIR/cac"

# 拼接顺序
SOURCES=(
    utils.sh
    dns_block.sh
    mtls.sh
    templates.sh
    cmd_setup.sh
    cmd_env.sh
    cmd_relay.sh
    cmd_check.sh
    cmd_stop.sh
    cmd_docker.sh
    cmd_delete.sh
    cmd_version.sh
    cmd_help.sh
    main.sh
)

{
    echo '#!/usr/bin/env bash'
    echo '# cac — Claude Anti-fingerprint Cloak'
    echo '# 由 build.sh 从 src/ 构建，勿直接编辑本文件'
    echo 'set -euo pipefail'
    echo
    echo 'CAC_DIR="$HOME/.cac"'
    echo 'ENVS_DIR="$CAC_DIR/envs"'
    echo

    for file in "${SOURCES[@]}"; do
        src="$SRC_DIR/$file"
        if [[ ! -f "$src" ]]; then
            echo "错误：找不到 $src" >&2; exit 1
        fi
        # 仅跳过源文件自身首行 shebang（保留 heredoc 内的 shebang）
        echo "# ━━━ $file ━━━"
        awk 'NR==1 && /^#!\// {next} {print}' "$src"
        echo
    done
} > "$OUT"

chmod +x "$OUT"

cp src/fingerprint-hook.js fingerprint-hook.js 2>/dev/null || true
cp src/relay.js relay.js 2>/dev/null || true

echo "✓ 构建完成 → ${OUT} ($(wc -l < "${OUT}") 行)"
