"""Rebuild task-owned R3/F4 real-format fixtures without Flutter or downloads.

Usage (bundled Python with Pillow 12.3.0; no package installation):
  python test/support/reader_format_fixtures_066.py --write
  python test/support/reader_format_fixtures_066.py --check

The committed RGBA references are decoded by Pillow/libjpeg/libwebp, NOT by
Flutter or the reader being tested. Tolerances below are fixed before Flutter
execution. --check regenerates in memory and never rewrites test evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps, features, __version__ as pillow_version

ROOT = Path(__file__).resolve().parents[1] / "fixtures" / "reader_066"
WIDTH, HEIGHT = 96, 64
# Distinct interiors avoid lossy edge ringing in the semantic marker checks.
MARKERS = [
    ("red_top_left", 12, 10),
    ("green_top_right", 78, 13),
    ("blue_bottom_left", 10, 51),
    ("yellow_bottom_right", 79, 49),
    ("white_offset", 38, 22),
    ("black_offset", 54, 38),
]
# Full-image comparison is to the fixed encoded/decoded reference, not RGB
# before lossy encoding. These thresholds are NOT learned from Flutter output.
TOLERANCES = {
    "jpeg": {"max_rgb_error": 3, "mean_rgb_error": 0.75},
    "webp_lossy": {"max_rgb_error": 2, "mean_rgb_error": 0.25},
    "lossless": {"max_rgb_error": 0, "mean_rgb_error": 0.0,
                 "translucent_premultiply_max_error": 1},
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def artwork(alpha: bool) -> Image.Image:
    image = Image.new("RGBA" if alpha else "RGB", (WIDTH, HEIGHT), (44, 68, 92))
    draw = ImageDraw.Draw(image)
    # Unequal sizes/positions: no 90-degree rotation or mirror leaves this
    # pattern invariant. No fonts or external files participate in generation.
    draw.rectangle((3, 3, 25, 20), fill=(224, 32, 48))
    draw.rectangle((64, 4, 91, 25), fill=(32, 192, 64))
    draw.rectangle((2, 41, 23, 61), fill=(32, 64, 224))
    draw.rectangle((62, 37, 93, 60), fill=(240, 208, 32))
    draw.rectangle((32, 5, 36, 28), fill=(250, 250, 250))
    draw.rectangle((32, 20, 47, 25), fill=(250, 250, 250))
    draw.rectangle((48, 31, 58, 43), fill=(6, 6, 6))
    draw.rectangle((27, 49, 47, 52), fill=(208, 48, 192))
    if alpha:
        draw.rectangle((28, 32, 42, 43), fill=(197, 91, 35, 0))
        draw.rectangle((49, 6, 59, 18), fill=(255, 64, 0, 128))
        draw.rectangle((49, 49, 57, 60), fill=(0, 255, 128, 32))
    return image


def transformed_xy(x: int, y: int, orientation: int) -> tuple[int, int]:
    # Independent EXIF coordinate definition, cross-checked against Pillow's
    # ImageOps transpose when constructing the committed reference.
    return {
        1: (x, y), 2: (WIDTH - 1 - x, y),
        3: (WIDTH - 1 - x, HEIGHT - 1 - y), 4: (x, HEIGHT - 1 - y),
        5: (y, x), 6: (HEIGHT - 1 - y, x),
        7: (HEIGHT - 1 - y, WIDTH - 1 - x), 8: (y, WIDTH - 1 - x),
    }[orientation]


def premultiplied(image: Image.Image) -> bytes:
    output = bytearray()
    for red, green, blue, alpha in image.convert("RGBA").get_flattened_data():
        output.extend(((red * alpha + 127) // 255,
                       (green * alpha + 127) // 255,
                       (blue * alpha + 127) // 255, alpha))
    return bytes(output)


def generate() -> dict[str, bytes]:
    if pillow_version != "12.3.0":
        raise RuntimeError("Use pinned bundled Pillow 12.3.0; do not silently change references")
    if not features.check("webp"):
        raise RuntimeError("Bundled Pillow has no WebP codec; do not install anything")
    assets: dict[str, bytes] = {}
    entries = []
    rgb, rgba = artwork(False), artwork(True)
    cases = [(f"jpeg_exif_{o}", "jpeg", o, rgb) for o in range(1, 9)]
    cases += [("png_alpha", "png", 1, rgba),
              ("webp_lossless_alpha", "webp_lossless", 1, rgba),
              ("webp_lossy", "webp_lossy", 1, rgb)]
    for name, kind, orientation, source in cases:
        stream = io.BytesIO()
        if kind == "jpeg":
            exif = Image.Exif()
            exif[274] = orientation
            params = {"quality": 95, "subsampling": 0, "optimize": False,
                      "progressive": False}
            source.save(stream, "JPEG", exif=exif, **params)
            extension, tolerance = "jpg", TOLERANCES["jpeg"]
        elif kind == "png":
            params = {"compress_level": 9, "optimize": False}
            source.save(stream, "PNG", **params)
            extension, tolerance = "png", TOLERANCES["lossless"]
        elif kind == "webp_lossless":
            params = {"lossless": True, "quality": 100, "method": 6, "exact": True}
            source.save(stream, "WEBP", **params)
            extension, tolerance = "webp", TOLERANCES["lossless"]
        else:
            params = {"lossless": False, "quality": 95, "method": 6}
            source.save(stream, "WEBP", **params)
            extension, tolerance = "webp", TOLERANCES["webp_lossy"]
        encoded = stream.getvalue()
        with Image.open(io.BytesIO(encoded)) as decoded:
            decoded.load()
            encoded_rgba = decoded.convert("RGBA")
            normalized = ImageOps.exif_transpose(decoded).convert("RGBA")
        reference = premultiplied(normalized)
        marks = list(MARKERS)
        if source.mode == "RGBA":
            marks += [("transparent", 35, 37), ("half_alpha", 53, 12),
                      ("low_alpha", 53, 55)]
        samples = []
        for label, x, y in marks:
            tx, ty = transformed_xy(x, y, orientation)
            expected = encoded_rgba.getpixel((x, y))
            assert normalized.getpixel((tx, ty)) == expected
            i = (ty * normalized.width + tx) * 4
            samples.append({"name": label, "source_xy": [x, y],
                            "normalized_xy": [tx, ty],
                            "encoded_straight_rgba": list(expected),
                            "premultiplied_rgba": list(reference[i:i + 4])})
        filename, reference_name = f"{name}.{extension}", f"{name}.rgba"
        assets[filename], assets[reference_name] = encoded, reference
        entries.append({
            "id": name, "file": filename, "format": kind,
            "encoded_size": [WIDTH, HEIGHT], "orientation": orientation,
            "normalized_size": list(normalized.size), "parameters": params,
            "sha256": digest(encoded), "reference": reference_name,
            "reference_sha256": digest(reference), "tolerance": tolerance,
            "samples": samples,
        })
    manifest = {
        "schema": 1,
        "purpose": "066 R3/F4 offline real codec references; no external/user images",
        "generator": "test/support/reader_format_fixtures_066.py",
        "reference_decoder": {"Pillow": pillow_version,
                              "libjpeg": features.version_codec("jpg"),
                              "libjpeg_turbo": features.version_feature("libjpeg_turbo"),
                              "libwebp": features.version_module("webp")},
        "reference_format": "row-major RGBA8 premultiplied, (channel*alpha+127)//255",
        "comparison": "alpha exact; opaque lossless RGB exact; translucent lossless RGB <=1; lossy fixed max AND mean",
        "fixtures": entries,
    }
    assets["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    return assets


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--write", action="store_true")
    choice.add_argument("--check", action="store_true")
    args = parser.parse_args()
    assets = generate()
    if args.write:
        ROOT.mkdir(parents=True, exist_ok=True)
        for name, data in assets.items():
            (ROOT / name).write_bytes(data)
        print(f"Wrote {len(assets)} task-owned files under {ROOT}")
    else:
        failures = [name for name, data in assets.items()
                    if not (ROOT / name).is_file() or (ROOT / name).read_bytes() != data]
        if failures:
            raise SystemExit("Rebuild mismatch (no files written): " + ", ".join(failures))
        print(f"Verified {len(assets)} byte-identical task-owned files; no files written")
    print(f"11 real encoded images, 11 independent RGBA references; {sum(map(len, assets.values()))} bytes")


if __name__ == "__main__":
    main()
