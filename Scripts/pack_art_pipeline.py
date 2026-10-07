#!/usr/bin/env python3
"""Download, match, segment, and background-mask English booster pack art."""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
from html.parser import HTMLParser
import io
import json
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

try:
    from PIL import Image, ImageDraw, ImageOps
except ImportError:  # pragma: no cover - exercised by CLI preflight
    Image = None

TOPIC_URL = "https://www.elitefourum.com/t/english-and-japanese-booster-pack-arts/28522"
TOPIC_JSON_URL = TOPIC_URL + ".json"
USER_AGENT = "BattleCardDex pack-art archival tool/1.0"


@dataclass(frozen=True)
class GalleryImage:
    name: str
    date: str | None
    section: str
    url: str
    title: str
    source_index: int


class GalleryParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.language: str | None = None
        self.section = ""
        self.current_name: str | None = None
        self.current_date: str | None = None
        self.capture: str | None = None
        self.text_parts: list[str] = []
        self.in_paragraph = False
        self.paragraph_parts: list[str] = []
        self.entries: list[GalleryImage] = []
        self.counts: dict[str, int] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag in {"h1", "h2", "strong"}:
            self.capture = tag
            self.text_parts = []
        if tag == "p":
            self.in_paragraph = True
            self.paragraph_parts = []
        if tag == "a" and "lightbox" in (values.get("class") or "").split():
            url = values.get("href")
            if not url or self.language != "English":
                return
            paragraph = " ".join("".join(self.paragraph_parts).split())
            date_match = re.search(r"\(([^()]*(?:19|20)\d{2}[^()]*)\)", paragraph)
            if date_match:
                self.current_date = date_match.group(1).strip()
            name = self.current_name or self.section
            index = self.counts.get(name, 0) + 1
            self.counts[name] = index
            self.entries.append(GalleryImage(name, self.current_date, self.section, url,
                                             values.get("title") or name, index))

    def handle_data(self, data: str) -> None:
        if self.capture:
            self.text_parts.append(data)
        if self.in_paragraph:
            self.paragraph_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "p":
            value = " ".join("".join(self.paragraph_parts).split())
            if self.language == "English":
                match = re.search(r"\(([^()]*(?:19|20)\d{2}[^()]*)\)", value)
                if match:
                    self.current_date = match.group(1).strip()
            self.in_paragraph = False
            self.paragraph_parts = []
            return
        if tag != self.capture:
            return
        value = " ".join("".join(self.text_parts).split())
        if tag == "h1":
            self.language = value
            self.current_name = None
        elif tag == "h2":
            self.section = value
            self.current_name = None
            self.current_date = None
        elif tag == "strong" and self.language == "English":
            self.current_name = value
            self.current_date = None
        self.capture = None
        self.text_parts = []


def normalize_name(value: str) -> str:
    value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    value = value.lower().replace("&", " and ")
    value = re.sub(r"\b(ex|hs)\b", " ", value)
    return re.sub(r"[^a-z0-9]+", "", value)


def fetch_bytes(url: str, timeout: int = 60) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def parse_gallery(topic_payload: bytes) -> list[GalleryImage]:
    root = json.loads(topic_payload)
    posts = root.get("post_stream", {}).get("posts", [])
    if not posts:
        raise ValueError("topic JSON contains no posts")
    parser = GalleryParser()
    for post in posts:
        parser.feed(html.unescape(post.get("cooked", "")))
    if not parser.entries:
        raise ValueError("no English gallery images found")
    return parser.entries


def extract_cached_sets(cache_dir: Path) -> dict[str, list[str]]:
    sets: dict[str, set[str]] = {}
    for path in sorted(cache_dir.glob("*.json")):
        try:
            wrapper = json.loads(path.read_text())
            payload = json.loads(base64.b64decode(wrapper["body"]))
        except (OSError, ValueError, KeyError, TypeError):
            continue
        cards = payload.get("data", []) if isinstance(payload, dict) else []
        for card in cards if isinstance(cards, list) else []:
            item = card.get("set") if isinstance(card, dict) else None
            if isinstance(item, dict) and item.get("id") and item.get("name"):
                sets.setdefault(str(item["id"]), set()).add(str(item["name"]))
    return {key: sorted(values) for key, values in sorted(sets.items())}


def load_overrides(path: Path) -> dict[str, Any]:
    with path.open() as stream:
        value = json.load(stream)
    if not isinstance(value.get("aliases", {}), dict) or not isinstance(value.get("assignments", {}), dict):
        raise ValueError("override file must contain object-valued aliases and assignments")
    return value


