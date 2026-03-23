# cac 真实测试指南

## 1. 构建镜像（在 luoxiaohei 上执行）

```bash
cd /tmp/cac-real-test
docker build -f Dockerfile.real-test -t cac-real .
```

## 2. 启动容器（交互模式）

```bash
docker run --rm -it --name cac-test cac-real
```

## 3. 容器内操作

### Step 1: 初始化 cac

```bash
cac setup
```

应看到 wrapper、shim、DNS guard、relay 等都被部署。

### Step 2: 添加代理环境

```bash
# 格式: cac add <名字> <host:port:user:pass>
# 或者: cac add <名字> socks5://user:pass@host:port
cac add test1 <你的代理地址>
# 输入 yes 确认
```

### Step 3: 切换到环境

```bash
cac test1
```

### Step 4: 检查状态

```bash
cac check
```

应看到：
- TCP 连通 ✓
- 出口 IP（代理的 IP，非本机）
- 冲突检测 ✓
- DNS 拦截 ✓
- 12 层环境变量 ✓

### Step 5: 登录 Claude

```bash
# source PATH (cac setup 写入的)
source ~/.bashrc

# 启动 claude（走 cac wrapper）
claude
```

进入 Claude 后执行 `/login`，按提示完成 OAuth 登录。

### Step 6: 验证隐私隔离

在 Claude 内执行（或另开终端）：

```bash
# 验证代理生效
curl -s https://api.ipify.org
# 应返回代理 IP，非本机 IP

# 验证 hostname 被隔离
hostname
# 应返回 host-xxxxxxxx 格式

# 验证环境变量
echo $HTTPS_PROXY
echo $DO_NOT_TRACK
echo $OTEL_SDK_DISABLED
```

### Step 7: 测试 Relay 功能

```bash
# 启用 relay
cac relay on

# 检查 relay 状态
cac relay status

# 再次启动 claude（这次走 relay 中转）
claude
```

在 Claude 内随便问一个问题，验证能正常对话。

### Step 8: 验证 Relay 代理指向

```bash
# 另开终端进入同一容器
docker exec -it cac-test bash

# 检查 relay 进程
ps aux | grep relay

# 检查端口
ss -tlnp | grep 17890
```

## 4. 清理

```bash
# 退出容器（自动删除，因为用了 --rm）
exit

# 删除镜像（可选）
docker rmi cac-real
```

## 5. 测试清单

| # | 测试项 | 预期结果 | 实际 |
|---|--------|----------|------|
| 1 | `cac setup` | 部署成功，含 relay.js | |
| 2 | `cac add` | 创建环境，检测代理和时区 | |
| 3 | `cac check` | 代理连通，出口 IP 正确 | |
| 4 | `claude` 启动 | 通过 wrapper 启动，无报错 | |
| 5 | `/login` | OAuth 登录成功 | |
| 6 | 对话测试 | 能正常与 Claude 对话 | |
| 7 | hostname 隔离 | 返回伪造的 host-xxx | |
| 8 | `cac relay on` | relay 启动，端口监听 | |
| 9 | relay 模式 claude | 通过 relay 正常对话 | |
| 10 | `cac relay off` | relay 停止，进程清理 | |
