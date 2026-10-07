"""Validate the additive prepared-only entry without application/device state."""
import argparse
import ctypes as c
import hashlib
import json
import os
import shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory

from benchmark_shared_backing import Metadata, Request, Result, file_hash


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--artifact-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not args.artifact_dir.is_absolute() or 'picakeep' not in str(args.artifact_dir):
        raise ValueError('An absolute task-owned picakeep artifact directory is required')
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    lib = c.CDLL(str(args.library))
    for name in ['pki_decode_region', 'pki_decode_prepared_region']:
        getattr(lib, name).argtypes = [c.c_char_p, c.c_char_p, c.POINTER(Request),
                                     c.POINTER(Result), c.c_char_p, c.c_uint64]
    lib.pki_probe.argtypes = [c.c_char_p, c.POINTER(Metadata), c.c_char_p, c.c_uint64]
    lib.pki_release.argtypes = [c.POINTER(Result)]
    lib.pki_token_create.restype = c.c_void_p
    lib.pki_token_cancel.argtypes = [c.c_void_p]
    lib.pki_token_destroy.argtypes = [c.c_void_p]

    def decode(source, backing, prepared=True, memory=96 << 20, token=None,
               box=(31, 73, 129, 137), output=None):
        x, y, w, h = box
        ow, oh = output or (w, h)
        req = Request(x, y, w, h, ow, oh, memory, 0 if prepared else 256 << 20, token)
        result, error = Result(), c.create_string_buffer(512)
        entry = lib.pki_decode_prepared_region if prepared else lib.pki_decode_region
        status = entry(str(source).encode('utf8'), str(backing).encode('utf8'),
                       c.byref(req), c.byref(result), error, 512)
        try:
            if status:
                assert not result.pixels and result.length == 0
                return {'status': status, 'error': error.value.decode('utf8')}
            assert (result.width, result.height) == (ow, oh)
            return {'status': 0, 'sha256': hashlib.sha256(c.string_at(
                result.pixels, result.length)).hexdigest(), 'diskBytes': result.disk,
                'peakBytes': result.peak, 'nativeUs': result.micros}
        finally:
            lib.pki_release(c.byref(result))

    records = []
    print('PREPARED_READ begin exact-pixel and lifecycle checks', flush=True)
    with TemporaryDirectory(prefix='picakeep-prepared-only-', dir=args.artifact_dir) as owned:
        work = Path(owned)
        for source in sorted(args.fixtures.glob('640x960*')):
            if source.suffix not in ['.png', '.jpg', '.webp']:
                continue
            before = file_hash(source), source.stat().st_mtime_ns
            backing = work / (source.name + '.raw')
            meta, error = Metadata(), c.create_string_buffer(512)
            assert lib.pki_probe(str(source).encode('utf8'), c.byref(meta), error, 512) == 0
            # Product=1 disables the quick-fit path and publishes a complete layer.
            prepared = decode(source, backing, prepared=False,
                              box=(0, 0, meta.width, meta.height), output=(1, 1))
            assert prepared['status'] == 0, prepared
            reference = decode(source, backing, prepared=False)
            backing_before = file_hash(backing), backing.stat().st_mtime_ns
            actual = decode(source, backing)
            assert actual['status'] == 0 and actual['sha256'] == reference['sha256']
            assert actual['diskBytes'] == backing.stat().st_size
            assert (file_hash(backing), backing.stat().st_mtime_ns) == backing_before
            assert (file_hash(source), source.stat().st_mtime_ns) == before
            records.append({'case': source.name, 'pixelsExact': True,
                            'sourceUnchanged': True, 'backingUnchanged': True,
                            'readDiskBudgetBytes': 0, **actual})

        source = args.fixtures / '640x960.png'
        backing = work / '640x960.png.raw'
        nested = work / 'missing-parent' / 'missing.raw'
        miss = decode(source, nested)
        assert miss['status'] == 5 and not nested.parent.exists()
        corrupt = work / 'corrupt.raw'
        shutil.copy2(backing, corrupt)
        with corrupt.open('r+b') as output:
            output.write(b'BADRAW!!')
        bad_before = file_hash(corrupt), corrupt.stat().st_mtime_ns
        bad = decode(source, corrupt)
        assert bad['status'] == 5
        assert (file_hash(corrupt), corrupt.stat().st_mtime_ns) == bad_before
        truncated = work / 'truncated.raw'
        truncated.write_bytes(b'PKIRAW3')
        assert decode(source, truncated)['status'] == 5
        stale = work / 'stale-source.png'
        shutil.copy2(source, stale)
        shutil.copy2(backing, work / 'stale.raw')
        os.utime(stale, ns=(stale.stat().st_atime_ns, stale.stat().st_mtime_ns + 2_000_000_000))
        assert decode(stale, work / 'stale.raw')['status'] == 5
        for budget in [0, 1, 1024]:
            assert decode(source, backing, memory=budget)['status'] == 3
        assert decode(source, backing, box=(639, 959, 2, 2))['status'] == 1
        token = lib.pki_token_create()
        assert token
        try:
            lib.pki_token_cancel(token)
            assert decode(source, backing, token=token)['status'] == 2
        finally:
            lib.pki_token_destroy(token)
        golden = decode(source, backing)['sha256']
        with ThreadPoolExecutor(max_workers=2) as pool:
            parallel = list(pool.map(lambda _: decode(source, backing), range(30)))
        assert all(item['status'] == 0 and item['sha256'] == golden for item in parallel)
        assert not list(work.rglob('*.partial')) and not list(work.rglob('*.coeff-*'))
        records.append({'case': 'miss-corrupt-truncated-stale-budget-cancel-concurrent',
                        'missingStatus': miss['status'], 'corruptStatus': bad['status'],
                        'missingParentNotCreated': True, 'partialResidue': 0,
                        'concurrentExactSamples': len(parallel)})
    report = {'status': 'passed', 'scope': 'standalone Windows native debug; '
              'Flutter/device performance is not measured', 'librarySha256': file_hash(args.library),
              'cases': records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
