"""Read-only, bounded OS memory sampling for an explicitly identified process.

Android uses run-as with an explicit adb device and PID. Windows uses native
process memory counters. Neither route installs, starts, stops or changes data.
"""
import argparse
import ctypes as c
from ctypes import wintypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def safe_output(task_root, output):
    if not task_root.is_absolute() or not output.is_absolute():
        raise ValueError('--task-root and --output must be absolute paths')
    if 'picakeep' not in str(task_root).lower():
        raise ValueError('Use an explicitly named picakeep task artifact root')
    root = task_root.resolve()
    candidate = output.resolve()
    candidate.relative_to(root)
    for parent in [output, *output.parents]:
        if parent.exists():
            attributes = getattr(parent.lstat(), 'st_file_attributes', 0)
            if parent.is_symlink() or attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError(f'Output ancestors cannot be links/reparse points: {parent}')
        if parent == task_root:
            break
    if candidate.exists():
        raise FileExistsError(f'Preserve prior evidence; choose a new output: {candidate}')
    candidate.parent.mkdir(parents=True, exist_ok=True)
    return candidate


def parse_proc_stat(line, expected_pid):
    match = re.fullmatch(r'(\d+) \((.*)\) (.+)', line)
    if not match or int(match[1]) != expected_pid:
        raise ValueError('Missing or unexpected process stat identity')
    fields = match[3].split()
    return {'pid': int(match[1]), 'comm': match[2], 'state': fields[0],
            'startTimeTicks': int(fields[19])}


def parse_memory_lines(lines):
    values, raw = {}, []
    for line in lines:
        match = re.fullmatch(r'([A-Za-z_]+):\s+(\d+) kB', line)
        if match:
            # Linux /proc's historical kB label means 1024 bytes.
            values[match[1] + 'Bytes'] = int(match[2]) * 1024
            raw.append(line)
    return values, raw


class AndroidSampler:
    def __init__(self, args):
        if not args.device or not re.fullmatch(r'[A-Za-z0-9._:\-]+', args.device):
            raise ValueError('Android requires a specific valid --device ID')
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+', args.package):
            raise ValueError('Invalid Android package name')
        adb = args.adb or shutil.which('adb')
        if not adb:
            raise FileNotFoundError('adb is unavailable; pass --adb with its executable')
        pid = args.pid
        # cat accepts all four files in one read-only invocation. Two stat
        # identities bracket memory reads to detect an exit or reused PID.
        self.command = [str(adb), '-s', args.device, 'shell', 'run-as', args.package,
                        'cat', f'/proc/{pid}/stat', f'/proc/{pid}/status',
                        f'/proc/{pid}/smaps_rollup', f'/proc/{pid}/stat']
        self.pid = pid
        self.identity = None

    def read(self):
        completed = subprocess.run(self.command, capture_output=True, text=True,
                                   timeout=8, encoding='utf8', errors='replace')
        lines = completed.stdout.splitlines()
        identities = [parse_proc_stat(line, self.pid) for line in lines
                      if re.match(r'^\d+ \(', line)]
        if len(identities) != 2:
            raise RuntimeError('Cannot bracket Android PID identity: '
                               + completed.stderr.strip()[:2048])
        before, after = identities
        if before['startTimeTicks'] != after['startTimeTicks']:
            raise RuntimeError('PID was reused during memory reads')
        if self.identity is not None and self.identity != before['startTimeTicks']:
            raise RuntimeError('PID identity changed; refusing to sample another process')
        self.identity = before['startTimeTicks']
        marker = next((index for index, line in enumerate(lines) if '[rollup]' in line), None)
        status_lines = lines[1:marker] if marker is not None else lines[1:-1]
        rollup_lines = lines[marker + 1:-1] if marker is not None else []
        status_values, status_raw = parse_memory_lines(status_lines)
        rollup_values, rollup_raw = parse_memory_lines(rollup_lines)
        if 'VmRSSBytes' not in status_values:
            raise RuntimeError('Android status did not expose VmRSS')
        return {'identity': before, 'status': status_values,
                'smapsRollup': rollup_values, 'statusRawMemoryLines': status_raw,
                'smapsRollupRawMemoryLines': rollup_raw,
                'smapsRollupAvailable': 'RssBytes' in rollup_values,
                'readExitCode': completed.returncode,
                'readDiagnostic': completed.stderr.strip()[:2048]}

    def close(self):
        pass


