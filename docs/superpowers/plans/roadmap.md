# cac Roadmap

## 一、同步与迁移

### 1.1 单机迁移：从裸 Claude Code 迁入 cac

**问题**：用户已经用裸 Claude Code 跑了一段时间，`.claude/` 下有 sessions、memory、credentials。装了 cac 之后，怎么把现有状态迁入一个 cac 环境？

**设计思路**：
```bash
cac env import <name> [--from ~/.claude]    # 默认从 ~/.claude 导入
```

需要处理：
- `.claude/` 目录：sessions、settings.json、CLAUDE.md、projects/ → 直接复制到 `~/.cac/envs/<name>/.claude/`
- `.credentials.json` → 复制（OAuth token）
- `.claude.json` 中的 userID/anonymousId → 重新生成（隔离身份）
- statsig → 重新生成
- 不迁移：telemetry 缓存字段（numStartups 等）

**反向操作**：
```bash
cac env export <name> [--to ~/backup/]      # 导出环境快照
```

### 1.2 单机环境克隆

**问题**：在同一台机器上基于已有环境创建变体（相同代理、不同身份）。

```bash
cac env clone <source> <new-name>           # 复制配置，重新生成身份
cac env clone work work-test --keep-identity # 保留身份（调试用）
```

**规则**：
- 默认：复制 proxy、version、tz、lang、settings.json、CLAUDE.md；重新生成 uuid、stable_id、user_id、machine_id、hostname、mac_address、mTLS cert
- `--keep-identity`：全部复制（仅用于调试/测试）
- sessions/credentials 不复制（需要重新 /login）

### 1.3 多机同步

**问题**：多台机器上保持环境配置一致。不是同步 sessions/credentials（这些和 OAuth 绑定，不可移植），而是同步「环境定义」。

**方案 A：导出/导入文件**
```bash
cac env export <name> --config-only > work.json   # 导出配置（proxy, version, tz, settings）
cac env import <name> --from work.json             # 在另一台机器上导入
```

JSON 格式：
```json
{
  "name": "work",
  "proxy": "socks5://u:p@host:port",
  "version": "2.1.83",
  "tz": "Asia/Shanghai",
  "lang": "en_US.UTF-8",
  "settings": { ... },
  "claude_md": "..."
}
```

身份信息不导出（每台机器独立生成）。

**方案 B：Git 同步（高级）**
```bash
cac sync init                                # 初始化 ~/.cac/sync/ git repo
cac sync push                               # 推送配置到 remote
cac sync pull                               # 拉取配置到本机
```

优先做方案 A（简单、无依赖），方案 B 作为进阶。

---

## 二、环境模板与预设

### 2.1 环境模板

**问题**：团队标准化——大家用相同的 settings.json、CLAUDE.md、代理配置模板。

```bash
cac template save <name> [--from <env>]      # 从现有环境保存模板
cac template ls                              # 列出本地模板
cac env create <name> --template <tpl>       # 从模板创建
```

**模板内容**（`~/.cac/templates/<name>/`）：
- `template.json`：proxy 模式、version 策略、tz、lang
- `settings.json`：Claude Code 设置
- `CLAUDE.md`：默认记忆/指令
- `hooks/`：可选的 hook 脚本

**内置模板**：
- `default`：当前的默认配置
- `minimal`：最小化，无 proxy，无 bypass
- `team`：团队标准（可由团队维护的 git repo 分发）

### 2.2 远程模板

```bash
cac template add <url>                       # 从 git repo 或 URL 拉取模板
cac template update                          # 更新所有远程模板
```

---

## 三、功能扩展

### 3.1 Hook 系统

**问题**：用户可能需要在环境激活/停用时执行自定义脚本（启动 VPN、切换 DNS 等）。

```
~/.cac/envs/<name>/
├── hooks/
│   ├── pre-activate.sh       # 激活前
│   ├── post-activate.sh      # 激活后
│   ├── pre-deactivate.sh     # 切换前
│   └── pre-claude.sh         # claude 启动前（wrapper 内）
```

### 3.2 插件机制（远期）

