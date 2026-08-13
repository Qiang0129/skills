---
name: deploy-github-to-wsl
description: 分析规范化 GitHub 仓库并规划或执行通用 WSL Docker Compose 公网部署，使用 Cloudflare API、独立 Tunnel 和 scuccs.me 主机名；支持首次部署的一次批准、阶段状态、Resume 续跑，以及已受管项目的低交互自治维护。适用于任何提供 Compose Web 服务的系统，并通过可选适配器支持应用专属维护。
---

# GitHub 到 WSL 公网部署

## 触发与边界

- 用户提供 GitHub 仓库 URL 并要求分析、部署、更新、验收或回滚 WSL 公网服务时触发本 Skill。
- 只接受规范化的 `https://github.com/<owner>/<repo>`；只发布 HTTP、HTTPS 和 WebSocket。原始 TCP/UDP 直接报告阻塞项和替代方案。
- 始终用简体中文输出、写文档和写代码注释；禁止读取或输出 Token、密码、Cookie、私钥、进程环境变量和完整 Tunnel 命令。
- 默认使用 rootful Docker、每项目独立远程 Tunnel、Compose 内部网络和 `scuccs.me`。不要复用 `wsl-home`，不要安装系统级运行时。
- 不要提交、推送、创建 PR 或修改上游仓库。部署覆盖只写入 `.codex-deploy/`，并加入 `.git/info/exclude`。
- 禁止自动删除 Tunnel、DNS、Access 应用、数据卷、源码或执行 `docker compose down -v`、系统清理和 `wsl --shutdown`。

## 两阶段状态机

### 计划阶段

1. 先运行 `scripts/inspect_wsl.ps1 -Compact`，每次实时扫描；使用报告里的发行版注册名，不从显示名称推导名称。WSL1、Docker/Compose 不可用、内存低于 2 GiB、磁盘低于 10 GiB、GitHub 网络失败或 Cloudflare 7844 失败时停止。
2. 并行执行 WSL 扫描、固定 ref/SHA、仓库只读扫描、Compose 结构化解析、镜像可用性检查和 Cloudflare Tunnel/DNS/Access 冲突预检。计划阶段不得写持久文件、创建容器或调用 Cloudflare 写接口。
3. 仓库获取必须关闭 Hook、子模块和 LFS smudge；私有仓库只使用 WSL Git 调用 Windows GCM，不接收聊天中的 PAT。
4. 使用 `scripts/scan_repository.py` 的结构化 Compose 输出，检查入口端口、持久化、迁移、环境变量键名、外部依赖、OAuth 回调、LFS/子模块、许可证和资源需求；不执行仓库脚本或 Dockerfile。
5. 自动采用可发现事实和安全默认值，只把无法发现且会改变方案的决策集中到一次最多三个问题：入口/必需配置、数据迁移与保留、匿名或 Access 身份策略。高风险权限只列为单独确认项，不重复询问事实。
6. 输出部署清单 v2、计划 SHA-256、精确对象名称、变更清单、验收范围、回滚边界和一次性授权范围。首次部署、新公网对象和高风险项未明确批准时不得执行。

### 执行阶段

