import Foundation

/// A carved-out or floating chunk of a day, replacing `TimeBlocks.Block` for Review/Submit.
/// See `PeriodCompiler` for how these are built.
enum PeriodKind: String, Codable, CaseIterable {
    case regular, daily, breakPeriod, codeReview, meeting
}

struct Period: Identifiable {
    var seq: Int                   // stable per-day id — see PeriodCompiler.matchSeqs
    var kind: PeriodKind
    var start: Date
    var end: Date
    /// Exact contributing (segment, clipped-duration) pairs — not re-derived from (start,end), so
    /// a floating regular block's skipped-over carve-outs are never double-counted downstream.
    var members: [(segment: Segment, seconds: Double)]
    var trueSeconds: Double        // real tracked time, never altered
    var reportedSeconds: Double    // rounded/clamped/padded value actually exported/submitted
    var ticket: String?
    var guessSource: String?
    var guessConfidence: Double?
    var assignedTicket: String?    // manual period_assignments override
    var assignedNote: String?
    var byTicket: [(ticket: String?, seconds: Double)]
    var byCategory: [(category: String?, seconds: Double)]
    var contextDoc: String?
    var recap: String?

    var id: String { String(seq) }
    var effectiveTicket: String? {
        if let a = assignedTicket, !a.isEmpty { return a }
        return ticket
    }
    var hasActivity: Bool { trueSeconds >= 60 }
}

extension Period: PeriodicReport {}

/// Builds a day's `[Period]` from its stored segments: carves out code-review (already tagged live
/// by the PR-review feature), meeting/daily, and a fixed break, then floats the remaining active
/// time into `blockHours`-sized regular blocks. Retrospective/batch only — real-time nudges and
/// `AssignView` keep using the fixed `TimeBlocks` model (see CLAUDE.md).
enum PeriodCompiler {
    static func compile(day: Date, config: Config, store: Store, attribution: Attribution, ollama: Ollama) async -> [Period] {
        var periods = compileSync(day: day, config: config, store: store, attribution: attribution)
        periods = await resolveMeetingTickets(periods, config: config, attribution: attribution, ollama: ollama)
        periods = matchSeqs(periods, day: day, store: store)
        applyRoundingAndPadding(&periods, day: day, config: config)
        return periods.sorted { $0.start < $1.start }
    }

    // MARK: - Pure, synchronous core (no network — dumpable/testable standalone)

