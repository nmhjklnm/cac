# cac-win

这是面向 **Windows 本地使用** 的 cac 适配仓库。

> 重点：本仓库 **没有发布到 npm**。不要用 `npm install -g claude-cac` 安装本仓库；那个命令安装的是上游 `nmhjklnm/cac`。使用本仓库时必须先 clone 到本地，再运行本地安装脚本。

## 项目定位

`cac-win` 保留上游 cac 的 Claude Code 环境管理能力，但 README 只保留 Windows 使用路径：

- Windows 10/11 下通过 CMD、PowerShell 或 Git Bash 使用
- `cac.cmd` / `cac.ps1` 自动查找 Git Bash，并委托给 Bash 主实现
- 通过 `scripts/install-local-win.ps1` 注册本地 checkout 的 `cac` 命令
- 初始化后生成 `%USERPROFILE%\.cac\bin\claude.cmd`
- Windows 下环境 clone 默认使用复制模式，避免 NTFS 符号链接权限问题

完整的上游式跨平台 README 已归档到 [docs/original-readme.md](docs/original-readme.md)。其中的 npm 安装/更新说明只适用于上游包，不代表本仓库已发布到 npm。

## 前置要求

- Windows 10/11
- Git for Windows，必须包含 Git Bash
- Node.js 18+，并确保 npm 在 PATH 中
- PowerShell 5.1+

## 本地安装

```powershell
git clone https://github.com/Cainiaooo/cac-win.git
cd cac-win

# 安装当前 checkout 的本地依赖
npm install

# 把当前 checkout 注册为全局 cac 命令
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-win.ps1
```

安装完成后，重新打开 CMD、PowerShell 或 Git Bash，再验证：

```powershell
cac -v
cac help
```

如果提示找不到 `cac`，检查 npm 全局 bin 目录是否在用户 PATH 中：

```powershell
npm prefix -g
```

常见路径是 `%APPDATA%\npm`。安装脚本会自动尝试写入用户 PATH，并适配 nvm-windows / fnm / volta 等 Node.js 管理器；如果当前终端没有刷新，重开终端后再试。

## 首次使用

```powershell
# 安装 cac 托管的 Claude Code 二进制
cac claude install latest

# 创建并激活 Windows 环境；代理可按需填写
cac env create win-work -p 1.2.3.4:1080:u:p

# 检查当前环境
cac env check

# 启动 Claude Code；首次进入后使用 /login
claude
```

不需要代理时也可以只做身份/配置隔离：

```powershell
cac env create personal
cac env create work -c 2.1.81
```

如果新开的 CMD / PowerShell 里找不到 `claude`，先重开终端；仍然找不到时，把 `%USERPROFILE%\.cac\bin` 加入用户 PATH。

## 常用流程

### 查看当前状态

```powershell
cac env ls
cac env check
cac env check -d
cac -v
```

### 创建和切换环境

```powershell
# 创建并自动激活环境
cac env create work

# 创建带代理的环境
cac env create work-proxy -p 1.2.3.4:1080:u:p

# 创建并绑定指定 Claude Code 版本
cac env create legacy -c 2.1.81

# 创建环境，并在每次激活时检查 Claude Code 更新
cac env create work-auto --autoupdate

# 从当前宿主配置复制 .claude 配置
cac env create cloned --clone

# 切换到某个环境
cac work

# 查看所有环境
cac env ls
```

### 修改环境

```powershell
# 给当前环境设置或修改代理
cac env set proxy 1.2.3.4:1080:u:p

# 给指定环境设置代理
cac env set work proxy 1.2.3.4:1080:u:p

# 移除当前环境代理
cac env set proxy --remove

# 切换当前环境使用的 Claude Code 版本
cac env set version 2.1.81

# 开启或关闭激活时的 Claude Code 更新检查
cac env set work autoupdate on
cac env set work autoupdate off

# 删除环境
cac env rm work
```

### 管理 Claude Code 版本

