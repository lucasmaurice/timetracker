import Foundation

/// A day's time, grouped by ticket — replacing `TimeBlocks.Block` for Review/Submit. Exact
/// start/stop clock times aren't tracked as meaningful data (only used internally to scope a
/// day's segment query and as a worklog `date`/`startTime` formality); what matters is how much
/// time landed on which ticket. See `PeriodCompiler` for how these are built.
enum PeriodKind: String, Codable, CaseIterable {
    case regular, daily, breakPeriod, codeReview, meeting
}

struct Period: Identifiable {
    var kind: PeriodKind
    var start: Date
    var end: Date
    /// Exact contributing (segment, clipped-duration) pairs — not re-derived from (start,end).
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

    /// `(kind, ticket)` is the day's natural identity now that time is grouped by ticket rather
    /// than by clock position — see `PeriodCompiler.applySavedAssignments`.
    var id: String { "\(kind.rawValue)|\(ticket ?? "")" }
    var effectiveTicket: String? {
        if let a = assignedTicket, !a.isEmpty { return a }
        return ticket
    }
    var hasActivity: Bool { trueSeconds >= 60 }
}

extension Period: PeriodicReport {}

/// Builds a day's `[Period]` from its stored segments: regular work and code-review time are
/// totaled per ticket (each segment already carries its own live-resolved `ticket`/`ticketSource`
/// — no synthetic time-bucketing needed), while daily-standup/break/meeting are carved out as
/// their own entries. Retrospective/batch only — real-time nudges and `AssignView` keep using the
/// fixed `TimeBlocks` model (see CLAUDE.md).
///
/// **`@MainActor` is load-bearing, not decoration.** This reads `Store` and — once per segment via
/// the regular gate — `Attribution.sprint`, a plain `[Ticket]` that `reloadSprint()` and
/// `cachePRReviewTicket()` mutate on main. A plain `nonisolated async` func hops to the global
/// cooperative pool (tools 5.9 = Swift 5 mode, so strict concurrency checking will NOT flag it and
/// a clean build proves nothing), which races those mutations — a real crash. Keep the isolation;
/// the sync core is cheap and the only genuine suspension is the Ollama call.
@MainActor
enum PeriodCompiler {
    static func compile(day: Date, config: Config, store: Store, attribution: Attribution, ollama: Ollama) async -> [Period] {
        var periods = compileSync(day: day, config: config, store: store, attribution: attribution)
        periods = await resolveMeetingTickets(periods, config: config, attribution: attribution, ollama: ollama)
        periods = mergeByTicket(periods)
        periods = applySavedAssignments(periods, day: day, store: store)
        applyRoundingAndPadding(&periods, day: day, config: config)
        return sortForDisplay(periods)
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
            kind: .breakPeriod, start: bStart, end: bEnd, members: [],
            trueSeconds: config.breakDurationMinutes * 60, reportedSeconds: config.breakDurationMinutes * 60,
            ticket: config.breakTicket.isEmpty ? nil : config.breakTicket, guessSource: "break-fixed",
            guessConfidence: nil, assignedTicket: nil, assignedNote: nil, byTicket: [], byCategory: [], contextDoc: nil, recap: "Break"))

        // 2. Code review — segments already tagged live (ticketSource == "prReview") by the
        // existing PR-review feature, including ones the live resolver checked and found no linked
        // work item for (ticket nil, source still "prReview" — see Attribution.cachePRReviewTicket).
        // Totaled per ticket for the whole day; a PR with no linked ticket falls back to the
        // configured generic-code-review ticket instead of silently abstaining.
        let crSegs = allSegs.filter { !$0.idle && $0.ticketSource == "prReview" && usable($0) > 0 }
        for (ticket, members) in groupByTicket(crSegs, usable: usable) {
            let finalTicket = ticket ?? (config.genericCodeReviewTicket.isEmpty ? nil : config.genericCodeReviewTicket)
            periods.append(makePeriod(kind: .codeReview, members: members, ticket: finalTicket, guessSource: "period-cr"))
        }

        // 3. Meeting / daily — segments carrying a meeting label. Still needs time-proximity
        // session grouping (unlike regular/CR below): a meeting's ticket isn't already known
        // per-segment, so distinct sessions must be identified before asking Ollama once per
        // session — merged back together by ticket afterward (see `mergeByTicket`, called once
        // the async pass below has resolved them).
        let meetingSegs = allSegs.filter { !$0.idle && $0.ticketSource != "prReview" && $0.meeting != nil && usable($0) > 0 }
        for run in groupRuns(meetingSegs, mergeGapSeconds: mergeGap) {
            let members = run.map { ($0, usable($0)) }
            let label = members.max(by: { $0.1 < $1.1 })?.0.meeting ?? ""
            let isDaily = !config.dailyStandupTitleMatch.isEmpty
                && label.range(of: config.dailyStandupTitleMatch, options: .caseInsensitive) != nil
            if isDaily {
                periods.append(makePeriod(kind: .daily, members: members,
                                           ticket: config.dailyStandupTicket.isEmpty ? nil : config.dailyStandupTicket,
                                           guessSource: "daily-fixed"))
            } else {
                // Ticket resolved in the async pass (Ollama), if enabled — abstain otherwise.
                periods.append(makePeriod(kind: .meeting, members: members, ticket: nil, guessSource: nil))
            }
        }

        // 4. Regular — everything else, totaled per ticket for the day (requirement #2's "most
        // mentioned" is now literally "which ticket did the live per-moment pipeline actually
        // resolve, summed over the day" — richer than a synthetic bucket-level re-score, since
        // live attribution already sees lexical/memory/repo/embedding/LLM signals per moment).
        // Gated to assignedToMe + isInProgressLike; ungated/untracked time pools into one
        // unticketed "regular" entry rather than each losing its own identity silently.
        let regularSegs = allSegs.filter { !$0.idle && $0.ticketSource != "prReview" && $0.meeting == nil }
        let gate: (String) -> Bool = { key in
            guard let t = attribution.tickets(for: [key]).first else { return false }
            return t.assignedToMe && t.isInProgressLike(preferredStates: config.preferredTicketStatesLower)
        }
        for (ticket, members) in groupByTicket(regularSegs, usable: usable, gate: gate) {
            periods.append(makePeriod(kind: .regular, members: members, ticket: ticket,
                                       guessSource: ticket != nil ? "period-regular" : nil))
        }

        return periods
    }

    private static func breakBounds(day: Date, config: Config) -> (start: Date, end: Date) {
        let sod = TimeBlocks.calendar.startOfDay(for: day)
        let start = sod.addingTimeInterval(config.breakStartHour * 3600)
        return (start, start.addingTimeInterval(config.breakDurationMinutes * 60))
    }

    /// Groups segments by their own `ticket` field across the WHOLE day (no time-bucketing) —
    /// each distinct ticket becomes one group. `gate`, when supplied, redirects a segment whose
    /// ticket fails it into the unticketed ("") group instead of dropping it outright, so gated-out
    /// time still shows up as reviewable/assignable rather than silently vanishing.
    private static func groupByTicket(_ segs: [Segment], usable: (Segment) -> Double,
                                       gate: ((String) -> Bool)? = nil) -> [(ticket: String?, members: [(segment: Segment, seconds: Double)])] {
        var byKey: [String: [(segment: Segment, seconds: Double)]] = [:]
        var order: [String] = []
        for s in segs {
            let secs = usable(s)
            guard secs > 0 else { continue }
            var key = s.ticket ?? ""
            if let gate, !key.isEmpty, !gate(key) { key = "" }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append((s, secs))
        }
        return order.map { key in (ticket: key.isEmpty ? nil : key, members: byKey[key]!) }
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
    /// segments — mirrors `Summary.report`'s per-block aggregation. `start`/`end` are derived from
    /// the member span purely as bookkeeping (worklog date/startTime formality) — not meaningful
    /// display data for a day-total period.
    private static func makePeriod(kind: PeriodKind, members: [(segment: Segment, seconds: Double)],
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
        let start = members.map { $0.segment.start }.min() ?? Date()
        let end = members.map { $0.segment.end }.max() ?? start
        return Period(kind: kind, start: start, end: end, members: members,
                      trueSeconds: trueSeconds, reportedSeconds: trueSeconds, ticket: ticket,
                      guessSource: guessSource, guessConfidence: guessConfidence,
                      assignedTicket: nil, assignedNote: nil, byTicket: byTicket, byCategory: byCategory,
                      contextDoc: repDoc?.doc, recap: repDoc.map { Summary.recap(fromDoc: $0.doc, apps: byApp) })
    }

    // MARK: - Async pass: guess a ticket for meeting sessions that don't already have one

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

    /// Collapses periods sharing the same `(kind, ticket)` into one — a no-op for regular/code
    /// review (already grouped uniquely by construction), but what lets multiple meeting sessions
    /// that Ollama resolved to the same ticket (or multiple daily-standup sessions) merge into a
    /// single day-total row.
    private static func mergeByTicket(_ periods: [Period]) -> [Period] {
        var groups: [String: [Period]] = [:]
        var order: [String] = []
        for p in periods {
            let key = p.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        return order.map { key in
            let group = groups[key]!
            guard group.count > 1 else { return group[0] }
            let guessSource = group.first(where: { $0.guessSource != nil })?.guessSource
            let guessConfidence = group.compactMap { $0.guessConfidence }.max()
            return makePeriod(kind: group[0].kind, members: group.flatMap { $0.members },
                              ticket: group[0].ticket, guessSource: guessSource, guessConfidence: guessConfidence)
        }
    }

    /// A period's identity is now exactly `(kind, ticket)` — an exact lookup, not the fuzzy
    /// time-window matching a clock-based model would need. Loading a saved override no longer
    /// risks drifting onto the wrong period as the day's segment data evolves between compiles.
    private static func applySavedAssignments(_ periods: [Period], day: Date, store: Store) -> [Period] {
        let existing = Dictionary(uniqueKeysWithValues: store.periodAssignments(day: TimeBlocks.dayString(day))
            .map { ("\($0.kind)|\($0.ticketKey)", $0) })
        return periods.map { p in
            var p = p
            if let row = existing[p.id] {
                p.assignedTicket = row.ticket
                p.assignedNote = row.note
            }
            return p
        }
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

    // MARK: - Display order

    /// No clock times to sort by anymore — order by kind (your actual ticket work first, fixed
    /// carve-outs after), then by how much time within each kind, so the biggest/most relevant
    /// entries lead.
    private static let kindOrder: [PeriodKind: Int] = [.regular: 0, .codeReview: 1, .meeting: 2, .daily: 3, .breakPeriod: 4]
    private static func sortForDisplay(_ periods: [Period]) -> [Period] {
        periods.sorted { a, b in
            let ka = kindOrder[a.kind] ?? 99, kb = kindOrder[b.kind] ?? 99
            return ka != kb ? ka < kb : a.trueSeconds > b.trueSeconds
        }
    }
}
