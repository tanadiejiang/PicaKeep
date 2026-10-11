"""066 F5 valid PNG safety fixtures, bounded-memory generation and validation.

No image library or external inputs. Never allocate a full large bitmap.
  bundled-python test/fixtures/reader_066/generate_safety.py --write
  bundled-python test/fixtures/reader_066/generate_safety.py --check
--check recompresses then verifies every PNG CRC and streamed inflated byte SHA.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def generate_png(width, height, long_pattern=False):
    compressor = zlib.compressobj(level=9)
    compressed = bytearray()
    raw_sha = hashlib.sha256()
    raw_length = 0
    colors = [(224, 32, 48, 255), (32, 192, 64, 255), (32, 64, 224, 255)]
    for y in range(height):
        if long_pattern:
            # Yellow left third plus different top/middle/bottom bands. Full
            # rect vs ROI/downsample artifacts are distinguishable by samples.
            row = b"\0" + bytes((240, 208, 32, 255)) * (width // 3) + bytes(colors[min(2, y * 3 // height)]) * (width - width // 3)
        else:
            row = b"\0" + bytes((224, 32, 48, 255)) * width
        assert len(row) <= 32769  # At most one 8192-pixel RGBA row + PNG filter.
        raw_sha.update(row)
        raw_length += len(row)
        compressed.extend(compressor.compress(row))
    compressed.extend(compressor.flush())
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    encoded = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", bytes(compressed)) + chunk(b"IEND", b"")
    return encoded, raw_length, raw_sha.hexdigest()


def verify_stream(encoded, expected_length, expected_sha):
    offset, inflated_length = 8, 0
    decoder = zlib.decompressobj()
    inflated_sha = hashlib.sha256()
    while offset < len(encoded):
        length = struct.unpack(">I", encoded[offset:offset + 4])[0]
        kind = encoded[offset + 4:offset + 8]
        body = encoded[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", encoded[offset + 8 + length:offset + 12 + length])[0]
        assert crc == zlib.crc32(kind + body)
        if kind == b"IDAT":
            pending = body
            while pending:
                output = decoder.decompress(pending, max_length=65536)
                pending = decoder.unconsumed_tail
                inflated_sha.update(output)
                inflated_length += len(output)
        offset += length + 12
    assert decoder.eof and not decoder.unused_data
    assert inflated_length == expected_length
    assert inflated_sha.hexdigest() == expected_sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true")
    group.add_argument("--check", action="store_true")
    args = parser.parse_args()
    assets, entries = {}, []
    for name, width, height, pattern in [("safety_long_24x6000.png", 24, 6000, True), ("safety_large_8192x8192.png", 8192, 8192, False)]:
        encoded, raw_length, raw_digest = generate_png(width, height, pattern)
        verify_stream(encoded, raw_length, raw_digest)
        assets[name] = encoded
        entries.append({"file": name, "width": width, "height": height,
                        "decoded_rgba_bytes": width * height * 4,
                        "encoded_bytes": len(encoded), "sha256": sha(encoded),
                        "inflated_scanline_bytes": raw_length,
                        "inflated_scanline_sha256": raw_digest})
    manifest = {"schema": 1, "zlib": zlib.ZLIB_VERSION,
                "generator": "streaming RGBA rows; PNG filter 0; zlib level9; CRC32 each chunk; no huge bitmap",
                "validation": "full inflated length + SHA in <=64KiB chunks; no large frame decode",
                "fixtures": entries}
    assets["safety_manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    for name, content in assets.items():
        path = ROOT / name
        if args.write:
            path.write_bytes(content)
        elif not path.is_file() or path.read_bytes() != content:
            raise SystemExit("Mismatch without rewriting: " + name)
    print(("Wrote" if args.write else "Verified byte-identical"), len(assets), "safety files;", sum(map(len, assets.values())), "encoded/manifest bytes")
    for item in entries:
        print(item["file"], item["encoded_bytes"], "encoded bytes;", item["decoded_rgba_bytes"], "declared/stream-validated RGBA bytes; never bitmap allocated")


if __name__ == "__main__":
    main()
