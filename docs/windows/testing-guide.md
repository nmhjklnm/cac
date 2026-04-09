# cac Windows 测试指南

## 测试环境要求

- Windows 10/11 (x64)
- Git for Windows 2.40+ (提供 Git Bash / MINGW64)
- Node.js 18+ (Claude Code 依赖)
- 可选: Docker Desktop (测试 docker 命令)

### 验证环境

```bash
# Git Bash 中执行
uname -s           # 应返回 MINGW64_NT-10.0-... 或类似
uname -m           # 应返回 x86_64
node --version     # 应返回 v18.x 或更高
bash --version     # 应返回 5.x
```

---

## 单元测试

### 1. `_tcp_check()` — TCP 端口检测

```bash
# 测试文件: tests/test-tcp-check.sh
source src/utils.sh

# 测试 1: 开放端口（需要网络）
_tcp_check google.com 443 && echo "PASS: open port" || echo "FAIL: open port"

# 测试 2: 关闭端口
_tcp_check 127.0.0.1 19999 && echo "FAIL: closed port" || echo "PASS: closed port"

# 测试 3: 无效主机
_tcp_check invalid.host.example 80 && echo "FAIL: invalid host" || echo "PASS: invalid host"
```

### 2. `python3` → `node` 替换

```bash
# _cac_setting
echo '{"max_sessions":"5","proxy":"socks5://1.2.3.4:1080"}' > /tmp/test-settings.json
CAC_DIR=/tmp
result=$(_cac_setting "max_sessions" "3")
[[ "$result" == "5" ]] && echo "PASS" || echo "FAIL: got $result"

result=$(_cac_setting "nonexistent" "default_val")
[[ "$result" == "default_val" ]] && echo "PASS" || echo "FAIL: got $result"

# _gen_uuid
uuid=$(_gen_uuid)
[[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && echo "PASS" || echo "FAIL: $uuid"

# _new_user_id
uid=$(_new_user_id)
[[ ${#uid} -eq 64 ]] && [[ "$uid" =~ ^[0-9a-f]+$ ]] && echo "PASS" || echo "FAIL: $uid"
```

### 3. `_detect_platform()`

```bash
platform=$(_detect_platform)
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        [[ "$platform" == "win32-x64" || "$platform" == "win32-arm64" ]] && echo "PASS" || echo "FAIL: $platform"
        ;;
    Darwin)
        [[ "$platform" =~ ^darwin- ]] && echo "PASS" || echo "FAIL: $platform"
        ;;
    Linux)
        [[ "$platform" =~ ^linux- ]] && echo "PASS" || echo "FAIL: $platform"
        ;;
esac
```

### 4. `_sha256()`

```bash
echo "test content" > /tmp/test-sha256.txt
expected=$(sha256sum /tmp/test-sha256.txt 2>/dev/null | cut -d' ' -f1 || \
    node -e "const h=require('crypto').createHash('sha256');h.update(require('fs').readFileSync('/tmp/test-sha256.txt'));process.stdout.write(h.digest('hex'))")
result=$(_sha256 /tmp/test-sha256.txt)
[[ "$result" == "$expected" ]] && echo "PASS" || echo "FAIL: $result != $expected"
```

### 5. `_count_claude_processes()`

```bash
count=$(_count_claude_processes)
[[ "$count" =~ ^[0-9]+$ ]] && echo "PASS: count=$count" || echo "FAIL: not a number: $count"
```

### 6. `_version_binary()`

```bash
bin=$(_version_binary "2.1.97")
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        [[ "$bin" == *"/versions/2.1.97/claude.exe" ]] && echo "PASS" || echo "FAIL: $bin"
        ;;
    *)
        [[ "$bin" == *"/versions/2.1.97/claude" ]] && echo "PASS" || echo "FAIL: $bin"
        ;;
esac
```

---

## 集成测试

### 7. 环境创建

```bash
# 创建无代理环境
cac env create win-test-basic
[[ -f "$HOME/.cac/envs/win-test-basic/uuid" ]] && echo "PASS: uuid exists" || echo "FAIL"
[[ -f "$HOME/.cac/envs/win-test-basic/hostname" ]] && echo "PASS: hostname exists" || echo "FAIL"
[[ -f "$HOME/.cac/envs/win-test-basic/mac_address" ]] && echo "PASS: mac exists" || echo "FAIL"
[[ -d "$HOME/.cac/envs/win-test-basic/.claude" ]] && echo "PASS: .claude dir exists" || echo "FAIL"

# 验证激活
current=$(cat "$HOME/.cac/current" 2>/dev/null)
[[ "$current" == "win-test-basic" ]] && echo "PASS: activated" || echo "FAIL: current=$current"

# 清理
cac env rm win-test-basic
```