def build_mapping(cached_sets: dict[str, list[str]], gallery: list[GalleryImage],
                  overrides: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    by_name: dict[str, list[GalleryImage]] = {}
    for entry in gallery:
        by_name.setdefault(normalize_name(entry.name), []).append(entry)
    mappings: dict[str, dict[str, Any]] = {}
    issues: list[dict[str, Any]] = []
    aliases = overrides.get("aliases", {})
    assignments = overrides.get("assignments", {})
    for set_id, names in cached_sets.items():
        assignment = assignments.get(set_id, {})
        candidate_name = assignment.get("source_name") or aliases.get(set_id) or names[0]
        candidates = by_name.get(normalize_name(candidate_name), [])
        source_index = assignment.get("source_index")
        if source_index is not None:
            candidates = [entry for entry in candidates if entry.source_index == int(source_index)]
        if len(candidates) == 1:
            mappings[set_id] = {
                "cached_names": names,
                "entry": candidates[0],
                "variant_indices": assignment.get("variant_indices"),
                "match": "override" if set_id in aliases or set_id in assignments else "normalized",
            }
        else:
            issues.append({"set_id": set_id, "cached_names": names, "candidate_name": candidate_name,
                           "status": "unmatched" if not candidates else "ambiguous",
                           "candidate_count": len(candidates)})
    used_sources = {(value["entry"].url, value["entry"].source_index) for value in mappings.values()}
    for entry in gallery:
        if (entry.url, entry.source_index) not in used_sources:
            issues.append({"status": "forum_unmatched", "forum_name": entry.name,
                           "forum_date": entry.date, "source_url": entry.url,
                           "source_index": entry.source_index})
    return mappings, issues


def edge_background_mask(image: "Image.Image", white_threshold: int, chroma_tolerance: int) -> "Image.Image":
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    mask = Image.new("1", rgb.size, 0)
    out = mask.load()
    queue: deque[tuple[int, int]] = deque()

    def candidate(x: int, y: int) -> bool:
        r, g, b = pixels[x, y]
        return min(r, g, b) >= white_threshold and max(r, g, b) - min(r, g, b) <= chroma_tolerance

    for x in range(width):
        if candidate(x, 0): queue.append((x, 0))
        if candidate(x, height - 1): queue.append((x, height - 1))
    for y in range(height):
        if candidate(0, y): queue.append((0, y))
        if candidate(width - 1, y): queue.append((width - 1, y))
    while queue:
        x, y = queue.popleft()
        if out[x, y] or not candidate(x, y):
            continue
        out[x, y] = 1
        if x: queue.append((x - 1, y))
        if x + 1 < width: queue.append((x + 1, y))
        if y: queue.append((x, y - 1))
        if y + 1 < height: queue.append((x, y + 1))
    return mask


def _runs(flags: Iterable[bool]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    start: int | None = None
    values = list(flags)
    for index, active in enumerate(values + [False]):
        if active and start is None: start = index
        elif not active and start is not None:
            result.append((start, index))
            start = None
    return result


def segment_boxes(image: "Image.Image", background: "Image.Image", min_gap: int,
                  min_width_fraction: float = 0.08) -> list[tuple[int, int, int, int]]:
    width, height = image.size
    bg = background.load()
    occupancy = [sum(not bg[x, y] for y in range(height)) for x in range(width)]
    active = [count >= max(3, int(height * 0.025)) for count in occupancy]
    # Fill only short holes inside a pack; genuine inter-pack gaps remain inactive.
    for start, end in _runs(not value for value in active):
        if start > 0 and end < width and end - start < min_gap:
            for x in range(start, end): active[x] = True
    bands = [(left, right) for left, right in _runs(active) if right - left >= width * min_width_fraction]
    boxes: list[tuple[int, int, int, int]] = []
    for left, right in bands:
        ys = [y for y in range(height) if any(not bg[x, y] for x in range(left, right))]
        if ys:
            boxes.append((left, min(ys), right, max(ys) + 1))
    return boxes


def transparent_crop(image: "Image.Image", background: "Image.Image",
                     box: tuple[int, int, int, int]) -> "Image.Image":
    crop = image.convert("RGBA").crop(box)
    bg = background.crop(box).convert("L")
    alpha = bg.point(lambda value: 0 if value else 255)
    crop.putalpha(alpha)
    bbox = crop.getbbox()
    crop = crop.crop(bbox) if bbox else crop
    # A small transparent guard makes background removal explicit and prevents
    # downstream texture sampling from clamping opaque edge pixels.
    return ImageOps.expand(crop, border=2, fill=(0, 0, 0, 0))


def warnings_for(boxes: list[tuple[int, int, int, int]], size: tuple[int, int], outputs: list["Image.Image"]) -> list[str]:
    width, height = size
    warnings: list[str] = []
    if not boxes: warnings.append("no pack components detected")
    if len(boxes) > 12: warnings.append(f"unexpected pack count: {len(boxes)}")
    for index, (box, output) in enumerate(zip(boxes, outputs), 1):
        left, top, right, bottom = box
        ratio = output.width / max(output.height, 1)
        if right - left < width * 0.08 or bottom - top < height * 0.45:
            warnings.append(f"variant {index} is implausibly small")
        if not 0.25 <= ratio <= 0.9:
            warnings.append(f"variant {index} has unusual aspect ratio {ratio:.3f}")
        alpha = output.getchannel("A")
        border = list(alpha.crop((0, 0, output.width, 1)).getdata()) + list(alpha.crop((0, output.height - 1, output.width, output.height)).getdata())
        if border and sum(value == 0 for value in border) / len(border) < 0.02:
            warnings.append(f"variant {index} has little transparent top/bottom border")
    return warnings


def source_path(root: Path, entry: GalleryImage) -> Path:
    suffix = Path(urllib.parse.urlparse(entry.url).path).suffix.lower() or ".img"
    digest = hashlib.sha256(entry.url.encode()).hexdigest()[:16]
    return root / "sources" / f"{normalize_name(entry.name) or 'pack'}-{entry.source_index}-{digest}{suffix}"


def get_source(root: Path, entry: GalleryImage, refresh: bool, offline: bool) -> tuple[Path, bytes]:
    path = source_path(root, entry)
    if path.exists() and not refresh:
        return path, path.read_bytes()
    if offline:
        raise FileNotFoundError(f"source is not cached: {entry.url}")
    data = fetch_bytes(entry.url)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path, data


def make_contact_sheet(items: list[tuple[str, "Image.Image"]], destination: Path) -> None:
    if not items: return
    thumb_width, thumb_height = 180, 360
    canvas = Image.new("RGBA", (thumb_width * min(6, len(items)), (thumb_height + 34) * ((len(items) + 5) // 6)), "white")
    draw = ImageDraw.Draw(canvas)
    for index, (label, source) in enumerate(items):
        thumb = source.copy(); thumb.thumbnail((thumb_width - 12, thumb_height - 12))
        x = (index % 6) * thumb_width + (thumb_width - thumb.width) // 2
        y = (index // 6) * (thumb_height + 34) + (thumb_height - thumb.height) // 2
        canvas.alpha_composite(thumb, (x, y)); draw.text((index % 6 * thumb_width + 5, y + thumb.height + 4), label[:27], fill="black")
    destination.parent.mkdir(parents=True, exist_ok=True); canvas.convert("RGB").save(destination, quality=90)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def run(args: argparse.Namespace) -> int:
    root = args.output.resolve()
    previous_manifest: dict[str, Any] = {}
    manifest_path = root / "manifest.json"
    if manifest_path.exists():
        try: previous_manifest = json.loads(manifest_path.read_text())
        except (OSError, ValueError): pass
    topic_cache = root / "sources" / "topic.json"
    if topic_cache.exists() and not args.refresh:
        topic_data = topic_cache.read_bytes()
    elif args.offline:
        raise FileNotFoundError("forum topic is not cached")
    else:
        topic_data = fetch_bytes(args.topic_url.rstrip("/") + ".json")
        topic_cache.parent.mkdir(parents=True, exist_ok=True); topic_cache.write_bytes(topic_data)
    gallery = parse_gallery(topic_data)
    cached_sets = extract_cached_sets(args.cache)
    if not cached_sets: raise ValueError(f"no card sets found in {args.cache}")
    mappings, issues = build_mapping(cached_sets, gallery, load_overrides(args.overrides))
    if args.set_id:
        selected = set(args.set_id)
        mappings = {key: value for key, value in mappings.items() if key in selected}
        issues = [issue for issue in issues if issue["set_id"] in selected]

    report = {
        "topic_url": args.topic_url, "cached_set_count": len(cached_sets),
        "gallery_image_count": len(gallery), "matched_set_count": len(mappings), "issues": issues,
    }
    write_json(root / "qa" / "mapping-report.json", report)
    if args.dry_run:
        print(json.dumps(report, indent=2, ensure_ascii=False)); return 0
    if Image is None: raise RuntimeError("Pillow is required: python3 -m pip install Pillow")

    manifest_sets: dict[str, Any] = dict(previous_manifest.get("sets", {})) if args.set_id else {}
    contacts: list[tuple[str, Image.Image]] = []
    for set_id, mapping in mappings.items():
        entry: GalleryImage = mapping["entry"]
        try:
            path, data = get_source(root, entry, args.refresh, args.offline)
            source_hash = hashlib.sha256(data).hexdigest()
            fingerprint_value = {
                "source_sha256": source_hash, "variant_indices": mapping["variant_indices"],
                "white_threshold": args.white_threshold, "chroma_tolerance": args.chroma_tolerance,
                "min_gap": args.min_gap,
            }
            fingerprint = hashlib.sha256(json.dumps(fingerprint_value, sort_keys=True).encode()).hexdigest()
            previous = previous_manifest.get("sets", {}).get(set_id, {})
            previous_files = [root / item.get("path", "") for item in previous.get("variants", [])]
            if not args.overwrite and previous.get("fingerprint") == fingerprint and previous_files and all(item.is_file() for item in previous_files):
                manifest_sets[set_id] = previous
                for item, file_path in zip(previous["variants"], previous_files):
                    with Image.open(file_path) as saved:
                        contacts.append((f"{set_id}/{item['index']:02d}", saved.convert("RGBA")))
                continue
            with Image.open(io.BytesIO(data)) as opened:
                image = ImageOps.exif_transpose(opened).convert("RGB")
            background = edge_background_mask(image, args.white_threshold, args.chroma_tolerance)
            boxes = segment_boxes(image, background, args.min_gap)
            crops = [transparent_crop(image, background, box) for box in boxes]
            chosen = mapping["variant_indices"] or list(range(1, len(crops) + 1))
            invalid = [value for value in chosen if not isinstance(value, int) or value < 1 or value > len(crops)]
            if invalid: raise ValueError(f"invalid variant indexes {invalid}; detected {len(crops)}")
            selected = [(index, boxes[index - 1], crops[index - 1]) for index in chosen]
            warnings = warnings_for([box for _, box, _ in selected], image.size, [crop for _, _, crop in selected])
            set_dir = root / "sets" / set_id; set_dir.mkdir(parents=True, exist_ok=True)
            variants = []
            for output_index, (source_index, box, crop) in enumerate(selected, 1):
                destination = set_dir / f"{output_index:02d}.png"
                crop.save(destination, optimize=True)
                variants.append({"index": output_index, "source_variant_index": source_index,
                                 "path": str(destination.relative_to(root)), "crop": list(box),
                                 "width": crop.width, "height": crop.height})
                contacts.append((f"{set_id}/{output_index:02d}", crop))
            manifest_sets[set_id] = {
                "status": "warning" if warnings else "processed", "cached_names": mapping["cached_names"],
                "forum_name": entry.name, "forum_date": entry.date, "section": entry.section,
                "source_url": entry.url, "source_path": str(path.relative_to(root)),
                "source_sha256": source_hash, "fingerprint": fingerprint, "source_width": image.width,
                "source_height": image.height, "match": mapping["match"], "warnings": warnings,
                "settings": {"white_threshold": args.white_threshold, "chroma_tolerance": args.chroma_tolerance,
                             "min_gap": args.min_gap}, "variants": variants,
            }
        except Exception as error:
            manifest_sets[set_id] = {"status": "failed", "cached_names": mapping["cached_names"],
                                     "forum_name": entry.name, "source_url": entry.url, "error": str(error)}
    manifest = {
        "schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
        "topic_url": args.topic_url, "attribution": "Images are sourced from the linked Elite Fourum community gallery; rights remain with their respective owners.",
        "cached_set_count": len(cached_sets), "sets": manifest_sets, "unmatched_or_ambiguous": issues,
    }
    write_json(root / "manifest.json", manifest)
    make_contact_sheet(contacts, root / "qa" / "contact-sheet.jpg")
    write_json(root / "qa" / "segmentation-warnings.json",
               {key: value for key, value in manifest_sets.items() if value["status"] != "processed"})
    failed = sum(value["status"] == "failed" for value in manifest_sets.values())
    print(f"Processed {len(manifest_sets) - failed} sets; {failed} failed; {len(issues)} unmatched/ambiguous. Output: {root}")
    return 1 if failed else 0


def parser() -> argparse.ArgumentParser:
    repository = Path(__file__).resolve().parents[1]
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--topic-url", default=TOPIC_URL)
    value.add_argument("--cache", type=Path, default=repository / ".loader-cache")
    value.add_argument("--overrides", type=Path, default=Path(__file__).with_name("pack_art_overrides.json"))
    value.add_argument("--output", type=Path, default=repository / ".generated" / "booster-pack-art")
    value.add_argument("--set-id", action="append", help="process only this cached set ID; repeatable")
    value.add_argument("--refresh", action="store_true", help="redownload the topic and image sheets")
    value.add_argument("--offline", action="store_true", help="fail rather than access the network")
    value.add_argument("--dry-run", action="store_true", help="write/print mapping report without downloading images")
    value.add_argument("--overwrite", action="store_true", help="replace existing output PNG files")
    value.add_argument("--white-threshold", type=int, default=238)
    value.add_argument("--chroma-tolerance", type=int, default=22)
    value.add_argument("--min-gap", type=int, default=14)
    return value


def main() -> int:
    args = parser().parse_args()
    if args.refresh and args.offline: parser().error("--refresh and --offline are mutually exclusive")
    try:
        return run(args)
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"pack-art pipeline failed: {error}", file=sys.stderr); return 2


if __name__ == "__main__":
    raise SystemExit(main())
