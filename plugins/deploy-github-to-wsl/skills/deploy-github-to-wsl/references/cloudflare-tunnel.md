# Cloudflare Tunnel 与 Access

## API 优先

- 默认 Zone 为 `scuccs.me`，主机名为 `<slug>.scuccs.me`，Tunnel 为 `wsl-<slug>`；每项目独立远程 Tunnel，不复用 `wsl-home`。
- 计划阶段只调用查询接口，检查 Tunnel、远程配置、Access 应用、DNS 和主机名冲突。名称冲突且没有可信 v2 状态或兼容 v1 所有权证据时阻塞，不接管对象。
- 执行阶段由 `CloudflareApi.psm1` 统一处理 HTTPS、超时、429/5xx 退避、状态码和错误脱敏。`cloudflare.ps1` 的 `Plan`、`Apply`、`Maintain`、`Status` 输出 schema v2 JSON；`Apply` 按对象 ID 幂等创建或更新，不删除对象。
- 远程 ingress 固定为 `https://` 或 `http://<compose-service>:<port>`，末尾必须是 `http_status:404`。DNS 为代理 CNAME：`<hostname> -> <tunnel-id>.cfargotunnel.com`。

## 凭据分层

首次初始化公共凭据时，仅允许指定账户的 Tunnel Write、账户只读发现，以及 `scuccs.me` Zone Read/DNS Write。`cloudflare.ps1 -Action InitializeCredential -CredentialProfile public` 从本机剪贴板读取一次，验证权限后使用 Windows 当前用户 DPAPI 写入 `%LOCALAPPDATA%\deploy-github-to-wsl\credentials\cloudflare-public.bin`，收紧 ACL 并清空剪贴板。

Access 使用独立的 `cloudflare-access.bin`，只授予 `Access: Apps and Policies Write` 与必要的账户发现权限。受保护清单必须给出应用名称、会话时长、Allow Policy 的 include 规则和单独的 Access 凭据；没有这些条件时 Plan 阻塞。公共 Token 不得被扩大为 Access 写权限。

API 获取的 Tunnel Token 只在内存中传递，经标准输入写入 WSL 固定路径，文件权限为 `600`；Compose 通过 secret 挂载 `/run/secrets/tunnel_token` 并用 `--token-file` 启动。Token 不进入环境变量、参数、剪贴板以外的日志、异常、状态或 JSON。旧的 `store_tunnel_token.ps1` 仅在用户明确选择浏览器兼容回退时使用。

## 一次批准与异常接管

- 一次执行批准覆盖清单中精确列出的 Tunnel 创建/更新、远程 ingress、Access 应用/Policy、DNS、WSL 文件和 Compose 操作。
- 删除对象、数据库迁移、高权限容器、覆盖非托管对象、凭据轮换和清理操作永远单独确认。
- Cloudflare 控制台登录失效、验证码、页面变化、权限不足或 API 返回未知对象时暂停并交由用户处理；不要求长期 API Token，也不自动切换浏览器方案。
- API 响应丢失时依靠本地状态中的对象 ID Resume；如果对象已存在但没有可信 ID，停止并重新规划。

## 自治维护边界

- `Maintain` 仅适用于已完成 v2 状态中同时保存 Tunnel ID、DNS ID、账户、Zone、hostname、service 和匿名 Access 模式的项目。
- 它只可更新同一 ID 的 Tunnel Ingress 与代理 DNS CNAME。Tunnel/DNS 缺失、名称重复、对象 ID 不同、状态缺失、Access 对象存在或请求包含创建/删除/接管时，必须阻断，不调用写接口。
- `Maintain` 不获取新的 Tunnel Token、不创建 Access 应用或 Policy、不改变 hostname、账户、Zone、凭据或权限。旧部署未保存 Cloudflare 配置快照时保持只读，等待受批准的升级建立新的基线。

## 验收

验证 Connector Healthy、配置 ingress、DNS、TLS、匿名或 Access 边界、HTTP/WebSocket 和重启策略。Access 应分别验证未授权拒绝、允许身份通过和源站 Token 校验。删除 Tunnel、DNS、Access 应用或 Token 文件前必须再次确认。

## 官方依据

- [创建 Tunnel](https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/methods/create/)
- [获取 Tunnel Token](https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/token/methods/get/)
- [更新远程配置](https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/subresources/configurations/methods/update/)
- [创建 DNS](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/)
- [创建 Access 应用](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/applications/methods/create/)
- [Docker Compose Secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
