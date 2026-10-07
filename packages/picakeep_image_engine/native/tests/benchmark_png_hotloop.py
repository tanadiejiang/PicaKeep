"""Isolated PNG hot-loop experiments. Never edits production or invokes Flutter.

prepare: generate frozen baseline / opaque-skip / opaque-RGB3 / row-skip copies and a
small Debug CMake project which reuses explicitly supplied built codec libs.
run: compare exact pixels, cancellation, budget failures and alternating N30
native-only measurements. Output/raw paths stay inside the experiment directory.
"""
import argparse
import ctypes as c
import difflib
import hashlib
import json
from pathlib import Path
import statistics
import threading
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


def prepare(args):
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    original = args.source.read_text(encoding='utf-8')
    assert sha(args.source) == '3f41c832b687f2b42c60b4c8d6450a22a24a0a18420e066cefea4a0de54dded1'
    skip = replace_once(original,
        'AreaRescaler(const pki_request &request, pki_result &result, Budget &budget)\n    : request(request), result(result), budget(budget), work(',
        'AreaRescaler(const pki_request &request, pki_result &result, Budget &budget, bool opaque = false)\n    : request(request), result(result), budget(budget), opaque(opaque), work(')
    skip = replace_once(skip, 'for (uint32_t x = 0; x < request.width; ++x) {\n      auto *p = pixels',
        'if (!opaque) for (uint32_t x = 0; x < request.width; ++x) {\n      auto *p = pixels')
    skip = replace_once(skip, 'throw Failure(1, "Incomplete area rescaler output");\n    for',
        'throw Failure(1, "Incomplete area rescaler output");\n    if (opaque) { budget.check(); return; }\n    for')
    skip = replace_once(skip, 'Budget &budget; Bytes work; WebPRescaler scaler{};',
        'Budget &budget; const bool opaque; Bytes work; WebPRescaler scaler{};')
    skip = replace_once(skip,
        'Bytes row(png_get_rowbytes(png, metadata)); AreaRescaler rescaler(request, result, budget);',
        'Bytes row(png_get_rowbytes(png, metadata));\n    AreaRescaler rescaler(request, result, budget, !(type & PNG_COLOR_MASK_ALPHA) && !transparency);')

    rgb3 = replace_once(original,
        'AreaRescaler(const pki_request &request, pki_result &result, Budget &budget)\n    : request(request), result(result), budget(budget), work(uint64_t(request.output_width) * 4 * 2 * sizeof(rescaler_t))',
        'AreaRescaler(const pki_request &request, pki_result &result, Budget &budget, int channels = 4)\n    : request(request), result(result), budget(budget), channels(channels), work(uint64_t(request.output_width) * channels * 2 * sizeof(rescaler_t))')
    rgb3 = replace_once(rgb3, 'int(result.stride), 4,\n      reinterpret_cast<rescaler_t *>(work.data)',
        'int(result.stride), channels,\n      reinterpret_cast<rescaler_t *>(work.data)')
    rgb3 = replace_once(rgb3, 'for (uint32_t x = 0; x < request.width; ++x) {\n      auto *p = pixels',
        'if (channels == 4) for (uint32_t x = 0; x < request.width; ++x) {\n      auto *p = pixels')
    rgb3 = replace_once(rgb3, 'WebPRescalerImport(&scaler, 1, pixels, int(request.width * 4))',
        'WebPRescalerImport(&scaler, 1, pixels, int(request.width * channels))')
    rgb3 = replace_once(rgb3, 'throw Failure(1, "Incomplete area rescaler output");\n    for',
        '''throw Failure(1, "Incomplete area rescaler output");
    if (channels == 3) {
      for (uint32_t y = 0; y < result.height; ++y) {
        budget.check(); auto *row = result.pixels + uint64_t(y) * result.stride;
        // The scaler writes packed RGB at each RGBA row's start. Expand from
        // right to left so writes never overwrite unread source components.
        for (uint32_t x = result.width; x-- > 0;) {
          const uint8_t r = row[uint64_t(x) * 3];
          const uint8_t g = row[uint64_t(x) * 3 + 1];
          const uint8_t b = row[uint64_t(x) * 3 + 2];
          auto *p = row + uint64_t(x) * 4;
          p[0] = r; p[1] = g; p[2] = b; p[3] = 255;
        }
      }
      return;
    }
    for''')
    rgb3 = replace_once(rgb3, 'Budget &budget; Bytes work; WebPRescaler scaler{};',
        'Budget &budget; const int channels; Bytes work; WebPRescaler scaler{};')
    rgb3 = replace_once(rgb3,
        'if (!(type & PNG_COLOR_MASK_ALPHA) && !transparency) png_set_add_alpha(png, 255, PNG_FILLER_AFTER);',
        'const bool opaque = !(type & PNG_COLOR_MASK_ALPHA) && !transparency;')
    rgb3 = replace_once(rgb3,
        'Bytes row(png_get_rowbytes(png, metadata)); AreaRescaler rescaler(request, result, budget);',
        '''const int channels = opaque ? 3 : 4;
    if (png_get_channels(png, metadata) != channels ||
        png_get_rowbytes(png, metadata) != uint64_t(request.width) * channels)
      throw Failure(1, "Unexpected PNG row layout for area fit");
    Bytes row(png_get_rowbytes(png, metadata));
    AreaRescaler rescaler(request, result, budget, channels);''')

    row_skip = replace_once(skip,
        '    if (opaque) { budget.check(); return; }\n', '')
    sources = {'baseline': original, 'opaque_skip': skip, 'opaque_rgb3': rgb3,
        'opaque_row_skip': row_skip}
    for name, source in sources.items():
        (root / (name + '.cpp')).write_text(source, encoding='utf-8', newline='\n')
        if name != 'baseline':
            patch = ''.join(difflib.unified_diff(original.splitlines(True), source.splitlines(True),
                fromfile='a/packages/picakeep_image_engine/native/src/image_core.cpp',
                tofile='b/packages/picakeep_image_engine/native/src/image_core.cpp'))
            (root / (name + '.patch')).write_text(patch, encoding='utf-8', newline='\n')
    deps = args.dependencies.resolve().as_posix()
    include = (args.native_include or args.source.resolve().parents[1].joinpath('include')).resolve().as_posix()
    includes = [include] + [deps + '/_deps/' + p for p in
        ['jpeg-src/src', 'jpeg-build', 'webp-src', 'webp-src/src', 'png-src', 'png-build', 'zlib-build', 'zlib-src', 'lcms-src/include']]
    libs = [deps + '/' + p for p in ['_deps/jpeg-build/Debug/jpeg-static.lib',
        '_deps/png-build/Debug/libpng16_staticd.lib', '_deps/zlib-build/Debug/zlibstaticd.lib',
        '_deps/webp-build/Debug/libwebp.lib', '_deps/webp-build/Debug/libwebpdemux.lib',
        'Debug/pki_lcms.lib', '_deps/webp-build/Debug/libsharpyuv.lib']]
    for library in libs:
        assert Path(library).is_file(), library
    cmake = '''cmake_minimum_required(VERSION 3.22)
project(pki_png_hotloop_experiment LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
if(NOT MSVC)
  message(FATAL_ERROR "This isolated project requires the explicitly supplied Windows Debug codec libs")
endif()
string(REGEX REPLACE "/RTC[^ ]*|/Od|/Ob0" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
'''
    for name in sources:
        cmake += f'add_library({name} SHARED {name}.cpp)\n'
        cmake += f'target_include_directories({name} PRIVATE ' + ' '.join('"' + p + '"' for p in includes) + ')\n'
        cmake += f'target_link_libraries({name} PRIVATE ' + ' '.join('"' + p + '"' for p in libs) + ' shlwapi ole32 windowscodecs)\n'
        cmake += f'target_compile_definitions({name} PRIVATE PKI_EXPORTS NOMINMAX _CRT_SECURE_NO_WARNINGS)\n'
        cmake += f'target_compile_options({name} PRIVATE /O2 /EHs /W4)\n'
    (root / 'CMakeLists.txt').write_text(cmake, encoding='utf-8')
    record = dict(productionSource=str(args.source.resolve()), productionSha256=sha(args.source),
        sources={name: sha(root / (name + '.cpp')) for name in sources},
        dependencies={p: sha(Path(p)) for p in libs})
    (root / 'prepare.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(json.dumps(record, indent=2))


class Request(c.Structure):
    _fields_ = [(k, c.c_uint32) for k in ['x', 'y', 'width', 'height', 'ow', 'oh']] + [('memory', c.c_uint64), ('disk', c.c_uint64), ('token', c.c_void_p)]


class Result(c.Structure):
    _fields_ = [('pixels', c.POINTER(c.c_uint8)), ('length', c.c_uint64)] + [(k, c.c_uint32) for k in ['width', 'height', 'stride']] + [(k, c.c_uint64) for k in ['peak', 'disk', 'micros']] + [('backend', c.c_char_p)]


def load(dll):
    library = c.CDLL(str(dll))
    library.pki_decode_region.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(Request), c.POINTER(Result), c.c_char_p, c.c_uint64]
    library.pki_release.argtypes = [c.POINTER(Result)]
    library.pki_token_create.restype = c.c_void_p
    library.pki_token_cancel.argtypes = [c.c_void_p]
    library.pki_token_destroy.argtypes = [c.c_void_p]
    return library


