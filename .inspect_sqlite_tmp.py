import json
import sqlite3

files = [
    r"E:\Pica\appdata等10个文件\history.db",
    r"E:\Pica\appdata等10个文件\local_favorite.db",
    r"E:\Pica\appdata等10个文件\cache.db",
    r"E:\Pica\appdata等10个文件\cookies.db",
    r"E:\Pica\手机收藏的完整数据库\download.db",
]

for file_path in files:
    print(f"=== {file_path} ===")
    conn = sqlite3.connect(file_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    print("tables:", tables)
    for table in tables:
        cols = [tuple(row) for row in cur.execute(f'PRAGMA table_info("{table}")')]
        print(f"table {table} columns: {cols}")
        count = cur.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        print("count:", count)
        rows = cur.execute(f'SELECT * FROM "{table}" LIMIT 2').fetchall()
        for row in rows:
            data = {key: row[key] for key in row.keys()}
            print("row:", json.dumps(data, ensure_ascii=False)[:1200])
    conn.close()
    print()