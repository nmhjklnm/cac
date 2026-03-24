<div align="center">

# cac

**Claude Code 小雨伞** — Isolate, protect, and manage your Claude Code.

版本、配置、身份、代理，一个命令搞定。

**[中文](#中文) | [English](#english)**

[![GitHub stars](https://img.shields.io/github/stars/nmhjklnm/cac?style=social)](https://github.com/nmhjklnm/cac)
[![Docs](https://img.shields.io/badge/Docs-cac.nextmind.space-D97706.svg)](https://cac.nextmind.space/docs)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey.svg)]()

If this project helps you, give it a :star: — it helps others find it too.

</div>

---

<a id="中文"></a>

## 中文

> **[Switch to English](#english)**

### 简介

**cac** 是 Claude Code 的环境管理器，类似 uv 之于 Python：

- **版本管理** — 安装、切换、回滚 Claude Code 版本
- **环境隔离** — 每个环境独立的 `.claude` 配置 + 身份 + 代理
- **隐私保护** — 设备指纹伪装 + 遥测阻断 + mTLS
- **零配置** — 无需 setup，首次使用自动初始化

### 安装

```bash
# npm（推荐）
npm install -g claude-cac

# 或手动安装
curl -fsSL https://raw.githubusercontent.com/nmhjklnm/cac/master/install.sh | bash
```

### 快速上手

```bash
# 安装 Claude Code
cac claude install latest

# 创建环境
cac env create work -p 1.2.3.4:1080:u:p -c latest

# 激活
cac work

# 启动 Claude Code（首次需 /login）
claude
```

代理可选 — 不需要代理也能用：

```bash
cac env create personal                  # 只要身份隔离
cac env create work -c 2.1.81           # 指定版本，无代理
```

### 版本管理

```bash
cac claude install latest               # 安装最新版
cac claude install 2.1.81               # 安装指定版本
cac claude ls                           # 列出已安装版本
cac claude pin 2.1.81                   # 当前环境切换版本
cac claude uninstall 2.1.81             # 卸载
```

### 环境管理

```bash
cac env create <name> [-p <proxy>] [-c <version>] [--type local|container]
cac env ls                              # 列出所有环境
cac env rm <name>                       # 删除环境
cac <name>                              # 激活环境（快捷方式）
cac ls                                  # = cac env ls
```

每个环境完全隔离：
- **Claude Code 版本** — 不同环境可以用不同版本
- **`.claude` 配置** — sessions、settings、memory 各自独立
- **身份信息** — UUID、hostname、MAC 等完全不同
- **代理出口** — 每个环境走不同代理（或不走代理）

### 全部命令

| 命令 | 说明 |
|:---|:---|
| **版本管理** | |
| `cac claude install [latest\|<ver>]` | 安装 Claude Code |
| `cac claude uninstall <ver>` | 卸载版本 |
| `cac claude ls` | 列出已安装版本 |
| `cac claude pin <ver>` | 当前环境绑定版本 |
| **环境管理** | |
| `cac env create <name> [-p proxy] [-c ver]` | 创建环境 |
| `cac env ls` | 列出环境 |
| `cac env rm <name>` | 删除环境 |
| `cac <name>` | 激活环境 |
| **自管理** | |
| `cac self update` | 更新 cac 自身 |
| **其他** | |
| `cac ls` | 列出环境（= `cac env ls`） |
| `cac check` | 检查当前环境 |
| `cac relay on\|off\|status` | 本地中转（绕过 TUN） |
| `cac stop` / `cac resume` | 暂停 / 恢复保护 |
| `cac delete` | 卸载 cac |
| `cac -v` | 版本号 |

### 代理格式

```
host:port:user:pass       带认证（自动检测协议）
host:port                 无认证
socks5://u:p@host:port    指定协议
```

### 隐私保护

| 特性 | 实现方式 |
|:---|:---|
| 硬件 UUID 隔离 | macOS `ioreg` / Linux `machine-id` / Windows `wmic`+`reg` shim |
| 主机名 / MAC 隔离 | Shell shim + Node.js `os.hostname()` / `os.networkInterfaces()` hook |
| Node.js 指纹钩子 | `fingerprint-hook.js` 通过 `NODE_OPTIONS --require` 注入 |
| 遥测阻断 | DNS guard + 12 层环境变量 + fetch 拦截 + HOSTALIASES |
| 健康检查 bypass | 本地 HTTPS server + `/etc/hosts` + `NO_PROXY` |
| mTLS 客户端证书 | 自签 CA + 每环境独立客户端证书 |
| `.claude` 配置隔离 | 每个环境独立的 `CLAUDE_CONFIG_DIR` |

### 工作原理

```
              cac wrapper（进程级，零侵入源代码）
              ┌──────────────────────────────────────────┐
  claude ────►│  CLAUDE_CONFIG_DIR → 隔离配置目录          │
              │  版本解析 → ~/.cac/versions/<ver>/claude   │
              │  健康检查 bypass（本地 HTTPS server）       │
              │  12 层遥测环境变量保护                      │──► 代理 ──► Anthropic API
              │  NODE_OPTIONS: DNS guard + 指纹钩子        │
              │  PATH: 设备指纹 shim                       │
              │  mTLS: 客户端证书注入                       │
              └──────────────────────────────────────────┘
```

### 文件结构

```
~/.cac/
├── versions/<ver>/claude     # Claude Code 二进制文件
├── bin/claude                # wrapper
├── shim-bin/                 # ioreg / hostname / ifconfig / cat shim
├── fingerprint-hook.js       # Node.js 指纹拦截
├── cac-dns-guard.js          # DNS + fetch 遥测拦截
├── ca/                       # 自签 CA + 健康检查 bypass 证书
├── current                   # 当前激活的环境名
└── envs/<name>/
    ├── .claude/              # 隔离的 .claude 配置目录
    ├── proxy                 # 代理地址（可选）
    ├── version               # 绑定的 Claude Code 版本
    ├── type                  # local / container
    ├── uuid / stable_id      # 隔离身份
    ├── hostname / mac_address / machine_id
    └── client_cert.pem       # mTLS 证书
```

### Docker 容器模式

完全隔离的运行环境：sing-box TUN 网络隔离 + cac 身份伪装，预装 Claude Code。

```bash
cac docker setup     # 粘贴代理地址，网络自动检测
cac docker start     # 启动容器
cac docker enter     # 进入容器，claude + cac 直接可用
cac docker check     # 网络 + 身份一键诊断
cac docker port 6287 # 端口转发
```

代理格式：`ip:port:user:pass`（SOCKS5）、`ss://...`、`vmess://...`、`vless://...`、`trojan://...`

### 注意事项

- **首次登录**：启动 `claude` 后，输入 `/login` 完成 OAuth 授权
- **TUN 冲突**：使用 `cac relay on` 或在 TUN 软件中为代理 IP 添加 DIRECT 规则
- **IPv6**：建议系统级关闭，防止真实地址泄露

---

<a id="english"></a>

## English

> **[切换到中文](#中文)**

### Overview

**cac** — Isolate, protect, and manage your Claude Code:

- **Version management** — install, switch, rollback Claude Code versions
- **Environment isolation** — independent `.claude` config + identity + proxy per environment
- **Privacy protection** — device fingerprint spoofing + telemetry blocking + mTLS
- **Zero config** — no setup needed, auto-initializes on first use

### Install

```bash
# npm (recommended)
npm install -g claude-cac

# or manual
curl -fsSL https://raw.githubusercontent.com/nmhjklnm/cac/master/install.sh | bash
```

### Quick start

```bash
# Install Claude Code
cac claude install latest

# Create environment
cac env create work -p 1.2.3.4:1080:u:p -c latest

# Activate
cac work

# Run Claude Code (first time: /login)
claude
```

Proxy is optional:

```bash
cac env create personal                  # identity isolation only
cac env create work -c 2.1.81           # pinned version, no proxy
```

### Version management

```bash
cac claude install latest               # install latest
cac claude install 2.1.81               # install specific version
cac claude ls                           # list installed versions
cac claude pin 2.1.81                   # pin current env to version
cac claude uninstall 2.1.81             # remove
```

### Environment management

```bash
cac env create <name> [-p <proxy>] [-c <version>] [--type local|container]
cac env ls                              # list all environments
cac env rm <name>                       # remove environment
cac <name>                              # activate (shortcut)
cac ls                                  # = cac env ls
```

Each environment is fully isolated:
- **Claude Code version** — different envs can use different versions
- **`.claude` config** — sessions, settings, memory are independent
- **Identity** — UUID, hostname, MAC are all different
- **Proxy** — each env routes through a different proxy (or none)

### All commands

| Command | Description |
|:---|:---|
| **Version management** | |
| `cac claude install [latest\|<ver>]` | Install Claude Code |
| `cac claude uninstall <ver>` | Remove version |
| `cac claude ls` | List installed versions |
| `cac claude pin <ver>` | Pin current env to version |
| **Environment management** | |
| `cac env create <name> [-p proxy] [-c ver]` | Create environment |
| `cac env ls` | List environments |
| `cac env rm <name>` | Remove environment |
| `cac <name>` | Activate environment |
| **Self-management** | |
| `cac self update` | Update cac itself |
| **Other** | |
| `cac ls` | List environments (= `cac env ls`) |
| `cac check` | Verify current environment |
| `cac relay on\|off\|status` | Local relay (bypass TUN) |
| `cac stop` / `cac resume` | Pause / resume protection |
| `cac delete` | Uninstall cac |
| `cac -v` | Show version |

### Privacy protection

| Feature | How |
|:---|:---|
| Hardware UUID isolation | macOS `ioreg` / Linux `machine-id` / Windows `wmic`+`reg` shim |
| Hostname / MAC isolation | Shell shim + Node.js `os.hostname()` / `os.networkInterfaces()` hook |
| Node.js fingerprint hook | `fingerprint-hook.js` via `NODE_OPTIONS --require` |
| Telemetry blocking | DNS guard + 12 env vars + fetch interception + HOSTALIASES |
| Health check bypass | Local HTTPS server + `/etc/hosts` + `NO_PROXY` |
| mTLS client certificates | Self-signed CA + per-profile client certs |
| `.claude` config isolation | Per-environment `CLAUDE_CONFIG_DIR` |

### How it works

```
              cac wrapper (process-level, zero source invasion)
              ┌──────────────────────────────────────────┐
  claude ────►│  CLAUDE_CONFIG_DIR → isolated config dir   │
              │  Version resolve → ~/.cac/versions/<ver>   │
              │  Health check bypass (local HTTPS server)  │
              │  Env vars: 12-layer telemetry kill         │──► Proxy ──► Anthropic API
              │  NODE_OPTIONS: DNS guard + fingerprint     │
              │  PATH: device fingerprint shims            │
              │  mTLS: client cert injection               │
              └──────────────────────────────────────────┘
```

### File layout

```
~/.cac/
├── versions/<ver>/claude     # Claude Code binaries
├── bin/claude                # wrapper
├── shim-bin/                 # ioreg / hostname / ifconfig / cat shims
├── fingerprint-hook.js       # Node.js fingerprint interception
├── cac-dns-guard.js          # DNS + fetch telemetry interception
├── ca/                       # self-signed CA + health bypass cert
├── current                   # active environment name
└── envs/<name>/
    ├── .claude/              # isolated .claude config directory
    ├── proxy                 # proxy URL (optional)
    ├── version               # pinned Claude Code version
    ├── type                  # local / container
    ├── uuid / stable_id      # isolated identity
    ├── hostname / mac_address / machine_id
    └── client_cert.pem       # mTLS cert
```

### Docker mode

Fully isolated environment: sing-box TUN network isolation + cac identity protection, with Claude Code pre-installed.

```bash
cac docker setup     # paste proxy, network auto-detected
cac docker start     # start container
cac docker enter     # shell with claude + cac ready
cac docker check     # network + identity diagnostics
cac docker port 6287 # port forwarding
```

Proxy formats: `ip:port:user:pass` (SOCKS5), `ss://...`, `vmess://...`, `vless://...`, `trojan://...`

### Notes

- **First login**: Run `claude`, then type `/login`. Health check is automatically bypassed.
- **TUN conflicts**: Use `cac relay on` or add DIRECT rule in your TUN software.
- **IPv6**: Recommend disabling system-wide to prevent real address exposure.

---

<div align="center">

MIT License

</div>
