"""Measure 512px original ROIs using one/two native callers on a stable layer.

Native/CPU-only evidence. This deliberately does not claim Flutter presentation.
An optional baseline report enforces identical per-region original pixel hashes.
"""
import argparse
import ctypes as c
import hashlib
import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


class Metadata(c.Structure):
    _fields_ = [(key, c.c_uint32) for key in
                ['width', 'height', 'ew', 'eh', 'format', 'orientation',
                 'animated', 'depth', 'profile']] + [('estimate', c.c_uint64)]


class Request(c.Structure):
    _fields_ = [(key, c.c_uint32) for key in
                ['x', 'y', 'width', 'height', 'ow', 'oh']] + [
                ('memory', c.c_uint64), ('disk', c.c_uint64), ('token', c.c_void_p)]


class Result(c.Structure):
    _fields_ = [('pixels', c.POINTER(c.c_uint8)), ('length', c.c_uint64)] + [
        (key, c.c_uint32) for key in ['width', 'height', 'stride']] + [
        (key, c.c_uint64) for key in ['peak', 'disk', 'micros']] + [
        ('backend', c.c_char_p)]


def file_hash(path):
    value = hashlib.sha256()
    with open(path, 'rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def distribution(values):
    ordered = sorted(values)
    return {'count': len(values), 'p50Ms': ordered[len(ordered) // 2] / 1000,
            'p95Ms': ordered[min(len(ordered) - 1, int(len(ordered) * .95))] / 1000}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--artifact-dir', required=True, type=Path)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--reference-report', type=Path)
    args = parser.parse_args()
    if not args.artifact_dir.is_absolute() or 'picakeep' not in str(args.artifact_dir):
        raise ValueError('Use an absolute, task-owned picakeep artifact directory')
    if args.samples < 30:
        raise ValueError('At least 30 measured rounds required')
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    backing = args.artifact_dir / 'stable.raw'
    library = c.CDLL(str(args.library))
    library.pki_probe.argtypes = [c.c_char_p, c.POINTER(Metadata), c.c_char_p, c.c_uint64]
    library.pki_decode_region.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(Request),
                                        c.POINTER(Result), c.c_char_p, c.c_uint64]
    library.pki_release.argtypes = [c.POINTER(Result)]
    error = c.create_string_buffer(512)
    metadata = Metadata()
    fixture_bytes = str(args.fixture).encode('utf8')
    assert library.pki_probe(fixture_bytes, c.byref(metadata), error, 512) == 0, error.value
    assert metadata.width >= 2560 and metadata.height >= 4608 and metadata.orientation == 1
    source_before = file_hash(args.fixture)

    def decode(box, prepare=False):
        x, y, width, height = box
        request = Request(x, y, width, height, 1 if prepare else width,
                          1 if prepare else height, 96 << 20, 512 << 20, None)
        result = Result()
        local_error = c.create_string_buffer(512)
        status = library.pki_decode_region(fixture_bytes, str(backing).encode('utf8'),
                                          c.byref(request), c.byref(result), local_error, 512)
        try:
            assert status == 0, (status, local_error.value)
            assert result.width == request.ow and result.height == request.oh
            assert result.stride == request.ow * 4 and result.length == request.ow * request.oh * 4
            data = c.string_at(result.pixels, result.length)
            return {'box': list(box), 'sha256': hashlib.sha256(data).hexdigest(),
                    'nativeUs': result.micros, 'workingPeakBytes': result.peak,
                    'diskBytes': result.disk}
        finally:
            library.pki_release(c.byref(result))

    decode((0, 0, metadata.width, metadata.height), prepare=True)
    coordinates = [(1024 + x * 512, 3072 + y * 512, 512, 512)
                   for y in range(3) for x in range(3)]
    # Read original RGBA rows independently from the completed exact disk layer.
    golden = []
    with backing.open('rb') as raw:
        for x, y, width, height in coordinates:
            value = hashlib.sha256()
            for row in range(height):
                raw.seek(128 + ((y + row) * metadata.ew + x) * 4)
                value.update(raw.read(width * 4))
            golden.append(value.hexdigest())
    if args.reference_report:
        baseline = json.loads(args.reference_report.read_text(encoding='utf-8-sig'))
        assert golden == baseline['regionHashes'], 'Candidate backing altered original pixels'
    groups = []
    for workers in [1, 2]:
        durations, native, peaks, rounds = [], [], [], []
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for index in range(args.samples + 1):
                start = time.perf_counter_ns()
                decoded = list(pool.map(decode, coordinates))
                wall_us = (time.perf_counter_ns() - start) // 1000
                assert [item['sha256'] for item in decoded] == golden
                if index:
                    durations.append(wall_us)
                    native.extend(item['nativeUs'] for item in decoded)
                    peaks.extend(item['workingPeakBytes'] for item in decoded)
                    rounds.append({'index': index - 1, 'wallUs': wall_us,
                                   'nativeUs': [item['nativeUs'] for item in decoded]})
        groups.append({'workers': workers, 'warmupRounds': 1,
                       'ROIsPerRound': len(coordinates), 'wall': distribution(durations),
                       'nativePerROI': distribution(native),
                       'maximumPerCallWorkingBytes': max(peaks), 'rounds': rounds})
    assert file_hash(args.fixture) == source_before, 'Source changed during benchmark'
    assert not list(args.artifact_dir.glob('*.partial'))
    assert not list(args.artifact_dir.glob('*.coeff-*'))
    report = {'status': 'passed', 'scope': 'Native only; no UI/engine/GPU/presentation',
              'library': str(args.library), 'librarySha256': file_hash(args.library),
              'fixture': str(args.fixture), 'fixtureSha256': source_before,
              'dimensions': [metadata.width, metadata.height], 'tileSize': 512,
              'coordinates': coordinates, 'regionHashes': golden,
              'sameCodecOriginalPixelDifference': 0, 'groups': groups}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ['regionHashes', 'coordinates', 'groups']}))
    for group in groups:
        print(json.dumps({key: value for key, value in group.items() if key != 'rounds'}))


if __name__ == '__main__':
    main()
