# WSL 与 Docker 部署

## 预检与状态

- 每次先运行 `inspect_wsl.ps1`；只使用报告中的发行版注册名，例如实际注册名是 `Ubuntu` 时不得推导为 `Ubuntu-24.04`。
- WSL2、Docker Engine、Compose、GitHub HTTPS、Cloudflare DNS 和 7844 出站连接是关键能力。systemd `degraded` 只是警告，按 Docker、DNS 和网络能力判定。
- 部署清单 v2 至少包含仓库 URL/ref/SHA、WSL 注册名、Compose 文件和 profiles、应用/Tunnel 服务、内部端口、域名、Tunnel 名、Access 模式、风险确认、状态路径和计划哈希；禁止密钥字段。
- 状态使用原子临时文件写入并设置 `600`，记录当前阶段、已完成阶段、Tunnel/DNS/Access 对象 ID、Compose/远程配置哈希、验收和脱敏错误码。对象创建后立即落盘 ID，以便响应失败后 Resume。

## 固定布局

| 用途 | 路径 | 约束 |
| --- | --- | --- |
| 源码 | `/root/projects/<slug>` | 固定提交，不保存 GitHub 凭据 |
| 覆盖文件 | `<repo>/.codex-deploy/` | 写入 `.git/info/exclude`，永不提交 |
| 状态 | `/root/.local/state/deploy-github-to-wsl/<slug>` | 目录 `700`、文件 `600`、无密钥 |
| Tunnel Token | `/root/.config/deploy-github-to-wsl/<slug>/secrets` | 目录 `700`、文件 `600` |

Slug 统一为小写字母数字和连字符，最长 63；Compose 项目名为 `codex-<slug>`，Tunnel 名为 `wsl-<slug>`。源码、覆盖、状态和密钥必须分别校验路径，拒绝 `..` 和符号链接逃逸。

## Compose 安全默认值

- 所有生命周期命令都读取清单中的 `profiles`，必须包含 `tunnel`，不能只启动默认 profile。
- 应用优先非 root、`read_only: true`、`no-new-privileges:true`、删除未用 capabilities、健康检查和 `restart: unless-stopped`；确需写入时只给受限 tmpfs 或命名卷。
- 默认只使用 `expose`，宿主端口只允许绑定 `127.0.0.1`。拒绝 `privileged`、`host network`、Docker Socket、宿主根目录、`/etc`、`/root`、`/proc`、`/sys` 和 `/var/run` 挂载；例外须单独确认。
- Cloudflared 使用固定摘要、版本不低于 2025.4.0 的镜像和 Compose secret：

```yaml
services:
  cloudflared:
    image: "cloudflare/cloudflared@sha256:<固定摘要>"
    command: ["tunnel", "--no-autoupdate", "run", "--token-file", "/run/secrets/tunnel_token"]
    profiles: ["tunnel"]
    secrets: ["tunnel_token"]
    restart: unless-stopped

secrets:
  tunnel_token:
    file: "/root/.config/deploy-github-to-wsl/<slug>/secrets/tunnel_token"
```

不要把 Token 放入 environment、`.env`、命令参数、日志或部署记录。

## 阶段与回滚

按 `preflight → source → build → app → tunnel → route → acceptance → recorded` 执行：预检和固定提交后获取源码，构建和应用健康后才启动 Tunnel，Tunnel 健康后才创建远程路由和 DNS。

计划批准覆盖清单中可逆的 WSL、Compose 和 Cloudflare 创建/更新。数据库迁移、高权限容器、覆盖非托管对象、凭据轮换和删除仍单独确认。失败时保留源码、卷、日志、状态和已创建的外部对象，不执行 `down -v`；修复后用相同计划哈希 Resume。可用性只承诺 Windows 开机且当前用户已登录期间。

## 已受管项目维护

- 首次部署成功后，状态还记录固定提交、Compose 项目/文件/profile、受管服务白名单、Cloudflare 配置快照和可选应用适配器绑定。维护执行器只信任这些证据，不从容器名称、数据库结构或公网名称猜测归属。
- `maintain.ps1 -Mode Inspect` 始终只读；`Apply` 与 `Resume` 仅处理用户明确发起的受管维护。每个操作写入 `maintenance/<operation-id>.json`，文件 `600`、目录 `700`，只记录请求哈希、阶段、影响对象、健康结果和脱敏错误码。
- 可自动执行：单服务重启/重建、受管 `.codex-deploy/` 覆盖更新及失败恢复、已有受管 Tunnel/DNS 同步、绑定适配器的单账号操作。服务命令必须显式使用 `docker compose -p codex-<slug>`，并拒绝迁移、seed、未列入白名单或没有 Compose 标签的容器。
- 旧 v2 状态没有维护字段时，只允许只读兼容识别。要启用写入型维护，必须在下一次受批准的固定提交升级或首次部署中写入受管服务和适配器绑定；不要自动补写旧状态或接管历史对象。
- 始终停止并要求确认：首次部署、新 hostname/Tunnel/DNS、Access 变更、数据库迁移、Docker daemon/systemd/代理变更、卷或源码删除、凭据轮换、高权限容器、未受管对象接管和任何批量数据操作。
