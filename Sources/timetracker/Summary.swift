import Foundation

/// Shared shape between `BlockReport` (fixed blocks) and `Period` (floating periods, see
/// PeriodCompiler.swift) so `Summary.describe(_:)`/`recap` work against either without duplicating
/// the "what dominated this stretch of time" logic.
protocol PeriodicReport {
    var byTicket: [(ticket: String?, seconds: Double)] { get }
    var byCategory: [(category: String?, seconds: Double)] { get }
}

struct BlockReport {
    var day: Date
    var dayString: String
    var block: String          // block id ("1"..."N")
    var label: String          // nominal clock window, e.g. "09:00–10:00"
    var start: Date
    var end: Date
    var activeSeconds: Double
    var idleSeconds: Double
    var byTicket: [(ticket: String?, seconds: Double)]   // sorted desc
    var byCategory: [(category: String?, seconds: Double)]
    var byApp: [(app: String, seconds: Double)]
    var assignedTicket: String?   // manual block_assignments override
    var assignedNote: String?
    // What the system inferred for this block (independent of any manual assignment), for the
    // review's "best guess / why" and to detect corrections for learning.
    var guessKey: String?
    var guessSource: String?
    var guessConfidence: Double?
    var contextDoc: String?       // representative (longest) segment's enriched context
    var recap: String?            // human recap of the work (repo · files · session · app)

    /// What the timesheet row should use: manual override, else dominant inferred ticket.
    var effectiveTicket: String? {
        if let a = assignedTicket, !a.isEmpty { return a }
        return byTicket.first(where: { $0.ticket != nil })?.ticket
    }

    var unknownActiveSeconds: Double {
        byTicket.first(where: { $0.ticket == nil })?.seconds ?? 0
    }

    var hasActivity: Bool { activeSeconds >= 60 }
}

extension BlockReport: PeriodicReport {}

/// Buckets segments into the two daily 4h blocks and produces timesheet output.
final class Summary {
    private let store: Store
    private let config: Config
    private let attribution: Attribution

    init(store: Store, config: Config, attribution: Attribution) {
        self.store = store
        self.config = config
        self.attribution = attribution
    }

    private func overlap(_ s: Segment, _ start: Date, _ end: Date) -> Double {
        let lo = max(s.start, start)
        let hi = min(s.end, end)
        return max(0, hi.timeIntervalSince(lo))
    }

    func report(day: Date, block: TimeBlocks.Block) -> BlockReport {
        let (bStart, bEnd) = (block.start, block.end)
        let segs = store.segments(from: bStart, to: bEnd)

        var ticketSecs: [String: Double] = [:]   // "" key == unknown
        var catSecs: [String: Double] = [:]
        var appSecs: [String: Double] = [:]
        var active = 0.0, idle = 0.0
        var repDoc: (dur: Double, doc: String)?
        var bestForTicket: [String: (dur: Double, source: String?, conf: Double?)] = [:]

        for s in segs {
            let dur = overlap(s, bStart, bEnd)
            if dur <= 0 { continue }
            if s.idle { idle += dur; continue }
            active += dur
            ticketSecs[s.ticket ?? "", default: 0] += dur
            catSecs[s.category ?? "", default: 0] += dur
            appSecs[s.appName, default: 0] += dur
            if let d = s.contextDoc, !d.isEmpty, dur > (repDoc?.dur ?? 0) { repDoc = (dur, d) }
            if let t = s.ticket, dur > (bestForTicket[t]?.dur ?? 0) {
                bestForTicket[t] = (dur, s.ticketSource, s.confidence)
            }
        }

        let byTicket = ticketSecs.sorted { $0.value > $1.value }
            .map { (ticket: $0.key.isEmpty ? nil : $0.key, seconds: $0.value) }
        let byCategory = catSecs.sorted { $0.value > $1.value }
            .map { (category: $0.key.isEmpty ? nil : $0.key, seconds: $0.value) }
        let byApp = appSecs.sorted { $0.value > $1.value }.map { (app: $0.key, seconds: $0.value) }

        let assignment = store.blockAssignment(day: TimeBlocks.dayString(day), block: block.id)
        let guessKey = byTicket.first(where: { $0.ticket != nil })?.ticket
        let best = guessKey.flatMap { bestForTicket[$0] }

        return BlockReport(
            day: day, dayString: TimeBlocks.dayString(day), block: block.id, label: block.label,
            start: bStart, end: bEnd, activeSeconds: active, idleSeconds: idle,
            byTicket: byTicket, byCategory: byCategory, byApp: byApp,
            assignedTicket: assignment?.ticket, assignedNote: assignment?.note,
            guessKey: guessKey, guessSource: best?.source, guessConfidence: best?.conf,
            contextDoc: repDoc?.doc, recap: repDoc.map { Self.recap(fromDoc: $0.doc, apps: byApp) })
    }

