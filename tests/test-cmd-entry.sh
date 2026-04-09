#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; SKIP=0

is_windows() { [[ "$(uname -s)" =~ MINGW*|MSYS*|CYGWIN* ]]; }
pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  ⏭️  $1"; }

resolve_git_bash() {
    local candidate
    for candidate in \
        "${ProgramFiles:-}/Git/bin/bash.exe" \
        "${ProgramW6432:-}/Git/bin/bash.exe" \
        "${LocalAppData:-}/Programs/Git/bin/bash.exe" \
        "${LocalAppData:-}/Git/bin/bash.exe"
    do
        [[ -n "$candidate" && -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done

    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        candidate="$(cygpath -u "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
        candidate="$(dirname "$candidate")/../bin/bash.exe"
        candidate="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd)/$(basename "$candidate")"
        [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done < <(cmd.exe /c "where git.exe" 2>/dev/null | tr -d '\r')

    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        [[ "$candidate" == *"\\WindowsApps\\"* ]] && continue
        candidate="$(cygpath -u "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
        [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done < <(cmd.exe /c "where bash.exe" 2>/dev/null | tr -d '\r')

    return 1
}

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
grep -q 'where.exe git.exe' "$PROJECT_DIR/cac.cmd" && pass "支持通过 git.exe 定位 Git Bash" || fail "缺少 git.exe 定位逻辑"
grep -q 'WindowsApps' "$PROJECT_DIR/cac.cmd" && pass "会跳过 WindowsApps bash stub" || fail "缺少 WindowsApps 过滤"

# ── E03: cac.ps1 保留 ──
echo ""
echo "[E03] cac.ps1 保留"
[[ -f "$PROJECT_DIR/cac.ps1" ]] && pass "cac.ps1 保留" || fail "cac.ps1 缺失"

# ── E04: claude.cmd 模板 ──
echo ""
echo "[E04] claude.cmd 生成模板"
grep -q 'claude.cmd' "$PROJECT_DIR/src/templates.sh" && pass "templates.sh 包含 claude.cmd 生成" || fail "缺 claude.cmd 生成"
grep -q '@echo off' "$PROJECT_DIR/src/templates.sh" && pass "包含 @echo off" || fail "缺 @echo off"
grep -q 'where.exe git.exe' "$PROJECT_DIR/src/templates.sh" && pass "模板支持通过 git.exe 定位 Git Bash" || fail "模板缺 git.exe 定位逻辑"
grep -q 'WindowsApps' "$PROJECT_DIR/src/templates.sh" && pass "模板会跳过 WindowsApps bash stub" || fail "模板缺 WindowsApps 过滤"
grep -q '"%BASH_EXE%" "%SCRIPT_DIR%\\claude"' "$PROJECT_DIR/src/templates.sh" && pass "调用解析后的 bash wrapper" || fail "claude.cmd 未调用解析后的 bash"

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
    bash_exe=$(resolve_git_bash || true)
    if [[ -z "$bash_exe" ]]; then
        skip "未找到可用的 Git Bash，跳过运行时入口测试"
    elif ! "$bash_exe" --version >/dev/null 2>&1; then
        skip "当前宿主无法正常启动 Git Bash，跳过运行时入口测试"
    else
        out=$(cmd.exe /v:on /c "\"$PROJECT_DIR\\cac.cmd\" --version >nul 2>&1 & echo EXITCODE:!ERRORLEVEL!" 2>&1 | tr -d '\r')
        [[ "$out" == *"EXITCODE:0"* ]] && pass "cac.cmd 返回码正确" || fail "cac.cmd 返回码异常: $out"
        if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PROJECT_DIR\\cac.ps1" --version >/dev/null 2>&1; then
            pass "cac.ps1 返回码正确"
        else
            fail "cac.ps1 返回码异常"
        fi
    fi
else
    skip "Windows 专项（需要 cmd.exe）"
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  结果: $PASS 通过, $FAIL 失败, $SKIP 跳过"
echo "════════════════════════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
