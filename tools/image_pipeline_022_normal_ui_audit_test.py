"""Focused read-only Android snapshot mapping tests; no app/UI acceptance."""
import argparse
from contextlib import closing, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import image_pipeline_022_normal_ui_audit as audit_tool


ANDROID_ROOT = "/data/data/lingxue.picakeep/files/normal-ui-022-android-v10-1006"
ANDROID_USER_ROOT = "/data/user/0/lingxue.picakeep/files/normal-ui-022-android-v10-1006"


def digest(data):
    return hashlib.sha256(data).hexdigest()


class SnapshotAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.root = self.parent / "normal-ui-022-captured"
        self.root.mkdir()

    def capture(self, identity):
        # Synthetic pinned inputs exercise paths/metadata, not image decoding.
        jpeg = b"\xff\xd8\xff-test-jpeg"
        pngs = [b"\x89PNG\r\n\x1a\n-first", b"\x89PNG\r\n\x1a\n-second"]
        zip_bytes = b"PK\x03\x04-test-archive"
        content = {"real-jpeg/1.jpg": jpeg, "real-jpeg/cover.jpg": jpeg,
                   "archive-001.zip": zip_bytes}
        for chapter, images in [("chapter-1", pngs), ("chapter-2", list(reversed(pngs)))]:
            content[f"real-workflow/{chapter}/1.jpg"] = jpeg
            for page, data in enumerate(images, 2):
                content[f"real-workflow/{chapter}/{page}.png"] = data
        for work, data in enumerate(pngs, 1):
            content[f"same-name-{work}/1.png"] = data
            content[f"same-name-{work}/cover.png"] = data
        for relative, data in content.items():
            target = self.root / "library" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        marker = self.root / "normal-ui-verification-022.json"
        marker.write_text(json.dumps({"scope": "picakeep-isolated-normal-ui-022",
                                      "version": 1, "root": identity}), encoding="utf-8")
        (self.root / "favorites").mkdir()
        (self.root / "exports").mkdir()
        (self.root / "support").mkdir()
        (self.root / "exports" / "saved.png").write_bytes(pngs[0])
        is_android = identity.startswith("/data/")

        def source_path(relative):
            return identity + "/" + relative if is_android else str(self.root / relative)

        favorites = []
        sources = [("library/same-name-1/1.png", pngs[0], 1),
                   ("library/same-name-2/1.png", pngs[1], 1),
                   ("archive:?" + urlencode({"path": source_path("library/archive-001.zip"), "entry": "2.png"}), pngs[1], 2),
                   ("library/real-jpeg/1.jpg", jpeg, 1)]
        for index, (relative, data, page) in enumerate(sources):
            cover_relative = f"favorites/{index}.{'jpg' if data is jpeg else 'png'}"
            (self.root / cover_relative).write_bytes(data)
            url = relative if relative.startswith("archive:") else source_path(relative)
            favorites.append((f"key{index}-bookmark", "fixture", source_path(cover_relative), 1, page,
                              json.dumps({"url": url, "sourceVersion": "v1", "sourceKey": f"key{index}"})))
        db = self.root / "support" / "history.db"
        with closing(sqlite3.connect(db)) as connection:
            connection.execute("create table image_favorites (id text, title text, cover text, ep integer, page integer, other text)")
            connection.execute("create table history (target text, title text, ep integer, page integer, max_page integer)")
            connection.executemany("insert into image_favorites values (?, ?, ?, ?, ?, ?)", favorites)
            connection.execute("insert into history values (?, 'fixture', 1, 1, 3)", (source_path("library/real-jpeg"),))
            connection.commit()
        return {"JPEG_SHA": digest(jpeg), "PNG_SHAS": list(map(digest, pngs)),
                "ZIP_SHA": digest(zip_bytes)}, marker, db, favorites

    def args(self, source_root=None):
        return argparse.Namespace(task_root=str(self.root), source_task_root=source_root,
                                  expect_export=[("saved.png", "same-name-1/1.png")], report=None)

    def run_audit(self, args, pinned):
        output = io.StringIO()
        with patch.multiple(audit_tool, **pinned), redirect_stdout(output):
            code = audit_tool.audit(args)
        return code, json.loads(output.getvalue())

    def test_android_snapshot_maps_direct_archive_and_cover_without_mutation(self):
        pinned, marker, db, original_rows = self.capture(ANDROID_ROOT)
        original_bytes = (marker.read_bytes(), db.read_bytes())
        code, report = self.run_audit(self.args(ANDROID_ROOT), pinned)
        self.assertEqual(code, 0)
        self.assertTrue(report["byteAuditPassed"])
        self.assertTrue(report["sameBasenameIndependent"])
        self.assertEqual(report["sourceTaskRoot"], ANDROID_ROOT)
        self.assertFalse(report["fullAcceptanceComplete"])
        self.assertEqual(report["favoriteCount"], 4)
        for record, row in zip(report["favorites"], original_rows):
            self.assertEqual(record["cover"], row[2])
            self.assertEqual(record["other"], json.loads(row[5]))
            self.assertTrue(Path(record["file"]["path"]).is_relative_to(self.root))
        self.assertEqual(original_bytes, (marker.read_bytes(), db.read_bytes()))

    def test_user_zero_root_is_accepted_only_as_exact_marker_identity(self):
        pinned, _, _db, _rows = self.capture(ANDROID_USER_ROOT)
        code, report = self.run_audit(self.args(ANDROID_USER_ROOT), pinned)
        self.assertEqual(code, 0)
        self.assertEqual(report["sourceTaskRoot"], ANDROID_USER_ROOT)
        with self.assertRaisesRegex(ValueError, "marker identity mismatch"):
            self.run_audit(self.args(ANDROID_ROOT), pinned)

    def test_original_host_mode_remains_strict(self):
        pinned, marker, _db, _rows = self.capture(str(self.root))
        code, report = self.run_audit(self.args(), pinned)
        self.assertEqual(code, 0)
        self.assertIsNone(report["sourceTaskRoot"])
        marker.write_text(json.dumps({"scope": "picakeep-isolated-normal-ui-022",
                                      "version": 1, "root": ANDROID_ROOT}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "marker identity mismatch"):
            self.run_audit(self.args(), pinned)

    def test_malformed_or_foreign_device_roots_are_rejected(self):
        bad_roots = [ANDROID_ROOT + "/", ANDROID_ROOT + "/child", ANDROID_ROOT.replace("/files/", "/files/../files/"),
                     ANDROID_ROOT.replace("lingxue.picakeep", "other.app"),
                     ANDROID_USER_ROOT.replace("/user/0/", "/user/10/"),
                     "data/data/lingxue.picakeep/files/normal-ui-022-task", "", None,
                     ANDROID_ROOT.replace("normal-ui-022-android-v10-1006", "normal-ui-022-")]
        for value in bad_roots:
            with self.subTest(value=value), self.assertRaises(ValueError):
                audit_tool.android_task_root(value)

    def test_traversal_aliases_and_unrelated_paths_are_rejected(self):
        bad_paths = [ANDROID_ROOT + "-other/library/1.png", ANDROID_ROOT.replace("/data/data/", "/data/user/0/") + "/library/1.png",
                     "/etc/passwd", "library/1.png", str(self.root / "library" / "1.png"),
                     ANDROID_ROOT + "/../other/1.png", ANDROID_ROOT + "/library/../1.png",
                     ANDROID_ROOT + "/library/./1.png", ANDROID_ROOT + "/library//1.png",
                     ANDROID_ROOT + "/library\\1.png", ANDROID_ROOT + "/library/1.png:stream",
                     ANDROID_ROOT + "/library/CON.png", ANDROID_ROOT + "/library/1.png.",
                     ANDROID_ROOT + "/library/1.png ", ANDROID_ROOT + "/library/\x001.png"]
        for value in bad_paths:
            with self.subTest(value=value), self.assertRaises(ValueError):
                audit_tool.snapshot_path(value, self.root, ANDROID_ROOT)

    def test_mapping_cannot_traverse_host_link(self):
        outside = self.parent / "outside"
        outside.mkdir()
        (outside / "1.png").write_bytes(b"outside")
        link = self.root / "library"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError:
            if os.name != "nt":
                raise
            subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)],
                           check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, "cannot traverse links"):
            audit_tool.snapshot_path(ANDROID_ROOT + "/library/1.png", self.root, ANDROID_ROOT)

    def test_nonempty_snapshot_wal_still_refuses_audit(self):
        pinned, _marker, db, _rows = self.capture(ANDROID_ROOT)
        Path(str(db) + "-wal").write_bytes(b"pending")
        with self.assertRaisesRegex(ValueError, "pending WAL"):
            self.run_audit(self.args(ANDROID_ROOT), pinned)


if __name__ == "__main__":
    unittest.main()