    /// Compact, human recap of a block's work for the review (so you remember what you did).
    static func recap(fromDoc doc: String, apps: [(app: String, seconds: Double)]) -> String {
        var parts: [String] = []
        for line in doc.split(separator: "\n") {
            if ["Repo:", "Editing:", "Changed files:", "AI session:"].contains(where: { line.hasPrefix($0) }) {
                parts.append(String(line.prefix(90)))
            }
        }
        if parts.isEmpty, let topApp = apps.first { parts.append("App: \(topApp.app)") }
        return parts.prefix(4).joined(separator: " · ")
    }

    /// Report for a block id (used by Tempo/assign paths that have only the id).
    func report(day: Date, blockId: String) -> BlockReport? {
        TimeBlocks.blocks(for: day, config).first { $0.id == blockId }.map { report(day: day, block: $0) }
    }

    func dayReports(_ day: Date) -> [BlockReport] {
        TimeBlocks.blocks(for: day, config).map { report(day: day, block: $0) }
    }

    /// Active, unticketed seconds in the block that currently contains `date`.
    /// Drives the real-time "unknown" prompt.
    func unknownActiveSeconds(inBlockContaining date: Date) -> Double {
        guard let block = TimeBlocks.block(for: date, config) else { return 0 }
        return report(day: date, block: block).unknownActiveSeconds
    }

    // MARK: - Text rendering

    static func hm(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return "\(m / 60)h\(String(format: "%02d", m % 60))"
    }

    /// Per-block duration label for the timesheet (e.g. "4h", "1h", "1.5h").
    var blockHoursLabel: String {
        let h = config.blockHours
        return h == h.rounded() ? "\(Int(h))h" : String(format: "%gh", h)
    }

    /// One-line description of what dominated a block/period (for the summary column).
    func describe(_ r: PeriodicReport) -> String {
        var bits: [String] = []
        for (ticket, secs) in r.byTicket.prefix(3) where secs >= 300 {
            if let t = ticket {
                let sum = attribution.summary(for: t).map { ": \($0)" } ?? ""
                bits.append("\(t)\(sum) (\(Summary.hm(secs)))")
            }
        }
        if bits.isEmpty {
            for (cat, secs) in r.byCategory.prefix(3) where secs >= 300 {
                bits.append("\(cat ?? "other") (\(Summary.hm(secs)))")
            }
        }
        return bits.isEmpty ? "(little activity)" : bits.joined(separator: ", ")
    }

    /// Append fixed 4h rows for a day to ~/timesheet-log.md, matching CLAUDE.md format.
    /// Returns the rows written (for echoing to the user).
    @discardableResult
    func appendTimesheet(day: Date) -> [String] {
        let dur = blockHoursLabel
        var rows: [String] = []
        for r in dayReports(day) where r.hasActivity {
            let ticket = r.effectiveTicket ?? "—"
            let summary = r.assignedNote ?? describe(r)
            rows.append("| \(r.dayString) | \(ticket) | \(dur) | \(summary) |")
        }
        return Self.writeTimesheetRows(rows, day: day)
    }

    /// `appendTimesheet(day:)`'s counterpart for the floating-period model: one row per period,
    /// using its own real (rounded/padded) duration instead of the fixed `blockHoursLabel`.
    @discardableResult
    func appendTimesheet(periods: [Period], day: Date) -> [String] {
        let dayStr = TimeBlocks.dayString(day)
        var rows: [String] = []
        for p in periods where p.hasActivity {
            let ticket = p.effectiveTicket ?? "—"
            let summary = p.assignedNote ?? describe(p)
            rows.append("| \(dayStr) | \(ticket) | \(Summary.hm(p.reportedSeconds)) | \(summary) |")
        }
        return Self.writeTimesheetRows(rows, day: day)
    }

    @discardableResult
    private static func writeTimesheetRows(_ rows: [String], day: Date) -> [String] {
        guard !rows.isEmpty else { return [] }
        let header = "\n<!-- timetracker \(TimeBlocks.dayString(day)) -->\n"
        let blob = header + rows.joined(separator: "\n") + "\n"
        let url = AppPaths.timesheetLog
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(blob.data(using: .utf8)!); try? fh.close()
        } else {
            try? blob.write(to: url, atomically: true, encoding: .utf8)
        }
        return rows
    }
}
