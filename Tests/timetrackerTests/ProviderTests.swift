import Foundation
import Testing
@testable import timetracker

/// #7 — the worklog map is the thing standing between a re-submit and a duplicated day on a real
/// timesheet. These drive the actual clients against a seeded map file rather than the pure
/// `WorklogKey` helpers, so the file format, the day filter and the clearing path are all covered.
extension TTTests {
@Suite(.serialized)
struct WorklogMapTests {

    private func seedTempoMap(_ env: TestEnv, _ map: [String: Int]) {
        let url = env.dir.appendingPathComponent("tempo-worklogs.json")
        try? JSONEncoder().encode(map).write(to: url)
    }

    @Test func tempoFindsLegacyFixedBlockRowsAndIgnoresPeriodRows() {
        let env = TestEnv()
        seedTempoMap(env, [
            "2026-03-11|1": 111,
            "2026-03-11|2": 222,
            "2026-03-11|regular|AB#9": 999,
            "2026-03-10|1": 100,
        ])
        let client = TempoClient(config: testConfig(), atlassian: Atlassian(config: testConfig()))

        let legacy = client.legacyFixedBlockWorklogIds(day: "2026-03-11")
        #expect(legacy.map(\.block) == ["1", "2"])
        #expect(legacy.map(\.id) == ["111", "222"])
        withExtendedLifetime(env) {}
    }

    /// The submit path clears each legacy entry as it deletes it, so an interrupted run doesn't
    /// re-prompt about worklogs that are already gone.
    @Test func clearingALegacyEntryRemovesItFromTheMap() {
        let env = TestEnv()
        seedTempoMap(env, ["2026-03-11|1": 111, "2026-03-11|2": 222])
        let client = TempoClient(config: testConfig(), atlassian: Atlassian(config: testConfig()))

        client.setWorklogId(day: "2026-03-11", block: "1", id: nil)
        #expect(client.legacyFixedBlockWorklogIds(day: "2026-03-11").map(\.block) == ["2"])

        // ...and it survives a reload, i.e. it really was written to disk.
        let reloaded = TempoClient(config: testConfig(), atlassian: Atlassian(config: testConfig()))
        #expect(reloaded.legacyFixedBlockWorklogIds(day: "2026-03-11").map(\.block) == ["2"])
        withExtendedLifetime(env) {}
    }

    /// A period-model id must round-trip without ever looking legacy — otherwise submitting would
    /// offer to delete the worklog it just created.
    @Test func periodModelIdsAreNeverReportedAsLegacy() {
        let env = TestEnv()
        let client = TempoClient(config: testConfig(), atlassian: Atlassian(config: testConfig()))
        client.setWorklogId(day: "2026-03-11", block: "regular|AB#9", id: "4242")

        #expect(client.worklogId(day: "2026-03-11", block: "regular|AB#9") == "4242")
        #expect(client.legacyFixedBlockWorklogIds(day: "2026-03-11").isEmpty)
        withExtendedLifetime(env) {}
    }

    @Test func sevenPaceKeepsItsOwnMapFileWithStringIds() {
        let env = TestEnv()
        let client = SevenPaceClient(config: testConfig())
        client.setWorklogId(day: "2026-03-11", block: "3", id: "0BDA-UUID")

        #expect(client.legacyFixedBlockWorklogIds(day: "2026-03-11").map(\.id) == ["0BDA-UUID"])
        // Separate file from Tempo's — merging them would turn a format change into duplicates.
        #expect(FileManager.default.fileExists(atPath: env.dir.appendingPathComponent("sevenpace-worklogs.json").path))
        #expect(!FileManager.default.fileExists(atPath: env.dir.appendingPathComponent("tempo-worklogs.json").path))
        withExtendedLifetime(env) {}
    }
}
}

/// #8 — the assignee tri-state. The original bug was that `assignee` was read but never requested,
/// so the field was always absent and every ticket silently read as "mine". These pin the three
/// cases apart.
@Suite struct AtlassianParseTests {

    private func issue(_ fields: [String: Any]) -> [String: Any] {
        ["key": "PROJ-1", "id": "1", "fields": fields.merging(["summary": "s"]) { a, _ in a }]
    }

    private func parse(_ fields: [String: Any]) -> Ticket? {
        var c = testConfig(); c.issueProvider = .jira
        return Atlassian(config: c).parseTicket(issue(fields), sprintKeys: [], queueKeys: [],
                                                commonKeys: [], sprintFieldId: nil)
    }

    /// Field absent — we genuinely can't tell, so assume it's yours (the majority case).
    @Test func absentAssigneeFieldMeansUnknownSoAssumeMine() {
        #expect(parse([:])?.assignedToMe == true)
    }

    /// Field present and null — the issue really is unassigned, which is NOT the same as unknown.
    /// Collapsing these two into one `else` is the bug this test exists for.
    @Test func nullAssigneeMeansUnassignedNotMine() {
        #expect(parse(["assignee": NSNull()])?.assignedToMe == false)
    }

    /// Assigned to someone, but with no identity of our own to compare against — fall back to true
    /// rather than silently declaring a ticket not yours.
    @Test func assignedWithNoLocalIdentityFallsBackToMine() {
        #expect(parse(["assignee": ["accountId": "someone-else"]])?.assignedToMe == true)
    }
}

/// #15 — extracted from `AppDelegate.dayNeedsFilling` precisely so it can be tested.
extension TTTests {
@Suite(.serialized)
struct TimesheetRecordTests {

    @Test func aDayWithNothingRecordedIsNotRecorded() {
        let env = TestEnv()
        #expect(!TimesheetRecord.exists(day: testDay, config: testConfig(), store: env.store, submittedDays: []))
    }

    @Test func aPeriodAssignmentCounts() {
        let env = TestEnv()
        env.store.setPeriodAssignment(day: TimeBlocks.dayString(testDay), kind: "regular",
                                      ticketKey: "AB#1", ticket: "AB#1", note: nil)
        #expect(TimesheetRecord.exists(day: testDay, config: testConfig(), store: env.store, submittedDays: []))
    }

    /// The regression this issue was about: a day reviewed under the OLD fixed-block model has no
    /// `period_assignments` row at all, and must not be reported as needing attention.
    @Test func aLegacyBlockAssignmentCounts() {
        let env = TestEnv()
        let config = testConfig()
        let block = TimeBlocks.blocks(for: testDay, config)[0]
        env.store.setBlockAssignment(day: TimeBlocks.dayString(testDay), block: block.id,
                                     ticket: "AB#1", note: nil)
        #expect(TimesheetRecord.exists(day: testDay, config: config, store: env.store, submittedDays: []))
    }

    @Test func anAlreadySubmittedDayCounts() {
        let env = TestEnv()
        #expect(TimesheetRecord.exists(day: testDay, config: testConfig(), store: env.store,
                                       submittedDays: [TimeBlocks.dayString(testDay)]))
    }

    /// An empty block assignment is not a record — the user cleared it.
    @Test func anEmptyBlockAssignmentDoesNotCount() {
        let env = TestEnv()
        let config = testConfig()
        let block = TimeBlocks.blocks(for: testDay, config)[0]
        env.store.setBlockAssignment(day: TimeBlocks.dayString(testDay), block: block.id, ticket: "", note: nil)
        #expect(!TimesheetRecord.exists(day: testDay, config: config, store: env.store, submittedDays: []))
    }
}
}
