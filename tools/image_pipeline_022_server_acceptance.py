"""Verify a separately started production Flutter server against task data only.

prepare creates a fresh marked workspace below the existing 022 E: work area.
verify never launches/kills apps and only sends requests to an explicit loopback
server. Root owns Flutter build/startup and records the actual process command.
"""
import argparse
import concurrent.futures
import hashlib
import io
import json
import math
import os
from pathlib import Path
import shutil
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from PIL import Image

WORK = Path(r"E:\picakeep-image-pipeline-022-work").resolve()
JPEG_SHA = "d5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690"
ZIP_SHA = "0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35"
PASSWORD = "verification-only-022"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def task_root(value):
    root = Path(value).resolve()
    assert root.parent == WORK and root.name.startswith("server-022-"), (
        "Only a dedicated server-022-* directory directly in the 022 work area is accepted"
    )
    return root


def prepare(args):
    root = task_root(args.task_root)
    assert not root.exists(), "Prepare requires a new task directory"
    source = WORK / "real-download-source"
    assert sha((source / "page-001.jpg").read_bytes()) == JPEG_SHA
    assert sha((source / "archive-001.zip").read_bytes()) == ZIP_SHA
    library = root / "library"
    (library / "real-jpeg").mkdir(parents=True)
    shutil.copyfile(source / "page-001.jpg", library / "real-jpeg" / "1.jpg")
    shutil.copyfile(source / "page-001.jpg", library / "real-jpeg" / "cover.jpg")
    shutil.copyfile(source / "archive-001.zip", library / "archive-001.zip")
    fixture = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "image-pipeline-022" / "zipcrypto.zip"
    shutil.copyfile(fixture, library / "locked-fixture.zip")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "host": "127.0.0.1", "port": port,
        "currentDownloadRoot": "", "originalDownloadRoot": "",
        "customLibraryRoots": [str(library)],
        "customLibraryCollectionShellModes": {},
        "managedDataRoot": str(root), "logRequests": False,
        "consolePassword": PASSWORD,
    }
    (root / "picakeep_server.data").write_text(json.dumps(config, indent=2), encoding="utf-8")
    marker = {"port": port, "jpegSha256": JPEG_SHA, "zipSha256": ZIP_SHA,
              "scope": "Only anonymous copied inputs and independent task data"}
    (root / "verification-022.json").write_text(json.dumps(marker, indent=2), encoding="utf-8")
    print(json.dumps({"taskRoot": str(root), "base": f"http://127.0.0.1:{port}",
                      "arguments": ["--server", f"--verification-data-root={root}"]}, indent=2))


