#!/usr/bin/env bash
# test-docker.sh — 在 Docker 中测试 cac PR#4 的所有 test plan 项
set -euo pipefail

PASS=0
FAIL=0
TESTS=()

_pass() { PASS=$((PASS+1)); TESTS+=("✅ $1"); echo "✅ PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); TESTS+=("❌ $1: $2"); echo "❌ FAIL: $1 — $2"; }

echo "========================================="
echo "  cac PR#4 Test Suite (Docker)"
echo "========================================="
echo

# --- 准备：创建 mock claude ---
mkdir -p /usr/local/bin
cat > /usr/local/bin/claude << 'MOCK'
#!/usr/bin/env bash
echo "mock claude $*"
MOCK
chmod +x /usr/local/bin/claude

# 确保 HOME 有 shell rc 文件
touch ~/.bashrc

##############################################
# Test 1: cac setup 自动写入 PATH
##############################################
echo "--- Test 1: cac setup 自动写入 PATH ---"
cac setup 2>&1 || true

if grep -q '# >>> cac' ~/.bashrc 2>/dev/null; then
    _pass "cac setup 自动写入 PATH 到 ~/.bashrc"
else
    _fail "cac setup 自动写入 PATH" "~/.bashrc 中未找到 cac PATH 标记块"
fi

# 验证标记块格式正确
if grep -q '# <<< cac' ~/.bashrc 2>/dev/null; then
    _pass "PATH 标记块格式正确（有开闭标记）"
else
    _fail "PATH 标记块格式" "缺少闭合标记 <<< cac"
fi

# 验证 ~/.cac 目录已创建
if [[ -d "$HOME/.cac" ]]; then
    _pass "~/.cac 目录已创建"
else
    _fail "~/.cac 目录" "目录未创建"
fi

# 验证 wrapper 已生成
if [[ -f "$HOME/.cac/bin/claude" ]]; then
    _pass "claude wrapper 已生成"
else
    _fail "claude wrapper" "未找到 ~/.cac/bin/claude"
fi

echo

##############################################
# Test 2: cac setup 重复执行（幂等性）
##############################################
echo "--- Test 2: cac setup 重复执行 ---"
count_before=$(grep -c '# >>> cac' ~/.bashrc 2>/dev/null || echo 0)
cac setup 2>&1 || true
count_after=$(grep -c '# >>> cac' ~/.bashrc 2>/dev/null || echo 0)

if [[ "$count_before" == "$count_after" ]]; then
    _pass "cac setup 幂等 — 不会重复写入 PATH"
else
    _fail "cac setup 幂等性" "PATH 被重复写入（before=$count_before, after=$count_after）"
fi

echo

##############################################
# Test 3: cac -v 版本信息
##############################################
echo "--- Test 3: cac -v ---"
version_output=$(cac -v 2>&1)

if echo "$version_output" | grep -q 'cac.*1\.0\.0'; then
    _pass "cac -v 显示版本号 1.0.0"
else
    _fail "cac -v 版本号" "输出: $version_output"
fi

if echo "$version_output" | grep -q '安装方式'; then
    _pass "cac -v 显示安装方式"
else
    _fail "cac -v 安装方式" "输出中无安装方式信息"
fi

echo

##############################################
# Test 4: cac --version（别名）
##############################################
echo "--- Test 4: cac --version ---"
version_output2=$(cac --version 2>&1)

if echo "$version_output2" | grep -q 'cac.*1\.0\.0'; then
    _pass "cac --version 也能正常工作"
else
    _fail "cac --version" "输出: $version_output2"
fi

echo

##############################################
# Test 5: cac delete 清理数据
##############################################
echo "--- Test 5: cac delete ---"
cac delete 2>&1 || true

if [[ ! -d "$HOME/.cac" ]]; then
    _pass "cac delete 已删除 ~/.cac"
else
    _fail "cac delete" "~/.cac 目录仍存在"
fi

if ! grep -q '# >>> cac' ~/.bashrc 2>/dev/null; then
    _pass "cac delete 已移除 ~/.bashrc 中的 PATH 配置"
else
    _fail "cac delete PATH 清理" "~/.bashrc 中仍存在 cac PATH"
fi

echo

##############################################
# Test 6: cac delete 重复执行（幂等性）
##############################################
echo "--- Test 6: cac delete 重复执行 ---"
delete_output=$(cac delete 2>&1)
delete_exit=$?

if [[ $delete_exit -eq 0 ]]; then
    _pass "cac delete 重复执行不报错"
else
    _fail "cac delete 幂等性" "退出码: $delete_exit"
fi

if echo "$delete_output" | grep -q '不存在'; then
    _pass "cac delete 重复执行提示已清理"
else
    _fail "cac delete 幂等提示" "输出: $delete_output"
fi

echo

##############################################
# Test 7: cac help 包含新命令
##############################################
echo "--- Test 7: cac help ---"
help_output=$(cac help 2>&1)

if echo "$help_output" | grep -q 'delete'; then
    _pass "cac help 包含 delete 命令"
else
    _fail "cac help" "未显示 delete 命令"
fi

if echo "$help_output" | grep -q '\-v'; then
    _pass "cac help 包含 -v 命令"
else
    _fail "cac help" "未显示 -v 命令"
fi

echo

##############################################
# Test 8: cac uninstall（delete 别名）
##############################################
echo "--- Test 8: cac uninstall ---"
# 先重新 setup
cac setup 2>&1 || true
uninstall_output=$(cac uninstall 2>&1)

if [[ ! -d "$HOME/.cac" ]]; then
    _pass "cac uninstall 也能正常卸载"
else
    _fail "cac uninstall" "~/.cac 目录仍存在"
fi

echo

##############################################
# 汇总
##############################################
echo
echo "========================================="
echo "  测试结果: $PASS 通过, $FAIL 失败"
echo "========================================="
for t in "${TESTS[@]}"; do
    echo "  $t"
done
echo

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "所有测试通过！"