### 8. 版本下载 (Windows)

```bash
# 注意: 需要网络
cac claude install latest

# 验证下载
latest_ver=$(cat "$HOME/.cac/versions/.latest" 2>/dev/null)
[[ -n "$latest_ver" ]] && echo "PASS: latest=$latest_ver" || echo "FAIL: no latest"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        [[ -f "$HOME/.cac/versions/$latest_ver/claude.exe" ]] && echo "PASS: claude.exe exists" || echo "FAIL"
        ;;
    *)
        [[ -f "$HOME/.cac/versions/$latest_ver/claude" ]] && echo "PASS: claude exists" || echo "FAIL"
        ;;
esac

# 版本列出
cac claude ls | grep -q "$latest_ver" && echo "PASS: ls shows version" || echo "FAIL"
```

### 9. 环境切换与验证

```bash
cac env create win-test-switch
cac win-test-switch

# 验证环境检查不报错
cac env check 2>&1
exit_code=$?
[[ $exit_code -eq 0 ]] && echo "PASS: env check passed" || echo "FAIL: exit code $exit_code"

cac env rm win-test-switch
```

### 10. Clone 环境（Windows 复制模式）

```bash
# 创建源环境
cac env create win-source
echo '{"test":"value"}' > "$HOME/.cac/envs/win-source/.claude/settings.json"

# 克隆
cac env create win-cloned --clone win-source

# 验证是副本不是符号链接
if [[ "$(uname -s)" =~ ^MINGW|^MSYS|^CYGWIN ]]; then
    # Windows 下应该是普通文件
    [[ -f "$HOME/.cac/envs/win-cloned/.claude/settings.json" ]] && echo "PASS: file exists" || echo "FAIL"
    # 修改源不影响克隆
    echo '{"test":"modified"}' > "$HOME/.cac/envs/win-source/.claude/settings.json"
    cloned_val=$(cat "$HOME/.cac/envs/win-cloned/.claude/settings.json")
    [[ "$cloned_val" == *'"value"'* ]] && echo "PASS: independent copy" || echo "FAIL: linked, not copied"
fi

cac env rm win-source
cac env rm win-cloned
```

---

## CMD / PowerShell 入口测试

### 11. CMD.exe 测试

在 CMD.exe（非 Git Bash）中执行：

```cmd
REM 测试 cac
cac --version

REM 测试环境列表
cac env ls

REM 测试 claude wrapper
claude --version
```

### 12. PowerShell 测试

```powershell
# 测试 cac
cac --version

# 测试环境列表
cac env ls

# 测试 claude wrapper
claude --version
```

### 13. PATH 持久化

```cmd
REM 打开新 CMD 窗口后
where cac
where claude
REM 两者都应在 %USERPROFILE%\.cac\bin\ 下找到
```

---

## 冒烟测试脚本

完整的自动化冒烟测试位于 `tests/test-windows.sh`，覆盖：

1. `cac --version` — 版本显示
2. `cac env create` — 环境创建 + 身份文件生成
3. `cac env ls` — 环境列出
4. `cac <name>` — 环境切换
5. `cac env check` — 全量检查通过
6. `cac claude install latest` — Windows 二进制下载
7. `claude --version` — wrapper 启动真实二进制
8. 带代理环境创建 — 时区检测
9. `--clone` — 复制模式验证
10. `cac self delete` — 完整卸载

---

## 回归测试

每次 Windows 适配改动后，需在 macOS/Linux 上验证：

```bash
# 构建
bash build.sh

# ShellCheck
shellcheck -s bash -S warning \
    src/utils.sh src/cmd_*.sh src/dns_block.sh \
    src/mtls.sh src/templates.sh src/main.sh build.sh

# 基本功能
cac --version
cac env create regression-test
cac env check
cac env rm regression-test
```

---

## 已知限制

1. **符号链接**: Windows 下 `--clone` 始终复制，不创建符号链接
2. **Shell shim**: Windows 不生成 hostname/ifconfig shim（fingerprint-hook.js 覆盖）
3. **TUN 检测**: Windows 下通过 ipconfig 检测 VPN 适配器，精度低于 Linux/macOS
4. **路由操作**: Windows 下 `route.exe` 需要管理员权限
5. **Persona**: macOS 特有的 persona 预设在 Windows 下部分有效（TERM_PROGRAM 有效，__CFBundleIdentifier 无意义）
