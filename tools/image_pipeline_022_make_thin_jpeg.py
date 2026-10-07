"""Synthetic progressive fixtures for disk admission and its MCU boundary."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=Path(r"E:\picakeep-image-pipeline-022-work\quota-thin-3000-fixtures"))
    parser.add_argument("--normal", action="store_true")
    args = parser.parse_args()
    root = args.output
    root.mkdir(parents=True, exist_ok=True)
    records = []
    for width, height in ([(3000, 3000)] if args.normal else [(1, 3000), (3000, 1)]):
        for subsampling in [0, 2]:
            image = Image.new("RGB", (width, height))
            image.putdata([(index % 256, index // 3 % 256, index // 7 % 256)
                           for index in range(width * height)])
            path = root / f"{width}x{height}-s{subsampling}-progressive.jpg"
            if path.exists():
                raise RuntimeError(f"Refusing to overwrite {path}")
            image.save(path, quality=95, progressive=True, subsampling=subsampling)
            records.append({"file": path.name, "bytes": path.stat().st_size,
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    print(json.dumps(records, indent=2))


if __name__ == "__main__":
    main()
