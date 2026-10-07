"""Read-only APK ZIP/ELF alignment evidence; does not imply runtime support."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zipfile


def inspect_elf(data):
    if data[:4] != b"\x7fELF":
        raise ValueError("Native library does not contain an ELF header")
    endian = "<" if data[5] == 1 else ">"
    elf64 = data[4] == 2
    phoff = struct.unpack_from(endian + ("Q" if elf64 else "I"), data, 32 if elf64 else 28)[0]
    phsize, phcount = struct.unpack_from(endian + "HH", data, 54 if elf64 else 42)
    loads, relro = [], []
    for index in range(phcount):
        values = struct.unpack_from(endian + ("IIQQQQQQ" if elf64 else "IIIIIIII"), data, phoff + index * phsize)
        if elf64:
            kind, _, offset, vaddr, _, _, memsz, align = values
        else:
            kind, offset, vaddr, _, _, memsz, _, align = values
        if kind == 1:
            loads.append({"offset": offset, "vaddr": vaddr, "memsz": memsz,
                          "align": align, "aligned16KiB": align >= 16384})
        elif kind == 0x6474E552:
            end = vaddr + memsz
            relro.append({"vaddr": vaddr, "memsz": memsz,
                          "endAligned16KiB": end % 16384 == 0,
                          "endAddress": end,
                          "protectEndRounded16KiB": (end + 16383) // 16384 * 16384})
    for entry in relro:
        next_starts = [load["vaddr"] for load in loads if load["vaddr"] >= entry["endAddress"]]
        next_start = min(next_starts) if next_starts else None
        entry["nextLoadStartAddress"] = next_start
        entry["roundedProtectionDoesNotOverlapNextLoad"] = (
            next_start is None or entry["protectEndRounded16KiB"] <= next_start)
    return {"elfBits": 64 if elf64 else 32, "loads": loads, "relro": relro}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--zipalign", type=Path)
    parser.add_argument("--device-page-size", type=int)
    parser.add_argument("--device-api", type=int)
    args = parser.parse_args()
    apk = args.apk.resolve(strict=True)
    with apk.open("rb") as input_file:
        initial_hash = hashlib.file_digest(input_file, "sha256").hexdigest()
    records = []
    with apk.open("rb") as raw, zipfile.ZipFile(apk) as archive:
        for entry in archive.infolist():
            if not entry.filename.startswith("lib/") or not entry.filename.endswith(".so"):
                continue
            data = archive.read(entry)
            raw.seek(entry.header_offset + 26)
            filename_bytes, extra_bytes = struct.unpack("<HH", raw.read(4))
            data_offset = entry.header_offset + 30 + filename_bytes + extra_bytes
            records.append({"path": entry.filename, "bytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest(),
                            "compression": entry.compress_type,
                            "zipDataOffset": data_offset,
                            "zipAligned16KiB": data_offset % 16384 == 0,
                            **inspect_elf(data)})
    with apk.open("rb") as input_file:
        final_hash = hashlib.file_digest(input_file, "sha256").hexdigest()
    if initial_hash != final_hash:
        raise RuntimeError("APK changed while the read-only inspection was running")
    records64 = [record for record in records if record["elfBits"] == 64]
    report = {"apk": str(apk), "apkBytes": apk.stat().st_size,
              "apkSha256": initial_hash,
              "abiSet": sorted({record["path"].split("/")[1] for record in records}),
              "flutterRuntimeAbiSet": sorted({record["path"].split("/")[1] for record in records
                                              if record["path"].endswith("/libflutter.so")}),
              "libraries": records,
              "allUncompressedLibrariesZip16KiBAligned": bool(records) and all(
                  record["compression"] != 0 or record["zipAligned16KiB"] for record in records),
              "all64BitLoadSegments16KiBAligned": bool(records64) and all(
                  segment["aligned16KiB"] for record in records64 for segment in record["loads"]),
              "all64BitRelroEnds16KiBAligned": bool(records64) and all(
                  segment["endAligned16KiB"] for record in records64 for segment in record["relro"]),
              "runtime16KiBDeviceTested": False,
              "officialCheck": "https://developer.android.com/guide/practices/page-sizes",
              "interpretation": "Structural alignment evidence only; runtime compatibility requires a 16KiB device test."}
    if args.zipalign:
        check = subprocess.run([str(args.zipalign), "-c", "-P", "16", "4", str(apk)],
                               capture_output=True, text=True, check=False)
        report["zipalign16KiBExitCode"] = check.returncode
        report["zipalignOutput"] = (check.stdout + check.stderr).strip()
    if args.device_page_size:
        report["devicePageSize"] = args.device_page_size
    if args.device_api:
        report["deviceApi"] = args.device_api
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "libraries"}))


if __name__ == "__main__":
    main()