def verify(args):
    root = task_root(args.task_root)
    marker = json.loads((root / "verification-022.json").read_text(encoding="utf-8"))
    base = f"http://127.0.0.1:{marker['port']}"
    records = []
    report = {"entryLabel": args.entry_label, "base": base,
              "taskRoot": str(root), "records": records, "complete": False,
              "notCovered": ["Actual GUI service controls", "App remote reader UI",
                             "Forced native cancellation after disconnect", "Slow 202 job count (separate integration tests)"]}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    token = None

    def request(path, *, method="GET", payload=None, headers=None):
        target = urllib.parse.urljoin(base + "/", path)
        parsed = urllib.parse.urlsplit(target)
        assert parsed.hostname == "127.0.0.1" and parsed.port == marker["port"]
        request_headers = dict(headers or {})
        if token:
            request_headers["Authorization"] = f"Bearer {token}"
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        req = urllib.request.Request(target, data=data, method=method, headers=request_headers)
        try:
            response = opener.open(req, timeout=30)
        except urllib.error.HTTPError as failure:
            response = failure
        with response:
            return response.status, {key.lower(): value for key, value in response.headers.items()}, response.read()

    def json_request(path, **options):
        status, headers, body = request(path, **options)
        assert status == 200, (path, status, body[:128])
        return json.loads(body)

    def ready(path):
        statuses = []
        for _ in range(61):
            status, headers, body = request(path)
            statuses.append(status)
            if status != 202:
                assert status == 200, (path, status, body[:128])
                assert headers["content-type"].startswith("image/")
                return headers, body, statuses
            assert headers["content-type"].startswith("application/json")
            assert json.loads(body)["state"] == "preparing"
            assert headers["cache-control"] == "no-store"
            time.sleep(.25)
        raise AssertionError("Derivative never became ready")

    def record(name, **result):
        records.append({"check": name, **result})
        print(name, "passed")

    def page_of(item):
        detail = json_request(item["detailUrl"])
        episode = detail["episodes"][0]
        assert episode["pages"]
        return episode["pages"][0]

    try:
        status = json_request("/status")
        assert status["online"] is True and status["serviceName"] == "PicaKeepServer"
        capabilities = status["imageCapabilities"]
        assert all(capabilities[key] is True for key in ["manifests", "levels", "tiles", "largeRegions"])
        assert "webp" in capabilities["coverFormats"]
        record("production native capabilities", capabilities=capabilities)
        unauth_status, _, _ = request("/api/admin/summary")
        assert unauth_status == 401
        login = json_request("/api/console/login", method="POST", payload={"password": PASSWORD})
        token = login["token"]
        summary = json_request("/api/admin/summary")
        assert Path(summary["dataPath"]).resolve() == root
        assert Path(summary["effectiveManagedDataRoot"]).resolve() == root
        assert Path(summary["configPath"]).resolve() == root / "picakeep_server.data"
        assert summary["currentDownloadRoot"] == summary["originalDownloadRoot"] == ""
        assert [Path(v).resolve() for v in summary["customLibraryRoots"]] == [root / "library"]
        record("isolated production data roots and authorization")
        listing = json_request("/api/library/items")
        jpeg_item = next(item for item in listing["items"] if item["title"] == "real-jpeg")
        zip_item = next(item for item in listing["items"] if item["title"].startswith("archive-001"))
        locked = next(item for item in listing["items"] if item["title"].startswith("locked-fixture"))
        page = page_of(jpeg_item)
        status_code, _, body = request(page)
        assert status_code == 200 and sha(body) == JPEG_SHA
        record("real downloaded JPEG original bytes", bytes=len(body), sha256=sha(body))
        cover_query = urllib.parse.urlsplit(jpeg_item["coverUrl"])
        query = dict(urllib.parse.parse_qsl(cover_query.query))
        query.update({"variant": "cover-v1", "w": "384", "format": "png", "a": "2"})
        cover = urllib.parse.urlunsplit(cover_query._replace(query=urllib.parse.urlencode(query)))
        cover_headers, cover_bytes, cover_states = ready(cover)
        with Image.open(io.BytesIO(cover_bytes)) as image:
            assert image.width == 384 and image.height == round(1500 * 384 / 1062)
            cover_size = list(image.size)
        assert len(cover_bytes) < len(body)
        record("real cover derivative", bytes=len(cover_bytes), size=cover_size, states=cover_states)
        code, _, conditional_body = request(cover, headers={"If-None-Match": cover_headers["etag"]})
        assert code == 304 and conditional_body == b""
        record("cover conditional GET")
        zip_page = page_of(zip_item)
        manifest = json_request(zip_page + "/manifest")
        assert [manifest["width"], manifest["height"]] == [3007, 4629]
        assert manifest["sourceQuality"] == "authoritativeOriginal" and manifest["tilesAvailable"] is True
        with zipfile.ZipFile(root / "library" / "archive-001.zip") as archive:
            member = next(entry for entry in archive.infolist()
                          if not entry.is_dir() and Path(entry.filename).stem.lower() != "cover")
            original_png = archive.read(member)
        code, _, served_member = request(manifest["originalUrl"])
        assert code == 200 and served_member == original_png
        record("real ZIP production extraction original bytes", bytes=len(served_member), sha256=sha(served_member))
        reference = Image.open(io.BytesIO(original_png)).convert("RGBA")
        level = manifest["levels"][-1]
        assert level["density"] == 1 and level["lossless"] is True
        for x, y in [(0, 0), (1, 1), ((reference.width - 1) // 512, (reference.height - 1) // 512)]:
            tile = level["tileUrlTemplate"].replace("{x}", str(x)).replace("{y}", str(y))
            tile_headers, pixels, states = ready(tile)
            actual = Image.open(io.BytesIO(pixels)).convert("RGBA")
            expected = reference.crop((x * 512, y * 512, min((x + 1) * 512, reference.width), min((y + 1) * 512, reference.height)))
            assert actual.size == expected.size and actual.tobytes() == expected.tobytes()
            assert tile_headers["x-image-source-version"] == manifest["sourceVersion"]
            code, _, conditional_body = request(tile, headers={"If-None-Match": tile_headers["etag"]})
            assert code == 304 and conditional_body == b""
            record("real ZIP exact original tile", column=x, row=y, size=list(actual.size), sha256=sha(pixels), states=states)
        concurrent_tile = level["tileUrlTemplate"].replace("{x}", "2").replace("{y}", "2")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            outputs = list(executor.map(lambda _: ready(concurrent_tile)[1], range(8)))
        assert len({sha(output) for output in outputs}) == 1
        record("eight concurrent real ZIP tile consumers", consumers=8, sha256=sha(outputs[0]),
               limitation="Response equality verifies delivery; renderer invocation count tested separately")
        stale_query = urllib.parse.urlsplit(concurrent_tile)
        stale_params = dict(urllib.parse.parse_qsl(stale_query.query))
        stale_params["v"] = "intentionally-stale"
        stale = urllib.parse.urlunsplit(stale_query._replace(query=urllib.parse.urlencode(stale_params)))
        code, headers, body = request(stale)
        assert code == 409 and headers["content-type"].startswith("application/json")
        record("stale version rejected as typed JSON")
        # Mutate only the task copy; appended JPEG trailing data remains valid.
        copy = root / "library" / "real-jpeg" / "1.jpg"
        original_bytes = copy.read_bytes()
        old_stat = copy.stat()
        jpeg_manifest = json_request(page + "/manifest")
        try:
            copy.write_bytes(original_bytes + b"\0")
            json_request("/api/admin/scan", method="POST", payload={})
            refreshed = json_request(page + "/manifest")
            assert refreshed["sourceVersion"] != jpeg_manifest["sourceVersion"]
            code, _, _ = request(jpeg_manifest["levels"][-1]["tileUrlTemplate"].replace("{x}", "0").replace("{y}", "0"))
            assert code == 409
            record("task source replacement invalidates old tile version")
        finally:
            copy.write_bytes(original_bytes)
            os.utime(copy, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
            json_request("/api/admin/scan", method="POST", payload={})
        assert locked["archiveEncrypted"] is True and locked["archivePasswordMatched"] is False
        locked_page = page_of(locked)
        code, _, _ = request(locked_page)
        assert code == 403
        code, _, _ = request(locked_page + "/manifest")
        assert code == 403
        unlock = json_request(locked["detailUrl"] + "/archive/unlock", method="POST", payload={"password": "fixture-password"})
        assert unlock["ok"] is True
        code, _, plain = request(locked_page)
        expected_plain = bytes((i * 31 + i // 251) & 255 for i in range(192 * 1024 + 7))
        assert code == 200 and plain == expected_plain
        record("production locked archive denies data then unlocks original bytes", bytes=len(plain),
               limitation="Synthetic encrypted member is an arbitrary byte fixture, not a valid image")
        assert sha((root / "library" / "real-jpeg" / "1.jpg").read_bytes()) == JPEG_SHA
        assert sha((root / "library" / "archive-001.zip").read_bytes()) == ZIP_SHA
        report["complete"] = True
    finally:
        destination = Path(args.report).resolve()
        assert destination.parent == WORK, "Reports stay directly in the task work area"
        destination.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        print(json.dumps({"complete": report["complete"], "checks": len(records), "report": str(destination)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--task-root", required=True)
    run = commands.add_parser("verify")
    run.add_argument("--task-root", required=True)
    run.add_argument("--report", required=True)
    run.add_argument("--entry-label", required=True,
                     help="Label only; the parent records actual process arguments separately")
    args = parser.parse_args()
    (prepare if args.command == "prepare" else verify)(args)


if __name__ == "__main__":
    main()
