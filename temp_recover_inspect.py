import json
import sqlite3
from pathlib import Path

fav_db = Path(r"C:\Users\tanad\AppData\Roaming\lingxue\picakeep\local_favorite.db")
download_db = Path(r"e:\Pica\download\download.db")
summary_path = Path(r"D:\Flutter_Projucts\PicaComic\PicaKeep\temp_recover_summary.json")

print("FAVORITE_DB", fav_db)
con = sqlite3.connect(fav_db)
cur = con.cursor()
print("TABLES")
for (name,) in cur.execute("select name from sqlite_master where type='table' order by name"):
    print(name)

for table in ["folder_order", "folder_sync", "AAA"]:
    print(f"SCHEMA {table}")
    for row in cur.execute(f"pragma table_info([{table}])"):
        print(json.dumps(row, ensure_ascii=False))

print("AAA_COUNT")
aaa_count = cur.execute("select count(1) from [AAA]").fetchone()[0]
print(aaa_count)

print("AAA_SAMPLE")
aaa_rows = cur.execute("select * from [AAA] order by display_order asc, time desc limit 20").fetchall()
for row in aaa_rows:
    print(json.dumps(row, ensure_ascii=False))

all_aaa_rows = cur.execute("select target, name, author, type, tags, cover_path, time, display_order from [AAA]").fetchall()
con.close()

def normalize_target(target: str) -> str:
    target = str(target).strip()
    if target.startswith("jm"):
        return target
    if target.isdigit():
        return f"jm{target}"
    return target

print("DOWNLOAD_DB", download_db)
con = sqlite3.connect(download_db)
cur = con.cursor()
print("DOWNLOAD_COUNT")
download_count = cur.execute("select count(1) from download").fetchone()[0]
print(download_count)

current_rows = cur.execute("select id, title, subtitle, time, directory, size, json from download").fetchall()
download_by_id = {row[0]: row for row in current_rows}
download_ids = set(download_by_id)

missing_rows = []
present_rows = []
for row in all_aaa_rows:
    normalized_id = normalize_target(row[0])
    enriched = {
        "favorite_target": row[0],
        "normalized_id": normalized_id,
        "name": row[1],
        "author": row[2],
        "type": row[3],
        "tags": row[4],
        "cover_path": row[5],
        "time": row[6],
        "display_order": row[7],
        "cover_exists": Path(row[5]).exists() if row[5] else False,
        "directory_name": Path(row[5]).parent.name if row[5] else "",
        "directory_path": str(Path(row[5]).parent) if row[5] else "",
    }
    if normalized_id in download_ids:
        present_rows.append(enriched)
    else:
        missing_rows.append(enriched)

print("MATCHED_BY_NORMALIZED_ID")
print(len(present_rows))
print("MISSING_BY_NORMALIZED_ID")
print(len(missing_rows))
for row in missing_rows[:120]:
    print(json.dumps(row, ensure_ascii=False))

summary = {
    "aaa_count": aaa_count,
    "download_count": download_count,
    "matched_count": len(present_rows),
    "missing_count": len(missing_rows),
    "missing_rows": missing_rows,
    "present_rows": present_rows,
}
summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
print("SUMMARY_PATH")
print(summary_path)

print("DOWNLOAD_SAMPLE")
for row in cur.execute("select id, title, directory from download order by time desc limit 20"):
    print(json.dumps(row, ensure_ascii=False))
con.close()