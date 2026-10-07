"""Read task-owned original exports and favorites after normal UI verification.

This never starts an app, performs an operation, modifies a database or counts
state snapshots as pixel/UI acceptance. Use after closing the isolated app.
"""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
from urllib.parse import parse_qs, urlsplit

JPEG_SHA = "d5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690"
ZIP_SHA = "0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35"
PNG_SHAS = ["8811fe1a50a009f754b59cc169e73f3a506564baba77b6415ae127856f753ffe",
            "c868636157f575a502f4debc9f536c43dab60669a3b41e405c96fa1673258990"]


def checked(path, root=None):
    path = Path(os.path.abspath(path))
    for parent in [path, *path.parents]:
        if parent.is_symlink() or getattr(parent, "is_junction", lambda: False)():
            raise ValueError(f"Task audit cannot traverse links: {parent}")
    resolved = path.resolve(strict=True)
    if root is not None and not resolved.is_relative_to(root):
        raise ValueError(f"Audit path escaped task: {path}")
    return resolved


def android_task_root(value):
    """Accept only an explicit canonical app task identity, without aliasing it."""
    if not isinstance(value, str) or not re.fullmatch(
        r"/data/(?:user/0|data)/lingxue\.picakeep/files/normal-ui-022-[A-Za-z0-9][A-Za-z0-9_-]*",
        value,
    ):
        raise ValueError("Source task root must be a canonical Android PicaKeep normal-ui-022-* task")
    return value