```powershell
cac claude install latest
cac claude install 2.1.81
cac claude ls
cac claude pin 2.1.81
cac claude update work
cac claude prune
cac claude prune --yes
cac claude uninstall 2.1.81
```

### 启动 Claude Code

```powershell
# 确认已经激活目标环境
cac env check

# 启动；首次进入后执行 /login
claude
```

## 代理格式

```text
host:port:user:pass
host:port
socks5://u:p@host:port
http://u:p@host:port
```

代理不是必填项；不加 `-p` 时，环境仍然会隔离 `.claude` 配置、身份信息和 Claude Code 版本。

## 命令速查

| 命令 | 用途 |
|:--|:--|
| `cac env create <name> [-p proxy] [-c version] [--clone] [--autoupdate]` | 创建并激活环境 |
| `cac <name>` | 切换到指定环境 |
| `cac env ls` / `cac ls` | 查看环境列表 |
| `cac env rm <name>` | 删除环境 |
| `cac env set [name] proxy <proxy>` | 设置环境代理 |
| `cac env set [name] proxy --remove` | 移除环境代理 |
| `cac env set [name] version <version>` | 切换环境绑定的 Claude Code 版本 |
| `cac env set [name] autoupdate <on\|off>` | 开启或关闭激活时的 Claude Code 更新检查 |
| `cac env check [-d]` / `cac check` | 检查当前环境 |
| `cac claude install [latest\|<version>]` | 安装 Claude Code 版本 |
| `cac claude ls` | 查看已安装 Claude Code 版本 |
| `cac claude pin <version>` | 当前环境绑定指定版本 |
| `cac claude update [env]` | 将环境更新到远端最新 Claude Code |
| `cac claude prune [--yes]` | 列出或删除未被环境引用的 Claude Code 版本 |
| `cac claude uninstall <version>` | 卸载指定版本 |
| `cac self delete` | 删除 cac 运行目录、wrapper 和环境数据 |
| `cac -v` | 查看 cac 版本 |

## 更新本地安装

pull 新代码或移动仓库目录后，重新生成本地 shim：

```powershell
git pull
bash build.sh
```

`build.sh` 重新生成 `cac` 脚本后立即生效——shim 直接指向本地 checkout，无需重新运行安装脚本。

如果本次更新包含 JS 运行时文件的修改（`fingerprint-hook.js`、`relay.js`、`cac-dns-guard.js`），还需同步到 `~/.cac/`：

```bash
# 手动复制（最直接）
cp cac-dns-guard.js fingerprint-hook.js relay.js ~/.cac/

# 或运行任意 cac 命令触发自动同步
cac env ls
```

> **如何判断是否需要同步 JS 文件？** 查看 `git log` 或 `git diff HEAD~1`，如果只改了 `src/*.sh` 则不需要；如果改了 `src/fingerprint-hook.js`、`src/relay.js` 或 `src/dns_block.sh` 则需要同步。

### 已安装用户如何更新

如果之前已经安装过 cac 并创建了环境，更新流程如下：

```bash
# 1. 进入仓库目录，拉取最新代码
cd E:\Projects\cac-win
git pull

# 2. 重新构建（必须在 Git Bash 中运行）
bash build.sh

# 3. 同步 JS 运行时文件（如果本次更新涉及 JS 文件修改）
cp fingerprint-hook.js relay.js cac-dns-guard.js ~/.cac/
```

**常见问题**：

- **新命令/新选项不可用**（如 `--autoupdate` 提示 `unknown option`）：说明本地 `cac` 构建产物未更新。确认已执行 `bash build.sh`，然后重试。
- **已有环境不受影响**：更新只替换 cac 程序本身，`~/.cac/envs/` 下的环境数据、身份信息、代理配置都会保留。
- **不需要重新运行安装脚本**：shim 指向本地 checkout 路径，`build.sh` 更新后立即生效。
- **不需要重新创建环境**：已有的环境和配置全部兼容。

