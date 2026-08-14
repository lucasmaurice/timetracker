import Foundation

struct Slice: Identifiable {
    var label: String
    var seconds: Double
    var id: String { label }
    var hours: Double { seconds / 3600 }
}

struct TimelineSeg: Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var label: String
    var category: String?
}

struct DaySlice: Identifiable {
    var day: String
    var ticket: String
    var hours: Double
    var id: String { "\(day)|\(ticket)" }
}

struct CoveragePoint: Identifiable {
    var day: String
    var coverage: Double   // 0–1
    var id: String { day }
}

/// Everything the dashboard renders. Same underlying data as the MD export, plus
/// AI-quality metrics, computed on demand for instant lookup.
struct DashboardData {
    var todayByTicket: [Slice] = []
    var todayByCategory: [Slice] = []
    var blocks: [BlockReport] = []
    var timeline: [TimelineSeg] = []
    var historical: [DaySlice] = []
    var coverageTrend: [CoveragePoint] = []

    // AI quality
    var sourceMix: [Slice] = []
    var coverageToday: Double = 0
    var exactnessToday: Double = 0
    var avgGuessConfidence: Double = 0
    var confidenceBuckets: [Slice] = []
    var activeHoursToday: Double = 0
}

final class DashboardBuilder {
    private let store: Store
    private let summary: Summary
    private let config: Config

    /// Sources that are exact/explicit (vs. a guess).
    static let exactSources: Set<String> = ["url", "branch", "title", "commit", "session", "learned", "manual"]
    static let guessSources: Set<String> = ["semantic", "embed", "llm"]

    init(store: Store, summary: Summary, config: Config) {
        self.store = store
        self.summary = summary
        self.config = config
    }

    private func clip(_ s: Segment, _ a: Date, _ b: Date) -> Double {
        max(0, min(s.end, b).timeIntervalSince(max(s.start, a)))
    }

    func build(historyDays: Int = 10) -> DashboardData {
        var d = DashboardData()
        let now = Date()
        let (dayStart, dayEnd) = TimeBlocks.dayBounds(now)
        let today = store.segments(from: dayStart, to: dayEnd)
        let active = today.filter { !$0.idle }

        // Today by ticket / category.
        d.todayByTicket = group(active, by: { $0.ticket ?? "untracked" }, in: dayStart, end: dayEnd)
        d.todayByCategory = group(active, by: { $0.category ?? "other" }, in: dayStart, end: dayEnd)
        d.activeHoursToday = active.reduce(0) { $0 + clip($1, dayStart, dayEnd) } / 3600

        // Expected timesheet blocks (AM/PM) + timeline strip.
        d.blocks = summary.dayReports(now)
        d.timeline = active.filter { clip($0, dayStart, dayEnd) >= 30 }.map {
            TimelineSeg(start: max($0.start, dayStart), end: min($0.end, dayEnd),
                        label: $0.ticket ?? ($0.category ?? "?"), category: $0.category)
        }

        // AI quality (today).
        let attributed = active.filter { $0.ticket != nil }
        let activeSecs = active.reduce(0) { $0 + clip($1, dayStart, dayEnd) }
        let attribSecs = attributed.reduce(0) { $0 + clip($1, dayStart, dayEnd) }
        let exactSecs = attributed.filter { Self.exactSources.contains($0.ticketSource ?? "") }
            .reduce(0) { $0 + clip($1, dayStart, dayEnd) }
        d.coverageToday = activeSecs > 0 ? attribSecs / activeSecs : 0
        d.exactnessToday = attribSecs > 0 ? exactSecs / attribSecs : 0

        var srcSecs: [String: Double] = [:]
        for s in active {
            let group = s.ticket == nil ? "none"
                : (Self.exactSources.contains(s.ticketSource ?? "") ? "exact" : "guess")
            srcSecs[group, default: 0] += clip(s, dayStart, dayEnd)
        }
        d.sourceMix = srcSecs.map { Slice(label: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }

        let guesses = active.filter { Self.guessSources.contains($0.ticketSource ?? "") && $0.confidence != nil }
        let confs = guesses.compactMap { $0.confidence }
        d.avgGuessConfidence = confs.isEmpty ? 0 : confs.reduce(0, +) / Double(confs.count)
        var buckets: [String: Double] = [:]
        for c in confs {
            let lo = (c * 10).rounded(.down) / 10
            buckets[String(format: "%.1f", lo), default: 0] += 1
        }
        d.confidenceBuckets = buckets.map { Slice(label: $0.key, seconds: $0.value) }.sorted { $0.label < $1.label }

        // Historical: last N days, hours by ticket (top 6 + Other) + coverage trend.
        for offset in stride(from: historyDays - 1, through: 0, by: -1) {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
            let (s, e) = TimeBlocks.dayBounds(day)
            let segs = store.segments(from: s, to: e).filter { !$0.idle }
            let label = String(TimeBlocks.dayString(day).suffix(5))  // MM-dd
            var byTicket: [String: Double] = [:]
            var act = 0.0, attr = 0.0
            for seg in segs {
                let dur = clip(seg, s, e); act += dur
                if let t = seg.ticket { byTicket[t, default: 0] += dur; attr += dur }
            }
            let top = byTicket.sorted { $0.value > $1.value }
            for (i, kv) in top.enumerated() {
                let key = i < 6 ? kv.key : "Other"
                d.historical.append(DaySlice(day: label, ticket: key, hours: kv.value / 3600))
            }
            d.coverageTrend.append(CoveragePoint(day: label, coverage: act > 0 ? attr / act : 0))
        }
        return d
    }

    private func group(_ segs: [Segment], by key: (Segment) -> String, in a: Date, end b: Date) -> [Slice] {
        var m: [String: Double] = [:]
        for s in segs { m[key(s), default: 0] += clip(s, a, b) }
        return m.map { Slice(label: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }
}
