import Foundation
import SQLite3

/// SQLite-required marker so bound strings are copied before the statement is reset.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A closed focus interval, as persisted.
struct Segment {
    var id: Int64 = -1
    var start: Date
    var end: Date
    var bundleId: String
    var appName: String
    var windowTitle: String
    var idle: Bool
    var ticket: String?
    var ticketSource: String?
    var category: String?
    var confidence: Double?
    /// The enriched WorkContext document that produced the attribution (repo, branch, changed
    /// files, commit subjects, AI-session prompts, kube context, …). Persisting it — not just the
    /// window title — is what lets the Teach UI, content memory, and the evaluator see the *actual
    /// work*, and lets us replay/audit a guess after the fact. Local-only, like everything else.
    var contextDoc: String?
    /// `WorkContext.meeting` at attribution time (app/keyword detected meeting label, e.g. a Teams
    /// window title) — mirrors `contextDoc` but kept as its own column so the period compiler can
    /// filter on it directly instead of parsing it back out of the free-text document.
    var meeting: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Local-only SQLite persistence. No network, ever.
final class Store {
    private var db: OpaquePointer?
    let dbPath: String

    init() {
        let dir = AppPaths.dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("timetracker.sqlite").path
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            FileHandle.standardError.write("timetracker: cannot open db at \(dbPath)\n".data(using: .utf8)!)
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=3000;")
        createSchema()
    }

    deinit { if db != nil { sqlite3_close(db) } }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_ts INTEGER NOT NULL,
            end_ts INTEGER NOT NULL,
            bundle_id TEXT,
            app_name TEXT,
            window_title TEXT,
            idle INTEGER NOT NULL DEFAULT 0,
            ticket TEXT,
            ticket_source TEXT,
            category TEXT,
            confidence REAL,
            context_doc TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_seg_start ON segments(start_ts);")
        // Migrate older DBs that predate later columns. Expected to fail silently when a column
        // already exists, so don't route these through the logging exec().
        sqlite3_exec(db, "ALTER TABLE segments ADD COLUMN confidence REAL;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE segments ADD COLUMN context_doc TEXT;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE segments ADD COLUMN meeting TEXT;", nil, nil, nil)
        exec("""
        CREATE TABLE IF NOT EXISTS labels (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            context_doc TEXT NOT NULL,
            ticket TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'correction'
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS block_assignments (
            day TEXT NOT NULL,
            block TEXT NOT NULL,
            ticket TEXT,
            note TEXT,
            PRIMARY KEY (day, block)
        );
        """)
        // Periods replace block_assignments' role for the floating-period compiler (PeriodCompiler.swift).
        // A separate table, not a repurposed block_assignments: a period's existence/shape is
        // data-dependent (derived from that day's actual segments), unlike a block, which is a pure
        // function of Config. Keyed by (day, kind, ticket_key) — a period's identity is now exactly
        // which ticket its time landed on (time is totaled per ticket, not tracked by clock
        // position — see PeriodCompiler), so this is an exact lookup, not fuzzy time-matching.
        // ticket_key is the COMPILER's own grouping ticket (empty string = untracked), stable
        // across re-compiles of the same segment data — distinct from `ticket`, the column that
        // actually holds a manual override.
        exec("""
        CREATE TABLE IF NOT EXISTS period_assignments (
            day TEXT NOT NULL,
            kind TEXT NOT NULL,
            ticket_key TEXT NOT NULL,
            ticket TEXT,
            note TEXT,
            PRIMARY KEY (day, kind, ticket_key)
        );
        """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err = err { FileHandle.standardError.write("sqlite: \(String(cString: err))\n".data(using: .utf8)!) }
            sqlite3_free(err)
            return false
        }
        return true
    }

    // MARK: - Writes