### 卸载

```powershell
# 1. 删除 cac 运行目录、wrapper 和环境数据
cac self delete

# 2. 移除全局 shim
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-win.ps1 -Uninstall

# 3.（可选）删除仓库目录
cd .. && Remove-Item -Recurse -Force cac-win
```

如果 `cac` 已经不可用，可直接删除 `%USERPROFILE%\.cac` 目录，然后再执行步骤 2。

### Windows 已知限制

- **Git Bash 是硬依赖** — 核心逻辑用 Bash 实现，`cac.cmd` / `cac.ps1` 会自动查找 Git Bash 并委托执行。未安装时会给出明确报错和下载链接。
- **Shell shim 层不适用** — `shim-bin/` 下的 Unix 命令（`ioreg`、`ifconfig`、`hostname`、`cat`）在 Windows 上不生效，Windows 指纹保护完全依赖 `fingerprint-hook.js`（拦截 `wmic`、`reg query` 等调用）。
- **Docker 容器模式仅 Linux** — sing-box TUN 网络隔离不支持 Windows，可通过 WSL2 + Docker Desktop 替代。

完整的 Windows 支持评估和已知问题见 [`docs/windows/`](docs/windows/)。

---

### 隐私保护

| 特性 | 实现方式 |
|:---|:---|
| 硬件 UUID 隔离 | Windows: `wmic`+`reg query` hook；macOS: `ioreg`；Linux: `machine-id` |
| 主机名 / MAC 隔离 | Node.js `os.hostname()` / `os.networkInterfaces()` hook（Windows）|
| Node.js 指纹钩子 | `fingerprint-hook.js` 通过 `NODE_OPTIONS --require` 注入 |
| 遥测阻断 | DNS guard + 环境变量 + fetch 拦截 |
| 健康检查 bypass | 进程内 Node.js 拦截（无需 hosts 文件或管理员权限） |
| mTLS 客户端证书 | 自签 CA + 每环境独立客户端证书 |
| `.claude` 配置隔离 | 每个环境独立的 `CLAUDE_CONFIG_DIR` |

### 工作原理

```
              cac wrapper（进程级，零侵入源代码）
              ┌──────────────────────────────────────────┐
  claude ────►│  CLAUDE_CONFIG_DIR → 隔离配置目录          │
              │  版本解析 → ~/.cac/versions/<ver>/claude   │
              │  健康检查 bypass（进程内拦截）                │
              │  12 层遥测环境变量保护                      │──► 代理 ──► Anthropic API
              │  NODE_OPTIONS: DNS guard + 指纹钩子        │
              │  PATH: 设备指纹 shim（macOS/Linux）         │
              │  mTLS: 客户端证书注入                       │
              └──────────────────────────────────────────┘
```

---

<a id="english"></a>

## English

