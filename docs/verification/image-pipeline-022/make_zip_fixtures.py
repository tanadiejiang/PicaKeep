"""Generate independent synthetic ZIP fixtures with Python and installed 7-Zip.

No application/private files are used. Fixtures exercise chunk boundaries and
encrypted member validation, not image decoding.
"""
from pathlib import Path
import subprocess
import tempfile
import zipfile
import struct
import zlib

output = Path(__file__).resolve().parents[3] / "test" / "fixtures" / "image-pipeline-022"
output.mkdir(parents=True, exist_ok=True)
seven_zip = Path(r"C:\Program Files\7-Zip\7z.exe")
payload = bytes((i * 31 + i // 251) & 255 for i in range(192 * 1024 + 7))
with tempfile.TemporaryDirectory(prefix="picakeep-zip-fixture-") as folder:
    root = Path(folder)
    (root / "1.png").write_bytes(payload)
    for name, compression in [("stored.zip", zipfile.ZIP_STORED), ("deflate.zip", zipfile.ZIP_DEFLATED)]:
        with zipfile.ZipFile(output / name, "w", compression=compression) as archive:
            archive.write(root / "1.png", "1.png")
    for name, method in [("zipcrypto.zip", "ZipCrypto"), ("aes256.zip", "AES256")]:
        subprocess.run([str(seven_zip), "a", "-tzip", "-mx=0", f"-mem={method}",
                        "-pfixture-password", str(output / name), "1.png"], cwd=root, check=True,
                       stdout=subprocess.DEVNULL)
    for name, method in [("zipcrypto-deflate.zip", "ZipCrypto"), ("aes256-deflate.zip", "AES256")]:
        subprocess.run([str(seven_zip), "a", "-tzip", "-mx=5", f"-mem={method}",
                        "-pfixture-password", str(output / name), "1.png"], cwd=root, check=True,
                       stdout=subprocess.DEVNULL)
    ae1 = bytearray((output / "aes256.zip").read_bytes())
    central = ae1.index(b"PK\x01\x02")
    struct.pack_into("I", ae1, 14, zlib.crc32(payload))
    struct.pack_into("I", ae1, central + 16, zlib.crc32(payload))
    for base, fixed, length_offset in [(0, 30, 26), (central, 46, 28)]:
        name_length, extra_length = struct.unpack_from("HH", ae1, base + length_offset)
        cursor = base + fixed + name_length
        end = cursor + extra_length
        while cursor + 4 <= end:
            tag, size = struct.unpack_from("HH", ae1, cursor)
            if tag == 0x9901:
                struct.pack_into("H", ae1, cursor + 4, 1)
            cursor += 4 + size
    (output / "aes256-ae1.zip").write_bytes(ae1)
print(output)
