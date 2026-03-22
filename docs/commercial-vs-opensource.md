# CAC 开源版 vs fkclaude 商业版

## 概述

CAC (Claude Anti-fingerprint Cloak) 有两个版本：

- **开源版 (cac)** — [github.com/nmhjklnm/cac](https://github.com/nmhjklnm/cac)，MIT 协议，社区维护
- **商业版 (fkclaude)** — 私有仓库，基于开源版扩展，提供增值服务

## 功能对比

| 功能 | 开源版 (cac) | 商业版 (fkclaude) |
|---|:---:|:---:|
| **隐私保护** | | |
| Shell shim 拦截 (ioreg/hostname/ifconfig/cat) | Y | Y |
| Node.js fingerprint-hook.js (os.hostname/networkInterfaces/userInfo) | Y | Y |
| 多层遥测环境变量保护 (12 层) | Y | Y |
| CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC | Y | Y |
| NS 层级 DNS 遥测拦截 + DoH | Y | Y |
| mTLS 客户端证书 | Y | Y |
| HOSTALIASES 备用拦截 | Y | Y |
| **代理 & 身份管理** | | |
| 多 profile 身份切换 | Y | Y |
| 代理注入 (HTTP/SOCKS5 自动检测) | Y | Y |
| Pre-flight 代理连通性检查 | Y | Y |
| Statsig stable_id / userID 注入 | Y | Y |
| 时区/语言自动检测 | Y | Y |
| **监控工具** | | |
| mitmproxy 抓包工具包 | Y | Y |
| 指纹泄漏关键词扫描 | Y | Y |
| **商业增值** | | |
| 一键安装脚本 (国内 OSS 镜像) | - | Y |
| Max 额度 Patch (hasExtraUsageEnabled) | - | Y |
| OAuth 自动授权 (fkclaude auth) | - | Y |
| Server + Token 模型 (中心化管理) | - | Y |
| Relay 本地中转 (绕过 TUN) | - | Y |
| Windows 支持 (PowerShell + CMD) | - | Y |
| Admin Web UI | - | Y |
| GitHub Actions CI/CD | - | Y |

## 技术差异

### 品牌 & 路径

| | 开源版 | 商业版 |
|---|---|---|
| 命令名 | `cac` | `fkclaude` |
| 数据目录 | `~/.cac/` | `~/.fkclaude/` |
| 变量名 | `CAC_DIR` | `FK_DIR` |
| 构建产物 | `cac` (bash script) | `fkclaude` (bash script) |

### 架构差异

**开源版**：用户自带代理，`cac add <name> <proxy_url>` 直接配置代理地址。

**商业版**：Server + Token 模型。用户配置服务端地址和 token，代理由服务端分配：
- `fkclaude server <addr>` 设置服务端
- `fkclaude add <name> <token>` 用 token 创建 profile
- `fkclaude auth` 从服务端获取 OAuth 凭证
- 可选 `cac-relay` 二进制做本地中转

## 贡献指南

开源版接受以下类型的贡献：
- 隐私保护能力增强（新的 shim、hook、环境变量）
- Bug 修复
- 跨平台兼容性改进
- 文档改进
- mitmproxy 监控工具增强

商业版的功能（server/relay/auth/Max patch/Windows）不会合入开源版。

## 仓库管理

- 通用改进在开源版上开发，手动移植到商业版
- 商业功能只在私有仓库开发
- 开源版使用 `cac` 品牌，商业版使用 `fkclaude` 品牌，互不混淆
