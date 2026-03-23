# CAC mitmproxy 抓包方案

通过 mitmproxy 中间人代理，解密 Claude Code 的 HTTPS 流量，观察它实际上报了哪些设备指纹数据。

## 代理链路

```
claude → 127.0.0.1:8080 (mitmproxy) → 远端代理 → Anthropic API
              ↓
    自动过滤指纹关键词
    输出 device_hits.jsonl
```

## 快速开始

```bash
# 1. 安装（只需一次）
cd /path/to/cac
bash mitm/install.sh

# 2. 确保已切换到一个 cac 环境
cac us1

# 3. 一键抓包启动
~/.cac/bin/claude-mitm
```

完成后 `claude` 退出时会自动停止 mitmproxy 并打印报告路径。

## 文件说明

| 文件 | 作用 |
|---|---|
| `install.sh` | 安装 mitmproxy（brew）、生成 CA 证书、创建目录、链接启动命令 |
| `claude-mitm.sh` | 一键启动器：启动 mitmproxy → 注入代理 → 启动 claude → 退出后输出报告 |
| `scripts/log_device_fingerprint.py` | mitmproxy 插件：过滤指纹关键词、输出 JSONL 明细 + 汇总 |
| `scripts/no-pin.js` | 可选：Node.js 证书钉扎绕过预加载脚本 |

## 监控的关键词

插件会自动过滤请求中包含以下关键词的数据（URL、请求头、请求体、查询参数）：

```
machineId, deviceId, hostname, networkInterfaces, stable_id,
userID, fingerprint, telemetry, statsig, anonymousId,
organizationUUID, accountUUID, user_metadata, event_metadata
```

## 报告位置

每次运行生成独立目录：

```
~/.cac/mitm/reports/<YYYYMMDD-HHMMSS>/
├── device_hits.jsonl   # 逐条命中的请求记录（JSON Lines）
├── summary.json        # 汇总统计：关键词分布、命中 host、请求路径
└── mitmdump.log        # mitmproxy 运行日志
```

### 查看报告

```bash
# 查看最新一次的汇总
cat ~/.cac/mitm/reports/$(ls -1t ~/.cac/mitm/reports | head -1)/summary.json

# 查看命中明细（前 10 条）
head -10 ~/.cac/mitm/reports/$(ls -1t ~/.cac/mitm/reports | head -1)/device_hits.jsonl

# 用 jq 格式化查看
cat ~/.cac/mitm/reports/$(ls -1t ~/.cac/mitm/reports | head -1)/device_hits.jsonl | jq .
```

### summary.json 示例

```json
{
  "total_requests_seen": 42,
  "total_hits": 5,
  "keyword_counts": {
    "userID": 3,
    "telemetry": 2,
    "stable_id": 1
  },
  "host_counts": {
    "api.anthropic.com": 4,
    "statsig.anthropic.com": 1
  },
  "path_counts": {
    "/v1/messages": 3,
    "/v1/logs": 2
  }
}
```

## 可选参数

```bash
# 自定义本地监听端口（默认 8080）
CAC_MITM_PORT=9090 ~/.cac/bin/claude-mitm

# 启用证书钉扎绕过（仅排查时使用）
CAC_BYPASS_PINNING=1 ~/.cac/bin/claude-mitm

# 透传参数给 claude
~/.cac/bin/claude-mitm chat
~/.cac/bin/claude-mitm --help
```

## 工作原理

1. 从 `~/.cac/current` 读取当前环境名
2. 从 `~/.cac/envs/<name>/proxy` 读取远端代理地址
3. 启动 `mitmdump` 上游模式：`127.0.0.1:8080 → 远端代理`
4. 通过 `HTTPS_PROXY` / `NODE_EXTRA_CA_CERTS` 让 claude 走本地 mitmproxy
5. 插件实时过滤指纹关键词，写入 JSONL
6. claude 退出后自动停止 mitmproxy，写入 summary.json

## 证书信任

- 安装时自动生成 mitmproxy CA 证书到 `~/.mitmproxy/mitmproxy-ca-cert.pem`
- 启动器通过 `NODE_EXTRA_CA_CERTS` 仅让 claude 进程信任该 CA
- **不做系统级信任**，不影响其他应用

## 安全注意事项

- `~/.mitmproxy/` 包含 CA 私钥，权限应为 `700`
- 报告中的 `authorization`、`cookie`、`proxy-authorization`、`x-api-key` 已自动脱敏
- 抓包完成后如需清理：

```bash
# 删除所有报告
rm -rf ~/.cac/mitm/reports/*

# 删除 mitmproxy CA（如果不再使用）
rm -rf ~/.mitmproxy
```

## 故障排查

```bash
# mitmproxy 启动失败 — 查看日志
cat ~/.cac/mitm/reports/<最新目录>/mitmdump.log

# 端口被占用
CAC_MITM_PORT=8888 ~/.cac/bin/claude-mitm

# 证书错误 — 重新生成 CA
rm -rf ~/.mitmproxy
bash mitm/install.sh

# claude 连接失败 — 检查远端代理是否通
cac check
```
