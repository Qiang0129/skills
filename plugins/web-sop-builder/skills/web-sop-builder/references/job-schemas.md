# Job Schemas

Create the job JSON outside the skill directory, normally beside the captured screenshots. Resolve every relative path from the JSON file's directory.

## annotation-job.json

```json
{
  "source_dir": "screenshots",
  "output_dir": "annotated",
  "font_path": "C:/Windows/Fonts/msyhbd.ttc",
  "images": [
    {
      "source": "01-create.png",
      "output": "01-create-annotated.png",
      "boxes": [[120, 220, 660, 520]],
      "annotations": [
        {
          "text": "选择商品",
          "target": [120, 220, 660, 520],
          "label": [720, 250],
          "label_side": "left",
          "target_side": "right",
          "max_width": 180
        }
      ]
    },
    {
      "source": "02-dialog.png",
      "output": "02-dialog-detail.png",
      "crop": [300, 180, 1300, 760],
      "resize_width": 1600,
      "boxes": [[520, 300, 1000, 600]],
      "annotations": [
        {
          "text": "确认提交",
          "target": [520, 300, 1000, 600],
          "label": [1050, 420],
          "label_side": "left",
          "target_side": "right"
        }
      ]
    }
  ]
}
```

- Use integer `[x1, y1, x2, y2]` rectangles with `x1 < x2` and `y1 < y2`.
- Specify `boxes`, `target`, and optional `target_point` in source-image coordinates. The crop and resize transformation is applied automatically.
- Specify `label` in final output-image coordinates. It is the top-left pixel of the rendered text bounds.
- Use `label_side` and `target_side` from `top`, `bottom`, `left`, or `right`. The renderer derives both arrow endpoints. To use a non-centre target endpoint, add `target_point: [x, y]`; it must lie exactly on the target rectangle edge.
- Make every annotation `target` equal to one item in `boxes`. The renderer rejects out-of-bounds labels, label-label overlap, label-frame overlap, arrows through any frame interior, and arrows over `max_arrow_length` (default 320).
- Add `max_arrow_length` at the root only to make the cap stricter. Values above 320 are rejected. Set `font_path`, `font_size`, `box_width`, `arrow_width`, or `color` only when a project requires a compatible override.

## sop-job.json

```json
{
  "title": "入库预报操作指南",
  "subtitle": "创建、提交与状态核对",
  "system_name": "业务后台（测试环境）",
  "applicable_scope": "入库预报创建及提交审核",
  "applicable_users": "具备相应权限的运营人员",
  "output_path": "output/入库预报操作指南.docx",
  "preparation": ["确认已在测试环境登录。", "准备本次业务所需资料。"],
  "sections": [
    {
      "title": "创建记录",
      "steps": [
        {
          "title": "进入页面",
          "action": "在导航中打开目标功能。",
          "expected_result": "页面显示目标列表。",
          "notes": ["按当前权限范围操作。"],
          "figures": [
            {
              "path": "annotated/01-create-annotated.png",
              "caption": "图 1  打开目标功能"
            }
          ]
        }
      ]
    }
  ],
  "notes": ["本文档不记录登录凭据或内部配置值。"],
  "common_issues": [
    {"issue": "找不到功能入口", "resolution": "确认权限和当前菜单。"}
  ],
  "version_history": [
    {"version": "1.0", "date": "2026-08-11", "change": "首次发布。"}
  ]
}
```

- Require `title`, `system_name`, `applicable_scope`, `applicable_users`, `output_path`, and at least one section with at least one step.
- Require every step to contain `title`, `action`, and `expected_result`. `notes` and `figures` are optional arrays.
- Require each figure to contain `path` and `caption`; use only reviewed annotated screenshots.
- `subtitle`, root `notes`, `preparation`, `common_issues`, and `version_history` are optional. The builder supplies neutral defaults for omitted optional sections.
- Do not put credentials, session values, token strings, API keys, or internal configuration values in the job. The builder rejects likely credential assignments before writing a document.
