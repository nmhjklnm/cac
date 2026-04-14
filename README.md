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
npm install
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

## 卸载

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
