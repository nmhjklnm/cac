#!/usr/bin/env bash
set -euo pipefail

# ── Windows 冒烟测试 (test-windows.sh) ──────────────────
# 在 Windows Git Bash (MINGW64) 环境下运行
# Linux 环境下自动跳过 Windows 专项测试，标记 SKIP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; SKIP=0

# 检测平台
is_windows() { [[ "$(uname -s)" =~ MINGW*|MSYS*|CYGWIN* ]]; }
is_linux() { [[ "$(uname -s)" == Linux ]]; }

pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭️  $1"; }

echo "════════════════════════════════════════════════════════"
echo "  cac Windows 冒烟测试"
echo "  Platform: $(uname -s)"
echo "════════════════════════════════════════════════════════"

# source utils
source "$PROJECT_DIR/src/utils.sh" 2>/dev/null || { echo "FATAL: cannot source utils.sh"; exit 1; }
source "$PROJECT_DIR/src/cmd_claude.sh" 2>/dev/null || { echo "FATAL: cannot source cmd_claude.sh"; exit 1; }
source "$PROJECT_DIR/src/mtls.sh" 2>/dev/null || { echo "FATAL: cannot source mtls.sh"; exit 1; }

# ── T01: 平台检测 ──
echo ""
echo "[T01] 平台检测"
p=$(_detect_platform)
if is_windows; then
    [[ "$p" =~ ^win32- ]] && pass "Windows 平台: $p" || fail "期望 win32-*, 实际: $p"
elif is_linux; then
    [[ "$p" =~ ^linux- ]] && pass "Linux 平台: $p" || fail "期望 linux-*, 实际: $p"
else
    pass "其他平台: $p"
fi

# ── T02: TCP 连通性检测 ──
echo ""
echo "[T02] TCP 连通性检测 (_tcp_check)"
if is_windows; then
    # Windows 下测试 _tcp_check 的 Node.js fallback
    node -e "const s=require('http').createServer(()=>{});s.listen(19883,'127.0.0.1',()=>console.log('READY'));setTimeout(()=>{s.close();process.exit(0)},3000);" &
    sleep 0.5
    _tcp_check 127.0.0.1 19883 && pass "开放端口可达" || fail "开放端口不可达"
    ! _tcp_check 127.0.0.1 19995 && pass "关闭端口不可达" || fail "关闭端口误报可达"
    wait
else
    skip "Windows 专项（Linux 下 _tcp_check 走原生 /dev/tcp）"
fi

# ── T03: python3 零残留 ──
echo ""
echo "[T03] python3 零残留 (src/*.sh)"
py=$(grep -rn 'python3' "$PROJECT_DIR/src/"*.sh 2>/dev/null || true)
if [[ -z "$py" ]]; then
    pass "src/*.sh 无 python3 引用"
else
    fail "python3 残留:"; echo "$py"
fi

# ── T04: /dev/tcp 仅在 utils.sh / 内联 helper ──
# templates.sh 的 wrapper 模板必须内联 _tcp_check（standalone 脚本无法 source utils.sh），
# 内联实现里同样使用 /dev/tcp 快路径 + node 兜底，与 utils.sh 行为对齐。
echo ""
echo "[T04] /dev/tcp 仅在 utils.sh / templates.sh 内联 helper"
dt=$(grep -rn '/dev/tcp' "$PROJECT_DIR/src/"*.sh 2>/dev/null | grep -vE 'src/(utils|templates)\.sh' || true)
if [[ -z "$dt" ]]; then
    pass "无外部 /dev/tcp 引用"
else
    fail "/dev/tcp 残留:"; echo "$dt"
fi

# ── T05: pgrep 仅在正确位置 ──
# 同样的原因，templates.sh 内联的 _count_claude_processes 在 Unix 分支使用 pgrep。
echo ""
echo "[T05] pgrep 仅在 Unix 分支 / utils.sh / templates.sh"
pg=$(grep -rn 'pgrep' "$PROJECT_DIR/src/"*.sh 2>/dev/null | grep -vE 'src/(utils|templates)\.sh' | grep -vi 'MINGW\|MSYS\|CYGWIN\|# ' || true)
if [[ -z "$pg" ]]; then
    pass "pgrep 仅在正确位置"
else
    fail "pgrep 残留:"; echo "$pg"
fi

# ── T06: 进程替换安全 ──
echo ""
echo "[T06] 进程替换 <(printf 已移除"
ps=$(grep -rn '<(printf' "$PROJECT_DIR/src/"*.sh 2>/dev/null || true)
if [[ -z "$ps" ]]; then
    pass "无 <(printf 进程替换"
