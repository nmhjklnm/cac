# cac Windows 适配计划

> 对应 Issue: [nmhjklnm/cac#32](https://github.com/nmhjklnm/cac/issues/32)

## 适配策略

基于 **Git Bash (MINGW64)**，而非 PowerShell 重写。

Claude Code 在 Windows 上已依赖 Git for Windows，Git Bash 保证可用。核心思路是修复 bash 脚本中的 Unix 专有特性，使其在 Git Bash 下正常运行，同时生成 `.cmd` 入口文件使 CMD/PowerShell 也能调用。

### 已有基础（无需改动）

| 组件 | 状态 | 说明 |
|------|------|------|
| `fingerprint-hook.js` | 已支持 | 完整 Windows 支持（拦截 wmic、reg query 等） |
| `cac-dns-guard.js` | 已支持 | 纯 Node.js，跨平台 |
| `relay.js` | 已支持 | 纯 Node.js，跨平台 |
| `_detect_os()` | 已支持 | 识别 MINGW/MSYS/CYGWIN → "windows" |
| `postinstall.js` | 已支持 | 处理 USERPROFILE |

### 需要解决的 7 类核心问题

| # | 问题 | 影响范围 | 解决方案 |
|---|------|----------|----------|
| 1 | `/dev/tcp` 不可用 | 7 处 | `_tcp_check()` 函数 + Node.js fallback |
| 2 | `python3` 不保证有 | 8+ 处 | 全部替换为 `node -e`（Node.js 保证可用） |
| 3 | `_detect_platform()` 不识别 Windows | 1 处 | 添加 `win32-x64` / `win32-arm64` |
| 4 | `pgrep/pkill` 不存在 | 3 处 | `tasklist.exe` / `taskkill.exe` |
| 5 | `ln -sf` 在 NTFS 上创建副本 | 2 处 | Windows 下强制复制模式 |
| 6 | 二进制名 `claude` vs `claude.exe` | 多处 | 平台感知的文件名处理 |
| 7 | CMD/PowerShell 无法直接调用 | 入口 | 生成 `.cmd` 包装器 |

---

## 任务分解

### Phase 0: 前置调研

#### Task 0.1: 验证 `/dev/tcp` 兼容性
- **类型**: 调研
- **内容**: 在 Git for Windows 2.40+, 2.44, 2.48 上测试 `/dev/tcp`，确认最低可用版本
- **产出**: 确定 `/dev/tcp` 替换是必须还是防御性 fallback
- **复杂度**: S

#### Task 0.2: 验证 Claude Code Windows 二进制下载
- **类型**: 调研
- **内容**: 从 GCS 下载 `win32-x64/claude.exe`，验证 checksum 和可执行性
- **产出**: 确认 URL 模式和平台字符串
- **复杂度**: S

---

### Phase 1: 基础设施 (src/utils.sh)

#### Task 1.1: 添加 `_tcp_check()` 跨平台 TCP 检测
- **文件**: `src/utils.sh`
- **改动**: 新增函数（先 `/dev/tcp`，fallback 到 Node.js `net.connect`），修改 `_proxy_reachable()` 调用
- **测试**: 开放端口返回 0，关闭端口返回 1，fallback 路径验证
- **复杂度**: S

#### Task 1.2: `python3` → `node -e` 全量替换
- **文件**: `src/utils.sh`（4 处函数）
- **改动**:
  - `_cac_setting()` → Node.js JSON 读取
  - `_gen_uuid()` → `crypto.randomUUID()`
  - `_new_user_id()` → `crypto.randomBytes(32).toString('hex')`
  - `_update_claude_json_user_id()` → Node.js JSON 读写
- **测试**: UUID 格式验证、hex 长度验证、JSON 读写正确性
- **复杂度**: M

#### Task 1.3: `_detect_platform()` Windows 支持
- **文件**: `src/utils.sh`
- **改动**: 添加 `MINGW*|MSYS*|CYGWIN*) os="win32"` 分支
- **测试**: 返回 `win32-x64`，其他平台不变
- **复杂度**: S

#### Task 1.4: `_sha256()` Node.js fallback
- **文件**: `src/utils.sh`
- **改动**: `sha256sum` 不可用时 fallback 到 `crypto.createHash('sha256')`
- **测试**: hash 输出与 sha256sum 一致
- **复杂度**: S

#### Task 1.5: `pgrep` 跨平台替换
- **文件**: `src/utils.sh`（新函数）、`src/cmd_check.sh`
- **改动**: 新增 `_count_claude_processes()`，Windows 用 `tasklist.exe`
- **测试**: 无进程时返回 0，`set -e` 不中断
- **复杂度**: S

#### Task 1.6: `_version_binary()` Windows 二进制名
- **文件**: `src/utils.sh`
- **改动**: Windows 下返回 `claude.exe`
- **依赖**: Task 1.3
- **测试**: 路径包含 `.exe` 后缀
- **复杂度**: S

---

### Phase 2: 核心命令

#### Task 2.1: `cmd_claude.sh` Windows 版本下载
- **文件**: `src/cmd_claude.sh`
- **改动**: 下载 `claude.exe`，manifest 解析用 node，URL 含 `win32-x64`
- **依赖**: Task 1.3, 1.4, 1.6
- **测试**: 下载、校验、列出版本
- **复杂度**: M

#### Task 2.2: `cmd_env.sh` python3 → node
- **文件**: `src/cmd_env.sh`
- **改动**: 时区 JSON 解析和 settings 深度合并改用 node
- **测试**: 时区检测、合并正确性
- **复杂度**: M

#### Task 2.3: `cmd_env.sh` 符号链接处理
- **文件**: `src/cmd_env.sh`
- **改动**: Windows 下强制 `clone_link=false`
- **测试**: 创建副本而非符号链接
- **复杂度**: S

#### Task 2.4: `cmd_setup.sh` Windows 适配
- **文件**: `src/cmd_setup.sh`、`src/utils.sh`
- **改动**: 搜索 `claude.exe`、跳过 Unix shim、python3→node
- **依赖**: Task 1.3, 1.6
- **测试**: 找到二进制、不生成 Unix shim
- **复杂度**: M

---

### Phase 3: Wrapper 与集成

#### Task 3.1: wrapper 中 python3 → node (templates.sh)
- **文件**: `src/templates.sh`
- **改动**: wrapper 内 settings merge 用 node
- **测试**: 无 python3 系统上合并正常
- **复杂度**: S

#### Task 3.2: wrapper 中 `/dev/tcp` + `pgrep` 替换
- **文件**: `src/templates.sh`
- **改动**: 内联 `_tcp_ok()`（4 处），pgrep→tasklist 条件逻辑（1 处）
- **测试**: 代理检查、端口扫描、进程计数
- **复杂度**: M

#### Task 3.3: `cmd_relay.sh` /dev/tcp 替换
- **文件**: `src/cmd_relay.sh`
- **改动**: 3 处替换为 `_tcp_check`
- **依赖**: Task 1.1
- **测试**: relay 端口检测正常
- **复杂度**: S

#### Task 3.4: `cmd_relay.sh` python3 + 路由支持
- **文件**: `src/cmd_relay.sh`
- **改动**: hostname 解析用 node，添加 Windows `route.exe` 和 TUN 检测
- **依赖**: Task 1.3
- **测试**: 解析正常、TUN 检测不误报
- **复杂度**: M

#### Task 3.5: `cmd_check.sh` Windows 适配
- **文件**: `src/cmd_check.sh`
- **改动**: python3→node、IPv6 检测 Windows 分支、pgrep 替换
- **依赖**: Task 1.5
- **测试**: `cac env check` 无错误
- **复杂度**: M

#### Task 3.6: wrapper 中 claude.exe 处理
- **文件**: `src/templates.sh`
- **改动**: 版本解析检查 `.exe`
- **依赖**: Task 2.1
- **测试**: wrapper 找到 claude.exe
- **复杂度**: S

#### Task 3.7: mTLS 进程替换修复
- **文件**: `src/mtls.sh`
- **改动**: `<(printf ...)` 改为临时文件方案
- **测试**: 证书生成和验证正常
- **复杂度**: S

---

### Phase 4: 高级特性

#### Task 4.1: `cmd_delete.sh` pkill 替换
- **文件**: `src/cmd_delete.sh`
- **改动**: 条件使用 `tasklist.exe + taskkill.exe`
- **测试**: 删除时正确终止进程
- **复杂度**: S

#### Task 4.2: `cmd_docker.sh` Windows 感知
- **文件**: `src/cmd_docker.sh`
- **改动**: 临时目录 `${TMPDIR:-/tmp}`
- **测试**: Docker Desktop 环境下运行
- **复杂度**: S

---

### Phase 5: 入口与打包

#### Task 5.1: 生成 `claude.cmd` 入口
- **文件**: `src/templates.sh`、`src/cmd_setup.sh`
- **改动**: Windows 下生成 `~/.cac/bin/claude.cmd` 调用 bash wrapper
- **依赖**: Task 2.4
- **测试**: CMD/PowerShell 下 `claude --version` 正常
- **复杂度**: M

#### Task 5.2: 更新 `cac.cmd`
- **文件**: `cac.cmd`
- **改动**: 从调用 `cac.ps1` 改为调用 `bash cac`
- **测试**: CMD/PowerShell 下 `cac env ls` 正常
- **复杂度**: S

#### Task 5.3: Windows 系统 PATH 设置
- **文件**: `src/utils.sh`
- **改动**: 通过 `powershell.exe` 添加 `~/.cac/bin` 到 User PATH
- **依赖**: Task 5.1
- **测试**: 新 CMD 窗口能找到 cac/claude
- **复杂度**: M

#### Task 5.4: `postinstall.js` Windows 适配
- **文件**: `scripts/postinstall.js`
- **改动**: Windows 下通过 bash 执行 cac，更新 wrapper patching
- **依赖**: Task 1.5
- **测试**: npm install 正常完成
- **复杂度**: M

---

### Phase 6: 端到端测试

#### Task 6.1: Windows 冒烟测试脚本
- **文件**: 新建 `tests/test-windows.sh`
- **内容**: 10 项完整流程测试
- **复杂度**: L

#### Task 6.2: CMD/PowerShell 入口测试
- **内容**: `.cmd` 入口和 PATH 持久化验证
- **依赖**: Task 5.1, 5.2, 5.3
- **复杂度**: M

---

## 依赖关系图

```
Phase 0: 调研
  0.1, 0.2 (并行)

Phase 1: 基础
  1.1, 1.2, 1.3, 1.4, 1.5 (并行)
  1.6 ← 1.3

Phase 2: 核心
  2.1 ← 1.3, 1.4, 1.6
  2.2, 2.3 (并行)
  2.4 ← 1.3, 1.6

Phase 3: 集成
  3.1, 3.7 (并行)
  3.2 (独立)
  3.3 ← 1.1
  3.4 ← 1.3
  3.5 ← 1.5
  3.6 ← 2.1

Phase 4: 高级
  4.1, 4.2 (并行)

Phase 5: 打包
  5.1 ← 2.4
  5.2 (独立)
  5.3 ← 5.1
  5.4 ← 1.5

Phase 6: 测试
  6.1 ← 全部
  6.2 ← 5.1, 5.2, 5.3
```

## 统计

| Phase | 任务数 | 复杂度 |
|-------|--------|--------|
| 0 调研 | 2 | 2S |
| 1 基础 | 6 | 5S + 1M |
| 2 核心 | 4 | 1S + 3M |
| 3 集成 | 7 | 4S + 3M |
| 4 高级 | 2 | 2S |
| 5 打包 | 4 | 2S + 2M |
| 6 测试 | 2 | 1M + 1L |
| **合计** | **27** | **16S, 9M, 1L** |

## 验证方式

每个任务完成后：
1. 运行任务自带的测试用例
2. `bash build.sh` 构建成功
3. `shellcheck -s bash -S warning` 通过
4. macOS/Linux 回归验证

Phase 6 完成后：
5. Windows Git Bash / CMD / PowerShell 完整流程
6. GitHub Actions CI 通过
