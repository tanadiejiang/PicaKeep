import json
import shutil
import sqlite3
from datetime import datetime
from pathlib import Path
import re

summary_path = Path(r"D:\Flutter_Projucts\PicaComic\PicaKeep\temp_recover_summary.json")
download_db_path = Path(r"e:\Pica\download\download.db")
root_path = Path(r"e:\Pica\download")
report_path = Path(r"D:\Flutter_Projucts\PicaComic\PicaKeep\temp_recover_apply_report.json")
recovered_db_path = root_path / "download.recovered.db"


def natural_key(value: str):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", value)]


def is_image_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}


def has_image_files(path: Path) -> bool:
    try:
        return any(is_image_file(child) for child in path.iterdir())
    except FileNotFoundError:
        return False


def collect_downloaded_chapters(directory_path: Path):
    children = sorted(directory_path.iterdir(), key=lambda p: natural_key(p.name))
    subdirs_with_images = [child for child in children if child.is_dir() and has_image_files(child)]
    flat_images = [child for child in children if is_image_file(child)]

    if flat_images and not subdirs_with_images:
        return [0], []

    if subdirs_with_images:
        downloaded = list(range(len(subdirs_with_images)))
        ep_names = [child.name for child in subdirs_with_images]
        return downloaded, ep_names

    return [0], []


def folder_size_mb(directory_path: Path) -> float:
    total = 0
    for path in directory_path.rglob("*"):
        if path.is_file():
            total += path.stat().st_size
    return total / 1024 / 1024


def build_jm_json(row: dict, size_mb: float, downloaded_chapters, ep_names):
    tags = [tag.strip() for tag in str(row.get("tags") or "").split(",") if tag.strip()]
    author = str(row.get("author") or "").strip()
    return {
        "comicId": str(row["favorite_target"]),
        "name": row["name"],
        "author": author,
        "size": size_mb,
        "downloadedChapters": downloaded_chapters,
        "epNames": ep_names,
        "tagList": tags,
    }


def parse_time_ms(value: str) -> int:
    try:
        return int(datetime.strptime(value, "%Y-%m-%d %H:%M:%S").timestamp() * 1000)
    except Exception:
        return int(datetime.now().timestamp() * 1000)


summary = json.loads(summary_path.read_text(encoding="utf-8"))
missing_rows = summary["missing_rows"]
expected_total = summary["download_count"] + summary["missing_count"]

timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backup_path = root_path / f"download.db.bak_{timestamp}"

shutil.copy2(download_db_path, backup_path)
if recovered_db_path.exists():
    recovered_db_path.unlink()

source = sqlite3.connect(download_db_path)
source.row_factory = sqlite3.Row
src_cur = source.cursor()
existing_rows = src_cur.execute("select id, title, subtitle, time, directory, size, json from download").fetchall()
source.close()

recovered = sqlite3.connect(recovered_db_path)
cur = recovered.cursor()
cur.execute(
    """
    create table if not exists download (
      id text primary key,
      title text,
      subtitle text,
      time int,
      directory text,
      size int,
      json text
    )
    """
)

for row in existing_rows:
    cur.execute(
        "insert or replace into download values (?,?,?,?,?,?,?)",
        (row["id"], row["title"], row["subtitle"], row["time"], row["directory"], row["size"], row["json"]),
    )

inserted_missing = []
for row in missing_rows:
    directory_path = Path(row["directory_path"])
    if not directory_path.exists():
        raise FileNotFoundError(f"Missing directory for recovery: {directory_path}")
    relative_directory = str(directory_path.relative_to(root_path))
    downloaded_chapters, ep_names = collect_downloaded_chapters(directory_path)
    size_mb = folder_size_mb(directory_path)
    payload = build_jm_json(row, size_mb, downloaded_chapters, ep_names)
    cur.execute(
        "insert or replace into download values (?,?,?,?,?,?,?)",
        (
            row["normalized_id"],
            row["name"],
            str(row.get("author") or "").strip(),
            parse_time_ms(str(row.get("time") or "")),
            relative_directory,
            size_mb,
            json.dumps(payload, ensure_ascii=False),
        ),
    )
    inserted_missing.append(
        {
            "id": row["normalized_id"],
            "directory": relative_directory,
            "downloaded_chapters": downloaded_chapters,
            "ep_names": ep_names,
            "size_mb": size_mb,
        }
    )

recovered.commit()
actual_total = cur.execute("select count(1) from download").fetchone()[0]
verify_ids = [missing_rows[0]["normalized_id"], missing_rows[-1]["normalized_id"]] if missing_rows else []
verified_rows = []
for comic_id in verify_ids:
    row = cur.execute("select id, directory, json from download where id=?", (comic_id,)).fetchone()
    verified_rows.append({
        "id": row[0],
        "directory": row[1],
        "json": json.loads(row[2]),
    })
recovered.close()

if actual_total != expected_total:
    raise RuntimeError(f"Recovered db count mismatch: expected {expected_total}, got {actual_total}")

shutil.copy2(recovered_db_path, download_db_path)

final = sqlite3.connect(download_db_path)
final_cur = final.cursor()
final_total = final_cur.execute("select count(1) from download").fetchone()[0]
final.close()

report = {
    "backup_path": str(backup_path),
    "recovered_db_path": str(recovered_db_path),
    "expected_total": expected_total,
    "actual_total": actual_total,
    "final_total": final_total,
    "preserved_existing_count": len(existing_rows),
    "inserted_missing_count": len(inserted_missing),
    "verified_rows": verified_rows,
}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=False, indent=2))