#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; SKIP=0

is_windows() { [[ "$(uname -s)" =~ MINGW*|MSYS*|CYGWIN* ]]; }
pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭️  $1"; }

echo "════════════════════════════════════════════════════════"
echo "  CMD/PowerShell 入口测试"
echo "════════════════════════════════════════════════════════"

# ── E01: cac.cmd 存在且可读 ──
echo ""
echo "[E01] cac.cmd 文件检查"
[[ -f "$PROJECT_DIR/cac.cmd" ]] && pass "cac.cmd 存在" || fail "cac.cmd 缺失"
[[ -r "$PROJECT_DIR/cac.cmd" ]] && pass "cac.cmd 可读" || fail "cac.cmd 不可读"

# ── E02: cac.cmd 调用 bash ──
echo ""
echo "[E02] cac.cmd 调用 bash wrapper"
grep -q 'bash' "$PROJECT_DIR/cac.cmd" && pass "调用 bash" || fail "未调用 bash"
grep -q 'cac.ps1' "$PROJECT_DIR/cac.cmd" && pass "保留 PowerShell fallback" || skip "无 PowerShell fallback（可接受）"

# ── E03: cac.ps1 保留 ──
echo ""
echo "[E03] cac.ps1 保留"
[[ -f "$PROJECT_DIR/cac.ps1" ]] && pass "cac.ps1 保留" || fail "cac.ps1 缺失"

# ── E04: claude.cmd 模板 ──
echo ""
echo "[E04] claude.cmd 生成模板"
grep -q 'claude.cmd' "$PROJECT_DIR/src/templates.sh" && pass "templates.sh 包含 claude.cmd 生成" || fail "缺 claude.cmd 生成"
grep -q '@echo off' "$PROJECT_DIR/src/templates.sh" && pass "包含 @echo off" || fail "缺 @echo off"
grep -q 'bash.*%~dpn0' "$PROJECT_DIR/src/templates.sh" && pass "调用 bash wrapper" || fail "claude.cmd 未调用 bash"

# ── E05: PATH 管理 ──
echo ""
echo "[E05] Windows PATH 管理"
grep -q '_add_to_user_path' "$PROJECT_DIR/src/utils.sh" && pass "函数定义" || fail "缺函数"
grep -q '_add_to_user_path' "$PROJECT_DIR/src/cmd_setup.sh" && pass "setup 中调用" || fail "setup 未调用"
grep -q 'SetEnvironmentVariable' "$PROJECT_DIR/src/utils.sh" && pass "PowerShell SetEnvironmentVariable" || fail "缺 SetEnvironmentVariable"

# ── E06: Windows 下实际测试 ──
echo ""
echo "[E06] Windows 下 CMD 入口实际测试"
if is_windows; then
    # 测试 cac.cmd 能被 cmd.exe 调用
    out=$(cmd.exe /c "$PROJECT_DIR\\cac.cmd" help 2>&1 || true)
    [[ -n "$out" ]] && pass "cac.cmd 有输出" || fail "cac.cmd 无输出"
else
    skip "Windows 专项（需要 cmd.exe）"
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  结果: $PASS 通过, $FAIL 失败, $SKIP 跳过"
echo "════════════════════════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
