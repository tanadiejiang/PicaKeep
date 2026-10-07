"""Deterministic 4000x6000 original; never reads a user's image collection."""
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    root = Path(r"E:\picakeep-image-pipeline-022-fixtures")
    root.mkdir(parents=True, exist_ok=True)
    width, height = 4000, 6000
    x = np.arange(width, dtype=np.uint32)[None, :]
    y = np.arange(height, dtype=np.uint32)[:, None]
    data = np.empty((height, width, 3), dtype=np.uint8)
    data[:, :, 0] = (x + y) % 256
    data[:, :, 1] = ((x // 48 + y // 48) % 2) * 255
    data[:, :, 2] = (x // 16 + y // 16) % 256
    data[(y % 53 == 0).flatten(), :, :] = 0
    image = Image.fromarray(data)
    results = []
    for name, options in [
        ("4000x6000.png", {}),
        ("4000x6000-baseline.jpg", {"quality": 95, "subsampling": 0}),
    ]:
        destination = root / name
        if destination.exists():
            raise RuntimeError(f"Refusing to overwrite existing fixture {name}")
        image.save(destination, **options)
        results.append({
            "file": name, "width": width, "height": height,
            "bytes": destination.stat().st_size,
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        })
    report = {
        "scope": "synthetic original with gradient, one-pixel ink and checkerboard",
        "workingRgba8Bytes": width * height * 4,
        "files": results,
    }
    (root / "ordinary-4000x6000-manifest.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
