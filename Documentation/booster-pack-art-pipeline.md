# Booster pack artwork pipeline

`Scripts/pack_art_pipeline.py` builds a local, reproducible set of transparent English booster-pack images from the Elite Fourum community gallery. It joins the forum names to the stable set IDs found in the existing `.loader-cache`; it does not change loader data, the app asset catalog, or CloudKit.

## Requirements and use

The script requires Python 3.10 or newer and Pillow:

```sh
python3 -m pip install Pillow
python3 Scripts/pack_art_pipeline.py --dry-run
python3 Scripts/pack_art_pipeline.py
```

Generated files are written to the gitignored `.generated/booster-pack-art/` directory. Source sheets are cached in `sources/`, transparent native-resolution variants are stored as `sets/<set-id>/01.png`, and `manifest.json` records source URLs, hashes, crop coordinates, dimensions, settings, warnings, and attribution. `qa/contact-sheet.jpg`, `qa/mapping-report.json`, and `qa/segmentation-warnings.json` support visual and structural review.

Useful controls:

```sh
# Rebuild selected sets from cached source material.
python3 Scripts/pack_art_pipeline.py --offline --overwrite --set-id base1 --set-id sv1

# Refresh the forum topic and source sheets.
python3 Scripts/pack_art_pipeline.py --refresh --overwrite

# Tune separation/background thresholds for diagnosis.
python3 Scripts/pack_art_pipeline.py --white-threshold 242 --chroma-tolerance 18 --min-gap 16
```

Default reruns reuse downloaded sheets and previously generated PNGs when the source hash and processing settings are unchanged. Changed sources or settings regenerate their PNGs; `--overwrite` forces regeneration regardless. `--offline` prohibits network access. `--refresh` and `--offline` cannot be combined.

## Mapping and review

Automatic matching removes punctuation, accents, series prefixes such as `EX`, and normalizes `&` to `and`. Known naming differences and combined sheets live in `Scripts/pack_art_overrides.json`. An assignment can select a repeated source image with `source_index` and can route specific left-to-right packs using one-based `variant_indices`.

Review `qa/mapping-report.json` after the dry run. Add only confirmed aliases or assignments to the override file; promo sets, galleries, and cached subsets without physical booster art should remain reported as unmatched. After processing, review the contact sheet and every warning before using the assets elsewhere.

## Image processing and provenance

The processor finds near-white pixels connected to the outside edge, rather than deleting every white pixel. This protects enclosed white logos, artwork, and foil highlights. Foreground column occupancy identifies pack runs despite differing sheet widths and trailing whitespace; each run is tightly cropped and exported with an alpha channel.

The source page is [English and Japanese Booster Pack Arts](https://www.elitefourum.com/t/english-and-japanese-booster-pack-arts/28522). Images remain the property of their respective owners. The generated manifest preserves source attribution, but inclusion in an app, upload to CloudKit, redistribution, or commercial use requires a separate rights review.

## Tests

Run the deterministic unit and synthetic-image suite from the repository root:

```sh
PYTHONPATH=Scripts python3 -m unittest Scripts/test_pack_art_pipeline.py
```

For a live integration check, process representative IDs such as `base1`, `sv1`, `me1`, and `me2pt5`, then inspect the generated contact sheet and warning report.