    static func compileSync(day: Date, config: Config, store: Store, attribution: Attribution) -> [Period] {
        let (dayStart, dayEnd) = TimeBlocks.dayBounds(day)
        let allSegs = store.segments(from: dayStart, to: dayEnd)
        let mergeGap = config.periodMergeGapMinutes * 60
        let (bStart, bEnd) = breakBounds(day: day, config: config)

        // Seconds of `s` OUTSIDE the fixed break window — the break wins outright over whatever
        // else was happening in that slot (clip, don't reclassify), per requirement #6.
        func usable(_ s: Segment) -> Double {
            let overlapStart = max(s.start, bStart)
            let overlapEnd = min(s.end, bEnd)
            return max(0, s.duration - max(0, overlapEnd.timeIntervalSince(overlapStart)))
        }

        var periods: [Period] = []

        // 1. Break — fixed injection, unconditional (req. #6), not detected from an idle gap.
        periods.append(Period(
            seq: 0, kind: .breakPeriod, start: bStart, end: bEnd, members: [],
            trueSeconds: config.breakDurationMinutes * 60, reportedSeconds: config.breakDurationMinutes * 60,
            ticket: config.breakTicket.isEmpty ? nil : config.breakTicket, guessSource: "break-fixed",
            guessConfidence: nil, assignedTicket: nil, assignedNote: nil, byTicket: [], byCategory: [], contextDoc: nil, recap: "Break"))

        // 2. Code review — segments already tagged live (ticketSource == "prReview") by the
        // existing PR-review feature. No new detection: group into runs, keep the run's own ticket.
        let crSegs = allSegs.filter { !$0.idle && $0.ticketSource == "prReview" && usable($0) > 0 }
        for run in groupRuns(crSegs, mergeGapSeconds: mergeGap) {
            let members = run.map { ($0, usable($0)) }
            let ticket = run.first(where: { $0.ticket != nil })?.ticket
            periods.append(makePeriod(kind: .codeReview, start: run.first!.start, end: run.last!.end,
                                       members: members, ticket: ticket, guessSource: "period-cr"))
        }

        // 3. Meeting / daily — segments carrying a meeting label, excluding ones already claimed
        // by code review above (a segment can't be both).
        let meetingSegs = allSegs.filter { !$0.idle && $0.ticketSource != "prReview" && $0.meeting != nil && usable($0) > 0 }
        for run in groupRuns(meetingSegs, mergeGapSeconds: mergeGap) {
            let members = run.map { ($0, usable($0)) }
            let label = members.max(by: { $0.1 < $1.1 })?.0.meeting ?? ""
            let isDaily = !config.dailyStandupTitleMatch.isEmpty
                && label.range(of: config.dailyStandupTitleMatch, options: .caseInsensitive) != nil
            if isDaily {
                periods.append(makePeriod(kind: .daily, start: run.first!.start, end: run.last!.end, members: members,
                                           ticket: config.dailyStandupTicket.isEmpty ? nil : config.dailyStandupTicket,
                                           guessSource: "daily-fixed"))
            } else {
                // Ticket resolved in the async pass (Ollama), if enabled — abstain otherwise.
                periods.append(makePeriod(kind: .meeting, start: run.first!.start, end: run.last!.end,
                                           members: members, ticket: nil, guessSource: nil))
            }
        }

        // 4. Regular — everything else, floated into blockHours-sized buckets (req. #1/#2).
        let regularSegs = allSegs.filter { !$0.idle && $0.ticketSource != "prReview" && $0.meeting == nil }
        periods += floatingRegularBlocks(regularSegs, usable: usable, config: config, attribution: attribution)

        return periods
    }

    private static func breakBounds(day: Date, config: Config) -> (start: Date, end: Date) {
        let sod = TimeBlocks.calendar.startOfDay(for: day)
        let start = sod.addingTimeInterval(config.breakStartHour * 3600)
        return (start, start.addingTimeInterval(config.breakDurationMinutes * 60))
    }

    /// Groups already-sorted (by start) segments into maximal runs: a new run starts whenever the
    /// gap since the previous member's end exceeds `mergeGapSeconds`, so a brief interruption
    /// doesn't split what's really one continuous session.
    private static func groupRuns(_ filtered: [Segment], mergeGapSeconds: Double) -> [[Segment]] {
        guard !filtered.isEmpty else { return [] }
        var runs: [[Segment]] = [[filtered[0]]]
        for s in filtered.dropFirst() {
            if s.start.timeIntervalSince(runs[runs.count - 1].last!.end) <= mergeGapSeconds {
                runs[runs.count - 1].append(s)
            } else {
                runs.append([s])
            }
        }
        return runs
    }

