import Foundation
import Testing
@testable import timetracker

/// #7 — the key-shape detection that stands between a re-submit and a duplicated day on someone's
/// official timesheet. Pure functions, so no environment needed.
@Suite struct WorklogKeyTests {

    @Test(arguments: ["1", "2", "9", "12"])
    func fixedBlockIdsAreRecognisedAsLegacy(block: String) {
        #expect(WorklogKey.isLegacyFixedBlock(block))
    }

    @Test(arguments: ["regular|CLOUD-1", "codeReview|AB#12", "breakPeriod|", "meeting|", "", "1a", "-1"])
    func periodIdsAndJunkAreNotLegacy(block: String) {
        #expect(!WorklogKey.isLegacyFixedBlock(block))
    }

    @Test func legacyIdsSelectsOnlyTheRequestedDaysFixedBlockRows() {
        let map = [
            "2026-03-11|1": 100,
            "2026-03-11|2": 200,
            "2026-03-11|regular|AB#1": 300,   // new model, same day — must be ignored
            "2026-03-12|1": 400,              // different day
        ]
        let found = WorklogKey.legacyIds(in: map, day: "2026-03-11")
        #expect(found.map(\.block) == ["1", "2"])
        #expect(found.map(\.id) == ["100", "200"])
    }

    /// 7pace's ids are UUID strings rather than Ints — one generic implementation serves both.
    @Test func legacyIdsWorksForStringIdMaps() {
        let map = ["2026-03-11|3": "a-uuid", "2026-03-11|regular|AB#1": "b-uuid"]
        let found = WorklogKey.legacyIds(in: map, day: "2026-03-11")
        #expect(found.count == 1)
        #expect(found.first?.id == "a-uuid")
    }

    @Test func aDayWithOnlyNewModelKeysHasNoLegacyRows() {
        let map = ["2026-03-11|regular|AB#1": 1, "2026-03-11|meeting|": 2]
        #expect(WorklogKey.legacyIds(in: map, day: "2026-03-11").isEmpty)
    }
}

/// The hand-written `Ticket.init(from:)` exists because a synthesized one throws on a missing
/// non-Optional key, which would empty the whole corpus on the first launch after an update.
@Suite struct TicketDecodingTests {

    @Test func decodesAFileWrittenBeforeAssignedToMeAndProjectExisted() throws {
        let json = #"{"key":"AB#1","summary":"s","done":false,"inSprint":false,"inQueue":false,"common":false}"#
        let t = try JSONDecoder().decode(Ticket.self, from: Data(json.utf8))
        #expect(t.key == "AB#1")
        #expect(t.assignedToMe, "must default to true, not throw or default to false")
        #expect(t.project == nil)
    }

    @Test func decodesAMinimalTicket() throws {
        let t = try JSONDecoder().decode(Ticket.self, from: Data(#"{"key":"AB#2","summary":"s"}"#.utf8))
        #expect(t.done == false)
        #expect(t.assignedToMe)
    }

    @Test func roundTripsEveryField() throws {
        let original = Ticket(key: "AB#3", summary: "s", text: "t", status: "Doing", updated: "2026-03-11",
                              done: false, inSprint: true, inQueue: true, common: true, issueId: "3",
                              statusCategory: "InProgress", assignedToMe: false, project: "Infra")
        let decoded = try JSONDecoder().decode(Ticket.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    /// `isInProgressLike` falls back through statusCategory → preferredStates → a name heuristic,
    /// because statusCategory is Azure-only and always nil for Jira.
    @Test func isInProgressLikeFallsBackWhenStatusCategoryIsAbsent() {
        let preferred: Set<String> = ["doing", "in review"]
        #expect(ticket("A", category: "InProgress").isInProgressLike(preferredStates: []))
        #expect(!ticket("B", category: "Proposed").isInProgressLike(preferredStates: preferred))
        #expect(ticket("C", status: "Doing", category: nil).isInProgressLike(preferredStates: preferred))
        #expect(ticket("D", status: "In Progress", category: nil).isInProgressLike(preferredStates: []))
        #expect(!ticket("E", status: "Backlog", category: nil).isInProgressLike(preferredStates: preferred))
    }

    @Test func doneIsNeverInProgressLike() {
        let t = ticket("F", status: "Doing", category: "InProgress", done: true)
        #expect(!t.isInProgressLike(preferredStates: ["doing"]))
    }
}

/// The daily target drives shortfall padding, so its edges are worth pinning.
@Suite struct TimeBlocksTests {

    @Test func summerFridayAppliesOnlyToFridaysInsideTheRange() {
        var c = testConfig()
        c.summerFridayEnabled = true
        c.summerFridayStartMonthDay = "06-01"
        c.summerFridayEndMonthDay = "08-31"
        c.summerFridayHours = 6

        func day(_ m: Int, _ d: Int) -> Date {
            var comps = DateComponents(); comps.year = 2026; comps.month = m; comps.day = d; comps.hour = 12
            return TimeBlocks.calendar.date(from: comps)!
        }
        #expect(TimeBlocks.isSummerFriday(day(7, 3), c))       // a Friday in range
        #expect(!TimeBlocks.isSummerFriday(day(7, 2), c))      // Thursday
        #expect(!TimeBlocks.isSummerFriday(day(5, 29), c))     // Friday before the range
        #expect(!TimeBlocks.isSummerFriday(day(9, 4), c))      // Friday after the range
    }

    @Test func disabledSummerFridayFallsBackToWorkdayHours() {
        var c = testConfig(workdayHours: 8)
        c.summerFridayEnabled = false
        var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = 3; comps.hour = 12
        #expect(TimeBlocks.dailyTargetSeconds(TimeBlocks.calendar.date(from: comps)!, c) == 28800.0)
    }
}