else
    fail "进程替换残留:"; echo "$ps"
fi

# ── T07: UUID / UserID 生成 ──
echo ""
echo "[T07] UUID / UserID 生成"
uuid=$(_gen_uuid)
[[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && pass "_gen_uuid: $uuid" || fail "_gen_uuid: $uuid"
uid=$(_new_user_id)
[[ ${#uid} -eq 64 ]] && [[ "$uid" =~ ^[0-9a-f]+$ ]] && pass "_new_user_id: ${uid:0:16}..." || fail "_new_user_id: $uid"

# ── T08: SHA256 计算 ──
echo ""
echo "[T08] SHA256 计算"
tmpf=$(mktemp)
echo "test-cac-windows" > "$tmpf"
r=$(_sha256 "$tmpf")
if is_linux; then
    e=$(sha256sum "$tmpf" | cut -d' ' -f1)
    [[ "$r" == "$e" ]] && pass "sha256 匹配" || fail "sha256 不匹配"
else
    # Windows: 验证输出格式（64 位十六进制）
    [[ "$r" =~ ^[0-9a-f]{64}$ ]] && pass "sha256 格式正确: ${r:0:16}..." || fail "sha256 格式错误: $r"
fi
rm -f "$tmpf"

# ── T09: claude.cmd / cac.cmd 入口 ──
echo ""
echo "[T09] .cmd 入口文件"
if is_windows; then
    [[ -f "$PROJECT_DIR/cac.cmd" ]] && pass "cac.cmd 存在" || fail "cac.cmd 缺失"
    grep -q 'bash' "$PROJECT_DIR/cac.cmd" && pass "cac.cmd 调用 bash" || fail "cac.cmd 未调用 bash"
    grep -q 'claude.cmd' "$PROJECT_DIR/src/templates.sh" && pass "templates.sh 生成 claude.cmd" || fail "未生成 claude.cmd"
    grep -q 'CLAUDE_CODE_GIT_BASH_PATH' "$PROJECT_DIR/src/templates.sh" && pass "claude wrapper 设置 Git Bash 路径" || fail "未设置 CLAUDE_CODE_GIT_BASH_PATH"
else
    skip "Windows 专项（.cmd 入口文件）"
fi

# ── T10: 语法完整性 ──
echo ""
echo "[T10] 全部 .sh 文件语法检查"
syntax_ok=true
for f in "$PROJECT_DIR/src/"*.sh; do
    if ! bash -n "$f" 2>/dev/null; then
        echo "    ❌ $(basename "$f") 语法错误"
        syntax_ok=false
    fi
done
$syntax_ok && pass "所有 .sh 文件语法正确" || fail "存在语法错误"

# ── T11: Node.js JSON 解析 ──
echo ""
echo "[T11] Node.js JSON 解析 (_cac_setting)"
tmpdir=$(mktemp -d)
echo '{"proxy":"socks5://1.2.3.4:1080","max_sessions":"5"}' > "$tmpdir/settings.json"
CAC_DIR="$tmpdir" r=$(_cac_setting "max_sessions" "3")
[[ "$r" == "5" ]] && pass "_cac_setting 读取: $r" || fail "_cac_setting: $r"
CAC_DIR="$tmpdir" r=$(_cac_setting "nonexistent" "default")
[[ "$r" == "default" ]] && pass "_cac_setting 默认值" || fail "_cac_setting 默认值: $r"
rm -rf "$tmpdir"

# ── T12: 版本二进制路径 ──
echo ""
echo "[T12] _version_binary 平台感知"
export VERSIONS_DIR="/tmp/.cac-versions-test"
b=$(_version_binary "2.1.97")
if is_windows; then
    [[ "$b" == *".exe" ]] && pass "Windows 路径: $b" || fail "Windows 路径缺 .exe: $b"
else
    [[ "$b" == "/tmp/.cac-versions-test/2.1.97/claude" ]] && pass "Linux 路径: $b" || fail "Linux 路径: $b"
fi

# ── T13: postinstall.js 语法和 win32 检查 ──
echo ""
echo "[T13] postinstall.js Windows 适配"
node -c "$PROJECT_DIR/scripts/postinstall.js" 2>/dev/null && pass "语法正确" || fail "语法错误"
grep -q 'claude.cmd' "$PROJECT_DIR/scripts/postinstall.js" && pass "claude.cmd 路径" || fail "缺 claude.cmd"
grep -q 'win32' "$PROJECT_DIR/scripts/postinstall.js" && pass "win32 平台检查" || fail "缺 win32"

# ── T13b: Windows PATH 日志函数 ──
echo ""
echo "[T13b] Windows PATH 日志函数"
grep -q '^_log()' "$PROJECT_DIR/src/utils.sh" && pass "_log 已定义" || fail "_log 未定义"

# ── T14: manifest 平台解析 ──
echo ""
echo "[T14] manifest 平台解析"
manifest='{"platforms":{"win32-x64":{"checksum":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}'
checksum=$(printf '%s' "$manifest" | _manifest_checksum "win32-x64" 2>/dev/null || true)
[[ "$checksum" == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]] \
    && pass "win32-x64 checksum 解析正确" \
    || fail "manifest checksum 解析失败: $checksum"

# ── T15: Windows 原生路径转换 ──
echo ""
echo "[T15] Windows 原生路径转换"
native_path=$(_native_path "$HOME/.cac/fingerprint-hook.js")
if is_windows; then
    [[ "$native_path" =~ ^[A-Za-z]:\\ ]] && pass "Windows 路径已转换: $native_path" || fail "未转换为 Windows 原生路径: $native_path"
else
    [[ "$native_path" == "$HOME/.cac/fingerprint-hook.js" ]] && pass "非 Windows 保持原路径" || fail "非 Windows 路径异常: $native_path"
fi

# ── T16: mTLS 自愈钩子 ──
echo ""
echo "[T16] mTLS 自愈钩子"
grep -q '_generate_ca_cert' "$PROJECT_DIR/src/cmd_setup.sh" && pass "初始化包含 CA 重试" || fail "初始化缺少 CA 重试"
grep -q '_generate_client_cert "$name"' "$PROJECT_DIR/src/cmd_env.sh" && pass "激活包含 client cert 回填" || fail "激活缺少 client cert 回填"

# ── T17: 出口 IP 检测源 ──
echo ""
echo "[T17] 出口 IP 检测源"
grep -q 'http://ip-api.com/json/?fields=query,timezone' "$PROJECT_DIR/src/cmd_check.sh" && pass "优先使用 ip-api 当前连接检测" || fail "缺少 ip-api 当前连接检测"
! grep -q 'ip.3322.net' "$PROJECT_DIR/src/cmd_check.sh" && pass "已移除 ip.3322.net" || fail "仍然使用 ip.3322.net"

# ── T18: Windows OpenSSL 选择 ──
echo ""
echo "[T18] Windows OpenSSL 选择"
grep -q '^_openssl()' "$PROJECT_DIR/src/mtls.sh" && pass "_openssl helper 已定义" || fail "_openssl helper 未定义"
grep -q '/c/Program Files/Git/mingw64/bin/openssl.exe' "$PROJECT_DIR/src/mtls.sh" && pass "优先 Git for Windows 标准 OpenSSL 路径" || fail "缺少 Git for Windows 标准 OpenSSL 路径"

# ── T19: env check read 兼容 set -e ──
echo ""
echo "[T19] env check read 兼容 set -e"
grep -q 'read -r proxy_ip ip_tz .*|| true' "$PROJECT_DIR/src/cmd_check.sh" && pass "proxy metadata read 已防止提前退出" || fail "proxy metadata read 仍可能提前退出"

# ── T20: proxy 协议级检查 ──
echo ""
echo "[T20] proxy 协议级检查 (_proxy_check)"
tmp_proxy_dir=$(mktemp -d "$PROJECT_DIR/.tmp-proxy-check.XXXXXX")
http_port_file="$tmp_proxy_dir/http.port"
socks_port_file="$tmp_proxy_dir/socks.port"
https_port_file="$tmp_proxy_dir/https.port"
proxy_pids=()

_wait_port_file() {
    local file="$1"
    local i
    for i in {1..50}; do
        [[ -s "$file" ]] && return 0
        sleep 0.1
    done
    return 1
}

node -e "
const http = require('http');
const fs = require('fs');
const portFile = process.argv[1];
const expected = 'Basic ' + Buffer.from('u:p').toString('base64');
const srv = http.createServer();
srv.on('connect', (req, socket) => {
  if (req.url !== 'api.ipify.org:443') {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  if (req.headers['proxy-authorization'] !== expected) {
    socket.end('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');
    return;
  }
  socket.end('HTTP/1.1 200 Connection Established\r\n\r\n');
});
srv.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(srv.address().port)));
setTimeout(() => srv.close(() => process.exit(0)), 15000);
" "$http_port_file" &
proxy_pids+=("$!")

node -e "
const net = require('net');
const fs = require('fs');
const portFile = process.argv[1];
const srv = net.createServer((sock) => {
  let state = 'greeting';
  let buf = Buffer.alloc(0);
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    if (state === 'greeting') {
      if (buf.length < 2) return;
      sock.write(Buffer.from([0x05, 0x02]));
      buf = buf.slice(2 + buf[1]);
      state = 'auth';
    }
    if (state === 'auth') {
      if (buf.length < 2) return;
      const ulen = buf[1];
      if (buf.length < 3 + ulen) return;
      const plen = buf[2 + ulen];
      if (buf.length < 3 + ulen + plen) return;
      const user = buf.slice(2, 2 + ulen).toString();
      const pass = buf.slice(3 + ulen, 3 + ulen + plen).toString();
      const ok = user === 'u' && pass === 'p';
      sock.write(Buffer.from([0x01, ok ? 0x00 : 0x01]));
      buf = buf.slice(3 + ulen + plen);
      if (!ok) {
        sock.destroy();
        return;
      }
      state = 'connect';
    }
    if (state === 'connect') {
      if (buf.length < 7) return;
      sock.end(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
    }
  });
});
srv.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(srv.address().port)));
setTimeout(() => srv.close(() => process.exit(0)), 15000);
" "$socks_port_file" &
proxy_pids+=("$!")

if _wait_port_file "$http_port_file" && _wait_port_file "$socks_port_file"; then
    http_port=$(cat "$http_port_file")
    socks_port=$(cat "$socks_port_file")
    _proxy_check "http://u:p@127.0.0.1:$http_port" 2 \
        && pass "HTTP CONNECT + 正确认证通过" \
        || fail "HTTP CONNECT + 正确认证失败"
    ! _proxy_check "http://bad:creds@127.0.0.1:$http_port" 2 \
        && pass "HTTP 407 认证失败不会误报可用" \
        || fail "HTTP 407 被误报为可用"
    _proxy_check "socks5://u:p@127.0.0.1:$socks_port" 2 \
        && pass "SOCKS5 认证 + CONNECT 通过" \
        || fail "SOCKS5 认证 + CONNECT 失败"
    ! _proxy_check "socks5://bad:creds@127.0.0.1:$socks_port" 2 \
        && pass "SOCKS5 错误认证不会误报可用" \
        || fail "SOCKS5 错误认证被误报为可用"
else
    fail "mock HTTP/SOCKS5 proxy 启动失败"
fi

if _openssl version >/dev/null 2>&1; then
    https_port_file_native=$(_openssl_path "$https_port_file")
    https_key_native=$(_openssl_path "$tmp_proxy_dir/key.pem")
    https_cert_native=$(_openssl_path "$tmp_proxy_dir/cert.pem")
    if ! _openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$https_key_native" \
        -out "$https_cert_native" \
        -subj "/CN=127.0.0.1" -days 1 >/dev/null 2>&1; then
        skip "OpenSSL 生成测试证书失败，跳过 HTTPS proxy mock"
    else
    node -e "
const tls = require('tls');
const fs = require('fs');
const portFile = process.argv[1];
const srv = tls.createServer({
  key: fs.readFileSync(process.argv[2]),
  cert: fs.readFileSync(process.argv[3])
}, (sock) => {
  let buf = Buffer.alloc(0);
  sock.on('error', () => {});
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    if (buf.indexOf('\r\n\r\n') === -1) return;
    const first = buf.slice(0, buf.indexOf('\r\n')).toString();
    sock.end(first === 'CONNECT api.ipify.org:443 HTTP/1.1'
      ? 'HTTP/1.1 200 Connection Established\r\n\r\n'
      : 'HTTP/1.1 403 Forbidden\r\n\r\n');
  });
});
srv.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(srv.address().port)));
setTimeout(() => srv.close(() => process.exit(0)), 15000);
" "$https_port_file_native" "$https_key_native" "$https_cert_native" &
        proxy_pids+=("$!")
        if _wait_port_file "$https_port_file"; then
            https_port=$(cat "$https_port_file")
            _proxy_check "https://127.0.0.1:$https_port" 2 \
                && pass "HTTPS proxy 使用 TLS 后 CONNECT 通过" \
                || fail "HTTPS proxy TLS CONNECT 失败"
        else
            fail "mock HTTPS proxy 启动失败"
        fi
    fi
else
    skip "OpenSSL 不可用，跳过 HTTPS proxy mock"
fi

for pid in "${proxy_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
done
rm -rf "$tmp_proxy_dir"

# ── 总结 ──
echo ""
echo "════════════════════════════════════════════════════════"
echo "  结果: $PASS 通过, $FAIL 失败, $SKIP 跳过"
echo "════════════════════════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