def snapshot_path(value, root, source_root=None):
    """Map captured absolute Android paths lexically; never alter persisted data."""
    if source_root is None:
        return checked(value, root)
    source_root = android_task_root(source_root)
    if not isinstance(value, str) or not value.startswith(source_root + "/"):
        raise ValueError(f"Captured path is outside the source task: {value}")
    parts = value[len(source_root) + 1:].split("/")
    for part in parts:
        # Reject traversal, alternate separators, Windows aliases/streams and
        # noncanonical paths before creating a host path from untrusted DB text.
        if (not part or part in (".", "..") or part.endswith((".", " "))
                or re.search(r'[\x00-\x1f\\<>:"|?*]', part)
                or re.fullmatch(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", part, re.IGNORECASE)):
            raise ValueError(f"Noncanonical captured path: {value}")
    return checked(root.joinpath(*parts), root)


def file_evidence(path, root, expected=None):
    path = checked(path, root)
    before = path.stat()
    digest = hashlib.sha256()
    with path.open("rb") as source:
        head = source.read(16)
        digest.update(head)
        for chunk in iter(lambda: source.read(64 * 1024), b""):
            digest.update(chunk)
    after = path.stat()
    sha = digest.hexdigest()
    fmt = "png" if head.startswith(b"\x89PNG\r\n\x1a\n") else "jpeg" if head.startswith(b"\xff\xd8\xff") else "unknown"
    return {"path": str(path), "bytes": before.st_size, "sha256": sha,
            "format": fmt, "extension": path.suffix.lower(),
            "stableDuringRead": before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns,
            "matchesExpected": expected is None or sha == expected}


def audit(args):
    root = checked(args.task_root)
    if not root.name.startswith("normal-ui-022-"):
        raise ValueError("An explicitly marked normal-ui-022-* task is required")
    source_root = getattr(args, "source_task_root", None)
    if source_root is not None:
        source_root = android_task_root(source_root)
    marker = json.loads(checked(root / "normal-ui-verification-022.json", root).read_text(encoding="utf-8"))
    marker_root = marker.get("root", "")
    root_matches = marker_root == source_root if source_root is not None else isinstance(marker_root, str) and os.path.normcase(os.path.normpath(marker_root)) == os.path.normcase(str(root))
    if marker.get("scope") != "picakeep-isolated-normal-ui-022" or marker.get("version") != 1 or not root_matches:
        raise ValueError("Task marker identity mismatch")
    expected = {"real-jpeg/1.jpg": JPEG_SHA, "real-jpeg/cover.jpg": JPEG_SHA,
                "archive-001.zip": ZIP_SHA}
    for chapter, order in [("chapter-1", PNG_SHAS), ("chapter-2", list(reversed(PNG_SHAS)))]:
        expected[f"real-workflow/{chapter}/1.jpg"] = JPEG_SHA
        for page, sha in enumerate(order, 2):
            expected[f"real-workflow/{chapter}/{page}.png"] = sha
    for work, sha in enumerate(PNG_SHAS, 1):
        expected[f"same-name-{work}/1.png"] = sha
        expected[f"same-name-{work}/cover.png"] = sha
    inputs = [file_evidence(root / "library" / relative, root, sha) for relative, sha in expected.items()]
    exports = []
    for output, reference in args.expect_export:
        if output.startswith("/") or Path(output).is_absolute() or Path(reference).is_absolute():
            raise ValueError("Export/reference arguments must be relative to exports/library")
        sha = expected.get(reference.replace("\\", "/"))
        if sha is None:
            raise ValueError(f"Unknown pinned reference: {reference}")
        item = file_evidence(root / "exports" / output, root, sha)
        item["reference"] = reference
        item["formatMatchesExtension"] = item["format"] == "png" and item["extension"] == ".png" or item["format"] == "jpeg" and item["extension"] in [".jpg", ".jpeg"]
        exports.append(item)
    db = checked(root / "support" / "history.db", root)
    wal = Path(str(db) + "-wal")
    if wal.exists() and checked(wal, root).stat().st_size:
        raise ValueError("history.db has pending WAL data; close the isolated app normally before auditing")
    favorites = []
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro&immutable=1", uri=True)) as connection:
        connection.row_factory = sqlite3.Row
        for row in connection.execute("select id, title, cover, ep, page, other from image_favorites order by id, ep, page"):
            record = dict(row)
            record["other"] = json.loads(record["other"])
            source_url = record["other"].get("url", "")
            expected_sha = None
            expected_page = None
            if source_url.startswith("archive:"):
                query = parse_qs(urlsplit(source_url).query)
                archive = snapshot_path(query["path"][0], root, source_root)
                if archive == root / "library" / "archive-001.zip":
                    entry = query.get("entry", [""])[0]
                    if entry in ["1.png", "2.png"]:
                        expected_page = int(entry[0])
                        expected_sha = PNG_SHAS[expected_page - 1]
            elif source_url:
                source = snapshot_path(source_url, root, source_root)
                if source.is_relative_to(root / "library"):
                    relative = source.relative_to(root / "library").as_posix()
                    expected_sha = expected.get(relative)
                    if source.stem.isdecimal():
                        expected_page = int(source.stem)
            item = file_evidence(snapshot_path(record["cover"], root, source_root), root, expected_sha)
            record["file"] = item
            record["expectedSourceResolved"] = expected_sha is not None
            record["metadataMatches"] = expected_page == record["page"] and bool(record["other"].get("sourceVersion")) and bool(record["other"].get("sourceKey")) and record["id"].startswith(record["other"]["sourceKey"] + "-")
            favorites.append(record)
        history = [dict(row) for row in connection.execute("select target, title, ep, page, max_page from history order by target")]
    audit_path = root / "normal-ui-audit.jsonl"
    events = [json.loads(line) for line in checked(audit_path, root).read_text(encoding="utf-8").splitlines()] if audit_path.exists() else []
    zoom_states = [event for event in events if event.get("event") == "reader-state" and any(surface.get("density") == 1 and surface.get("demandComplete") for surface in event.get("surfaces", []))]
    same_name = [record for record in favorites if any(f"same-name-{work}" in record["other"].get("url", "") for work in [1, 2])]
    report = {
        "taskRoot": str(root), "sourceTaskRoot": source_root,
        "pathMapping": "Explicit Android task paths mapped into a host snapshot; persisted metadata unchanged" if source_root else "Host paths checked against task root",
        "inputs": inputs, "exports": exports,
        "favorites": favorites, "history": history,
        "exportCount": len(exports), "favoriteCount": len(favorites),
        "byteAuditPassed": all(item["stableDuringRead"] and item["matchesExpected"] for item in inputs + exports) and all(item["formatMatchesExtension"] for item in exports) and all(record["expectedSourceResolved"] and record["metadataMatches"] and record["file"]["matchesExpected"] and record["file"]["stableDuringRead"] for record in favorites),
        "sameBasenameIndependent": len(same_name) == 2 and len({record["cover"] for record in same_name}) == 2 and {record["file"]["sha256"] for record in same_name} == set(PNG_SHAS) if same_name else None,
        "nativeDensityCompleteStateCount": len(zoom_states),
        "osMemoryPressureEventCount": sum(event.get("event") == "os-memory-pressure" for event in events),
        "nativeShareCalls": [event for event in events if event.get("event", "").startswith("native-share-")],
        "scope": "Read-only hashes and persisted metadata after real isolated UI; no UI actions performed by this script",
        "notCovered": ["Actual raster pixel equivalence", "Share receiver delivery/bytes", "Performance thresholds", "Permission recovery", "User observation of dialogs/gestures", "Normal-UAT completeness"],
        "fullAcceptanceComplete": False,
    }
    encoded = json.dumps(report, ensure_ascii=False, indent=2)
    if args.report:
        output = Path(args.report)
        # Refuse an accidental overwrite; never touch app databases or inputs.
        with output.open("x", encoding="utf-8") as destination:
            destination.write(encoded + "\n")
    print(encoded)
    return 0 if report["byteAuditPassed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-root", required=True)
    parser.add_argument("--source-task-root", help="Offline Android snapshot only: exact /data/data/lingxue.picakeep/files/normal-ui-022-* or /data/user/0 equivalent recorded by the marker; no aliases are substituted")
    parser.add_argument("--expect-export", nargs=2, action="append", default=[], metavar=("EXPORT_RELATIVE", "LIBRARY_REFERENCE"))
    parser.add_argument("--report", help="A new report file; an existing file is never overwritten")
    args = parser.parse_args()
    try:
        return audit(args)
    except (OSError, ValueError, KeyError, sqlite3.Error) as error:
        print(json.dumps({"status": "audit-refused-or-failed", "error": str(error), "fullAcceptanceComplete": False}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
