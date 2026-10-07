"""Verify ceil-sized JPEG IDCT whole fits without changing exact ROI pixels.

Only synthetic files beneath an explicit artifact directory are written. Exact
reference pixels come from a separate vendored-codec full-scanline tool that
does not call region/crop/backing code. Pillow IJG 9.0 is an additional comparison
reported separately; its floor-sized draft target forces the same denominator.
"""
import argparse
import ctypes as c
import hashlib
import json
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

import numpy as np
from PIL import Image, ImageCms


class Metadata(c.Structure):
    _fields_ = [(key, c.c_uint32) for key in
                ['width', 'height', 'ew', 'eh', 'format', 'orientation',
                 'animated', 'depth', 'profile']] + [('estimate', c.c_uint64)]


class Request(c.Structure):
    _fields_ = [(key, c.c_uint32) for key in
                ['x', 'y', 'width', 'height', 'ow', 'oh']] + [
                    ('memory', c.c_uint64), ('disk', c.c_uint64),
                    ('token', c.c_void_p)]


class Result(c.Structure):
    _fields_ = [('pixels', c.POINTER(c.c_uint8)), ('length', c.c_uint64)] + [
        (key, c.c_uint32) for key in ['width', 'height', 'stride']] + [
        (key, c.c_uint64) for key in ['peak', 'disk', 'micros']] + [
        ('backend', c.c_char_p)]


def library_at(path):
    library = c.CDLL(str(path))
    library.pki_probe.argtypes = [c.c_char_p, c.POINTER(Metadata), c.c_char_p,
                                 c.c_uint64]
    library.pki_decode_region.argtypes = [c.c_char_p, c.c_char_p,
                                         c.POINTER(Request), c.POINTER(Result),
                                         c.c_char_p, c.c_uint64]
    library.pki_release.argtypes = [c.POINTER(Result)]
    library.pki_token_create.restype = c.c_void_p
    library.pki_token_cancel.argtypes = [c.c_void_p]
    library.pki_token_destroy.argtypes = [c.c_void_p]
    return library


def decode(library, source, backing, ow, oh, box=None, disk=384 << 20):
    metadata, error = Metadata(), c.create_string_buffer(512)
    assert library.pki_probe(str(source).encode(), c.byref(metadata), error,
                             512) == 0, error.value
    x, y, width, height = box or (0, 0, metadata.width, metadata.height)
    request = Request(x, y, width, height, ow, oh, 192 << 20, disk, None)
    result = Result()
    status = library.pki_decode_region(str(source).encode(),
                                       str(backing).encode(), c.byref(request),
                                       c.byref(result), error, 512)
    try:
        if status:
            assert not result.pixels and result.length == 0
            return {'status': status, 'error': error.value.decode()}, None
        assert (result.width, result.height, result.stride) == (ow, oh, ow * 4)
        pixels = np.ctypeslib.as_array(result.pixels, shape=(result.length,))
        pixels = pixels.reshape(oh, ow, 4).copy()
        record = dict(status=0, nativeUs=result.micros, peakBytes=result.peak,
                      diskBytes=result.disk, backend=result.backend.decode(),
                      outputWidth=ow, outputHeight=oh)
        return record, pixels
    finally:
        library.pki_release(c.byref(result))


