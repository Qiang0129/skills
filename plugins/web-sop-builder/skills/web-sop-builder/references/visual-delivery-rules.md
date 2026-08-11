# Visual And Delivery Rules

## Data handling

- Treat internal test screenshots as not requiring a desensitization overlay unless the user asks for one.
- Never write passwords, tokens, API keys, session values, login credentials, or internal configuration values into a document, job file, log, or memory note.
- For production systems or material intended for external distribution, confirm the required data treatment before capture or delivery.

## Annotation style

- Draw 3 px deep-red square-corner frames.
- Draw labels as deep-red bold text with no fill, border, background, shadow, or visual-effect layer.
- Draw 4 px deep-red solid arrows with solid pointed heads.
- Put labels inside the screenshot, first in non-critical blank space. If necessary, cover only unimportant background content.
- Start every arrow at a label edge and end it on the corresponding frame edge. For a whole-area explanation, target the whole-area frame edge; for a control explanation, target that control's frame edge.
- Do not add external whitespace, title strips, or overlays to full screenshots or local crops.
- Keep arrows short. The renderer rejects arrows longer than 320 px by default.

## Delivery sequence

1. Capture the verified workflow and generate annotated screenshot previews.
2. Show the previews and obtain confirmation of the annotation style and factual steps.
3. Generate or overwrite the DOCX only after confirmation.
4. Export PDF and render page PNGs only when explicitly requested.
