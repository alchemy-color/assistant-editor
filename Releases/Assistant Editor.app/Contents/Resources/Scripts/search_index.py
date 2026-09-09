#!/usr/bin/env python3
"""Search SQLite FTS5 index → JSON results."""
import sys, json, sqlite3

def search(db_path, query):
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute("""
            SELECT t.interview, t.folder, t.file_type,
                   snippet(fts, 0, '<<', '>>', '...', 60) AS snippet
            FROM fts
            JOIN transcripts t ON t.id = fts.rowid
            WHERE fts MATCH ?
            ORDER BY rank
            LIMIT 30
        """, (query,))
        rows = cur.fetchall()
    except sqlite3.OperationalError as e:
        return {"results": [], "error": str(e)}
    finally:
        conn.close()
    results = []
    for interview, folder, file_type, snippet in rows:
        results.append({
            "interview": interview,
            "folder": folder,
            "file_type": file_type,
            "snippet": snippet
        })
    return {"results": results}

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: search_index.py <db_path> <query>"}))
        sys.exit(1)
    result = search(sys.argv[1], sys.argv[2])
    print(json.dumps(result, ensure_ascii=False))
