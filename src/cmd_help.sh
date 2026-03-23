# ── cmd: help ──────────────────────────────────────────────────

cmd_help() {
cat <<EOF
$(_bold "cac") — Claude Anti-fingerprint Cloak

$(_bold "用法：")
  cac setup                         首次安装（自动配置 PATH）
  cac add <名字> <host:port:u:p>    添加新环境（需要 yes 确认）
  cac <名字>                        切换到指定环境
  cac ls                            列出所有环境
  cac check                         核查当前环境（代理 + 安全防护）
  cac relay [on|off|status]          本地中转（绕过 TUN）
  cac stop                          临时停用，claude 裸跑
  cac -c                            恢复停用
  cac delete                        卸载 cac（清除所有数据和配置）
  cac -v                            查看版本号和安装方式

$(_bold "代理格式：")
  host:port:user:pass    带认证的 SOCKS5
  host:port              无认证的 SOCKS5

$(_bold "Relay 中转：")
  cac relay on              启用本地中转（绕过 TUN/Clash 等代理冲突）
  cac relay on --route      启用 + 添加直连路由（需 sudo，解决激进 TUN）
  cac relay off             停用
  cac relay status          查看状态

$(_bold "安全防护：")
  NS 层级 DNS 拦截       拦截 statsig.anthropic.com 等遥测域名
  fetch 遥测拦截         替换原生 fetch，防止绕过 DNS 拦截
  多层环境变量保护       DO_NOT_TRACK / OTEL_SDK_DISABLED 等 12 层遥测阻断
  mTLS 客户端证书        自签 CA + 客户端证书 + https.globalAgent 注入

$(_bold "Docker 容器模式：")
  cac docker setup              配置代理 + 网络（交互式）
  cac docker create             拉取 Docker 镜像
  cac docker start              启动容器
  cac docker enter              进入容器（claude + cac 可用）
  cac docker check              网络 + 身份诊断
  cac docker port <端口>         端口转发到 localhost
  cac docker stop               停止容器
  cac docker help               查看所有 docker 子命令

$(_bold "示例：")
  cac add us1 1.2.3.4:1080:username:password
  cac us1
  cac check
  cac stop
  cac docker setup && cac docker start && cac docker enter

$(_bold "文件目录：")
  ~/.cac/bin/claude           wrapper（拦截所有 claude 调用）
  ~/.cac/shim-bin/            ioreg / hostname / ifconfig shim
  ~/.cac/cac-dns-guard.js     NS 层级 DNS 拦截 + DoH + mTLS 注入模块
  ~/.cac/blocked_hosts        HOSTALIASES 遥测域名拦截
  ~/.cac/ca/                  mTLS 自签 CA 证书
  ~/.cac/current              当前激活的环境名
  ~/.cac/relay.js                relay 本地中转服务
  ~/.cac/relay.pid               relay 进程 PID
  ~/.cac/relay.port              relay 监听端口
  ~/.cac/envs/<name>/         各环境：proxy / uuid / stable_id / client_cert
EOF
}
