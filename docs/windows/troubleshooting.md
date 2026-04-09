# Windows 排障

## `cac env check` 显示 `fingerprint hook not working`

这条报错通常表示 `fingerprint-hook.js` 没有被 Node.js 成功预加载。  
在 Windows + Git Bash 场景下，最常见原因是 `NODE_OPTIONS --require` 使用了 `/c/Users/...` 这种 Git Bash 路径，而原生 `node.exe` / `claude.exe` 更稳妥的是 Windows 原生路径，例如 `C:\Users\...\fingerprint-hook.js`。

### 快速修复

1. 重新打开一个新的 `CMD` / `PowerShell` 窗口。
2. 重新激活环境：

```powershell
cac main
```

3. 再次检查：

```powershell
cac env check -d
```

### 手动验证 hook 是否生效

将 `main` 替换为你的当前环境名：

```powershell
$envName = "main"
$home = $env:USERPROFILE
$expected = (Get-Content "$home\.cac\envs\$envName\hostname" -Raw).Trim()
$env:NODE_OPTIONS = "--require $home\.cac\fingerprint-hook.js"
$env:CAC_HOSTNAME = $expected
node -e "process.stdout.write(require('os').hostname())"
```

如果输出等于环境里的伪造主机名，说明 hook 本身是正常的。

### 检查文件是否存在

```powershell
dir $env:USERPROFILE\.cac\fingerprint-hook.js
dir $env:USERPROFILE\.cac\bin\claude.cmd
```

### 常见原因

- 使用了旧版 `cac` wrapper，尚未包含 Windows 原生路径转换修复
- 当前终端没有重新加载 PATH 或 shim
- 直接调用了真实 `claude.exe`，绕过了 `cac` wrapper

### 重新生成本地安装 shim

如果你是从本地仓库安装：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-win.ps1
```

然后重开终端再试。

## `cac env check` 显示 `TZ mismatch`

这表示当前环境保存的 `tz` 与代理出口 IP 所在时区不一致。  
这通常发生在：

- 环境创建时，代理出口在另一个地区
- 后续更换了代理，但没有同步更新时间伪装参数

### 快速修复

例如出口 IP 已经是上海：

```powershell
cac env set main tz Asia/Shanghai
cac env set main lang zh_CN.UTF-8
cac main
cac env check
```

### 说明

- 这是**一致性告警**，不是指纹 hook 失效
- 最好让 `tz` 与出口 IP 所在地区保持一致
- 如果只改了代理，没有重建环境，建议至少同步更新 `tz`

## `cac env check` 显示 `mTLS ✗ CA cert not found`

这表示 `%USERPROFILE%\.cac\ca\ca_cert.pem` 不存在。  
常见原因是旧版 Windows 初始化阶段没有成功生成 CA，之后又因为 wrapper 已存在而没有重试。  
在 Git for Windows 上，另一个常见原因是误用了 `usr\bin\openssl.exe`，它在某些 PowerShell / CMD 启动链路下会直接失败，只留下 `ca_key.pem`，不会生成 `ca_cert.pem`。  
当前修复版会优先使用 Git 安装目录下明确可用的 `mingw64\bin\openssl.exe`，绕开这类兼容性问题。

### 快速修复

1. 刷新本地安装入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-local-win.ps1
```

2. 重新打开一个新的 `CMD` / `PowerShell` 窗口。

3. 重新激活当前环境，让 `cac` 自动补生成 CA 和 client cert：

```powershell
cac main
cac env check
```

如果你的环境名不是 `main`，把命令里的环境名替换掉。

### 检查文件是否已补齐

```powershell
dir $env:USERPROFILE\.cac\ca
dir $env:USERPROFILE\.cac\envs\main\client_cert.pem
dir $env:USERPROFILE\.cac\envs\main\client_key.pem
```

如果你只看到 `ca_key.pem`，但没有 `ca_cert.pem`，就是典型的 Windows OpenSSL 选择问题。

### 仍然失败时

- 确认 `cac` 是当前仓库修复后的版本，而不是旧的全局 shim
- 确认 Git for Windows 安装完整，Git Bash 可正常启动
- 如果 `ca` 目录仍为空，优先检查 Git Bash 里的 `openssl` 是否可用
- 如果 `ca` 目录里只有 `ca_key.pem`，重新执行 `cac main` 让新版逻辑用 MinGW OpenSSL 补生成证书
