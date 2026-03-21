#!/usr/bin/env bash
# 安装 mitmproxy 抓包方案依赖，并把启动器链接到 ~/.cac/bin/claude-mitm。
set -euo pipefail


# 统一日志输出，便于诊断安装过程中的失败点。
info() { printf '[mitm-install] %s\n' "$*"; }
warn() { printf '[mitm-install] 警告：%s\n' "$*" >&2; }
die() { printf '[mitm-install] 错误：%s\n' "$*" >&2; exit 1; }


# 解析安装脚本真实目录，兼容从软链接或不同工作目录执行。
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


# 选择一个空闲端口，避免为生成 CA 启动 mitmdump 时与其他服务冲突。
pick_free_port() {
    python3 <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}


# 首次运行 mitmdump 会自动生成 mitmproxy CA；这里通过短暂启动一次来完成初始化。
bootstrap_mitm_ca() {
    local cert_file="$1"
    local port
    local pid
    local attempt

    [[ -f "$cert_file" ]] && return 0

    port="$(pick_free_port)"
    info "首次初始化 mitmproxy CA 证书 ..."
    mitmdump --listen-host 127.0.0.1 --listen-port "$port" >/dev/null 2>&1 &
    pid=$!

    for attempt in {1..50}; do
        if [[ -f "$cert_file" ]]; then
            break
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            break
        fi

        sleep 0.2
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi

    [[ -f "$cert_file" ]] || die "mitmproxy CA 初始化失败，请手动运行 mitmdump 检查"
}


SCRIPT_DIR="$(resolve_script_dir)"
LAUNCHER="$SCRIPT_DIR/claude-mitm.sh"
CAC_DIR="$HOME/.cac"
CAC_BIN_DIR="$CAC_DIR/bin"
REPORT_ROOT="$CAC_DIR/mitm/reports"
MITM_CERT_DIR="$HOME/.mitmproxy"
MITM_CA_CERT="$MITM_CERT_DIR/mitmproxy-ca-cert.pem"
TARGET_LINK="$CAC_BIN_DIR/claude-mitm"

command -v python3 >/dev/null 2>&1 || die "未找到 python3"
[[ -f "$LAUNCHER" ]] || die "找不到启动脚本：$LAUNCHER"

if ! command -v mitmdump >/dev/null 2>&1; then
    info "未检测到 mitmproxy，准备通过 Homebrew 安装"
    command -v brew >/dev/null 2>&1 || die "未找到 brew，请先安装 Homebrew 后重试"
    brew install mitmproxy
fi

command -v mitmdump >/dev/null 2>&1 || die "mitmproxy 安装后仍不可用，请检查 PATH"

mkdir -p "$CAC_BIN_DIR" "$REPORT_ROOT" "$MITM_CERT_DIR"
bootstrap_mitm_ca "$MITM_CA_CERT"

ln -sfn "$LAUNCHER" "$TARGET_LINK"
chmod +x "$LAUNCHER"

info "安装完成"
info "启动命令：$TARGET_LINK"
info "CA 证书：$MITM_CA_CERT"
info "报告目录根路径：$REPORT_ROOT"

if [[ ! -f "$CAC_DIR/real_claude" ]]; then
    warn "尚未检测到 ~/.cac/real_claude；首次使用前请先执行 cac setup"
fi
