import Foundation
import SQLite3

class SearchDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.assistanteditor.searchdb")

    deinit { close() }

    func open(path: String) throws {
        var opened: OpaquePointer?
        let rc = queue.sync { () -> Int32 in
            _close()
            let code = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            if code == SQLITE_OK { db = opened }
            return code
        }
        guard rc == SQLITE_OK, let opened else {
            throw SearchError("Failed to open database (\(sqlite3_extended_errcode(opened))): \(sqliteErrStr)")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try createSchema()
    }

    func openInMemory() throws {
        queue.sync { _close() }
        let rc = sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            throw SearchError("Failed to open in-memory database: \(sqliteErrStr)")
        }
        try createSchema()
    }

    func close() {
        queue.sync { _close() }
    }

    private func _close() {
        guard let db else { return }
        // close_v2 is safe even if statements are somehow outstanding —
        // the connection frees when the last statement finalizes instead
        // of leaking or corrupting.
        sqlite3_close_v2(db)
        self.db = nil
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS subtitle_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_file TEXT,
                interview TEXT,
                folder TEXT,
                location TEXT,
                start_s REAL,
                end_s REAL,
                speaker TEXT,
                text_content TEXT,
                embedding BLOB
            )
        """)
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS subtitle_fts USING fts5(
                text_content, speaker, interview, location, folder,
                content='subtitle_entries', content_rowid='id',
                tokenize='porter unicode61'
            )
        """)

    }

    // MARK: - Subtitles

    func loadSubtitles(_ entries: [SubtitleEntry], folder: String) throws {
        guard let db else { throw SearchError("Database not open") }
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            // One transaction: a mid-loop failure can no longer leave a
            // truncated-but-committed table behind.
            try execNoQueue("BEGIN IMMEDIATE TRANSACTION")
            do {
                try insertEntries(entries, folder: folder)
                try execNoQueue("COMMIT")
            } catch {
                _ = try? execNoQueue("ROLLBACK")
                throw error
            }
        }
    }

    private func insertEntries(_ entries: [SubtitleEntry], folder: String) throws {
        guard let db else { throw SearchError("Database not open") }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        try execNoQueue("DELETE FROM subtitle_entries")

            let sql = """
                INSERT INTO subtitle_entries(source_file, interview, folder, location, start_s, end_s, speaker, text_content)
                VALUES(?,?,?,?,?,?,?,?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SearchError("Prepare failed: \(sqliteErrStr)")
            }
            for entry in entries {
                bindText(stmt, 1, entry.sourceFile)
                bindText(stmt, 2, entry.interview)
                bindText(stmt, 3, entry.folder)
                bindText(stmt, 4, entry.location)
                sqlite3_bind_double(stmt, 5, entry.start_s)
                sqlite3_bind_double(stmt, 6, entry.end_s)
                bindText(stmt, 7, entry.speaker)
                bindText(stmt, 8, entry.text)
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    throw SearchError("Insert failed: \(sqliteErrStr)")
                }
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
            stmt = nil
            try execNoQueue("INSERT INTO subtitle_fts(subtitle_fts) VALUES('rebuild')")
            setMetadataUnqueued("sourceFolder", folder)
            setMetadataUnqueued("entryCount", "\(entries.count)")
    }

    static func cachePath(for folder: String, kind: String, tag: String = "") -> String {
        let folderName = URL(fileURLWithPath: folder).lastPathComponent
        let appCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let ns = tag.isEmpty ? "" : "_\(tag)"
        return appCache.appendingPathComponent("assistanteditor_\(kind)\(ns)_\(folderName).db").path
    }

    func needsSubtitleRebuild(folder: String) -> Bool {
        guard let db else { return true }
        return queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            // check sourceFolder metadata
            let mSQL = "SELECT value FROM metadata WHERE key = ?"
            guard sqlite3_prepare_v2(db, mSQL, -1, &stmt, nil) == SQLITE_OK else { return true }
            bindText(stmt, 1, "sourceFolder")
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return true }
            let cached = String(cString: c)
            sqlite3_finalize(stmt)
            stmt = nil

            guard cached == folder else { return true }

            // Row count must match what the last completed build stored.
            if let expected = getMetadataUnqueued("entryCount"), let n = Int(expected), n > 0 {
                guard sqlite3_prepare_v2(db, "SELECT count(*) FROM subtitle_entries", -1, &stmt, nil) == SQLITE_OK else { return true }
                guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
                return Int(sqlite3_column_int64(stmt, 0)) != n
            }

            // Legacy cache without a count — accept non-empty tables.
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM subtitle_entries", -1, &stmt, nil) == SQLITE_OK else { return true }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
            return sqlite3_column_int(stmt, 0) == 0
        }
    }

    func searchSubtitles(_ query: String, folder: String? = nil, limit: Int = 500) -> [SubtitleEntry] {
        guard let db, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let ftsQuery = ftsQueryString(query)
        var sql = """
            SELECT e.id, e.source_file, e.interview, e.folder, e.location,
                   e.start_s, e.end_s, e.speaker, e.text_content
            FROM subtitle_entries e
            INNER JOIN subtitle_fts f ON e.id = f.rowid
            WHERE subtitle_fts MATCH ?
        """
        if let folder {
            sql += " AND e.folder LIKE ?"
        }
        sql += " ORDER BY rank LIMIT ?"

        return queue.sync { () -> [SubtitleEntry] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            if folder != nil {
                bindText(stmt, 1, ftsQuery)
                bindText(stmt, 2, "\(folder!)%")
                sqlite3_bind_int(stmt, 3, Int32(limit))
            } else {
                bindText(stmt, 1, ftsQuery)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }

            var results: [SubtitleEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let entry = SubtitleEntry(
                    sourceFile: colStr(stmt, 1),
                    interview: colStr(stmt, 2),
                    folder: colStr(stmt, 3),
                    location: colStr(stmt, 4),
                    start_s: sqlite3_column_double(stmt, 5),
                    end_s: sqlite3_column_double(stmt, 6),
                    speaker: colStr(stmt, 7),
                    text: colStr(stmt, 8)
                )
                results.append(entry)
            }
            return results
        }
    }

    func allSubtitleEntries() -> [SubtitleEntry] {
        guard let db else { return [] }
        return queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT source_file, interview, folder, location, start_s, end_s, speaker, text_content FROM subtitle_entries ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [SubtitleEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(SubtitleEntry(
                    sourceFile: colStr(stmt, 0),
                    interview: colStr(stmt, 1),
                    folder: colStr(stmt, 2),
                    location: colStr(stmt, 3),
                    start_s: sqlite3_column_double(stmt, 4),
                    end_s: sqlite3_column_double(stmt, 5),
                    speaker: colStr(stmt, 6),
                    text: colStr(stmt, 7)
                ))
            }
            return results
        }
    }

    // MARK: - Embedding Storage

    func saveSubtitleEmbedding(id: Int64, vec: [Double]) throws {
        guard let db else { throw SearchError("Database not open") }
        let data = try JSONSerialization.data(withJSONObject: vec)
        try queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "UPDATE subtitle_entries SET embedding = ? WHERE id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            try data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                sqlite3_bind_blob(stmt, 1, base, Int32(buf.count), nil)
            }
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func saveSubtitleEmbeddingByEntry(sourceFile: String, start_s: Double, vec: [Double]) throws {
        guard let db else { throw SearchError("Database not open") }
        let data = try JSONSerialization.data(withJSONObject: vec)
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE subtitle_entries SET embedding = ? WHERE source_file = ? AND start_s = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            try data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                sqlite3_bind_blob(stmt, 1, base, Int32(buf.count), nil)
            }
            bindText(stmt, 2, sourceFile)
            sqlite3_bind_double(stmt, 3, start_s)
            sqlite3_step(stmt)
        }
    }

    func loadAllSubtitleEmbeddings() -> [String: [Double]] {
        guard let db else { return [:] }
        return queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT source_file, start_s, embedding FROM subtitle_entries WHERE embedding IS NOT NULL"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var result: [String: [Double]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sourceFile = colStr(stmt, 0)
                let start_s = sqlite3_column_double(stmt, 1)
                let key = "\(sourceFile)/\(start_s)"
                if let blob = sqlite3_column_blob(stmt, 2) {
                    let len = Int(sqlite3_column_bytes(stmt, 2))
                    let data = Data(bytes: blob, count: len)
                    if let vec = try? JSONSerialization.jsonObject(with: data) as? [Double] {
                        result[key] = vec
                    }
                }
            }
            return result
        }
    }

    // MARK: - Counts

    func subtitleCount() -> Int {
        guard let db else { return 0 }
        return (try? queue.sync { () -> Int in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM subtitle_entries", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }) ?? 0
    }

    // MARK: - Metadata

    /// Content fingerprint stored with the subtitle cache (nil = never saved)
    func getCachedFingerprint() -> String? {
        getMetadata("subtitles_fingerprint")
    }

    func storeCachedFingerprint(_ value: String) {
        setMetadata("subtitles_fingerprint", value)
    }

    /// Callers already holding the queue may call directly; everything else
    /// must go through the queued wrappers below. Raw access here was the
    /// source of concurrent-use segfaults (crash on 3rd folder re-read).
    private func setMetadataUnqueued(_ key: String, _ value: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func getMetadataUnqueued(_ key: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM metadata WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return colStr(stmt, 0)
    }

    private func setMetadata(_ key: String, _ value: String) {
        queue.sync { setMetadataUnqueued(key, value) }
    }

    private func getMetadata(_ key: String) -> String? {
        queue.sync { getMetadataUnqueued(key) }
    }

    // MARK: - Helpers

    private func ftsQueryString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.isEmpty { return trimmed }
        // Quote each term and escape embedded quotes so FTS5 boolean operators
        // (OR/AND/NOT/NEAR), parentheses and quotes are treated as literal text
        // instead of producing a syntax error (which silently returned 0 hits).
        let safe = parts.map { term -> String in
            let esc = term.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(esc)\"*"
        }
        if parts.count == 1 { return safe[0] }
        return safe.joined(separator: " AND ")
    }

    private func exec(_ sql: String) throws {
        // Queued: open()/createSchema() call this from arbitrary threads while
        // builders may still be draining statements on the serial queue.
        try queue.sync { try execNoQueue(sql) }
    }

    private func execNoQueue(_ sql: String) throws {
        guard let db else { throw SearchError("Database not open") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let msg = err.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            let code = db != nil ? sqlite3_extended_errcode(db) : 0
            throw SearchError("SQL error \(code): \(msg)")
        }
    }

    private var sqliteErrStr: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func colStr(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ text: String) {
        guard let cstr = (text as NSString).utf8String else {
            sqlite3_bind_text(stmt, idx, "", -1, nil)
            return
        }
        sqlite3_bind_text(stmt, idx, cstr, -1, nil)
    }
}

struct SearchError: Error, LocalizedError {
    let message: String
    init(_ msg: String) { message = msg }
    var errorDescription: String? { message }
}
