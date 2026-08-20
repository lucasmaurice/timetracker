import Foundation
import Testing
@testable import timetracker

/// Regression tests for the PR #5 review findings that live in `PeriodCompiler`.
/// Serialized: they share `AppPaths.overrideDataDir`. `compileFast` is used throughout — it is the
/// full pipeline minus the Ollama meeting guess, so these stay offline and deterministic.
@Suite(.serialized)
@MainActor
struct PeriodCompilerTests {

    // MARK: #11 — exact sources must never be gated

    /// The bug: the gate required the ticket to be in `sprint` AND assigned-and-active, so a
    /// ticket resolved from a branch/commit/url that ISN'T in your assigned corpus (anything mined
    /// from git history lives in `guessTickets`, not `sprint`) was silently dumped into untracked.
    @Test func exactSourceSurvivesAnEmptyCorpus() {
        let env = TestEnv(sprint: [])          // deliberately empty: key is in no corpus at all
        let config = testConfig()
        env.store.insert(segment(at(9), at(10), ticket: "AB#111", source: "branch"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))

        #expect(periods.regularTickets.contains("AB#111"))
        #expect(periods.first(kind: .regular, ticket: "AB#111")?.trueSeconds == 3600)
    }

    /// Every source in `Attribution.exactSources` gets the same treatment — this is the property
    /// that must hold, not just the one case that was reported.
    @Test(arguments: ["url", "branch", "title", "commit", "session", "learned", "manual", "pinned"])
    func everyExactSourceSurvivesTheGate(source: String) {
        let env = TestEnv(sprint: [])
        let config = testConfig()
        env.store.insert(segment(at(9), at(10), ticket: "AB#222", source: source))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(periods.regularTickets.contains("AB#222"), "source \(source) was gated out")
    }

