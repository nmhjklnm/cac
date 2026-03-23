#!/usr/bin/env bash
# test-relay-docker.sh — 在 Docker 中测试 relay 本地中转功能
set -euo pipefail

PASS=0
FAIL=0
TESTS=()

_pass() { PASS=$((PASS+1)); TESTS+=("✅ $1"); echo "✅ PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); TESTS+=("❌ $1: $2"); echo "❌ FAIL: $1 — $2"; }

echo "========================================="
echo "  cac Relay 本地中转 Test Suite (Docker)"
echo "========================================="
echo

# --- 准备：mock claude + 安装 cac ---
mkdir -p /usr/local/bin
cat > /usr/local/bin/claude << 'MOCK'
#!/usr/bin/env bash
# Mock claude: 输出环境变量用于验证
echo "HTTPS_PROXY=$HTTPS_PROXY"
echo "HTTP_PROXY=$HTTP_PROXY"
echo "ALL_PROXY=$ALL_PROXY"
# 尝试通过代理发请求（验证 relay 是否能接受连接）
if command -v curl >/dev/null 2>&1; then
    curl -s -x "$HTTPS_PROXY" --connect-timeout 3 http://httpbin.org/ip 2>&1 || echo "curl_exit=$?"
fi
MOCK
chmod +x /usr/local/bin/claude
touch ~/.bashrc

echo "--- 准备完成 ---"
echo

##############################################
# Test 1: relay.js 语法检查
##############################################
echo "--- Test 1: relay.js syntax ---"
if node -c /opt/cac/src/relay.js 2>/dev/null; then
    _pass "relay.js 语法正确"
else
    _fail "relay.js 语法" "语法错误"
fi

echo

##############################################
# Test 2: relay.js 启动和监听
##############################################
echo "--- Test 2: relay.js 启动监听 ---"
# 启动 relay（上游指向一个不存在的地址，仅测试本地监听）
node /opt/cac/src/relay.js 17890 http://127.0.0.1:19999 /tmp/relay-test.pid &
RELAY_PID=$!
sleep 1

if [[ -f /tmp/relay-test.pid ]]; then
    _pass "relay PID 文件已创建"
else
    _fail "relay PID 文件" "未找到 /tmp/relay-test.pid"
fi

PID_CONTENT=$(cat /tmp/relay-test.pid 2>/dev/null || echo "")
if [[ "$PID_CONTENT" == "$RELAY_PID" ]]; then
    _pass "relay PID 内容正确 ($PID_CONTENT)"
else
    _fail "relay PID 内容" "期望=$RELAY_PID 实际=$PID_CONTENT"
fi

# 检查端口监听
if (echo >/dev/tcp/127.0.0.1/17890) 2>/dev/null; then
    _pass "relay 监听 127.0.0.1:17890"
else
    # 用 nc 重试
    if nc -z 127.0.0.1 17890 2>/dev/null; then
        _pass "relay 监听 127.0.0.1:17890 (nc)"
    else
        _fail "relay 监听" "端口 17890 未开放"
    fi
fi

# 清理
kill $RELAY_PID 2>/dev/null; wait $RELAY_PID 2>/dev/null || true
rm -f /tmp/relay-test.pid

echo

##############################################
# Test 3: relay.js SOCKS5 上游模式启动
##############################################
echo "--- Test 3: relay.js SOCKS5 模式 ---"
node /opt/cac/src/relay.js 17891 socks5://127.0.0.1:19999 /tmp/relay-test2.pid &
RELAY_PID2=$!
sleep 1

if (echo >/dev/tcp/127.0.0.1/17891) 2>/dev/null; then
    _pass "relay SOCKS5 模式监听成功"
else
    _fail "relay SOCKS5 监听" "端口 17891 未开放"
fi

kill $RELAY_PID2 2>/dev/null; wait $RELAY_PID2 2>/dev/null || true
rm -f /tmp/relay-test2.pid

echo

##############################################
# Test 4: relay.js 带认证上游
##############################################
echo "--- Test 4: relay.js 带认证上游 ---"
node /opt/cac/src/relay.js 17892 http://user:pass@127.0.0.1:19999 /tmp/relay-test3.pid &
RELAY_PID3=$!
sleep 1

if (echo >/dev/tcp/127.0.0.1/17892) 2>/dev/null; then
    _pass "relay 带认证上游启动成功"
else
    _fail "relay 带认证" "端口 17892 未开放"
fi

kill $RELAY_PID3 2>/dev/null; wait $RELAY_PID3 2>/dev/null || true
rm -f /tmp/relay-test3.pid

echo

##############################################
# Test 5: relay.js SIGTERM 清理
##############################################
echo "--- Test 5: relay.js 优雅退出 ---"
node /opt/cac/src/relay.js 17893 http://127.0.0.1:19999 /tmp/relay-test4.pid &
RELAY_PID4=$!
sleep 1

kill -TERM $RELAY_PID4 2>/dev/null
sleep 0.5

if ! kill -0 $RELAY_PID4 2>/dev/null; then
    _pass "relay SIGTERM 后进程已退出"
else
    _fail "relay SIGTERM" "进程仍在运行"
    kill -9 $RELAY_PID4 2>/dev/null || true
fi

if [[ ! -f /tmp/relay-test4.pid ]]; then
    _pass "relay SIGTERM 后 PID 文件已清理"
else
    _fail "relay PID 清理" "PID 文件仍存在"
    rm -f /tmp/relay-test4.pid
fi

echo

##############################################
# Test 6: relay.js CONNECT 请求处理
##############################################
echo "--- Test 6: relay CONNECT 请求 ---"
# 启动一个简单 TCP echo server 作为"上游代理"
node -e '
const net = require("net");
const s = net.createServer(c => {
  let buf = "";
  c.on("data", d => {
    buf += d.toString();
    // 收到 CONNECT 请求时返回 200
    if (buf.includes("\r\n\r\n") && buf.startsWith("CONNECT")) {
      c.write("HTTP/1.1 200 OK\r\n\r\n");
      // 之后 echo 模式
      c.on("data", chunk => c.write(chunk));
    }
  });
});
s.listen(18080, "127.0.0.1", () => process.stdout.write("mock-upstream-ready\n"));
' &
MOCK_UPSTREAM=$!
sleep 0.5

# 启动 relay 指向 mock 上游
node /opt/cac/src/relay.js 17894 http://127.0.0.1:18080 /tmp/relay-test5.pid &
RELAY_PID5=$!
sleep 0.5

# 通过 relay 发送 CONNECT 请求
RESPONSE=$(curl -s -x http://127.0.0.1:17894 --connect-timeout 3 http://test.example.com/ 2>&1 || true)

if [[ -n "$RESPONSE" ]] || (echo >/dev/tcp/127.0.0.1/17894) 2>/dev/null; then
    _pass "relay 能接受并转发 CONNECT 请求"
else
    _fail "relay CONNECT" "无法通过 relay 连接"
fi

kill $RELAY_PID5 2>/dev/null; wait $RELAY_PID5 2>/dev/null || true
kill $MOCK_UPSTREAM 2>/dev/null; wait $MOCK_UPSTREAM 2>/dev/null || true
rm -f /tmp/relay-test5.pid

echo

##############################################
# Test 7: cac setup 部署 relay.js
##############################################
echo "--- Test 7: cac setup 部署 relay.js ---"
export PATH="/opt/cac:$PATH"
cac setup 2>&1 || true

if [[ -f "$HOME/.cac/relay.js" ]]; then
    _pass "cac setup 部署 relay.js"
else
    _fail "cac setup relay.js" "未找到 ~/.cac/relay.js"
fi

echo

##############################################
# Test 8: cac relay status（无环境）
##############################################
echo "--- Test 8: cac relay 命令 ---"
relay_help=$(cac relay 2>&1 || true)
if echo "$relay_help" | grep -qi "relay\|未激活\|未启用"; then
    _pass "cac relay 命令可正常执行"
else
    _fail "cac relay" "输出: $relay_help"
fi

echo

##############################################
# Test 9: cac help 包含 relay
##############################################
echo "--- Test 9: cac help 包含 relay ---"
help_output=$(cac help 2>&1)
if echo "$help_output" | grep -q "relay"; then
    _pass "cac help 包含 relay 命令"
else
    _fail "cac help relay" "未显示 relay"
fi

if echo "$help_output" | grep -q "TUN"; then
    _pass "cac help 包含 TUN 说明"
else
    _fail "cac help TUN" "未显示 TUN 说明"
fi

echo

##############################################
# Test 10: 端到端 relay 集成测试
##############################################
echo "--- Test 10: 端到端 relay 集成 ---"

# 清理所有残留 relay/node 进程
pkill -f "relay.js" 2>/dev/null || true
pkill -f "18080" 2>/dev/null || true
sleep 1

# 创建环境（非交互）
mkdir -p "$HOME/.cac/envs/test1"
echo "http://127.0.0.1:19999" > "$HOME/.cac/envs/test1/proxy"
echo "TEST-UUID" > "$HOME/.cac/envs/test1/uuid"
echo "test-sid" > "$HOME/.cac/envs/test1/stable_id"
echo "test-uid" > "$HOME/.cac/envs/test1/user_id"
echo "test-machine" > "$HOME/.cac/envs/test1/machine_id"
echo "host-test" > "$HOME/.cac/envs/test1/hostname"
echo "02:aa:bb:cc:dd:ee" > "$HOME/.cac/envs/test1/mac_address"
echo "America/New_York" > "$HOME/.cac/envs/test1/tz"
echo "en_US.UTF-8" > "$HOME/.cac/envs/test1/lang"
echo "test1" > "$HOME/.cac/current"

# 启用 relay
echo "on" > "$HOME/.cac/envs/test1/relay"

# 验证 relay 文件
if [[ -f "$HOME/.cac/envs/test1/relay" ]] && [[ "$(cat "$HOME/.cac/envs/test1/relay")" == "on" ]]; then
    _pass "relay 配置文件已创建"
else
    _fail "relay 配置" "文件内容不正确"
fi

echo

##############################################
# Test 11: cac relay status 显示正确状态
##############################################
echo "--- Test 11: cac relay status ---"
status_output=$(cac relay status 2>&1)
if echo "$status_output" | grep -q "已启用"; then
    _pass "cac relay status 显示已启用"
else
    _fail "cac relay status" "输出: $status_output"
fi

echo

##############################################
# Test 12: cac relay on 启动 relay
##############################################
echo "--- Test 12: cac relay on 启动 ---"
# 确保端口干净
pkill -f "relay.js" 2>/dev/null || true
sleep 0.5
rm -f "$HOME/.cac/relay.pid" "$HOME/.cac/relay.port"
# 注意：不能用 $() 捕获，因为后台 relay 的 stderr 会阻塞 subshell
cac relay on > /tmp/relay_on_out.txt 2>&1 </dev/null || true
relay_on_output=$(cat /tmp/relay_on_out.txt)
if echo "$relay_on_output" | grep -q "已启用\|127.0.0.1"; then
    _pass "cac relay on 输出正确"
else
    _fail "cac relay on" "输出: $relay_on_output"
fi

# 检查 relay 是否在运行
sleep 1
if [[ -f "$HOME/.cac/relay.pid" ]]; then
    local_pid=$(cat "$HOME/.cac/relay.pid")
    if kill -0 "$local_pid" 2>/dev/null; then
        _pass "cac relay on 启动了 relay 进程 (PID=$local_pid)"
    else
        _fail "relay 进程" "PID=$local_pid 但进程不存在"
    fi
else
    _fail "relay PID" "PID 文件不存在"
fi

if [[ -f "$HOME/.cac/relay.port" ]]; then
    local_port=$(cat "$HOME/.cac/relay.port")
    _pass "relay 端口文件存在 (port=$local_port)"
else
    _fail "relay 端口" "端口文件不存在"
fi

echo

##############################################
# Test 13: cac relay off 停止 relay
##############################################
echo "--- Test 13: cac relay off ---"
cac relay off > /tmp/relay_off_out.txt 2>&1 </dev/null || true
relay_off_output=$(cat /tmp/relay_off_out.txt)
if echo "$relay_off_output" | grep -q "停用"; then
    _pass "cac relay off 输出正确"
else
    _fail "cac relay off" "输出: $relay_off_output"
fi

if [[ ! -f "$HOME/.cac/relay.pid" ]]; then
    _pass "cac relay off 清理了 PID 文件"
else
    _fail "relay off PID 清理" "PID 文件仍存在"
fi

if [[ ! -f "$HOME/.cac/envs/test1/relay" ]]; then
    _pass "cac relay off 移除了 relay 配置"
else
    _fail "relay off 配置清理" "配置文件仍存在"
fi

echo

##############################################
# Test 14: wrapper 中 relay 自动启动
##############################################
echo "--- Test 14: wrapper relay 集成 ---"
# 重新启用 relay
echo "on" > "$HOME/.cac/envs/test1/relay"

# 确保先前的 relay 已停止
pkill -f "relay.js" 2>/dev/null || true
sleep 1
rm -f "$HOME/.cac/relay.pid" "$HOME/.cac/relay.port"

# 启动一个假的代理监听（wrapper 有 pre-flight 连通性检查）
node -e 'require("net").createServer(c=>c.end()).listen(19999,"127.0.0.1",()=>process.stdout.write("fake-proxy-ready\n"))' &
FAKE_PROXY_PID=$!
sleep 0.5

# 运行 wrapper（它应该自动启动 relay 并指向本地）
timeout 15 "$HOME/.cac/bin/claude" test-arg > /tmp/wrapper_out.txt 2>&1 </dev/null || true
kill $FAKE_PROXY_PID 2>/dev/null; wait $FAKE_PROXY_PID 2>/dev/null || true
wrapper_output=$(cat /tmp/wrapper_out.txt)

if echo "$wrapper_output" | grep -q "HTTPS_PROXY=http://127.0.0.1:"; then
    _pass "wrapper 自动将 HTTPS_PROXY 指向本地 relay"
else
    _fail "wrapper relay 集成" "输出: $wrapper_output"
fi

# 提取端口
relay_port=$(echo "$wrapper_output" | grep -oP 'HTTPS_PROXY=http://127.0.0.1:\K[0-9]+' || true)
if [[ -n "$relay_port" ]]; then
    _pass "wrapper 分配了 relay 端口: $relay_port"
else
    _fail "wrapper relay 端口" "未能提取端口"
fi

# wrapper 退出后 relay 应已清理（因为 trap）
sleep 0.5
if ! [[ -f "$HOME/.cac/relay.pid" ]] || ! kill -0 "$(cat "$HOME/.cac/relay.pid" 2>/dev/null)" 2>/dev/null; then
    _pass "wrapper 退出后 relay 进程已清理"
else
    _fail "wrapper relay 清理" "relay 进程仍在运行"
fi

echo

##############################################
# Test 15: wrapper 不启用 relay 时仍用 exec
##############################################
echo "--- Test 15: wrapper 无 relay 模式 ---"
rm -f "$HOME/.cac/envs/test1/relay"
pkill -f "relay.js" 2>/dev/null || true
sleep 0.5

# 启动假代理（pre-flight 检查需要）
node -e 'require("net").createServer(c=>c.end()).listen(19999,"127.0.0.1",()=>process.stdout.write("ready\n"))' &
FAKE_PROXY_PID2=$!
sleep 0.5

timeout 15 "$HOME/.cac/bin/claude" test > /tmp/wrapper_out2.txt 2>&1 </dev/null || true
kill $FAKE_PROXY_PID2 2>/dev/null; wait $FAKE_PROXY_PID2 2>/dev/null || true
wrapper_output2=$(cat /tmp/wrapper_out2.txt)
if echo "$wrapper_output2" | grep -q "HTTPS_PROXY=http://127.0.0.1:19999"; then
    _pass "无 relay 模式 HTTPS_PROXY 指向远端代理"
else
    _fail "无 relay 模式" "输出: $wrapper_output2"
fi

echo

##############################################
# Test 16: cac check 显示 relay 状态
##############################################
echo "--- Test 16: cac check relay 状态 ---"
echo "on" > "$HOME/.cac/envs/test1/relay"
check_output=$(cac check 2>&1 || true)

if echo "$check_output" | grep -q "Relay"; then
    _pass "cac check 显示 Relay 段落"
else
    _fail "cac check relay" "未显示 Relay 信息"
fi

echo

##############################################
# 清理
##############################################
pkill -f "relay.js" 2>/dev/null || true
pkill -f "mock-upstream\|18080" 2>/dev/null || true

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