    @discardableResult
    func insert(_ s: Segment) -> Int64 {
        let sql = """
        INSERT INTO segments (start_ts,end_ts,bundle_id,app_name,window_title,idle,ticket,ticket_source,category,confidence,context_doc,meeting)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(s.start.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(s.end.timeIntervalSince1970))
        bindText(stmt, 3, s.bundleId)
        bindText(stmt, 4, s.appName)
        bindText(stmt, 5, s.windowTitle)
        sqlite3_bind_int(stmt, 6, s.idle ? 1 : 0)
        bindText(stmt, 7, s.ticket)
        bindText(stmt, 8, s.ticketSource)
        bindText(stmt, 9, s.category)
        if let c = s.confidence { sqlite3_bind_double(stmt, 10, c) } else { sqlite3_bind_null(stmt, 10) }
        bindText(stmt, 11, s.contextDoc)
        bindText(stmt, 12, s.meeting)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Re-tag a day's segments that match a (bundle/title) signature with a manual ticket.
    /// Used when the user overrides the current ticket from the menu.
    func retagToday(matchingWindowTitle title: String, ticket: String) {
        let (start, end) = TimeBlocks.dayBounds(Date())
        let sql = "UPDATE segments SET ticket=?, ticket_source='manual' WHERE window_title=? AND start_ts>=? AND start_ts<?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, ticket)
        bindText(stmt, 2, title)
        sqlite3_bind_int64(stmt, 3, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 4, Int64(end.timeIntervalSince1970))
        sqlite3_step(stmt)
    }

    /// Re-tag all persisted segments that start within [from,to) with a manual ticket.
    func retag(from start: Date, to end: Date, ticket: String) {
        let sql = "UPDATE segments SET ticket=?, ticket_source='manual' WHERE idle=0 AND start_ts>=? AND start_ts<?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, ticket)
        sqlite3_bind_int64(stmt, 2, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 3, Int64(end.timeIntervalSince1970))
        sqlite3_step(stmt)
    }

    func setBlockAssignment(day: String, block: String, ticket: String?, note: String?) {
        let sql = "INSERT INTO block_assignments(day,block,ticket,note) VALUES(?,?,?,?) ON CONFLICT(day,block) DO UPDATE SET ticket=excluded.ticket, note=excluded.note;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, day)
        bindText(stmt, 2, block)
        bindText(stmt, 3, ticket)
        bindText(stmt, 4, note)
        sqlite3_step(stmt)
    }

    func blockAssignment(day: String, block: String) -> (ticket: String?, note: String?)? {
        let sql = "SELECT ticket,note FROM block_assignments WHERE day=? AND block=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, day)
        bindText(stmt, 2, block)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (colText(stmt, 0), colText(stmt, 1))
    }

    // MARK: - Labels (the teachable training data)

    func insertLabel(contextDoc: String, ticket: String, kind: String) {
        let sql = "INSERT INTO labels(ts,context_doc,ticket,kind) VALUES(?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
        bindText(stmt, 2, contextDoc)
        bindText(stmt, 3, ticket)
        bindText(stmt, 4, kind)
        sqlite3_step(stmt)
    }

    /// Most recent labeled examples (capped) for the in-memory k-NN index, with their `kind`
    /// (`correction`/`training`/`backfill`) so the matcher can trust user labels over seeds.
    func allLabels(limit: Int = 3000) -> [(doc: String, ticket: String, kind: String)] {
        let sql = "SELECT context_doc,ticket,kind FROM labels ORDER BY ts DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [(String, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((colText(stmt, 0) ?? "", colText(stmt, 1) ?? "", colText(stmt, 2) ?? "correction"))
        }
        return out
    }

    // MARK: - One-time data hygiene (poison repair)

    /// Normalize/repair or drop poisoned ticket values in `labels`. `normalize` returns a clean
    /// key (kept/updated) or nil (row deleted). Returns (deleted, repaired).
    @discardableResult
    func sanitizeLabels(_ normalize: (String) -> String?) -> (deleted: Int, repaired: Int) {
        var rows: [(id: Int64, ticket: String)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id,ticket FROM labels;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), colText(stmt, 1) ?? ""))
            }
        }
        sqlite3_finalize(stmt)
        var deleted = 0, repaired = 0
        for r in rows {
            guard let clean = normalize(r.ticket) else {
                exec("DELETE FROM labels WHERE id=\(r.id);"); deleted += 1; continue
            }
            if clean != r.ticket {
                var u: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE labels SET ticket=? WHERE id=?;", -1, &u, nil) == SQLITE_OK {
                    bindText(u, 1, clean); sqlite3_bind_int64(u, 2, r.id); sqlite3_step(u)
                }
                sqlite3_finalize(u); repaired += 1
            }
        }
        return (deleted, repaired)
    }

    /// Normalize/repair or null out poisoned ticket values in `segments` (keeps the time record;
    /// only fixes the attribution). `normalize` nil → ticket+source cleared. Returns (nulled, repaired).
    @discardableResult
    func sanitizeSegmentTickets(_ normalize: (String) -> String?) -> (nulled: Int, repaired: Int) {
        var rows: [(id: Int64, ticket: String)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id,ticket FROM segments WHERE ticket IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), colText(stmt, 1) ?? ""))
            }
        }
        sqlite3_finalize(stmt)
        var nulled = 0, repaired = 0
        for r in rows {
            guard let clean = normalize(r.ticket) else {
                exec("UPDATE segments SET ticket=NULL, ticket_source=NULL WHERE id=\(r.id);"); nulled += 1; continue
            }
            if clean != r.ticket {
                var u: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE segments SET ticket=? WHERE id=?;", -1, &u, nil) == SQLITE_OK {
                    bindText(u, 1, clean); sqlite3_bind_int64(u, 2, r.id); sqlite3_step(u)
                }
                sqlite3_finalize(u); repaired += 1
            }
        }
        return (nulled, repaired)
    }

    // MARK: - Housekeeping / pruning

    /// Re-tag only the UNtracked (ticket IS NULL) active segments in [from,to).
    func retagUntracked(from: Date, to: Date, ticket: String) {
        let sql = "UPDATE segments SET ticket=?, ticket_source='manual' WHERE idle=0 AND ticket IS NULL AND start_ts>=? AND start_ts<?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, ticket)
        sqlite3_bind_int64(stmt, 2, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 3, Int64(to.timeIntervalSince1970))
        sqlite3_step(stmt)
    }

    /// Delete segments that ended before the given date.
    func deleteSegments(before: Date) {
        exec("DELETE FROM segments WHERE end_ts < \(Int64(before.timeIntervalSince1970));")
    }

    /// Delete segments starting within [from,to) — used to clean a boxed (submitted) day.
    func deleteSegments(from: Date, to: Date) {
        exec("DELETE FROM segments WHERE start_ts >= \(Int64(from.timeIntervalSince1970)) AND start_ts < \(Int64(to.timeIntervalSince1970));")
    }

    /// Dedupe identical (context, ticket) labels and cap to the most recent `max` (0 = no cap).
    func pruneLabels(max: Int) {
        exec("DELETE FROM labels WHERE id NOT IN (SELECT MAX(id) FROM labels GROUP BY context_doc, ticket);")
        if max > 0 {
            exec("DELETE FROM labels WHERE id NOT IN (SELECT id FROM labels ORDER BY ts DESC LIMIT \(max));")
        }
    }

    func labelCount() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM labels;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Reads

    /// All segments overlapping [start,end).
    func segments(from start: Date, to end: Date) -> [Segment] {
        let sql = "SELECT id,start_ts,end_ts,bundle_id,app_name,window_title,idle,ticket,ticket_source,category,confidence,context_doc,meeting FROM segments WHERE end_ts>? AND start_ts<? ORDER BY start_ts;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(end.timeIntervalSince1970))
        var out: [Segment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Segment(
                id: sqlite3_column_int64(stmt, 0),
                start: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                end: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2))),
                bundleId: colText(stmt, 3) ?? "",
                appName: colText(stmt, 4) ?? "",
                windowTitle: colText(stmt, 5) ?? "",
                idle: sqlite3_column_int(stmt, 6) != 0,
                ticket: colText(stmt, 7),
                ticketSource: colText(stmt, 8),
                category: colText(stmt, 9),
                confidence: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10),
                contextDoc: colText(stmt, 11),
                meeting: colText(stmt, 12)
            ))
        }
        return out
    }

    // MARK: - Period assignments (manual overrides for the floating-period compiler)

    func setPeriodAssignment(day: String, kind: String, ticketKey: String, ticket: String?, note: String?) {
        let sql = """
        INSERT INTO period_assignments(day,kind,ticket_key,ticket,note) VALUES(?,?,?,?,?)
        ON CONFLICT(day,kind,ticket_key) DO UPDATE SET ticket=excluded.ticket, note=excluded.note;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, day)
        bindText(stmt, 2, kind)
        bindText(stmt, 3, ticketKey)
        bindText(stmt, 4, ticket)
        bindText(stmt, 5, note)
        sqlite3_step(stmt)
    }

    /// All manually-saved periods for a day, for `PeriodCompiler.applySavedAssignments`'s exact
    /// (kind, ticket) lookup against a fresh compilation.
    func periodAssignments(day: String) -> [(kind: String, ticketKey: String, ticket: String?, note: String?)] {
        let sql = "SELECT kind,ticket_key,ticket,note FROM period_assignments WHERE day=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, day)
        var out: [(String, String, String?, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((
                colText(stmt, 0) ?? "regular",
                colText(stmt, 1) ?? "",
                colText(stmt, 2),
                colText(stmt, 3)
            ))
        }
        return out
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let v = value { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
}
