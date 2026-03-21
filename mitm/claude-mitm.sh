#!/usr/bin/env bash
# 通过 mitmproxy 捕获真实 claude 的网络请求，并将上游转发到当前 cac 环境的远端代理。
set -euo pipefail


# 统一输出格式，便于用户快速定位问题。
info() { printf '[claude-mitm] %s\n' "$*"; }
warn() { printf '[claude-mitm] 警告：%s\n' "$*" >&2; }
die() { printf '[claude-mitm] 错误：%s\n' "$*" >&2; exit 1; }


# 解析脚本真实目录，兼容通过 ~/.cac/bin/claude-mitm 软链接启动。
resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [[ -L "$source" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}


# 使用 Python 解析代理 URL，避免 shell 对 URL 编码、用户名密码、scheme 的处理不可靠。
parse_proxy_to_env() {
    local raw_proxy="$1"
    python3 - "$raw_proxy" <<'PY'
import shlex
import sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()
if not raw:
    raise SystemExit("空代理地址")

# 兼容历史 host:port:user:pass / host:port 两种形式。
if "://" not in raw:
    parts = raw.split(":")
    if len(parts) == 2:
        raw = f"http://{parts[0]}:{parts[1]}"
    elif len(parts) >= 4:
        host, port, user = parts[0], parts[1], parts[2]
        password = ":".join(parts[3:])
        raw = f"http://{user}:{password}@{host}:{port}"
    else:
        raise SystemExit(f"无法识别代理格式: {raw}")

parsed = urlparse(raw)
if not parsed.scheme:
    raise SystemExit(f"代理缺少 scheme: {raw}")
if not parsed.hostname:
    raise SystemExit(f"代理缺少 host: {raw}")
if parsed.port is None:
    raise SystemExit(f"代理缺少 port: {raw}")

values = {
    "PROXY_RAW": raw,
    "PROXY_SCHEME": parsed.scheme,
    "PROXY_HOST": parsed.hostname,
    "PROXY_PORT": str(parsed.port),
    "PROXY_USERNAME": parsed.username or "",
    "PROXY_PASSWORD": parsed.password or "",
    "UPSTREAM_PROXY_URL": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}",
}

for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
}


# 等待本地 mitmproxy 监听成功，避免 claude 抢先启动导致直连失败。
wait_for_local_proxy() {
    local port="$1"
    local pid="$2"
    local log_file="$3"
    local attempt

    for attempt in {1..50}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            warn "mitmdump 提前退出，以下是日志尾部："
            tail -n 50 "$log_file" 2>/dev/null || true
            return 1
        fi

        if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
            return 0
        fi

        sleep 0.2
    done

    warn "等待本地代理超时，以下是日志尾部："
    tail -n 50 "$log_file" 2>/dev/null || true
    return 1
}


SCRIPT_DIR="$(resolve_script_dir)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
ADDON_SCRIPT="$SCRIPTS_DIR/log_device_fingerprint.py"
NO_PIN_SCRIPT="$SCRIPTS_DIR/no-pin.js"

CAC_DIR="$HOME/.cac"
CURRENT_FILE="$CAC_DIR/current"
REAL_CLAUDE_FILE="$CAC_DIR/real_claude"

[[ -f "$ADDON_SCRIPT" ]] || die "找不到 mitmproxy 插件：$ADDON_SCRIPT"
[[ -f "$NO_PIN_SCRIPT" ]] || die "找不到 no-pin 预加载脚本：$NO_PIN_SCRIPT"
[[ -f "$CURRENT_FILE" ]] || die "未找到 $CURRENT_FILE，请先切换到一个 cac 环境"
[[ -f "$REAL_CLAUDE_FILE" ]] || die "未找到 $REAL_CLAUDE_FILE，请先执行 cac setup"

command -v python3 >/dev/null 2>&1 || die "未找到 python3"
command -v mitmdump >/dev/null 2>&1 || die "未找到 mitmdump，请先运行 bash mitm/install.sh"

CURRENT_ENV="$(tr -d '[:space:]' < "$CURRENT_FILE")"
[[ -n "$CURRENT_ENV" ]] || die "$CURRENT_FILE 为空，无法确定当前环境"

ENV_DIR="$CAC_DIR/envs/$CURRENT_ENV"
PROXY_FILE="$ENV_DIR/proxy"
[[ -d "$ENV_DIR" ]] || die "当前环境目录不存在：$ENV_DIR"
[[ -f "$PROXY_FILE" ]] || die "未找到代理配置：$PROXY_FILE"