> **[切换到中文](#中文)**

### About this repository

**cac-win** is a Windows-focused fork of [nmhjklnm/cac](https://github.com/nmhjklnm/cac). It is **not published to npm** — installation requires cloning this repository locally. macOS and Linux users should use the [upstream repository](https://github.com/nmhjklnm/cac) instead.

Additional Windows fixes in this fork:
- IPv6 leak detection on localized Windows (Chinese/Japanese/etc.) — fixed false negatives caused by locale-dependent `ipconfig` labels
- npm global directory detection — now uses `npm config get prefix` instead of hardcoding `%APPDATA%\npm`, compatible with nvm-windows / fnm / volta / Scoop
- OpenSSL path resolution in `mtls.sh` — cleaned up to standard Git for Windows locations
- Windows entry points (`cac.cmd` / `cac.ps1`) with automatic Git Bash detection

### Notes

> **Account ban notice**: cac provides device fingerprint layer protection (UUID, hostname, MAC, telemetry blocking, config isolation), but **cannot affect account-layer risks** — including your OAuth account, payment method fingerprint, IP reputation score, or Anthropic's server-side decisions.

> **Proxy tool conflicts**: Turn off Clash, sing-box or other local proxy/VPN tools before using cac. Even if a conflict occurs, cac will fail-closed — **your real IP is never exposed**.

- **First login**: Run `claude`, then type `/login` to authorize.
- **Verify setup**: Run `cac env check` anytime to confirm privacy protection is active.
- **IPv6**: Recommend disabling system-wide to prevent real address exposure.

### Install (Windows)

**Prerequisites**:
- Windows 10 / 11
- [Git for Windows](https://git-scm.com/download/win) (must include Git Bash)
- Node.js 18+

```powershell
# 1. Clone this repository
git clone https://github.com/Cainiaooo/cac-win.git
cd cac-win

# 2. Run the installer (from PowerShell)
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-win.ps1
```

本地 shim 会记录当前 checkout 路径；仓库位置变化后必须重新执行一次。

如果你是开发者并修改了 `src/`，还需要重新生成根目录脚本：

```bash
bash build.sh
```

如果本次更新涉及 JS 运行时文件修改（`src/fingerprint-hook.js`、`src/relay.js` 或 `src/dns_block.sh`），运行任意 cac 命令会触发同步到 `%USERPROFILE%\.cac`：

```powershell
cac env ls
```

> **Do I need to sync JS files?** Check `git log` or `git diff HEAD~1` — if only `src/*.sh` changed, no sync needed. If `src/fingerprint-hook.js`, `src/relay.js`, or `src/dns_block.sh` changed, sync is required.

### Updating an existing installation

If you already have cac installed with environments set up, the update process is:

```bash
# 1. Navigate to the repo and pull latest
cd E:\Projects\cac-win
git pull

# 2. Rebuild (must run from Git Bash)
bash build.sh

# 3. Sync JS runtime files (only if this update changed JS files)
cp fingerprint-hook.js relay.js cac-dns-guard.js ~/.cac/
```

**Common issues**:

- **New commands/options not available** (e.g. `--autoupdate` shows `unknown option`): the local `cac` build is stale. Confirm `bash build.sh` was run, then retry.
- **Existing environments are preserved**: updating only replaces the cac program itself. Environment data, identities, and proxy configs under `~/.cac/envs/` are kept intact.
- **No need to re-run the installer**: shims point to your local checkout path, so `build.sh` updates take effect immediately.
- **No need to recreate environments**: existing environments and configs are fully compatible.

### Uninstall

```powershell
# 删除 cac 运行目录、wrapper 和环境数据
cac self delete

# 删除 install-local-win.ps1 创建的全局 shim
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-win.ps1 -Uninstall
```

如果 `cac` 已经不可用，可以手动删除 `%USERPROFILE%\.cac`，再从仓库根目录执行上面的 `-Uninstall` 命令。

## Windows 注意事项

- `cac.cmd` 和 `cac.ps1` 需要能找到 Git Bash；如果启动失败，先确认 Git for Windows 安装完整。
- Windows 的指纹保护主要依赖 Node.js 层的 `fingerprint-hook.js`，用于拦截 `wmic`、`reg query`、`os.hostname()`、`os.networkInterfaces()` 等调用。
- Docker 模式需要原生 Linux；Windows 用户优先使用 `cac env`，确实需要 Docker 隔离时再考虑 WSL2 + Docker Desktop。
- 如果代理不处理 IPv6，建议在系统或网卡层面关闭 IPv6，避免真实 IPv6 出口泄露。

## 更多文档

- [完整 README 归档](docs/original-readme.md)
- [Windows 排障](docs/windows/troubleshooting.md)
- [Windows 测试指南](docs/windows/testing-guide.md)
- [Windows 已知问题](docs/windows/known-issues.md)
- [Windows IPv6 测试指南](docs/windows/ipv6-test-guide.md)
- [Windows 支持评估](docs/windows/windows-support-assessment.md)
- [上游文档站](https://cac.nextmind.space/docs)