可扩展的 Node.js 插件：
- 自定义 DNS 规则
- 额外的指纹 hook
- 代理健康监控 + 自动切换

### 3.3 自动更新与版本追踪

```bash
cac claude watch                             # 后台检查新版本
cac claude diff 2.1.83 2.1.84               # 对比两个版本的变化（尤其是指纹相关）
```

- 新版本发布时通知用户
- 可选自动下载但不自动切换
- 重点：每个新版本需要逆向分析指纹采集变化

---

## 四、TUI / 用户体验

### 4.1 交互式 TUI

当前所有操作都是命令行参数，可以增加交互模式：

```bash
cac                                          # 无参数时进入交互模式
```

- 环境列表：上下键选择，回车激活
- 创建向导：引导输入名称、代理、版本
- 状态面板：当前环境 + 代理连通性 + 版本信息

技术选型：用 bash `select`/`read` 做简单版，或用 Node.js `inquirer`/`ink` 做丰富版。

### 4.2 Check 可视化增强

- `cac env check` 输出更美观的表格
- `cac env check --watch`：持续监控模式
- `cac env check --json`：机器可读输出

### 4.3 命令补全

```bash
cac completion bash > /etc/bash_completion.d/cac
cac completion zsh > ~/.zfunc/_cac
cac completion fish > ~/.config/fish/completions/cac.fish
```

---

## 五、Docker 模式完善

当前 `cac docker` 有基本功能但缺少维护：

- 镜像更新策略（当前是固定 Dockerfile）
- 多容器管理（不同环境不同容器）
- 容器内 cac 自动同步宿主机配置
- sing-box 配置自动生成优化
- GPU passthrough（给需要本地模型的用户）

---

## 六、测试框架

### 6.1 当前状态

- CI：仅 ShellCheck + build.sh 构建一致性 + JS 语法检查
- 无功能测试、无集成测试

### 6.2 目标

**单元测试**（bash）：
- 用 bats-core 测试各函数
- UUID/hostname/MAC 生成格式验证
- proxy 解析
- 版本排序

**集成测试**：
- `cac env create` → 验证文件结构
- `cac env check` → mock proxy 验证输出
- wrapper 注入 → 验证环境变量
- `fingerprint-hook.js` → 验证拦截效果

**E2E 测试**：
- Docker 容器内跑完整流程
- 多平台 CI（macOS + Linux + Windows/Git Bash）

---

## 七、Windows 适配（社区协作）

**方案已确定**：基于 Git Bash（Windows 安装 Claude Code 必须有 Git for Windows）。

**核心改动**：
1. `/dev/tcp` → `_tcp_check()` 用 `node net.connect` 替代
2. `python3` → 替换为 `node -e`
3. Wrapper：Windows 生成 `claude.cmd`
4. Shims：Windows 跳过（fingerprint-hook.js 覆盖）
5. RC 文件：Git Bash `~/.bashrc` + Windows 系统 PATH
6. 平台标识：`_detect_platform` 增加 `win32-x64`

**适合作为 Good First Issue 拆分给社区**。

---

## 优先级排序

| 优先级 | 功能 | 工作量 | 谁做 |
|:---:|------|:---:|:---:|
| P0 | 测试框架（bats-core 基础） | 中 | 自己 |
| P1 | Windows 适配 | 大 | 社区 |
| P1 | 单机迁移（import from ~/.claude） | 小 | 社区 |
| P1 | 环境克隆（clone） | 小 | 社区 |
| P1 | 环境导出/导入（export/import JSON） | 中 | 社区 |
| P2 | 环境模板（template save/create） | 中 | 社区 |
| P2 | 命令补全 | 小 | 社区 |
| P2 | Check JSON 输出 | 小 | 社区 |
| P3 | TUI 交互模式 | 中 | 社区 |
| P3 | Hook 系统 | 中 | 社区 |
| P3 | 多机 Git 同步 | 大 | 后期 |
| P3 | Docker 模式完善 | 大 | 后期 |
| P4 | 版本变化追踪/自动 diff | 大 | 后期 |
| P4 | 插件机制 | 大 | 后期 |
