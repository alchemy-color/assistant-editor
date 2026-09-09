#!/usr/bin/env python3
"""Rebuild SQLite FTS5 index.
Usage: rebuild_index.py <transcripts_root> <db_path>
Outputs JSON: {"count": N}
"""
import sys, json, os, sqlite3

SEARCH_EXTS = (".txt", ".yaml", ".EDL")

def rebuild(transcripts_root, db_path):
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("DROP TABLE IF EXISTS transcripts")
    conn.execute("DROP TABLE IF EXISTS fts")
    conn.execute("""
        CREATE TABLE transcripts (
            id INTEGER PRIMARY KEY,
            interview TEXT NOT NULL,
            folder TEXT NOT NULL,
            file_type TEXT NOT NULL,
            content TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE VIRTUAL TABLE fts USING fts5(
            content, interview, file_type,
            content=transcripts, content_rowid=id
        )
    """)
    count = 0
    for root, dirs, files in os.walk(transcripts_root):
        # Skip top-level items we don't want to index
        rel = os.path.relpath(root, transcripts_root)
        if rel == ".":
            continue
        first = rel.split(os.sep)[0] if rel != "." else ""
        if first in ("Legacy", "SRTs", "dist", "Assistant Editor-Xcode",
                     "__pycache__", "build", ".git"):
            continue
        for f in files:
            if not f.endswith(SEARCH_EXTS):
                continue
            path = os.path.join(root, f)
            folder = os.path.relpath(root, transcripts_root)
            interview = os.path.basename(root)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    content = fh.read()
            except Exception:
                continue
            ft = None
            if f.endswith(".txt"):
                if "_synopsis" in f:
                    ft = "synopsis"
                elif "_youtube" in f or "_YouTube" in f:
                    ft = "youtube"
                else:
                    ft = "transcript"
            elif f.endswith(".yaml") and "_summary" in f:
                ft = "summary"
            elif f.endswith(".EDL"):
                ft = "markers"
            if not ft:
                continue
            conn.execute(
                "INSERT INTO transcripts (interview, folder, file_type, content) VALUES (?, ?, ?, ?)",
                (interview, folder, ft, content))
            count += 1
    conn.commit()
    conn.execute("""
        INSERT INTO fts(rowid, content, interview, file_type)
        SELECT id, content, interview, file_type FROM transcripts
    """)
    conn.commit()
    conn.close()
    return {"count": count}

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: rebuild_index.py <transcripts_root> <db_path>"}))
        sys.exit(1)
    result = rebuild(sys.argv[1], sys.argv[2])
    print(json.dumps(result, ensure_ascii=False))
