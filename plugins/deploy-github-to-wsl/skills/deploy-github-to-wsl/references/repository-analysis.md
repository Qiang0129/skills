# 仓库可行性判定

## 只读获取

1. 先用 `scan_repository.py --validate-url-only` 校验 URL，只接受 `https://github.com/<owner>/<repo>`，拒绝凭据、端口、查询参数、分支页、路径穿越和其他主机。
2. 用 `git ls-remote --symref` 解析默认分支，再固定完整提交 SHA。计划清单同时记录规范 URL、ref 和 SHA；执行前再次比较，任何漂移都回到计划阶段。
3. 私有仓库使用 Windows GCM 的 WSL 配置完成网页登录，凭据留在 Windows 凭据管理器。不要索要 PAT，不要将令牌写入 URL、Git 配置或 WSL 明文文件。
4. 分析副本使用 `--no-checkout --no-recurse-submodules --filter=blob:none`，设置 `GIT_LFS_SKIP_SMUDGE=1` 和空 `core.hooksPath`，再用 `git archive` 解包固定提交。不要初始化子模块、运行过滤器、Hook、安装脚本或 Dockerfile。

## 检查矩阵

| 维度 | 检查内容 | 输出方式 |
| --- | --- | --- |
| 构建 | Dockerfile、Compose、语言清单、锁文件、生命周期脚本 | 结构化清单与风险项，不执行脚本 |
| 入口 | HTTP/HTTPS/WebSocket、监听端口、反向代理、多应用 | 选出一个公网入口；无法自动选择时纳入批量决策 |
| 数据 | 数据库、缓存、上传目录、命名卷、迁移命令 | 记录持久化路径、备份和单独迁移确认 |
| 配置 | `.env.example`、OAuth、外部 API、回调地址 | 只输出环境变量键名和缺失键名 |
| 资源 | 架构、CPU、内存、磁盘、构建峰值 | 与实时 WSL 报告比较，保留现有项目余量 |
| 安全 | root、privileged、host network、capabilities、设备、宿主挂载 | 高风险项进入单独确认清单 |
| 运维 | 健康检查、日志、restart、摘要、备份 | 通过 `.codex-deploy/` 补齐，不改上游 |
| 许可 | LICENSE、README 许可和第三方镜像 | 报告完整性风险，不作法律判断 |

`scan_repository.py` 对 Compose 必须使用 `docker compose config --format json --no-interpolate --no-env-resolution` 的结构化结果。只报告环境变量键名、密钥是否存在和文件权限，禁止输出真实值、进程环境和响应体敏感字段。

## 判定

- `ready`：有明确 Web 入口、可复现容器路径、健康检查和持久化策略，且没有高风险项。
- `conditional`：可以部署，但缺少配置、Access、迁移、资源、高权限或许可证决策。
- `blocked`：URL 不合法、WSL/Docker 不可用、Compose 无法解析、资源不足、缺少部署单元或只提供 TCP/UDP。

先列阻塞项，再列单独确认风险，最后给出主方案和一个有意义的备选方案。计划阶段最多询问三个会改变方案的业务决策；系统和仓库可以发现的事实不要提问。
