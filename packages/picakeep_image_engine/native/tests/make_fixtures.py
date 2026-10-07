"""Local deterministic original-image fixtures; never uses user image data."""
from pathlib import Path
import argparse
import json
import os
import numpy as np
from PIL import Image, ImageCms

parser = argparse.ArgumentParser()
parser.add_argument('--large', action='store_true')
parser.add_argument('--output-dir', type=Path,
                    default=Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_FIXTURES', 'E:/picakeep-image-pipeline-022-fixtures')))
args = parser.parse_args()
target = args.output_dir
target.mkdir(exist_ok=True, parents=True)
sizes = [(8000, 12000), (800, 30000)] if args.large else [(640, 960), (80, 3000)]
manifest = []
for width, height in sizes:
    # Gradients, 1px text-like lines, checkerboard details and alpha edges.
    x = np.arange(width, dtype=np.uint32)[None, :]
    y = np.arange(height, dtype=np.uint32)[:, None]
    data = np.empty((height, width, 3), dtype=np.uint8)
    data[:, :, 0] = (x + y) % 256
    data[:, :, 1] = ((x // 48 + y // 48) % 2) * 255
    data[:, :, 2] = (x // 16 + y // 16) % 256
    data[(y % 53 == 0).flatten(), :, :] = 0
    image = Image.fromarray(data)
    stem = f'{width}x{height}'
    for progressive in [False, True]:
        path = target / f'{stem}-{"progressive" if progressive else "baseline"}.jpg'
        image.save(path, quality=95, progressive=progressive, subsampling=0)
        manifest.append(str(path))
    path = target / f'{stem}.png'
    image.save(path)
    manifest.append(str(path))
    if width <= 16383 and height <= 16383:
        for lossless in [False, True]:
            path = target / f'{stem}-{"lossless" if lossless else "lossy"}.webp'
            image.save(path, lossless=lossless, quality=80, method=6)
            manifest.append(str(path))
    if not args.large:
        path = target / f'{stem}-chroma-420.jpg'
        image.save(path, quality=95, subsampling=2)
        manifest.append(str(path))
        rgba = np.array(image.convert('RGBA'))
        yy, xx = np.indices(rgba.shape[:2])
        rgba[:, :, 3] = ((xx * 19 + yy * 31) % 256).astype(np.uint8)
        rgba[(xx + yy) % 31 == 0, 3] = 0
        path = target / f'{stem}-alpha.png'
        Image.fromarray(rgba).save(path)
        manifest.append(str(path))
        del rgba, yy, xx
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        for orientation in range(1, 9):
            exif = Image.Exif(); exif[274] = orientation
            path = target / f'{stem}-orientation-{orientation}.jpg'
            image.save(path, quality=95, exif=exif, icc_profile=profile, subsampling=0)
            manifest.append(str(path))
    del image, data
(target / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(f'Generated {len(manifest)} files in {target}')