REMOTE_PROXY_URL="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip())' "$PROXY_FILE")"
[[ -n "$REMOTE_PROXY_URL" ]] || die "代理配置为空：$PROXY_FILE"

eval "$(parse_proxy_to_env "$REMOTE_PROXY_URL")"

LOCAL_PORT="${CAC_MITM_PORT:-8080}"
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || die "CAC_MITM_PORT 必须是数字，当前值：$LOCAL_PORT"
(( LOCAL_PORT >= 1 && LOCAL_PORT <= 65535 )) || die "CAC_MITM_PORT 超出端口范围：$LOCAL_PORT"

REAL_CLAUDE="$(tr -d '[:space:]' < "$REAL_CLAUDE_FILE")"
[[ -x "$REAL_CLAUDE" ]] || die "真实 claude 不可执行：$REAL_CLAUDE"

CA_CERT="${CAC_MITM_CA_CERT:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}"
[[ -f "$CA_CERT" ]] || die "未找到 mitmproxy CA 证书：$CA_CERT，请先运行 bash mitm/install.sh"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
REPORT_DIR="$CAC_DIR/mitm/reports/$TIMESTAMP"
SUMMARY_FILE="$REPORT_DIR/summary.json"
HITS_FILE="$REPORT_DIR/device_hits.jsonl"
MITM_LOG="$REPORT_DIR/mitmdump.log"
mkdir -p "$REPORT_DIR"

LOCAL_PROXY_URL="http://127.0.0.1:$LOCAL_PORT"
MITM_PID=""
CLAUDE_EXIT=0

cleanup() {
    local exit_code="${CLAUDE_EXIT:-$?}"

    if [[ -n "$MITM_PID" ]] && kill -0 "$MITM_PID" 2>/dev/null; then
        kill "$MITM_PID" 2>/dev/null || true
        wait "$MITM_PID" 2>/dev/null || true
    fi

    info "报告目录：$REPORT_DIR"
    if [[ -f "$HITS_FILE" ]]; then
        info "命中明细：$HITS_FILE"
    else
        info "命中明细：暂无命中（文件尚未生成）"
    fi

    if [[ -f "$SUMMARY_FILE" ]]; then
        info "汇总报告：$SUMMARY_FILE"
    else
        warn "未生成 summary.json，请检查 $MITM_LOG"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

UPSTREAM_AUTH_ARGS=()
if [[ -n "$PROXY_USERNAME" || -n "$PROXY_PASSWORD" ]]; then
    UPSTREAM_AUTH_ARGS=(--upstream-auth "${PROXY_USERNAME}:${PROXY_PASSWORD}")
fi

info "当前环境：$CURRENT_ENV"
info "远端代理：$PROXY_HOST:$PROXY_PORT"
info "本地监听：$LOCAL_PROXY_URL"
info "报告目录：$REPORT_DIR"

CAC_MITM_REPORT_DIR="$REPORT_DIR" \
CAC_MITM_SUMMARY_PATH="$SUMMARY_FILE" \
mitmdump \
    --listen-host 127.0.0.1 \
    --listen-port "$LOCAL_PORT" \
    --mode "upstream:${UPSTREAM_PROXY_URL}" \
    "${UPSTREAM_AUTH_ARGS[@]}" \
    -s "$ADDON_SCRIPT" \
    >"$MITM_LOG" 2>&1 &
MITM_PID=$!

wait_for_local_proxy "$LOCAL_PORT" "$MITM_PID" "$MITM_LOG" || die "mitmdump 启动失败"

# 清除外部代理环境，确保下面显式注入的是本地 mitmproxy，而不是 cac wrapper 或外层 shell 残留值。
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy

export HTTP_PROXY="$LOCAL_PROXY_URL"
export HTTPS_PROXY="$LOCAL_PROXY_URL"
export ALL_PROXY="$LOCAL_PROXY_URL"
export http_proxy="$LOCAL_PROXY_URL"
export https_proxy="$LOCAL_PROXY_URL"
export all_proxy="$LOCAL_PROXY_URL"
export NODE_EXTRA_CA_CERTS="$CA_CERT"

if [[ "${CAC_BYPASS_PINNING:-0}" == "1" ]]; then
    export CAC_BYPASS_PINNING=1
    export NODE_OPTIONS="--require=$NO_PIN_SCRIPT ${NODE_OPTIONS:-}"
    info "已启用 Node 证书钉扎绕过"
fi

info "开始启动真实 claude：$REAL_CLAUDE"
set +e
"$REAL_CLAUDE" "$@"
CLAUDE_EXIT=$?
set -e

exit "$CLAUDE_EXIT"
