import base64
import io
import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

import pack_art_pipeline as pipeline


class PackArtPipelineTests(unittest.TestCase):
    def test_normalize_name_handles_branding_punctuation_and_accents(self):
        self.assertEqual(pipeline.normalize_name("Pokémon: X & Y"), "pokemonxandy")
        self.assertEqual(pipeline.normalize_name("EX Ruby & Sapphire"), "rubyandsapphire")

    def test_gallery_parser_stops_at_japanese(self):
        cooked = '''<h1>English</h1><h2>Era</h2><p><strong>Base Set</strong> (January 9, 1999)
        <a class="lightbox" href="https://example/a.png" title="Base"></a></p>
        <h1>Japanese</h1><p><strong>Japanese Set</strong><a class="lightbox" href="https://example/b.png"></a></p>'''
        payload = json.dumps({"post_stream": {"posts": [{"cooked": cooked}]}}).encode()
        result = pipeline.parse_gallery(payload)
        self.assertEqual([(x.name, x.date, x.url) for x in result],
                         [("Base Set", "January 9, 1999", "https://example/a.png")])

    def test_extract_cached_sets_decodes_loader_entries_and_preserves_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            body = {"data": [{"set": {"id": "svp", "name": "Name A"}},
                              {"set": {"id": "svp", "name": "Name B"}}]}
            wrapped = {"body": base64.b64encode(json.dumps(body).encode()).decode()}
            Path(directory, "one.json").write_text(json.dumps(wrapped))
            self.assertEqual(pipeline.extract_cached_sets(Path(directory)), {"svp": ["Name A", "Name B"]})

    def test_override_can_split_one_sheet_between_set_ids(self):
        gallery = [pipeline.GalleryImage("Black Bolt & White Flare", None, "SV", "u", "t", 1)]
        cached = {"black": ["Black Bolt"], "white": ["White Flare"]}
        overrides = {"aliases": {}, "assignments": {
            "black": {"source_name": "Black Bolt & White Flare", "variant_indices": [1]},
            "white": {"source_name": "Black Bolt & White Flare", "variant_indices": [2]}}}
        matches, issues = pipeline.build_mapping(cached, gallery, overrides)
        self.assertFalse(issues)
        self.assertEqual(matches["white"]["variant_indices"], [2])

    def test_override_selects_repeated_source_sheet(self):
        gallery = [pipeline.GalleryImage("POP Series", None, "POP", "one", "1-5", 1),
                   pipeline.GalleryImage("POP Series", None, "POP", "two", "6-9", 2)]
        matches, issues = pipeline.build_mapping(
            {"pop6": ["POP Series 6"]}, gallery,
            {"aliases": {}, "assignments": {"pop6": {
                "source_name": "POP Series", "source_index": 2, "variant_indices": [1]}}})
        self.assertFalse([issue for issue in issues if issue["status"] != "forum_unmatched"])
        self.assertEqual(len([issue for issue in issues if issue["status"] == "forum_unmatched"]), 1)
        self.assertEqual(matches["pop6"]["entry"].url, "two")

    def test_segmentation_preserves_enclosed_white_and_trailing_space(self):
        image = Image.new("RGB", (800, 300), "white")
        draw = ImageDraw.Draw(image)
        for left in (20, 250, 480):
            draw.rectangle((left, 15, left + 160, 285), fill=(30, 60, 120))
            draw.ellipse((left + 45, 90, left + 115, 160), fill="white")
        mask = pipeline.edge_background_mask(image, 238, 22)
        boxes = pipeline.segment_boxes(image, mask, 14)
        self.assertEqual(len(boxes), 3)
        crops = [pipeline.transparent_crop(image, mask, box) for box in boxes]
        self.assertEqual(crops[0].getpixel((82, 112))[3], 255)
        self.assertTrue(all(crop.getpixel((0, 0))[3] == 0 for crop in crops))

    def test_transparent_crop_removes_irregular_border_background(self):
        image = Image.new("RGB", (240, 220), "white")
        draw = ImageDraw.Draw(image)
        draw.polygon([(45, 15), (190, 25), (205, 200), (30, 195)], fill=(120, 20, 30))
        mask = pipeline.edge_background_mask(image, 238, 22)
        boxes = pipeline.segment_boxes(image, mask, 10)
        crop = pipeline.transparent_crop(image, mask, boxes[0])
        self.assertEqual(crop.mode, "RGBA")
        self.assertGreater(sum(value == 0 for value in crop.getchannel("A").getdata()), 0)

    def test_single_pack_with_pale_shadow_is_not_split(self):
        image = Image.new("RGB", (500, 300), "white")
        draw = ImageDraw.Draw(image)
        draw.rectangle((48, 24, 236, 284), fill=(225, 225, 225))
        draw.rectangle((40, 16, 225, 275), fill=(15, 80, 145))
        mask = pipeline.edge_background_mask(image, 238, 22)
        boxes = pipeline.segment_boxes(image, mask, 14)
        self.assertEqual(len(boxes), 1)
        self.assertGreaterEqual(boxes[0][2], 236)

    def test_manifest_json_is_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory, "manifest.json")
            pipeline.write_json(destination, {"z": 1, "a": 2})
            self.assertEqual(destination.read_text(), '{\n  "a": 2,\n  "z": 1\n}\n')


if __name__ == "__main__":
    unittest.main()