def jpeg_pattern(width, height):
    x = np.arange(width, dtype=np.uint32)[None, :]
    y = np.arange(height, dtype=np.uint32)[:, None]
    pixels = np.empty((height, width, 3), dtype=np.uint8)
    pixels[:, :, 0] = (x * 3 + y * 5) % 256
    pixels[:, :, 1] = (x * 7 + y * 2) % 256
    pixels[:, :, 2] = ((x // 13 ^ y // 17) * 31) % 256
    return Image.fromarray(pixels, 'RGB')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--baseline-library', type=Path)
    parser.add_argument('--scaled-reference', type=Path, required=True)
    parser.add_argument('--artifact-dir', type=Path, required=True)
    parser.add_argument('--large', action='store_true')
    args = parser.parse_args()
    assert args.artifact_dir.is_absolute()
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    library = library_at(args.library)
    baseline = library_at(args.baseline_library) if args.baseline_library else None
    records = []
    with TemporaryDirectory(prefix='pki-jpeg-ceil-', dir=args.artifact_dir) as tmp:
        root = Path(tmp)
        root.resolve().relative_to(args.artifact_dir.resolve())
        source_image = jpeg_pattern(643, 967)
        cases = [('420', source_image, {'subsampling': 2}),
                 ('444', source_image, {'subsampling': 0}),
                 ('gray', source_image.convert('L'), {})]
        sources = []
        for name, image, options in cases:
            source = root / f'odd-{name}.jpg'
            image.save(source, quality=95, **options)
            sources.append(source)
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            for denominator in (2, 4, 8):
                ow, oh = ((643 + denominator - 1) // denominator,
                          (967 + denominator - 1) // denominator)
                backing = root / f'odd-{name}-d{denominator}.raw'
                record, pixels = decode(library, source, backing, ow, oh, disk=1)
                assert record['status'] == 0, record
                assert record['backend'] == 'libjpeg-turbo/budgeted-crop-skip'
                assert record['diskBytes'] == 0 and not backing.exists()
                reference_image = Image.open(source)
                reference_image.draft('RGB', (643 // denominator, 967 // denominator))
                reference = np.array(reference_image.convert('RGBA'))
                assert reference.shape == pixels.shape
                difference = np.abs(reference.astype(int) - pixels.astype(int))
                same_codec_path = root / f'reference-{name}-d{denominator}.rgba'
                subprocess.run([str(args.scaled_reference), str(source),
                                str(denominator), str(same_codec_path)],
                               check=True, capture_output=True)
                same_codec = np.frombuffer(same_codec_path.read_bytes(), dtype=np.uint8)
                same_codec = same_codec.reshape(oh, ow, 4)
                assert np.array_equal(same_codec, pixels), (name, denominator)
                records.append(dict(case=f'odd-{name}-d{denominator}',
                                    reference='vendored libjpeg-turbo full scanlines same IDCT denominator',
                                    sameCodecPixelDifference=0,
                                    pillowIjg9MaximumChannelDifference=int(difference.max()),
                                    pillowIjg9MeanChannelDifference=float(difference.mean()),
                                    sourceSha256=before, **record))
            assert hashlib.sha256(source.read_bytes()).hexdigest() == before
        # The former exact-divisible scaled fast path remains byte-identical.
        even = root / 'even.jpg'
        jpeg_pattern(640, 960).save(even, quality=95, subsampling=2)
        sources.append(even)
        for denominator in (2, 4, 8):
            record, pixels = decode(library, even, root / f'even-d{denominator}.raw',
                                    640 // denominator, 960 // denominator, disk=1)
            assert record['status'] == 0, record
            if baseline:
                old_record, old_pixels = decode(
                    baseline, even, root / f'old-even-d{denominator}.raw',
                    640 // denominator, 960 // denominator, disk=1)
                assert old_record['status'] == 0 and np.array_equal(pixels, old_pixels)
            records.append(dict(case=f'even-d{denominator}',
                                previousCodecPixelDifference=0 if baseline else None,
                                **record))
        # Exact 1:1 ROIs retain their existing decoder and output bytes.
        for source in sources:
            record, pixels = decode(library, source, root / f'{source.stem}-roi.raw',
                                    123, 111, box=(17, 29, 123, 111), disk=1)
            assert record['status'] == 0, record
            if baseline:
                old_record, old_pixels = decode(
                    baseline, source, root / f'old-{source.stem}-roi.raw',
                    123, 111, box=(17, 29, 123, 111), disk=1)
                assert old_record['status'] == 0 and np.array_equal(pixels, old_pixels)
            records.append(dict(case=f'{source.stem}-exact-roi',
                                previousCodecPixelDifference=0 if baseline else None,
                                **record))
        # These sources deliberately require the original backing path.
        progressive = root / 'odd-progressive.jpg'
        source_image.save(progressive, quality=95, progressive=True)
        icc = root / 'odd-icc.jpg'
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        source_image.save(icc, quality=95, icc_profile=profile)
        rotated = root / 'odd-rotated.jpg'
        exif = Image.Exif()
        exif[274] = 6
        source_image.save(rotated, quality=95, exif=exif)
        extended = root / 'odd-extended-sof1.jpg'
        extended_bytes = bytearray(sources[0].read_bytes())
        marker = extended_bytes.find(b'\xff\xc0')
        assert marker >= 0
        extended_bytes[marker + 1] = 0xc1
        extended.write_bytes(extended_bytes)
        for source, dimensions in [(progressive, (643, 967)), (icc, (643, 967)),
                                   (rotated, (967, 643)), (extended, (643, 967))]:
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            for denominator in (2, 4, 8):
                ow, oh = ((dimensions[0] + denominator - 1) // denominator,
                          (dimensions[1] + denominator - 1) // denominator)
                backing = root / f'{source.stem}-d{denominator}.raw'
                record, _ = decode(library, source, backing, ow, oh)
                assert record['status'] == 0 and backing.exists(), record
                assert record['backend'] != 'libjpeg-turbo/budgeted-crop-skip'
                assert backing.stat().st_size == 128 + 643 * 967 * 4
                records.append(dict(case=f'{source.stem}-fallback-d{denominator}',
                                    sourceSha256=before, **record))
            assert hashlib.sha256(source.read_bytes()).hexdigest() == before
        # Ceil output for a partial crop is not the new whole-original path.
        record, _ = decode(library, sources[0], root / 'partial.raw', 81, 121,
                           box=(0, 0, 323, 483))
        assert record['status'] == 0 and (root / 'partial.raw').exists(), record
        records.append(dict(case='partial-ceil-requires-backing', **record))
        # New fast admission does not bypass the decoder's memory/cancel guards.
        for mode in ('memory', 'cancel'):
            token = library.pki_token_create() if mode == 'cancel' else None
            if token:
                library.pki_token_cancel(token)
            request = Request(0, 0, 643, 967, 81, 121,
                              1024 if mode == 'memory' else 192 << 20, 1, token)
            result, error = Result(), c.create_string_buffer(512)
            backing = root / f'guard-{mode}.raw'
            try:
                status = library.pki_decode_region(
                    str(sources[0]).encode(), str(backing).encode(),
                    c.byref(request), c.byref(result), error, 512)
                assert status == (3 if mode == 'memory' else 2)
                assert not result.pixels and result.length == 0
                assert not backing.exists()
                records.append(dict(case=f'ceil-{mode}-guard', status=status))
            finally:
                library.pki_release(c.byref(result))
                if token:
                    library.pki_token_destroy(token)
        if args.large:
            large = root / 'large-odd.jpg'
            jpeg_pattern(6001, 9001).save(large, quality=90, subsampling=2)
            before = hashlib.sha256(large.read_bytes()).hexdigest()
            record, _ = decode(library, large, root / 'large-odd.raw', 751, 1126,
                               disk=1)
            assert record['status'] == 0 and record['diskBytes'] == 0, record
            if baseline:
                old_record, _ = decode(baseline, large, root / 'old-large-odd.raw',
                                       751, 1126)
                assert old_record['status'] == 0 and (root / 'old-large-odd.raw').exists()
                record['previous'] = old_record
            assert hashlib.sha256(large.read_bytes()).hexdigest() == before
            records.append(dict(case='large-odd6001x9001-fit-d8', **record))
        assert not list(root.glob('*.partial'))
        assert not list(root.glob('*.coeff-*'))
    report = args.artifact_dir / 'jpeg-ceil-fit-verification1007.json'
    report.write_text(json.dumps(records, indent=2), encoding='utf-8')
    print(f'PASS {len(records)} JPEG ceil/old-fast/exact-ROI/fallback cases: {report}')


if __name__ == '__main__':
    main()
