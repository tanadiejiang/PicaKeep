"""Copy one downloaded page and at most one archive using existing Root.

Reads only two explicitly known download roots; never starts the application,
reads account data, changes grants, or mutates source files. Filenames in reports
are anonymous and the source locator is represented only by its SHA-256.
"""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys

from PIL import Image

SOURCE_DEVICE = "192.168.5.4:5555"
TARGET_DEVICE = "8021129d"
ROOTS = [
    "/storage/emulated/0/1/pica/picakeep/download",
    "/storage/emulated/0/1/pica/picakeep/pixiv_download",
]
DESTINATION = "/data/local/tmp/picakeep-image-pipeline-022-real-source"


def root_shell(script):
    command = "su -c " + shlex.quote(script)
    result = subprocess.run(
        ["adb", "-s", SOURCE_DEVICE, "shell", command],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False,
    )
    if result.returncode:
        raise RuntimeError("Existing Root read failed; no permission changes attempted")
    return result.stdout.decode("utf-8").strip()


def find_first(extensions, maximum_mb):
    for root in ROOTS:
        for extension in extensions:
            script = (f"find {shlex.quote(root)} -maxdepth 4 -type f "
                      f"-iname '*.{extension}' ! -iname 'cover*' "
                      f"-size +64k -size -{maximum_mb}M -print -quit")
            value = root_shell(script)
            if value:
                return value.splitlines()[0]
    return None


def snapshot(source):
    quoted = shlex.quote(source)
    stat = root_shell(f"stat -c '%s %Y' {quoted}").split()
    digest = root_shell(f"sha256sum {quoted}").split()[0]
    return int(stat[0]), int(stat[1]), digest


def copy_one(source, label, task_root):
    before = snapshot(source)
    target = task_root / (label + ".bin")
    # subprocess writes directly to the managed file: no complete bytes object.
    with target.open("wb") as output:
        result = subprocess.run(
            ["adb", "-s", SOURCE_DEVICE, "exec-out",
             "su -c " + shlex.quote("cat " + shlex.quote(source))],
            stdout=output, stderr=subprocess.PIPE, timeout=120, check=False,
        )
    if result.returncode:
        raise RuntimeError("Read-only original stream failed")
    digest = hashlib.sha256()
    with target.open("rb") as stream:
        while chunk := stream.read(65536):
            digest.update(chunk)
    after = snapshot(source)
    if before != after or target.stat().st_size != before[0] or digest.hexdigest() != before[2]:
        raise RuntimeError("Source changed or copied original failed integrity verification")
    record = {
        "sampleId": label, "bytes": before[0], "sha256": before[2],
        "sourceLocatorSha256": hashlib.sha256(source.encode()).hexdigest(),
        "sourceSizeMtimeShaUnchanged": before == after,
        "localSha256Matches": True,
    }
    if label.startswith("page"):
        with Image.open(target) as image:
            record.update(format=image.format, width=image.width, height=image.height,
                          mode=image.mode, frames=getattr(image, "n_frames", 1),
                          iccProfileBytes=len(image.info.get("icc_profile", b"")),
                          exifOrientation=image.getexif().get(274, 1))
            extension = {"JPEG": ".jpg", "PNG": ".png", "WEBP": ".webp"}.get(image.format, ".bin")
    else:
        extension = ".zip"
    renamed = target.with_suffix(extension)
    target.rename(renamed)
    subprocess.run(["adb", "-s", TARGET_DEVICE, "shell", "mkdir", "-p", DESTINATION],
                   stdout=subprocess.DEVNULL, check=True, timeout=15)
    remote = DESTINATION + "/" + renamed.name
    subprocess.run(["adb", "-s", TARGET_DEVICE, "push", str(renamed), remote],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
    result = subprocess.run(["adb", "-s", TARGET_DEVICE, "shell", "sha256sum", remote],
                            stdout=subprocess.PIPE, check=True, timeout=15)
    record["targetSha256Matches"] = result.stdout.decode().split()[0] == before[2]
    if not record["targetSha256Matches"]:
        raise RuntimeError("Independent device copy failed SHA-256 verification")
    record.update(localFile=str(renamed), targetFile=remote)
    return record


def main():
    task_root = Path(sys.argv[1])
    task_root.mkdir(parents=True, exist_ok=True)
    report = {"sourceDevice": SOURCE_DEVICE, "targetDevice": TARGET_DEVICE,
              "sourceReadOnly": True, "sourceAppStarted": False,
              "permissionsChanged": False, "fullLibraryExported": False,
              "samples": []}
    source = find_first(["jpg", "jpeg", "png", "webp"], 30)
    if source is None:
        raise RuntimeError("No bounded downloaded page in configured roots")
    report["samples"].append(copy_one(source, "page-001", task_root))
    archive = find_first(["zip", "cbz"], 64)
    if archive:
        report["samples"].append(copy_one(archive, "archive-001", task_root))
        report["archiveStatus"] = "copied"
    else:
        report["archiveStatus"] = "notFoundInBoundedConfiguredRootSearch"
    report["status"] = "copiedAndVerified"
    (task_root / "manifest.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=True))


if __name__ == "__main__":
    main()
