---
name: web-sop-builder
description: Create evidence-based Chinese SOPs for web back-office systems. Use for 网页操作 SOP、后台系统操作指南、OMS/ERP/WMS 流程文档、截图红框标注、中文 DOCX SOP, especially when a real browser workflow must be captured, annotated, reviewed, and turned into an internal operation guide.
---

# 网页 SOP 编写

Create a factual SOP from the current system and the user's stated scope. Do not invent fields, outcomes, permissions, or business rules.

Run the bundled scripts with a Python environment containing `Pillow` and `python-docx`.

1. Read [job-schemas.md](references/job-schemas.md) and [visual-delivery-rules.md](references/visual-delivery-rules.md) before preparing jobs.
2. Use the `playwright` skill to operate the web system, capture full-page screenshots, and obtain the exact flow evidence. Do not put credentials in scripts, job JSON, documents, logs, or memory.
3. Create `annotation-job.json` beside the screenshots. Run `scripts/annotate_screenshots.py` and show the generated screenshots to the user.
4. Do not create or overwrite a DOCX until the user confirms the screenshot annotation preview, unless the user explicitly requests otherwise.
5. After confirmation, create `sop-job.json`, run `scripts/build_sop_docx.py`, then run `scripts/check_docx.py` with the expected image count and any forbidden terms.
6. Use the `pdf` skill only when the user explicitly requests PDF export or page-image acceptance. Render and inspect every page in that phase.

Keep labels short and place them inside the screenshot. Use the bundled scripts rather than recreating their rendering or DOCX logic. Preserve the staged delivery order: screenshot preview, user confirmation, DOCX, then optional PDF/page review.