    /// The gate must still do its job for NON-exact sources: a fused guess for a ticket that isn't
    /// assigned-and-active pools into the single untracked entry rather than being reported.
    @Test func nonExactGuessOutsideTheCorpusIsGatedToUntracked() {
        let env = TestEnv(sprint: [ticket("AB#333", assignedToMe: false)])
        let config = testConfig()
        env.store.insert(segment(at(9), at(10), ticket: "AB#333", source: "semantic"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(!periods.regularTickets.contains("AB#333"))
        #expect(periods.first(kind: .regular, ticket: nil)?.trueSeconds == 3600)
    }

    @Test func doneTicketIsGatedOut() {
        let env = TestEnv(sprint: [ticket("AB#444", status: "Closed", category: "Completed", done: true)])
        let config = testConfig()
        env.store.insert(segment(at(9), at(10), ticket: "AB#444", source: "semantic"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(!periods.regularTickets.contains("AB#444"))
    }

    // MARK: #13 — manual assignment granularity (the regression found in manual testing)

    /// `Store.retag` is how AssignView actually delivers a manual assignment: it stamps the
    /// segments themselves with `ticket_source = "manual"`. Choosing "Last 1 hour" must therefore
    /// move exactly that hour — NOT the whole enclosing block, which is what a
    /// `block_assignments`-derived override did.
    @Test func manualRetagAppliesAtItsOwnGranularityNotTheWholeBlock() {
        let env = TestEnv(sprint: [ticket("AB#555"), ticket("AB#666")])
        let config = testConfig()
        // Three hours on one ticket...
        env.store.insert(segment(at(8), at(9), ticket: "AB#555", source: "semantic"))
        env.store.insert(segment(at(9), at(10), ticket: "AB#555", source: "semantic"))
        env.store.insert(segment(at(10), at(11), ticket: "AB#555", source: "semantic"))
        // ...then the user reassigns only the last hour, exactly as `.lastHour` does.
        env.store.retag(from: at(10), to: at(11), ticket: "AB#666")

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))

        #expect(periods.first(kind: .regular, ticket: "AB#666")?.trueSeconds == 3600)
        #expect(periods.first(kind: .regular, ticket: "AB#555")?.trueSeconds == 7200,
                "the earlier two hours must not be re-broadened onto the reassigned ticket")
    }

    /// A manual retag also has to beat the corpus gate — `manual` is an exact source, so it holds
    /// even for a ticket that is not assigned to you.
    @Test func manualRetagBeatsTheCorpusGate() {
        let env = TestEnv(sprint: [ticket("AB#777", assignedToMe: false)])
        let config = testConfig()
        env.store.insert(segment(at(9), at(10), ticket: nil, source: nil))
        env.store.retag(from: at(9), to: at(10), ticket: "AB#777")

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(periods.regularTickets.contains("AB#777"))
    }

    // MARK: #14 — one predicate for export and submit, and no inflated display

    /// A sub-minute period must not be clamped up to `periodMinMinutes`: it is filtered out of both
    /// the timesheet export and submission, so showing it as a 15-minute row was a figure that
    /// could never be reconciled — and it fed the shortfall padding below.
    @Test func subMinutePeriodIsNotInflatedByTheMinimumClamp() {
        let env = TestEnv(sprint: [ticket("AB#888")])
        let config = testConfig()
        env.store.insert(segment(at(9), at(9, 0).addingTimeInterval(36), ticket: "AB#888", source: "prReview"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        let cr = try? #require(periods.first { $0.kind == .codeReview })
        #expect(cr?.trueSeconds == 36)
        #expect(cr?.reportedSeconds == 36, "clamped to periodMinMinutes despite being unbillable")
        #expect(cr?.hasActivity == false)
    }

    /// ...while a period above the floor still rounds, which is the behaviour the clamp is for.
    @Test func periodAboveTheActivityFloorStillRounds() {
        let env = TestEnv(sprint: [ticket("AB#999")])
        let config = testConfig(periodRoundMinutes: 5, periodMinMinutes: 15)
        env.store.insert(segment(at(9), at(9, 7), ticket: "AB#999", source: "prReview"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        let cr = try? #require(periods.first { $0.kind == .codeReview })
        #expect(cr?.trueSeconds == 420)
        #expect(cr?.reportedSeconds == 900, "7min should clamp up to the 15min floor")
    }

    /// Code review with no linked work item falls back to the configured generic ticket.
    @Test func codeReviewWithoutAWorkItemUsesTheGenericTicket() {
        let env = TestEnv(sprint: [])
        let config = testConfig(genericCodeReviewTicket: "AB#1")
        env.store.insert(segment(at(9), at(10), ticket: nil, source: "prReview"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(periods.first { $0.kind == .codeReview }?.ticket == "AB#1")
    }

    // MARK: Break clipping and shortfall padding — previously only ever eyeballed via --dump-periods

    /// The break wins outright over whatever else was happening: overlapping time is clipped out of
    /// the other period rather than reclassified.
    @Test func breakClipsOverlappingRegularTime() {
        let env = TestEnv(sprint: [ticket("AB#1234")])
        let config = testConfig(breakStartHour: 12, breakDurationMinutes: 20)
        env.store.insert(segment(at(11, 50), at(12, 30), ticket: "AB#1234", source: "branch"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        // 40 minutes of segment, 20 of which sit inside the 12:00–12:20 break.
        #expect(periods.first(kind: .regular, ticket: "AB#1234")?.trueSeconds == 1200)
        #expect(periods.first { $0.kind == .breakPeriod }?.trueSeconds == 1200)
    }

    @Test func breakIsInjectedEvenOnAnOtherwiseEmptyDay() {
        let env = TestEnv(sprint: [])
        let config = testConfig()
        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(periods.contains { $0.kind == .breakPeriod })
    }

    /// Shortfall pads the single most-dominant regular period, and `trueSeconds` stays untouched —
    /// the two are load-bearing separately (see CLAUDE.md).
    @Test func shortfallPadsTheDominantRegularPeriodWithoutTouchingTrueSeconds() {
        let env = TestEnv(sprint: [ticket("AB#100"), ticket("AB#200")])
        let config = testConfig(workdayHours: 8, breakDurationMinutes: 0)
        env.store.insert(segment(at(9), at(11), ticket: "AB#100", source: "branch"))   // 2h, dominant
        env.store.insert(segment(at(14), at(15), ticket: "AB#200", source: "branch"))  // 1h

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        let dominant = try? #require(periods.first(kind: .regular, ticket: "AB#100"))
        let other = try? #require(periods.first(kind: .regular, ticket: "AB#200"))

        #expect(dominant?.trueSeconds == 7200, "real tracked time must never be altered")
        #expect(other?.reportedSeconds == 3600, "only the dominant period absorbs the shortfall")
        #expect(periods.reduce(0) { $0 + $1.reportedSeconds } == 28800.0)
    }

    /// Overtime is never trimmed back to the target.
    @Test func overtimeIsNotTrimmed() {
        let env = TestEnv(sprint: [ticket("AB#300")])
        let config = testConfig(workdayHours: 4, breakDurationMinutes: 0)
        env.store.insert(segment(at(8), at(16), ticket: "AB#300", source: "branch"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        // NB: spell the expected value as an explicit Double. Inside the #expect macro an integer
        // *expression* like `8 * 3600` is type-checked in isolation and defaults to Int, so
        // comparing it against a Double? silently yields false. A bare literal takes its type from
        // context and is fine — which is why only this assertion was affected.
        #expect(periods.first(kind: .regular, ticket: "AB#300")?.reportedSeconds == 28800.0)
    }

    // MARK: Identity and grouping

    /// `Period.id` is `(kind, ticket)`, and `compile` must never return two periods sharing one —
    /// Save/Submit build a dictionary from these. (#21 removed the trap; this keeps the invariant
    /// the trap was relying on honest.)
    @Test func compiledPeriodIdsAreUnique() {
        let env = TestEnv(sprint: [ticket("AB#400")])
        let config = testConfig(genericCodeReviewTicket: "AB#400")
        env.store.insert(segment(at(9), at(10), ticket: "AB#400", source: "branch"))
        env.store.insert(segment(at(10), at(11), ticket: "AB#400", source: "prReview"))
        env.store.insert(segment(at(11), at(11, 30), ticket: nil, source: "prReview"))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(Set(periods.map(\.id)).count == periods.count)
    }

    /// Idle time is never billed.
    @Test func idleSegmentsAreExcluded() {
        let env = TestEnv(sprint: [ticket("AB#500")])
        let config = testConfig(breakDurationMinutes: 0)
        env.store.insert(segment(at(9), at(10), ticket: "AB#500", source: "branch", idle: true))

        let periods = PeriodCompiler.compileFast(day: testDay, config: config,
                                                 store: env.store, attribution: env.attribution(config))
        #expect(periods.allSatisfy { $0.trueSeconds == 0 })
    }
}