class ProcessMemoryCounters(c.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [
        (name, c.c_size_t) for name in ['PeakWorkingSetSize', 'WorkingSetSize',
        'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage',
        'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage',
        'PagefileUsage', 'PeakPagefileUsage']]


class WindowsSampler:
    def __init__(self, args):
        if os.name != 'nt':
            raise RuntimeError('Windows process counters require a Windows host')
        self.pid = args.pid
        self.kernel = c.WinDLL('kernel32', use_last_error=True)
        self.psapi = c.WinDLL('psapi', use_last_error=True)
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [
            c.POINTER(wintypes.FILETIME)] * 4
        self.kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, c.POINTER(wintypes.DWORD)]
        self.psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE,
                                                  c.POINTER(ProcessMemoryCounters), wintypes.DWORD]
        self.handle = self.kernel.OpenProcess(0x0400 | 0x0010, False, self.pid)
        if not self.handle:
            raise c.WinError(c.get_last_error())
        created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
        if not self.kernel.GetProcessTimes(self.handle, c.byref(created), c.byref(exited),
                                           c.byref(kernel), c.byref(user)):
            self.close()
            raise c.WinError(c.get_last_error())
        self.identity = (created.dwHighDateTime << 32) | created.dwLowDateTime

    def read(self):
        code = wintypes.DWORD()
        if not self.kernel.GetExitCodeProcess(self.handle, c.byref(code)):
            raise c.WinError(c.get_last_error())
        if code.value != 259:
            raise RuntimeError(f'Windows target process exited with code {code.value}')
        counters = ProcessMemoryCounters()
        counters.cb = c.sizeof(counters)
        if not self.psapi.GetProcessMemoryInfo(self.handle, c.byref(counters), counters.cb):
            raise c.WinError(c.get_last_error())
        return {'identity': {'pid': self.pid, 'creationTimeFileTime': self.identity},
                'WorkingSet64': counters.WorkingSetSize,
                'PeakWorkingSet64': counters.PeakWorkingSetSize,
                'PrivateCommitBytes': counters.PagefileUsage,
                'PeakPrivateCommitBytes': counters.PeakPagefileUsage,
                'PageFaultCount': counters.PageFaultCount}

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['android', 'windows'])
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--seconds', required=True, type=float)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--device')
    parser.add_argument('--package', default='lingxue.picakeep')
    parser.add_argument('--adb', type=Path)
    parser.add_argument('--task-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.seconds <= 3600 or not .5 <= args.interval <= 60:
        parser.error('positive PID, seconds 1..3600 and interval .5..60 are required')
    output = safe_output(args.task_root, args.output)
    sampler = None
    started, next_sample = time.monotonic(), time.monotonic()
    samples, errors = 0, 0
    with output.open('x', encoding='utf8') as target:
        def emit(value):
            target.write(json.dumps(value) + '\n')
            target.flush()

        emit({'type': 'metadata', 'schema': 'picakeep-022-os-memory-v1',
              'startedUtc': utc_now(), 'platform': args.platform, 'pid': args.pid,
              'device': args.device, 'package': args.package if args.platform == 'android' else None,
              'durationSeconds': args.seconds, 'intervalSeconds': args.interval,
              'maximumLastReadSeconds': 8 if args.platform == 'android' else None,
              'readOnly': True, 'pidReuseGuard': True,
              'method': 'run-as cat stat/status/smaps_rollup/stat' if args.platform == 'android'
              else 'GetProcessMemoryInfo process handle and creation time',
              'memoryMeaning': 'status VmRSS/VmHWM and smaps RSS/PSS are separate sequential '
              'OS counters, not a simultaneous Dart comparison or leak verdict'})
        try:
            sampler = AndroidSampler(args) if args.platform == 'android' else WindowsSampler(args)
            while time.monotonic() - started < args.seconds:
                delay = next_sample - time.monotonic()
                if delay > 0:
                    time.sleep(min(delay, max(0, started + args.seconds - time.monotonic())))
                if time.monotonic() - started >= args.seconds:
                    break
                read_start, read_utc = time.monotonic(), utc_now()
                try:
                    value = sampler.read()
                except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                    errors += 1
                    emit({'type': 'error', 'sample': samples, 'observedUtc': read_utc,
                          'elapsedSeconds': time.monotonic() - started, 'error': str(error)})
                    # A missing permission/process or reused PID is not an empty-RSS sample.
                    break
                samples += 1
                emit({'type': 'sample', 'index': samples - 1, 'observedUtc': read_utc,
                      'elapsedSeconds': read_start - started,
                      'readWallMs': (time.monotonic() - read_start) * 1000,
                      **value})
                next_sample += args.interval
                if next_sample < time.monotonic():
                    next_sample = time.monotonic()
        except (RuntimeError, OSError, ValueError) as error:
            errors += 1
            emit({'type': 'error', 'stage': 'open', 'observedUtc': utc_now(),
                  'elapsedSeconds': time.monotonic() - started, 'error': str(error)})
        finally:
            if sampler is not None:
                sampler.close()
            emit({'type': 'summary', 'finishedUtc': utc_now(), 'samples': samples,
                  'errors': errors, 'elapsedSeconds': time.monotonic() - started,
                  'stoppedAtRequestedDuration': errors == 0,
                  'verdict': 'observations only; memory acceptance not evaluated'})
    print(json.dumps({'output': str(output), 'samples': samples, 'errors': errors}))
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
