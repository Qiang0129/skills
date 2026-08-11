# Web SOP Builder

用于 OMS、ERP、WMS 等网页后台的中文 SOP 编写 Codex 插件。它把真实网页操作取证、截图红框/箭头标注、用户确认和中文 DOCX 生成组织成一个可重复的流程。

## 安装

在 Codex 中添加这个 GitHub marketplace：

```text
codex plugin marketplace add Qiang0129/skills --ref main
codex plugin add web-sop-builder@web-sop-builder
```

安装后可在新任务中显式调用：

```text
$web-sop-builder
```

也可以直接让 Codex 处理网页操作 SOP、OMS/ERP/WMS 流程文档、截图红框标注或中文 DOCX SOP。

## 默认流程

1. 使用 Playwright skill 操作网页并截取已验证的全页或局部截图。
2. 使用 `annotation-job.json` 生成截图标注预览。
3. 展示截图并等待用户确认标注样式和事实内容。
4. 用户确认后使用 `sop-job.json` 生成或覆盖中文 DOCX。
5. 仅在明确要求时导出 PDF 并逐页检查页面 PNG。

默认标注样式为 3 px 深红色直角框、无底板加粗文字、4 px 实线实心尖头箭头。标签必须在截图内部，箭头起点位于文字边界，终点位于红框边缘，默认最大长度为 320 px。

## 脚本依赖

使用脚本的 Python 环境需要安装 `Pillow` 和 `python-docx`。浏览器取证使用 Codex 的 Playwright skill 和本机可用的浏览器环境。

## 数据边界

内部测试截图默认不添加脱敏覆盖，但永远不要把账号、密码、令牌、API key、session 值或内部配置写入 job JSON、文档、日志或记忆。生产环境和外发材料应先确认数据处理要求。

## 目录

- `plugins/web-sop-builder/.codex-plugin/plugin.json`：插件 manifest。
- `plugins/web-sop-builder/skills/web-sop-builder/`：可复用 skill、脚本和参考规则。
- `.agents/plugins/marketplace.json`：仓库 marketplace 配置。

本仓库未提交 OMS 业务截图、测试数据或现有 DOCX，也未提交任何真实登录凭据。