def decode(library, source, backing, size, output, memory=64 << 20, token=None):
    assert not backing.exists()
    request = Request(0, 0, *size, *output, memory, 128 << 20, token)
    result = Result()
    error = c.create_string_buffer(512)
    start = time.perf_counter_ns()
    status = library.pki_decode_region(str(source).encode(), str(backing).encode(), c.byref(request), c.byref(result), error, 512)
    wall = (time.perf_counter_ns() - start) / 1e6
    try:
        pixels = c.string_at(result.pixels, result.length) if result.pixels else b''
        record = dict(status=status, error=error.value.decode(), nativeMs=result.micros / 1000,
            wallMs=wall, peakBytes=result.peak, diskBytes=result.disk,
            backend=result.backend.decode() if result.backend else None,
            outputSha256=hashlib.sha256(pixels).hexdigest(), length=len(pixels), nullOutput=not bool(result.pixels))
        return pixels, record
    finally:
        library.pki_release(c.byref(result))


def run(args):
    import numpy as np
    from PIL import Image
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    libraries = {name: load(args.build / 'Debug' / (name + '.dll')) for name in
        ['baseline', 'opaque_skip', 'opaque_rgb3', 'opaque_row_skip']}
    rng = np.random.default_rng(22022)
    records = []
    backing = root / 'picakeep-png-hotloop-test.raw'
    assert not backing.exists()
    cases = []
    for number, (w, h, ow, oh) in enumerate([(19, 17, 7, 6), (97, 163, 33, 55), (640, 960, 231, 317)]):
        rgb = rng.integers(0, 256, (h, w, 3), dtype=np.uint8)
        gray = rng.integers(0, 256, (h, w), dtype=np.uint8)
        rgba = np.concatenate([rgb, rng.choice(np.array([0, 1, 64, 128, 254, 255], dtype=np.uint8), (h, w, 1))], axis=2)
        variants = [('rgb', Image.fromarray(rgb)), ('gray', Image.fromarray(gray)), ('gray1', Image.fromarray(gray > 127)),
            ('alpha', Image.fromarray(rgba)), ('opaque-rgba', Image.fromarray(np.concatenate([rgb, np.full((h, w, 1), 255, np.uint8)], axis=2))),
            ('palette', Image.fromarray(rgb).quantize(colors=64)), ('palette1', Image.fromarray(rgb).quantize(colors=2)),
            ('palette2', Image.fromarray(rgb).quantize(colors=4)), ('palette4', Image.fromarray(rgb).quantize(colors=16)),
            ('palette-trns', Image.fromarray(rgb).quantize(colors=64)), ('gray-trns', Image.fromarray(gray))]
        for label, image in variants:
            path = root / f'case-{number}-{label}.png'
            options = {'transparency': bytes(range(64))} if label == 'palette-trns' else {'transparency': 127} if label == 'gray-trns' else {'bits': int(label[7:])} if label in ['palette1', 'palette2', 'palette4'] else {}
            image.save(path, **options)
            cases.append((label, path, (w, h), (ow, oh)))
    # Exercise tiny/noninteger outputs and near-identity expansion boundaries.
    for number in range(32):
        w, h = map(int, rng.integers(3, 130, 2))
        ow, oh = int(rng.integers(2, w)), int(rng.integers(2, h))
        path = root / f'random-rgb-{number}.png'
        Image.fromarray(rng.integers(0, 256, (h, w, 3), dtype=np.uint8)).save(path)
        cases.append(('random-rgb', path, (w, h), (ow, oh)))
    for label, path, size, output in cases:
        expected = None
        result = {}
        for name, library in libraries.items():
            pixels, record = decode(library, path, backing, size, output)
            assert record['status'] == 0, (label, name, record)
            assert record['diskBytes'] == 0 and not backing.exists()
            if expected is None:
                expected = pixels
            else:
                assert pixels == expected, (label, name, size, output)
            result[name] = record
        records.append(dict(case=path.name, sourceSha256=sha(path), size=size, output=output, measurements=result, exact=True))
    for label in ['rgb', 'alpha']:
        path = root / f'case-0-{label}.png'
        image = Image.open(path).convert('RGBA')
        result = {}
        for name, library in libraries.items():
            pixels, record = decode(library, path, backing, image.size, image.size)
            assert record['status'] == 0 and pixels == image.tobytes(), (label, name, record)
            assert backing.is_file()
            backing.unlink()
            result[name] = record
        records.append(dict(case=path.name + '-original-1to1', sourceSha256=sha(path), size=image.size,
            output=image.size, measurements=result, exact=True, originalPixelsExact=True))
    # All paths outside quick PNG keep their byte-exact baseline behavior.
    for filename in ['640x960-alpha.png', '640x960-16bit.png', '640x960-p3-icc.png', '640x960-16bit-interlaced-icc.png']:
        path = args.fixtures / filename
        size = Image.open(path).size
        expected = None
        result = {}
        for name, library in libraries.items():
            pixels, record = decode(library, path, backing, size, (213, 319))
            assert record['status'] == 0, (filename, name, record)
            expected = pixels if expected is None else expected
            assert pixels == expected
            if backing.exists():
                backing.unlink()
            result[name] = record
        records.append(dict(case=filename, sourceSha256=sha(path), size=size, output=[213, 319], measurements=result, exact=True))
    extremes = []
    for w, h, ow, oh in [(4000, 6000, 2, 2), (4097, 4099, 2, 2), (4000, 6000, 3, 3),
        (4000, 6000, 384, 384), (8192, 8192, 2, 3), (640, 60000, 2, 2), (60000, 640, 2, 2)]:
        path = root / f'uniform-{w}x{h}.png'
        if not path.exists():
            Image.new('RGB', (w, h), (255, 191, 87)).save(path)
        result = {}
        expected = None
        for name, library in libraries.items():
            pixels, record = decode(library, path, backing, (w, h), (ow, oh))
            assert record['status'] == 0 and record['diskBytes'] == 0
            expected = pixels if expected is None else expected
            record['exactBaseline'] = pixels == expected
            record['firstPixel'] = list(pixels[:4])
            if name == 'opaque_row_skip':
                assert pixels == expected, (path.name, [ow, oh], record)
            result[name] = record
        extremes.append(dict(case=path.name, sourceSha256=sha(path), size=[w, h], output=[ow, oh], measurements=result))
    cover_size = Image.open(args.cover).size
    measurements = {name: [] for name in libraries}
    hashes = set()
    for sample in range(args.samples + args.warmup):
        # Rotate order so startup, filesystem cache and concurrent desktop load
        # do not systematically favor one candidate.
        names = list(libraries)
        names = names[sample % len(names):] + names[:sample % len(names)]
        for name in names:
            pixels, record = decode(libraries[name], args.cover, backing, cover_size, (384, 384))
            assert record['status'] == 0 and record['diskBytes'] == 0 and not backing.exists(), record
            hashes.add(record['outputSha256'])
            if sample >= args.warmup:
                measurements[name].append(record)
    assert len(hashes) == 1, hashes
    failures = {}
    for name, library in libraries.items():
        _, small = decode(library, args.cover, backing, cover_size, (384, 384), memory=1024)
        assert small['status'] == 3 and small['nullOutput']
        token = library.pki_token_create()
        assert token
        library.pki_token_cancel(token)
        _, early = decode(library, args.cover, backing, cover_size, (384, 384), token=token)
        library.pki_token_destroy(token)
        assert early['status'] == 2 and early['nullOutput']
        token = library.pki_token_create()
        finished = threading.Event()
        timer = threading.Thread(target=lambda: (finished.wait(.010) or library.pki_token_cancel(token)))
        timer.start()
        try:
            _, live = decode(library, args.cover, backing, cover_size, (384, 384), token=token)
        finally:
            finished.set(); timer.join(); library.pki_token_destroy(token)
        assert live['status'] == 2 and live['nullOutput'], live
        _, recovered = decode(library, args.cover, backing, cover_size, (384, 384))
        assert recovered['status'] == 0 and recovered['outputSha256'] in hashes
        failures[name] = dict(memory1024=small, cancelledBefore=early, cancelledDuring=live, recovered=recovered)
    def p95(values):
        return sorted(values)[int(np.ceil(.95 * len(values))) - 1]
    stats = {name: dict(nativeP50Ms=statistics.median(s['nativeMs'] for s in runs),
        nativeP95Ms=p95([s['nativeMs'] for s in runs]), wallP50Ms=statistics.median(s['wallMs'] for s in runs),
        wallP95Ms=p95([s['wallMs'] for s in runs]), peakBytes=max(s['peakBytes'] for s in runs)) for name, runs in measurements.items()}
    report = dict(scope='Windows native-only optimized Debug; native cold backing absent; OS/encoded file cache uncontrolled; no Flutter/GPU/device claim',
        prepare=json.loads((root / 'prepare.json').read_text(encoding='utf-8')),
        dllSha256={name: sha(args.build / 'Debug' / (name + '.dll')) for name in libraries},
        coverSource=str(args.cover.resolve()), coverSha256=sha(args.cover), sourceSize=cover_size,
        outputSize=[384, 384], samples=args.samples, warmup=args.warmup,
        statistics=stats, measurements=measurements, pixelCases=records, extremeCases=extremes, failures=failures,
        coverOutputExactAcrossCandidates=True, acceptedCandidate='opaque_row_skip',
        acceptedCandidateExactBaseline=True, rejectedCandidates=['opaque_skip', 'opaque_rgb3'],
        rejectionReason='4000x6000 to 2x2 fixed-point alpha becomes 254; skipping final unpremultiply or filling 255 changes output',
        rawOrPartialRemaining=[str(p) for p in root.glob('*.raw*')])
    assert not report['rawOrPartialRemaining']
    (root / 'png-hotloop-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(dict(statistics=stats, pixelCases=len(records), extremeCases=len(extremes), failuresPassed=list(failures), acceptedCandidateExact=True), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--source', type=Path, required=True)
    prep.add_argument('--dependencies', type=Path, required=True)
    prep.add_argument('--native-include', type=Path)
    prep.add_argument('--output', type=Path, required=True)
    bench = sub.add_parser('run')
    bench.add_argument('--build', type=Path, required=True)
    bench.add_argument('--cover', type=Path, required=True)
    bench.add_argument('--fixtures', type=Path, required=True)
    bench.add_argument('--output', type=Path, required=True)
    bench.add_argument('--samples', type=int, default=30)
    bench.add_argument('--warmup', type=int, default=3)
    arguments = parser.parse_args()
    prepare(arguments) if arguments.mode == 'prepare' else run(arguments)
