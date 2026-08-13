# 通用账号适配器协议

账号适配器是部署项目提供的、受首次部署清单 SHA-256 绑定的应用侧运行器。核心 Skill 不假设数据库、表名、密码算法、角色存储或认证框架。

## 描述文件

描述文件必须位于 `.codex-deploy/maintenance/adapters/`，使用 UTF-8 无 BOM JSON：

```json
{
  "schemaVersion": "1.0",
  "kind": "deploy-github-to-wsl/account-adapter",
  "runtime": "python3",
  "runnerPath": ".codex-deploy/maintenance/adapters/accounts.py",
  "runnerSha256": "<运行器真实文件字节 SHA-256>",
  "allowedRoles": ["owner", "labeler"],
  "resultContract": "json-line-v1"
}
```

描述文件本身和 `runnerPath` 都必须在首次部署清单中绑定 SHA-256。运行时重新计算两者哈希；任何漂移都阻断账号操作。

## 运行器输入输出

- 标准输入第一行是维护核心生成的 `operation` JSON；不得包含密码明文或密码字段，只包含操作类型、账号名、显示名和角色等非敏感字段。
- 第一行之后是可选密码字节。创建和重置密码时由核心从剪贴板或安全标准输入读取并直接转发；运行器负责在应用侧内存中生成适合自身认证系统的哈希。
- 运行器不得把密码、哈希、Token 或完整环境变量写入日志、文件、命令参数或结果。
- 成功必须输出恰一行 JSON：

```json
{"schemaVersion":"1.0","ok":true,"username":"example","operation":"account.create"}
```

- 失败使用非零退出码；标准输出不得输出诊断数据。核心只记录脱敏错误码。

## 支持的操作

核心允许 `account.create`、`account.reset-password`、`account.update-roles`、`account.disable` 和 `account.soft-delete`，但最终字段和业务约束由适配器实现。核心始终限制单个明确用户名，不接受批量账号、任意 SQL 或未绑定适配器。

例如某个标注系统可以在自己的适配器中实现 `owner`、`labeler`、`reviewer` 等角色；其它系统应提供独立适配器，不修改通用核心。适配器示例不构成 Skill 的内置业务模型。
