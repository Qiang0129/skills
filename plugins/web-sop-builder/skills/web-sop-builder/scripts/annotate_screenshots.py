#!/usr/bin/env python3
"""Render validated in-image SOP callouts from annotation-job.json."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from math import atan2, cos, hypot, sin
from pathlib import Path
from typing import Any, Iterable

from PIL import Image, ImageDraw, ImageFont


DEFAULT_COLOR = (173, 31, 29)
DEFAULT_BOX_WIDTH = 3
DEFAULT_ARROW_WIDTH = 4
DEFAULT_FONT_SIZE = 20
DEFAULT_MAX_ARROW_LENGTH = 320
ARROW_HEAD_LENGTH = 18
ARROW_HEAD_HALF_WIDTH = 8
SIDES = {"top", "bottom", "left", "right"}
EPSILON = 1e-9


class JobError(ValueError):
    """Raise a concise, actionable validation error for a job definition."""


@dataclass(frozen=True)
class TextLayout:
    lines: list[str]
    bounds: tuple[int, int, int, int]
    line_height: int
    glyph_offsets: list[tuple[int, int]]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create validated SOP screenshot annotations.")
    parser.add_argument(
        "job",
        nargs="?",
        default="annotation-job.json",
        help="Path to annotation-job.json (default: annotation-job.json).",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise JobError(f"Job file does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise JobError(f"Invalid JSON in {path}: line {error.lineno}, column {error.colno}") from error
    if not isinstance(data, dict):
        raise JobError("The job root must be a JSON object.")
    return data


def resolve_path(job_path: Path, value: Any, field: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise JobError(f"{field} must be a non-empty path string.")
    candidate = Path(value)
    return candidate if candidate.is_absolute() else job_path.parent / candidate


def as_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise JobError(f"{field} must be an integer.")
    return value


def rect(value: Any, field: str) -> tuple[int, int, int, int]:
    if not isinstance(value, list) or len(value) != 4:
        raise JobError(f"{field} must be [x1, y1, x2, y2].")
    x1, y1, x2, y2 = (as_int(item, field) for item in value)
    if x1 >= x2 or y1 >= y2:
        raise JobError(f"{field} must satisfy x1 < x2 and y1 < y2.")
    return x1, y1, x2, y2


def point(value: Any, field: str) -> tuple[int, int]:
    if not isinstance(value, list) or len(value) != 2:
        raise JobError(f"{field} must be [x, y].")
    return as_int(value[0], field), as_int(value[1], field)


def parse_color(value: Any) -> tuple[int, int, int]:
    if value is None:
        return DEFAULT_COLOR
    if not isinstance(value, str) or not value.startswith("#") or len(value) != 7:
        raise JobError("color must use #RRGGBB format.")
    try:
        return tuple(int(value[index : index + 2], 16) for index in (1, 3, 5))
    except ValueError as error:
        raise JobError("color must use #RRGGBB format.") from error


def positive_int(value: Any, field: str, default: int) -> int:
    if value is None:
        return default
    number = as_int(value, field)
    if number <= 0:
        raise JobError(f"{field} must be greater than zero.")
    return number


def load_font(job: dict[str, Any], job_path: Path, size: int) -> ImageFont.FreeTypeFont:
    candidates: list[Path] = []
    configured = job.get("font_path")
    if configured is not None:
        candidates.append(resolve_path(job_path, configured, "font_path"))
    candidates.extend(
        [
            Path(r"C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf"),
            Path(r"C:\Windows\Fonts\msyhbd.ttc"),
            Path(r"C:\Windows\Fonts\simhei.ttf"),
        ]
    )
    for candidate in candidates:
        if candidate.is_file():
            return ImageFont.truetype(str(candidate), size)
    try:
        return ImageFont.truetype("DejaVuSans-Bold.ttf", size)
    except OSError as error:
        raise JobError("No usable bold font was found. Set font_path in annotation-job.json.") from error


def split_lines(draw: ImageDraw.ImageDraw, font: ImageFont.FreeTypeFont, text: str, max_width: int) -> list[str]:
    if not isinstance(text, str) or not text.strip():
        raise JobError("annotation text must be a non-empty string.")
    lines: list[str] = []
    for paragraph in text.splitlines() or [text]:
        current = ""
        for character in paragraph or " ":
            candidate = current + character
            candidate_box = draw.textbbox((0, 0), candidate, font=font)
            width = candidate_box[2] - candidate_box[0]
            if current and width > max_width:
                lines.append(current)
                current = character
            else:
                current = candidate
        lines.append(current)
    return lines


def layout_text(
    draw: ImageDraw.ImageDraw,
    font: ImageFont.FreeTypeFont,
    text: str,
    position: tuple[int, int],
    max_width: int,
) -> TextLayout:
    lines = split_lines(draw, font, text, max_width)
    glyph_boxes = [draw.textbbox((0, 0), line, font=font) for line in lines]
    glyph_height = max(box[3] - box[1] for box in glyph_boxes)
    line_height = glyph_height + max(4, font.size // 4)
    x, y = position
    widths = [box[2] - box[0] for box in glyph_boxes]
    total_height = glyph_height + line_height * (len(lines) - 1)
    offsets = [(-box[0], -box[1]) for box in glyph_boxes]
    return TextLayout(lines, (x, y, x + max(widths), y + total_height), line_height, offsets)


def edge_point(bounds: tuple[int, int, int, int], side: str) -> tuple[int, int]:
    if side not in SIDES:
        raise JobError(f"Unsupported arrow side: {side}. Use top, bottom, left, or right.")
    x1, y1, x2, y2 = bounds
    if side == "top":
        return (x1 + x2) // 2, y1
    if side == "bottom":
        return (x1 + x2) // 2, y2
    if side == "left":
        return x1, (y1 + y2) // 2
    return x2, (y1 + y2) // 2


def point_on_edge(value: tuple[int, int], bounds: tuple[int, int, int, int]) -> bool:
    x, y = value
    x1, y1, x2, y2 = bounds
    return (x in (x1, x2) and y1 <= y <= y2) or (y in (y1, y2) and x1 <= x <= x2)


def rect_inside(inner: tuple[int, int, int, int], outer: tuple[int, int, int, int]) -> bool:
    return outer[0] <= inner[0] and outer[1] <= inner[1] and inner[2] <= outer[2] and inner[3] <= outer[3]


def rectangles_overlap(first: tuple[int, int, int, int], second: tuple[int, int, int, int]) -> bool:
    return not (first[2] <= second[0] or second[2] <= first[0] or first[3] <= second[1] or second[3] <= first[1])


def open_interval(start: float, end: float, lower: float, upper: float) -> tuple[float, float] | None:
    delta = end - start
    if abs(delta) < EPSILON:
        return (-float("inf"), float("inf")) if lower < start < upper else None
    first = (lower - start) / delta
    second = (upper - start) / delta
    return min(first, second), max(first, second)


def segment_enters_rect_interior(
    start: tuple[int, int], end: tuple[int, int], target: tuple[int, int, int, int]
) -> bool:
    x_interval = open_interval(start[0], end[0], target[0], target[2])
    y_interval = open_interval(start[1], end[1], target[1], target[3])
    if x_interval is None or y_interval is None:
        return False
    lower = max(0.0, x_interval[0], y_interval[0])
    upper = min(1.0, x_interval[1], y_interval[1])
    return lower + EPSILON < upper


def transform_rect(source_rect: tuple[int, int, int, int], crop: tuple[int, int, int, int], scale: float) -> tuple[int, int, int, int]:
    return tuple(round((source_rect[index] - crop[index % 2]) * scale) for index in range(4))  # type: ignore[return-value]


def transform_point(source_point: tuple[int, int], crop: tuple[int, int, int, int], scale: float) -> tuple[int, int]:
    return round((source_point[0] - crop[0]) * scale), round((source_point[1] - crop[1]) * scale)


def draw_arrow(draw: ImageDraw.ImageDraw, start: tuple[int, int], end: tuple[int, int], color: tuple[int, int, int], width: int) -> None:
    draw.line((start, end), fill=color, width=width)
    angle = atan2(end[1] - start[1], end[0] - start[0])
    base = (end[0] - ARROW_HEAD_LENGTH * cos(angle), end[1] - ARROW_HEAD_LENGTH * sin(angle))
    normal = (-sin(angle), cos(angle))
    left = (base[0] + ARROW_HEAD_HALF_WIDTH * normal[0], base[1] + ARROW_HEAD_HALF_WIDTH * normal[1])
    right = (base[0] - ARROW_HEAD_HALF_WIDTH * normal[0], base[1] - ARROW_HEAD_HALF_WIDTH * normal[1])
    draw.polygon((end, left, right), fill=color)


def draw_label(draw: ImageDraw.ImageDraw, layout: TextLayout, font: ImageFont.FreeTypeFont, color: tuple[int, int, int]) -> None:
    x, y, _, _ = layout.bounds
    for index, (line, offset) in enumerate(zip(layout.lines, layout.glyph_offsets)):
        draw.text((x + offset[0], y + index * layout.line_height + offset[1]), line, font=font, fill=color)


def normalise_crop(value: Any, image: Image.Image, image_name: str) -> tuple[int, int, int, int]:
    if value is None:
        return 0, 0, image.width, image.height
    crop = rect(value, f"{image_name}.crop")
    if not rect_inside(crop, (0, 0, image.width, image.height)):
        raise JobError(f"{image_name}.crop leaves source image bounds.")
    return crop


def require_array(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise JobError(f"{field} must be an array.")
    return value


def render_image(
    image_job: dict[str, Any],
    source_dir: Path,
    output_dir: Path,
    font: ImageFont.FreeTypeFont,
    color: tuple[int, int, int],
    box_width: int,
    arrow_width: int,
    max_arrow_length: int,
    index: int,
) -> dict[str, Any]:
    prefix = f"images[{index}]"
    source_value = image_job.get("source")
    output_value = image_job.get("output")
    if not isinstance(source_value, str) or not source_value:
        raise JobError(f"{prefix}.source must be a non-empty file name.")
    if not isinstance(output_value, str) or not output_value:
        raise JobError(f"{prefix}.output must be a non-empty file name.")
    source_path = source_dir / source_value
    if not source_path.is_file():
        raise JobError(f"Source screenshot does not exist: {source_path}")
    if Path(output_value).is_absolute():
        raise JobError(f"{prefix}.output must be relative to output_dir.")
    with Image.open(source_path) as opened:
        source = opened.convert("RGB")
    crop = normalise_crop(image_job.get("crop"), source, prefix)
    cropped = source.crop(crop)
    resize_width = positive_int(image_job.get("resize_width"), f"{prefix}.resize_width", cropped.width)
    scale = resize_width / cropped.width
    if resize_width != cropped.width:
        canvas = cropped.resize((resize_width, round(cropped.height * scale)), Image.Resampling.LANCZOS)
    else:
        canvas = cropped
    canvas_bounds = (0, 0, canvas.width, canvas.height)
    raw_boxes = require_array(image_job.get("boxes"), f"{prefix}.boxes")
    if not raw_boxes:
        raise JobError(f"{prefix}.boxes must contain at least one rectangle.")
    source_boxes = [rect(item, f"{prefix}.boxes[{box_index}]") for box_index, item in enumerate(raw_boxes)]
    if not all(rect_inside(item, (0, 0, source.width, source.height)) for item in source_boxes):
        raise JobError(f"{prefix}.boxes leaves source image bounds.")
    boxes = [transform_rect(item, crop, scale) for item in source_boxes]
    if not all(rect_inside(item, canvas_bounds) for item in boxes):
        raise JobError(f"{prefix}.boxes must remain inside the crop.")
    annotations = require_array(image_job.get("annotations"), f"{prefix}.annotations")
    draw = ImageDraw.Draw(canvas)
    planned: list[tuple[TextLayout, tuple[int, int], tuple[int, int], tuple[int, int, int, int], str]] = []
    for annotation_index, annotation in enumerate(annotations):
        field = f"{prefix}.annotations[{annotation_index}]"
        if not isinstance(annotation, dict):
            raise JobError(f"{field} must be an object.")
        text = annotation.get("text")
        target_source = rect(annotation.get("target"), f"{field}.target")
        if target_source not in source_boxes:
            raise JobError(f"{field}.target must exactly match one red frame in {prefix}.boxes.")
        label = point(annotation.get("label"), f"{field}.label")
        text_width = positive_int(annotation.get("max_width"), f"{field}.max_width", 260)
        layout = layout_text(draw, font, text, label, text_width)
        if not rect_inside(layout.bounds, canvas_bounds):
            raise JobError(f"{field} label leaves screenshot bounds: {layout.bounds}")
        if any(rectangles_overlap(layout.bounds, existing[0].bounds) for existing in planned):
            raise JobError(f"{field} label overlaps another label.")
        if any(rectangles_overlap(layout.bounds, item) for item in boxes):
            raise JobError(f"{field} label overlaps a red frame.")
        target = transform_rect(target_source, crop, scale)
        start = edge_point(layout.bounds, annotation.get("label_side"))
        if "target_point" in annotation:
            end = transform_point(point(annotation["target_point"], f"{field}.target_point"), crop, scale)
            if not point_on_edge(end, target):
                raise JobError(f"{field}.target_point must lie on the target red-frame edge.")
        else:
            end = edge_point(target, annotation.get("target_side"))
        if not point_on_edge(start, layout.bounds) or not point_on_edge(end, target):
            raise JobError(f"{field} has an invalid arrow anchor.")
        arrow_length = hypot(end[0] - start[0], end[1] - start[1])
        if arrow_length > max_arrow_length:
            raise JobError(f"{field} arrow is too long ({arrow_length:.1f}px; maximum {max_arrow_length}px).")
        for box_index, other_box in enumerate(boxes):
            if segment_enters_rect_interior(start, end, other_box):
                target_name = "target" if other_box == target else f"boxes[{box_index}]"
                raise JobError(f"{field} arrow enters {target_name} frame interior.")
        planned.append((layout, start, end, target, str(text)))
    for _, start, end, _, _ in planned:
        draw_arrow(draw, start, end, color, arrow_width)
    for box in boxes:
        draw.rectangle(box, outline=color, width=box_width)
    for layout, _, _, _, _ in planned:
        draw_label(draw, layout, font, color)
    output_path = output_dir / output_value
    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output_path, optimize=True)
    return {"output": str(output_path), "size": [canvas.width, canvas.height], "annotations": len(planned)}


def main() -> int:
    args = parse_args()
    job_path = Path(args.job).resolve()
    try:
        job = load_json(job_path)
        source_dir = resolve_path(job_path, job.get("source_dir"), "source_dir")
        output_dir = resolve_path(job_path, job.get("output_dir"), "output_dir")
        if not source_dir.is_dir():
            raise JobError(f"source_dir does not exist: {source_dir}")
        font_size = positive_int(job.get("font_size"), "font_size", DEFAULT_FONT_SIZE)
        font = load_font(job, job_path, font_size)
        color = parse_color(job.get("color"))
        box_width = positive_int(job.get("box_width"), "box_width", DEFAULT_BOX_WIDTH)
        arrow_width = positive_int(job.get("arrow_width"), "arrow_width", DEFAULT_ARROW_WIDTH)
        max_arrow_length = positive_int(job.get("max_arrow_length"), "max_arrow_length", DEFAULT_MAX_ARROW_LENGTH)
        if max_arrow_length > DEFAULT_MAX_ARROW_LENGTH:
            raise JobError(f"max_arrow_length cannot exceed {DEFAULT_MAX_ARROW_LENGTH}px.")
        images = require_array(job.get("images"), "images")
        if not images:
            raise JobError("images must contain at least one screenshot job.")
        output_dir.mkdir(parents=True, exist_ok=True)
        report = []
        for index, image_job in enumerate(images):
            if not isinstance(image_job, dict):
                raise JobError(f"images[{index}] must be an object.")
            report.append(
                render_image(
                    image_job,
                    source_dir,
                    output_dir,
                    font,
                    color,
                    box_width,
                    arrow_width,
                    max_arrow_length,
                    index,
                )
            )
        print(json.dumps({"status": "ok", "images": report}, ensure_ascii=False, indent=2))
        return 0
    except JobError as error:
        print(f"annotation validation failed: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
