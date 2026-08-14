import Foundation

/// Headless measurement harness (`timetracker --eval`): makes "is the guesser good?" a number
/// instead of a vibe. Reports (1) timesheet coverage from stored segments, (2) the mined
/// repo→ticket bridge, and (3) leave-one-out ranking accuracy of the deterministic text guesser
/// over the labeled examples. Read-only; never starts the menu-bar app.
enum EvalHarness {
    static func run() {
        let config = Config.load()
        let store = Store()
        let attribution = Attribution(config: config, store: store)
        FileHandle.standardError.write("Mining git history for the repo→ticket bridge…\n".data(using: .utf8)!)
        attribution.rebuildRepoBridge()
        attribution.reloadMemory()

        print("══════════════════════════════════════════════════════════════")
        print(" TimeTracker guesser evaluation")
        print("══════════════════════════════════════════════════════════════")
        coverageReport(store: store, config: config)
        repoBridgeReport(attribution: attribution)
        repoBacktest(attribution: attribution)
        segmentReplay(store: store, attribution: attribution)
        labelAccuracy(store: store, attribution: attribution)
    }

    // MARK: - Segment replay (real contexts you confirmed)

    /// Replay the guesser over historical segments that (a) carry the rich context document and
    /// (b) have a user-confirmed ticket — the gold standard for "did the guess match the truth?".
    /// Only meaningful for segments captured after context persistence was added.
    private static func segmentReplay(store: Store, attribution: Attribution) {
        let now = Date()
        let segs = store.segments(from: now.addingTimeInterval(-60 * 86400), to: now)
            .filter { !$0.idle && ($0.contextDoc?.isEmpty == false) }
        let confirmed = segs.filter { $0.ticket != nil && ($0.ticketSource == "manual" || $0.ticketSource == "learned") }
        print("\n── Segment replay (your confirmed contexts) ──────────────────")
        guard confirmed.count >= 5 else {
            print("  \(confirmed.count) confirmed segment(s) with rich context so far — accrues as you")
            print("  correct guesses (older segments predate context capture).")
            return
        }
        var top1 = 0, top3 = 0
        for s in confirmed {
            let r = attribution.evaluateDoc(s.contextDoc!, trueTicket: s.ticket!)
            if r.top1 { top1 += 1 }; if r.top3 { top3 += 1 }
        }
        let n = Double(confirmed.count)
        print(String(format: "  %d confirmed contexts: guess matched top-1 %.0f%%, top-3 %.0f%%",
                     confirmed.count, 100 * Double(top1) / n, 100 * Double(top3) / n))
    }

    // MARK: - Temporal backtest (leakage-free repo-signal accuracy)

    private static func repoBacktest(attribution: Attribution) {
        print("\n── Repo-signal temporal backtest (train on history >21d old) ──")
        let r = attribution.repoBacktest(cutoffDays: 21)
        guard r.n > 0 else { print("  not enough recent commits to backtest"); return }
        let pct = { (a: Int, b: Int) in b > 0 ? 100 * Double(a) / Double(b) : 0 }
        print("  predict the ticket of each commit from the last 21 days using only older history:")
        print(String(format: "    %d test commits across repos", r.n))
        print(String(format: "    top-1: %.0f%%   top-3: %.0f%%   (all test commits)", pct(r.top1, r.n), pct(r.top3, r.n)))
        print(String(format: "    top-1: %.0f%%   (%d/%d commits whose ticket recurs in the repo's history)",
                     pct(r.recurringTop1, r.recurring), r.recurringTop1, r.recurring))
    }

    // MARK: - Coverage (how much active time gets a ticket, and from where)

    private static func coverageReport(store: Store, config: Config) {
        let now = Date()
        let from = now.addingTimeInterval(-30 * 86400)
        let segs = store.segments(from: from, to: now).filter { !$0.idle }
        let active = segs.reduce(0.0) { $0 + $1.duration }
        guard active > 0 else { print("\n[coverage] no active segments in the last 30 days"); return }
        let tagged = segs.filter { $0.ticket != nil }.reduce(0.0) { $0 + $1.duration }

        var bySource: [String: Double] = [:]
        for s in segs where s.ticket != nil { bySource[s.ticketSource ?? "?", default: 0] += s.duration }

        print("\n── Coverage (last 30 days) ───────────────────────────────────")
        print(String(format: "  active:   %6.1f h", active / 3600))
        print(String(format: "  tagged:   %6.1f h  (%.0f%%)", tagged / 3600, 100 * tagged / active))
        print(String(format: "  untagged: %6.1f h  (%.0f%%)", (active - tagged) / 3600, 100 * (active - tagged) / active))
        print("  by source:")
        for (src, secs) in bySource.sorted(by: { $0.value > $1.value }) {
            print(String(format: "    %-10s %6.1f h", (src as NSString).utf8String!, secs / 3600))
        }
    }

    // MARK: - Repo → ticket bridge

    private static func repoBridgeReport(attribution: Attribution) {
        let summary = attribution.repoBridgeSummary(topPerRepo: 3)
        print("\n── Repo → ticket bridge (\(summary.count) repos mined) ─────────────")
        for entry in summary.prefix(20) {
            let tix = entry.tickets.map { "\($0.0)(\(String(format: "%.1f", $0.1)))" }.joined(separator: ", ")
            print(String(format: "  %-30s %@", (entry.repo as NSString).utf8String!, tix as NSString))
        }
        if summary.count > 20 { print("  … and \(summary.count - 20) more") }
    }

    // MARK: - Ranking accuracy (leave-one-out over labeled examples)

    private static func labelAccuracy(store: Store, attribution: Attribution) {
        let labels = store.allLabels().filter { $0.ticket != "(no ticket)" && !$0.doc.isEmpty }
        let clean = labels.filter { $0.kind == "correction" || $0.kind == "training" }
        print("\n── Ranking accuracy (leave-one-out) ──────────────────────────")
        report(name: "user-confirmed (correction/training)", set: clean, attribution: attribution)
        report(name: "all labels incl. git backfill", set: labels, attribution: attribution)
        print("\nNote: this scores the deterministic text guesser (lexical + memory + repo).")
        print("Embedding/LLM corroborators run live only and lift these numbers further.\n")
    }

    private static func report(name: String,
                               set: [(doc: String, ticket: String, kind: String)],
                               attribution: Attribution) {
        guard set.count >= 5 else {
            print("  • \(name): only \(set.count) example(s) — not enough to measure yet")
            return
        }
        var top1 = 0, top3 = 0, autoTagged = 0, autoCorrect = 0
        for l in set {
            let r = attribution.evaluateDoc(l.doc, trueTicket: l.ticket)
            if r.top1 { top1 += 1 }
            if r.top3 { top3 += 1 }
            if r.autoTagged { autoTagged += 1; if r.top1 { autoCorrect += 1 } }
        }
        let n = Double(set.count)
        let precision = autoTagged > 0 ? Double(autoCorrect) / Double(autoTagged) : 0
        print("  • \(name): \(set.count) examples")
        print(String(format: "      top-1 accuracy: %.0f%%   top-3: %.0f%%", 100 * Double(top1) / n, 100 * Double(top3) / n))
        print(String(format: "      auto-tag: would fire on %.0f%% of them, precision %.0f%% (%d/%d correct)",
                     100 * Double(autoTagged) / n, 100 * precision, autoCorrect, autoTagged))
    }
}