    /// Shared field aggregation (byTicket/contextDoc/recap) for every period built from real
    /// segments — mirrors `Summary.report`'s per-block aggregation.
    private static func makePeriod(kind: PeriodKind, start: Date, end: Date,
                                    members: [(segment: Segment, seconds: Double)],
                                    ticket: String?, guessSource: String?, guessConfidence: Double? = nil) -> Period {
        var ticketSecs: [String: Double] = [:]
        var catSecs: [String: Double] = [:]
        var appSecs: [String: Double] = [:]
        var repDoc: (dur: Double, doc: String)?
        for (s, secs) in members {
            ticketSecs[s.ticket ?? "", default: 0] += secs
            catSecs[s.category ?? "", default: 0] += secs
            appSecs[s.appName, default: 0] += secs
            if let d = s.contextDoc, !d.isEmpty, secs > (repDoc?.dur ?? 0) { repDoc = (secs, d) }
        }
        let byTicket = ticketSecs.sorted { $0.value > $1.value }.map { (ticket: $0.key.isEmpty ? nil : $0.key, seconds: $0.value) }
        let byCategory = catSecs.sorted { $0.value > $1.value }.map { (category: $0.key.isEmpty ? nil : $0.key, seconds: $0.value) }
        let byApp = appSecs.sorted { $0.value > $1.value }.map { (app: $0.key, seconds: $0.value) }
        let trueSeconds = members.reduce(0) { $0 + $1.seconds }
        return Period(seq: 0, kind: kind, start: start, end: end, members: members,
                      trueSeconds: trueSeconds, reportedSeconds: trueSeconds, ticket: ticket,
                      guessSource: guessSource, guessConfidence: guessConfidence,
                      assignedTicket: nil, assignedNote: nil, byTicket: byTicket, byCategory: byCategory,
                      contextDoc: repDoc?.doc, recap: repDoc.map { Summary.recap(fromDoc: $0.doc, apps: byApp) })
    }

    /// Walks segments in order, accumulating USABLE (non-break, non-idle) seconds; once adding a
    /// whole segment would exceed `blockHours`, that segment starts the next bucket instead —
    /// buckets can overshoot by at most one segment's worth, a deliberate simplicity tradeoff since
    /// the floating boundary itself has no user-facing significance (unlike non-regular periods,
    /// which DO have a strict rounding/minimum rule).
    private static func floatingRegularBlocks(_ segs: [Segment], usable: (Segment) -> Double,
                                               config: Config, attribution: Attribution) -> [Period] {
        let blockSeconds = config.blockHours * 3600
        var periods: [Period] = []
        var bucket: [(segment: Segment, seconds: Double)] = []
        var bucketSeconds: Double = 0

        func flush() {
            guard !bucket.isEmpty else { return }
            var p = makePeriod(kind: .regular, start: bucket.first!.segment.start, end: bucket.last!.segment.end,
                                members: bucket, ticket: nil, guessSource: nil)
            p.ticket = scoreRegularTicket(bucket, config: config, attribution: attribution)
            if p.ticket != nil { p.guessSource = "period-regular" }
            periods.append(p)
            bucket = []; bucketSeconds = 0
        }

        for s in segs {
            let secs = usable(s)
            guard secs > 0 else { continue }
            if blockSeconds > 0, bucketSeconds > 0, bucketSeconds + secs > blockSeconds { flush() }
            bucket.append((s, secs))
            bucketSeconds += secs
        }
        flush()
        return periods
    }

    /// "Mix of both" (requirement #2): duration-dominance plus explicit ticket-key mentions in the
    /// bucket's own titles/context, gated to tickets assigned to the user AND actively in progress.
    /// Scoped to keys already resolved on some segment in the bucket — not a corpus-wide sweep.
    private static func scoreRegularTicket(_ bucket: [(segment: Segment, seconds: Double)],
                                           config: Config, attribution: Attribution) -> String? {
        var durationByKey: [String: Double] = [:]
        for (s, secs) in bucket {
            guard let t = s.ticket, !t.isEmpty else { continue }
            durationByKey[t, default: 0] += secs
        }
        guard !durationByKey.isEmpty else { return nil }
        var best: (key: String, score: Double)?
        for key in durationByKey.keys {
            guard let t = attribution.tickets(for: [key]).first,
                  t.assignedToMe, t.isInProgressLike(preferredStates: config.preferredTicketStatesLower)
            else { continue }
            var mentions = 0
            for (s, _) in bucket {
                let hay = "\(s.windowTitle) \(s.contextDoc ?? "")"
                if hay.range(of: key, options: .caseInsensitive) != nil { mentions += 1 }
            }
            let score = durationByKey[key]! + Double(mentions) * config.periodMentionWeightSeconds
            if best == nil || score > best!.score { best = (key, score) }
        }
        return best?.key
    }

    // MARK: - Async pass: guess a ticket for meeting periods that don't already have one

