"""Verify stable-layer sharing, cold publication, cancellation and replacement.

Runs only task-owned synthetic files. A concurrent caller waits behind an actual
large PNG build; it is cancelled cooperatively, never by stopping active FFI.
"""
import argparse
import ctypes as c
import hashlib
import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

from benchmark_shared_backing import Metadata, Request, Result, file_hash


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--artifact-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not args.artifact_dir.is_absolute() or 'picakeep' not in str(args.artifact_dir):
        raise ValueError('An absolute task-owned picakeep artifact directory is required')
    args.artifact_dir.mkdir(parents=True, exist_ok=True)
    library = c.CDLL(str(args.library))
    library.pki_probe.argtypes = [c.c_char_p, c.POINTER(Metadata), c.c_char_p, c.c_uint64]
    library.pki_decode_region.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(Request),
                                        c.POINTER(Result), c.c_char_p, c.c_uint64]
    library.pki_release.argtypes = [c.POINTER(Result)]
    library.pki_token_create.restype = c.c_void_p
    library.pki_token_cancel.argtypes = [c.c_void_p]
    library.pki_token_destroy.argtypes = [c.c_void_p]
    metadata, error = Metadata(), c.create_string_buffer(512)
    source = str(args.fixture).encode('utf8')
    assert library.pki_probe(source, c.byref(metadata), error, 512) == 0, error.value
    source_before = file_hash(args.fixture)

    def decode(backing, token=None, memory=96 << 20, disk=512 << 20):
        req = Request(1024, 3072, 512, 512, 512, 512, memory, disk, token)
        result, error = Result(), c.create_string_buffer(512)
        status = library.pki_decode_region(source, str(backing).encode('utf8'),
                                          c.byref(req), c.byref(result), error, 512)
        try:
            if status:
                assert not result.pixels and result.length == 0
                return {'status': status, 'message': error.value.decode('utf8')}
            assert result.width == 512 and result.height == 512 and result.stride == 2048
            data = c.string_at(result.pixels, result.length)
            return {'status': 0, 'sha256': hashlib.sha256(data).hexdigest(),
                    'nativeUs': result.micros, 'peakBytes': result.peak}
        finally:
            library.pki_release(c.byref(result))

    records = []
    backing = args.artifact_dir / 'cold-shared.raw'
    # A dedicated fresh pathname rather than deleting a pre-existing layer.
    backing = backing.with_name(f'cold-shared-{time.time_ns()}.raw')
    gate = Barrier(4)

    def concurrent(_):
        gate.wait(timeout=5)
        return decode(backing)

    with ThreadPoolExecutor(max_workers=4) as pool:
        cold = list(pool.map(concurrent, range(4)))
    assert all(item['status'] == 0 for item in cold), cold
    golden = cold[0]['sha256']
    assert all(item['sha256'] == golden for item in cold)
    assert backing.stat().st_size == 128 + metadata.ew * metadata.eh * 4
    records.append({'case': 'fourCallerColdPublication', 'callers': cold,
                    'originalPixelDifference': 0, 'finalBackingBytes': backing.stat().st_size})
    with ThreadPoolExecutor(max_workers=2) as pool:
        warm = list(pool.map(lambda _: decode(backing), range(60)))
    assert all(item['status'] == 0 and item['sha256'] == golden for item in warm)
    records.append({'case': 'twoCallerWarmSixty', 'samples': 60,
                    'originalPixelDifference': 0, 'maximumPerCallPeak':
                    max(item['peakBytes'] for item in warm)})
    denied = decode(backing, memory=1024)
    assert denied['status'] == 3
    denied_disk = decode(backing, disk=1)
    assert denied_disk['status'] == 3
    records.append({'case': 'sharedReadBudgetRefusal', 'memory': denied, 'disk': denied_disk})
    # Controlled corruption of a task-owned layer must be replaced under the
    # writer guard. New cold callers can never return pixels from that layer.
    with backing.open('r+b') as existing:
        existing.write(b'BADHDR!!')
    gate = Barrier(4)
    with ThreadPoolExecutor(max_workers=4) as pool:
        replaced = list(pool.map(concurrent, range(4)))
    assert all(item['status'] == 0 and item['sha256'] == golden for item in replaced)
    records.append({'case': 'invalidHeaderRebuiltUnderExclusiveGuard', 'callers': 4,
                    'originalPixelDifference': 0})
    waiting = args.artifact_dir / f'writer-wait-cancel-{time.time_ns()}.raw'
    token = library.pki_token_create()
    assert token
    with ThreadPoolExecutor(max_workers=2) as pool:
        writer = pool.submit(decode, waiting)
        deadline = time.monotonic() + 5
        partial = Path(str(waiting) + '.partial')
        while not partial.exists() and not writer.done() and time.monotonic() < deadline:
            time.sleep(.001)
        assert partial.exists() and not writer.done(), 'Did not observe active cold build'
        cancelled = pool.submit(decode, waiting, token)
        # A brief bounded delay allows the second caller to reach lock wait.
        time.sleep(.01)
        assert not writer.done(), 'Cold writer finished before cancellation contention'
        started = time.perf_counter_ns()
        library.pki_token_cancel(token)
        cancelled_result = cancelled.result(timeout=2)
        cancellation_ms = (time.perf_counter_ns() - started) / 1e6
        assert cancelled_result['status'] == 2
        writer_result = writer.result(timeout=10)
        assert writer_result['status'] == 0 and writer_result['sha256'] == golden
        library.pki_token_destroy(token)
    records.append({'case': 'cancelBehindExclusiveColdBuild', 'cancelled': cancelled_result,
                    'cancelCompletionMs': cancellation_ms, 'writerOriginalPixelsExact': True,
                    'activeFFIWasKilled': False})
    assert file_hash(args.fixture) == source_before
    assert not list(args.artifact_dir.glob('*.partial'))
    assert not list(args.artifact_dir.glob('*.coeff-*'))
    report = {'status': 'passed', 'scope': 'Windows native debug; product source/budget '
              'lease admission and Android Flutter presentation not measured',
              'library': str(args.library), 'librarySha256': file_hash(args.library),
              'fixture': str(args.fixture), 'fixtureSha256': source_before,
              'cases': records, 'partialAndCoefficientResidue': 0}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
