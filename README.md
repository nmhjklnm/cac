<div align="center">

# cac — Claude Code Cloak

**Privacy Cloak + CLI Proxy for Claude Code**

**[中文](#中文) | [English](#english)**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)]()
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)]()

</div>

---

<a id="中文"></a>

## 中文

> **[Switch to English](#english)**

### 为什么需要 cac

Claude Code 在运行过程中会读取并上报设备标识符（硬件 UUID、安装 ID、网络出口 IP 等）。cac 通过 wrapper 机制拦截所有 `claude` 调用，在进程层面同时解决两个问题：

**A. 隐私隔离** — 每个配置对外呈现独立的设备身份，彻底隔离真实设备指纹。

**B. CLI 专属代理** — 进程级注入代理，`claude` 流量直连远端代理服务器。无需 Clash / Shadowrocket 等本地代理工具，无需中转，无需起本地服务端。配合静态住宅 IP，获得固定、干净的出口身份。

### 特性一览

| | 特性 | 说明 |
|:---|:---|:---|
| **A** | 硬件 UUID 隔离 | macOS: 拦截 `ioreg` / Linux: 拦截 `machine-id` |
| **A** | hostname / MAC 隔离 | 拦截 `hostname` 和 `ifconfig` 命令 |
| **A** | stable_id / userID 隔离 | 切换配置时自动写入独立标识 |
| **A** | 时区 / 语言伪装 | 根据代理出口地区自动匹配 |
| **A** | NS 层级遥测拦截 | DNS guard 拦截 `statsig.anthropic.com` 等遥测域名 |
| **A** | 12 层环境变量保护 | 全面禁用遥测、错误上报、非必要流量 |
| **A** | fetch 遥测拦截 | 替换原生 fetch，防止绕过 DNS 拦截 |
| **A** | mTLS 客户端证书 | 自签 CA + 每环境独立客户端证书 |
| **B** | 进程级代理 | 支持 HTTP/HTTPS/SOCKS5 代理 |
| **B** | 免本地服务端 | 无需 Clash / Shadowrocket / TUN，CLI 直连 |
| **B** | 静态住宅 IP 支持 | 配置固定代理 → 固定出口 IP |
| **B** | 启动前连通检测 | 代理不可达时拒绝启动，真实 IP 零泄漏 |
| **B** | 本地代理冲突检测 | `cac check` 自动检测 Clash/TUN 冲突 |

所有 `claude` 调用（含 Agent 子进程）均通过 wrapper 拦截。零入侵 Claude Code 源代码。

### 安装

> ⚠️ **请只选择其中一种方式，切勿同时安装！**

**方式 A：npm（推荐）**

```bash
npm install -g claude-cac
cac setup          # 自动配置 PATH，无需手动修改
```

**方式 B：一键脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/nmhjklnm/cac/master/install.sh | bash
```

安装完成后重开终端，或执行 `source ~/.zshrc`。

### 卸载

```bash
cac delete                       # 自动清除数据 + PATH 配置
npm uninstall -g claude-cac      # npm 用户需额外执行此步
```

<details>
<summary>手动卸载</summary>

```bash
rm -rf ~/.cac                    # 删除数据目录
rm -f ~/bin/cac                  # 删除命令（bash 安装）
# 编辑 ~/.zshrc，移除 # >>> cac ... <<< 标记块
```
</details>

### 使用

```bash
# 添加配置
cac add us1 1.2.3.4:1080:username:password
cac add us2 "socks5://username:password@1.2.3.4:1080"
cac add us3 "http://127.0.0.1:7890"
cac add us4 "socks5://127.0.0.1:7891"

# 切换配置
cac us1

# 检查状态（含代理冲突检测）
cac check

# 启动 Claude Code
claude
```

首次使用需在 Claude Code 内执行 `/login` 完成账号登录。

### 命令

| 命令 | 说明 |
|:---|:---|
| `cac setup` | 首次安装，自动配置 PATH |
| `cac add <名字> <host:port:u:p>` | 添加配置 |
| `cac <名字>` | 切换配置 |
| `cac ls` | 列出所有配置 |
| `cac check` | 检查代理 + 安全防护 + 冲突检测 |
| `cac stop` / `cac -c` | 停用 / 恢复保护 |
| `cac delete` | 卸载（清除数据 + PATH） |
| `cac -v` | 版本号 + 安装方式 |

### 工作原理

```
                cac wrapper (进程级，零入侵源代码)
                ┌──────────────────────────────────────┐
  claude ──────►│ 12 层环境变量遥测保护                  │──── 直连远端代理 ────► Anthropic API
                │ NODE_OPTIONS --require DNS guard     │     (静态住宅 IP)
                │ PATH 前置 shim（设备指纹隔离）         │
                │ mTLS 客户端证书注入                    │
                │ 启动前代理连通性检测                    │
                └──────────────────────────────────────┘
                    ↑ dns.lookup / net.connect / fetch 遥测拦截
                    ↑ macOS: ioreg/hostname/ifconfig shim
                    ↑ Linux: cat/hostname/ifconfig shim
```

### 文件结构

```
~/.cac/
├── bin/claude            # wrapper（拦截所有 claude 调用）
├── shim-bin/             # ioreg / hostname / ifconfig / cat shim
├── cac-dns-guard.js      # NS 层级 DNS 拦截 + mTLS 注入 + fetch 补丁
├── blocked_hosts         # HOSTALIASES 遥测域名拦截（备用层）
├── ca/                   # mTLS 自签 CA 证书
├── real_claude           # 真实 claude 二进制路径
├── current               # 当前激活的配置名
└── envs/<name>/
    ├── proxy             # 代理地址
    ├── uuid / stable_id / user_id  # 独立身份标识
    ├── machine_id / hostname / mac_address  # 独立设备指纹
    ├── client_cert.pem / client_key.pem     # mTLS 客户端证书
    └── tz / lang         # 时区 / 语言
```

### 注意事项

> **本地代理工具共存**
> 若同时使用 Clash / Shadowrocket 等 TUN 模式，需为代理服务器 IP 添加 DIRECT 规则。`cac check` 会自动检测冲突并给出修复建议。

> **第三方 API 配置**
> wrapper 启动时自动清除 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`。

> **IPv6**
> 建议在系统层关闭 IPv6，防止真实出口 IPv6 地址被暴露。

---

<a id="english"></a>

## English

> **[切换到中文](#中文)**

### Why cac

Claude Code reads and reports device identifiers at runtime (hardware UUID, installation ID, network egress IP, etc.). cac intercepts all `claude` invocations via a wrapper, solving two problems at the process level — without modifying any Claude Code source code:

**A. Privacy Cloak** — Each profile presents an independent device identity, fully isolating your real device fingerprint.

**B. CLI Proxy** — Process-level proxy injection; `claude` traffic connects directly to the remote proxy server. No Clash / Shadowrocket or any local proxy tools needed.

### Features

| | Feature | Description |
|:---|:---|:---|
| **A** | Hardware UUID isolation | macOS: intercepts `ioreg` / Linux: intercepts `machine-id` |
| **A** | hostname / MAC isolation | Intercepts `hostname` and `ifconfig` commands |
| **A** | stable_id / userID isolation | Writes independent identifiers on profile switch |
| **A** | Timezone / locale spoofing | Auto-detected from proxy exit region |
| **A** | NS-level telemetry blocking | DNS guard blocks `statsig.anthropic.com` and other telemetry domains |
| **A** | 12-layer env var protection | Disables telemetry, error reporting, non-essential traffic |
| **A** | fetch telemetry interception | Replaces native fetch to prevent DNS interception bypass |
| **A** | mTLS client certificates | Self-signed CA + per-profile client certificates |
| **B** | Process-level proxy | Supports HTTP/HTTPS/SOCKS5 proxies |
| **B** | No local server needed | No Clash / Shadowrocket / TUN — direct CLI connection |
| **B** | Static residential IP support | Fixed proxy config = fixed egress IP |
| **B** | Pre-launch connectivity check | Blocks startup if proxy unreachable — zero real IP leakage |
| **B** | Local proxy conflict detection | `cac check` detects Clash/TUN conflicts automatically |

All `claude` invocations (including Agent subprocesses) are intercepted. Zero invasion of Claude Code source code.

### Installation

> ⚠️ **Choose only ONE method. Do NOT install both!**

**Option A: npm (recommended)**

```bash
npm install -g claude-cac
cac setup          # auto-configures PATH
```

**Option B: One-line script**

```bash
curl -fsSL https://raw.githubusercontent.com/nmhjklnm/cac/master/install.sh | bash
```

Restart your terminal or run `source ~/.zshrc` after installation.

### Uninstallation

```bash
cac delete                       # removes all data + PATH entries
npm uninstall -g claude-cac      # npm users: also run this
```

<details>
<summary>Manual uninstall</summary>

```bash
rm -rf ~/.cac                    # remove data directory
rm -f ~/bin/cac                  # remove command (bash install)
# edit ~/.zshrc, remove the # >>> cac ... <<< block
```
</details>

### Usage

```bash
cac add us1 1.2.3.4:1080:username:password
cac add us2 "socks5://username:password@1.2.3.4:1080"
cac add us3 "http://127.0.0.1:7890"
cac add us4 "socks5://127.0.0.1:7891"
cac us1
cac check    # includes proxy conflict detection
claude
```

On first use, run `/login` inside Claude Code to authenticate.

### Commands

| Command | Description |
|:---|:---|
| `cac setup` | First-time setup, auto-configures PATH |
| `cac add <name> <host:port:u:p>` | Add profile |
| `cac <name>` | Switch profile |
| `cac ls` | List all profiles |
| `cac check` | Check proxy + security + conflict detection |
| `cac stop` / `cac -c` | Disable / re-enable protection |
| `cac delete` | Uninstall (removes data + PATH) |
| `cac -v` | Version + installation method |

### How It Works

```
                cac wrapper (process-level, zero source invasion)
                ┌──────────────────────────────────────┐
  claude ──────►│ 12-layer env var telemetry protection │──── Direct to remote ────► Anthropic API
                │ NODE_OPTIONS --require DNS guard      │     (static residential)
                │ PATH-prepended shims (fingerprint)    │
                │ mTLS client cert injection            │
                │ Pre-flight proxy check                │
                └──────────────────────────────────────┘
                    ↑ dns.lookup / net.connect / fetch telemetry interception
                    ↑ macOS: ioreg/hostname/ifconfig shim
                    ↑ Linux: cat/hostname/ifconfig shim
```

### Notes

> **Coexisting with local proxy tools**
> If you also use Clash / Shadowrocket in TUN mode, add a DIRECT rule for the proxy server IP. `cac check` will detect conflicts and provide fix suggestions.

> **Third-party API configuration**
> The wrapper automatically clears `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` on startup.

> **IPv6**
> It is recommended to disable IPv6 at the system level to prevent your real IPv6 egress address from being exposed.

---

<div align="center">

MIT License

</div>