    private static func resolveMeetingTickets(_ periods: [Period], config: Config,
                                               attribution: Attribution, ollama: Ollama) async -> [Period] {
        guard config.ollamaEnabled else { return periods }
        let candidates = Array(attribution.sprint.filter {
            $0.assignedToMe && $0.isInProgressLike(preferredStates: config.preferredTicketStatesLower)
        }.prefix(12))
        guard !candidates.isEmpty else { return periods }

        var out = periods
        for i in out.indices where out[i].kind == .meeting && out[i].ticket == nil {
            let digest = meetingDigest(out[i])
            guard !digest.isEmpty,
                  let s = await ollama.suggest(arc: "", current: digest, candidates: candidates, previous: nil)
            else { continue }
            if s.key.caseInsensitiveCompare(config.noTicketLabel) == .orderedSame { continue }
            out[i].ticket = s.key
            out[i].guessSource = "period-meeting-llm"
            out[i].guessConfidence = s.confidence
        }
        return out
    }

    private static func meetingDigest(_ p: Period) -> String {
        var lines: [String] = []
        if let label = p.members.max(by: { $0.seconds < $1.seconds })?.segment.meeting {
            lines.append("Meeting: \(label)")
        }
        let appSecs = Dictionary(grouping: p.members, by: { $0.segment.appName })
            .mapValues { $0.reduce(0.0) { $0 + $1.seconds } }
            .sorted { $0.value > $1.value }
        for (app, secs) in appSecs.prefix(3) { lines.append("App: \(app) (\(Int(secs))s)") }
        if let doc = p.contextDoc, !doc.isEmpty { lines.append(String(doc.prefix(400))) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Seq stability

    /// A day's period shape is data-dependent (a segment gets re-tagged, more activity accrues
    /// between two compiles), so a naive positional `seq` would silently break worklog-id/
    /// period_assignments continuity. Greedily match each fresh period to an unconsumed saved row
    /// of the same kind with a close start (within 10 min), reusing its seq + manual override;
    /// unmatched periods get a brand-new, append-only seq (never reused/decremented).
    private static func matchSeqs(_ periods: [Period], day: Date, store: Store) -> [Period] {
        var existing = store.periodAssignments(day: TimeBlocks.dayString(day))
        var out = periods.sorted { $0.start < $1.start }
        var nextSeq = (existing.map { $0.seq }.max() ?? -1) + 1
        let tolerance: TimeInterval = 600
        for i in out.indices {
            if let idx = existing.firstIndex(where: {
                $0.kind == out[i].kind.rawValue && abs($0.start.timeIntervalSince(out[i].start)) <= tolerance
            }) {
                let row = existing.remove(at: idx)
                out[i].seq = row.seq
                out[i].assignedTicket = row.ticket
                out[i].assignedNote = row.note
            } else {
                out[i].seq = nextSeq
                nextSeq += 1
            }
        }
        return out
    }

    // MARK: - Rounding (non-regular only) + shortfall padding

    private static func applyRoundingAndPadding(_ periods: inout [Period], day: Date, config: Config) {
        let roundTo = max(1, config.periodRoundMinutes * 60)
        let minSeconds = config.periodMinMinutes * 60
        for i in periods.indices {
            guard periods[i].kind != .regular else { periods[i].reportedSeconds = periods[i].trueSeconds; continue }
            let rounded = (periods[i].trueSeconds / roundTo).rounded() * roundTo
            periods[i].reportedSeconds = max(minSeconds, rounded)
        }

        let target = TimeBlocks.dailyTargetSeconds(day, config)
        let total = periods.reduce(0.0) { $0 + $1.reportedSeconds }
        let shortfall = target - total
        guard shortfall > 0 else { return }   // overtime: never trim (req. #9)

        let regularWithTicket = periods.indices.filter { periods[$0].kind == .regular && periods[$0].effectiveTicket != nil }
        guard let topIdx = regularWithTicket.max(by: { periods[$0].trueSeconds < periods[$1].trueSeconds }) else { return }
        periods[topIdx].reportedSeconds += shortfall
    }
}