1. 用户明确批准计划哈希后，调用 `scripts/deploy.ps1 -Mode Apply -ApprovedPlanHash <hash>`；中断后用相同清单和哈希调用 `-Mode Resume`。提交、WSL 资源、域名、Tunnel、DNS、Access 或清单发生漂移时停止并重新计划。
2. 按 `preflight → source → build → app → tunnel → route → acceptance → recorded` 执行。每个阶段完成后原子写入 root-only 的 v2 状态，状态中只记录对象 ID、哈希、阶段和脱敏错误码。
3. 所有 Compose 生命周期命令读取清单中的 `profiles`，必须包含 `tunnel`；应用健康后才启动 `cloudflared`，Tunnel 健康后才配置路由和 DNS。
4. 源码放在 `/root/projects/<slug>`；覆盖文件放在 `.codex-deploy/`；状态目录为 `/root/.local/state/deploy-github-to-wsl/<slug>`（目录 `700`、文件 `600`）；Tunnel Token 目录为 `/root/.config/deploy-github-to-wsl/<slug>/secrets`（目录 `700`、文件 `600`）。
5. Compose 默认不发布宿主端口；应用优先非 root、只读根文件系统、最小 capabilities、`no-new-privileges`、健康检查和 `restart: unless-stopped`。高权限容器、Docker Socket、host network、根挂载、公开数据库端口和未知安装脚本必须单独确认。
6. Cloudflare 使用 API 优先：创建前检查对象所有权；Tunnel 远程 ingress 固定为 Compose 服务名，末尾配置 `http_status:404`；DNS 使用代理 CNAME 指向 `<tunnel-id>.cfargotunnel.com`。公共站点使用匿名路由，后台、个人数据和无鉴权服务必须使用 Access。
7. 首次初始化公共凭据时，从剪贴板一次性读取最小权限 API Token（指定账户 Tunnel Write、只读发现、仅 `scuccs.me` Zone Read/DNS Write），验证后用 Windows 当前用户 DPAPI 保存到 `%LOCALAPPDATA%\deploy-github-to-wsl\credentials\cloudflare-public.bin` 并清空剪贴板。Access 使用独立的 `cloudflare-access.bin` 和 `Access: Apps and Policies Write` 凭据，不扩大公共 Token 权限。
8. API 获取的 Tunnel Token 仅在内存中存在，经标准输入写入 WSL `600` 文件，并通过 Compose secret 的 `/run/secrets/tunnel_token` 和 `--token-file` 使用；不得进入参数、环境变量、日志、异常或部署记录。旧的 `store_tunnel_token.ps1` 仅作为用户明确选择的浏览器兼容回退。
9. 一次批准覆盖清单中精确列出的可逆 WSL 写入、容器操作、Tunnel、远程配置、Access 应用/Policy 和 DNS 创建/更新。删除、数据库迁移、高权限容器、覆盖非托管对象、凭据轮换和任何清理仍须在动作前单独确认。

### 已受管项目自治维护

1. 用户明确提出对已受管项目进行检查、修复、重启、重建、账号操作或 Cloudflare 同步时，优先调用 `scripts/maintain.ps1`，不再为普通维护重复索取计划哈希。
2. 维护只接受已完成的 v2 状态、固定提交、`codex-<slug>` Compose 项目和受管目录；所有命令显式带 `-p`、服务白名单和 Compose profile。状态、配置、对象 ID 或文件哈希漂移时停止。
3. 维护操作分为：只读检查、受管服务维护、受管覆盖修复、精确账号操作和受管 Cloudflare 同步。每次操作使用唯一 `operationId`，写入 root-only 的 `maintenance/<operationId>.json`，记录请求哈希、阶段、影响对象、健康结果和脱敏错误码。
4. 账号操作只接受清单中同哈希绑定的应用适配器；核心不理解数据库表、ORM 或角色模型。适配器通过 [account-adapter.md](references/account-adapter.md) 的运行器协议接收结构化操作和可选密码标准输入，返回不含敏感值的确认 JSON。
5. 适配器必须使用真实文件字节 SHA-256 绑定。密码仅可来自本机剪贴板或安全标准输入，核心不得把密码放入请求 JSON、环境变量、参数、日志、状态或聊天内容。
6. 受管 Cloudflare 维护只更新状态中同 ID 的 Tunnel Ingress 和 DNS；不创建、删除、接管新对象，也不自动修改 Access。对象缺失或冲突时阻断。
7. 受管覆盖先备份、原子写入、定向重建并健康检查；失败时只恢复本次受管覆盖和受影响服务，不删除卷、数据库用户或外部对象。

## 验收与回滚

- 验证 Compose 应用和 Tunnel 健康、内部首页/静态资源/404、Tunnel Connector、DNS、TLS、HTTP/WebSocket、Access 拒绝与允许边界、重启策略和现有项目不受影响；不得为测试执行 `wsl --shutdown`。
- 失败时停止当前新容器，保留源码、卷、日志、部署状态以及已创建的 Cloudflare 对象；不要自动删除外部对象。修复后从 `currentStage` Resume，重复执行不得创建第二个受管对象。
- 数据库迁移前必须备份并单独确认；不可逆迁移失败时使用已验证备份流程，不宣称自动回滚。
- 只承诺 Windows 开机且当前用户已登录期间可用；休眠、关机或未登录期间不保证在线。

## 工具入口

- `scripts/cloudflare.ps1 -Action InitializeCredential|Plan|Apply|Status`：凭据初始化、只读预检、幂等 Cloudflare 操作和状态检查。
- `scripts/deploy.ps1 -Mode Plan|Apply|Resume`：首次部署、固定提交升级、迁移前计划和阶段状态。
- `scripts/maintain.ps1 -Mode Inspect|Apply|Resume -RequestPath <json>`：已受管项目的低交互自治维护。
- `scripts/inspect_wsl.ps1`、`scripts/scan_repository.py`：环境和仓库只读分析。
