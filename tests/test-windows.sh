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

# ── T04: /dev/tcp 仅在 utils.sh ──
echo ""
echo "[T04] /dev/tcp 仅在 utils.sh 内部"
dt=$(grep -rn '/dev/tcp' "$PROJECT_DIR/src/"*.sh 2>/dev/null | grep -v 'src/utils.sh' || true)
if [[ -z "$dt" ]]; then
    pass "无外部 /dev/tcp 引用"
else
    fail "/dev/tcp 残留:"; echo "$dt"
fi

# ── T05: pgrep 仅在正确位置 ──
echo ""
echo "[T05] pgrep 仅在 Unix 分支 / utils.sh"
pg=$(grep -rn 'pgrep' "$PROJECT_DIR/src/"*.sh 2>/dev/null | grep -v 'src/utils.sh' | grep -vi 'MINGW\|MSYS\|CYGWIN\|# ' || true)
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

# ── 总结 ──
echo ""
echo "════════════════════════════════════════════════════════"
echo "  结果: $PASS 通过, $FAIL 失败, $SKIP 跳过"
echo "════════════════════════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
