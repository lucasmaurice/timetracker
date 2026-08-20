import Foundation
import Testing
@testable import timetracker

/// A disposable data directory + `Store`, so tests never touch the real
/// `~/Library/Application Support/TimeTracker`. `AppPaths.overrideDataDir` is process-global, so
/// every suite using this must carry `.serialized`.
final class TestEnv {
    let dir: URL
    let store: Store

    init(sprint: [Ticket] = [], provider: IssueProviderKind = .azureDevOps) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppPaths.overrideDataDir = dir
        // Written before Store/Attribution exist: Attribution.init calls reloadSprint() eagerly.
        let file = SprintFile(provider: provider.rawValue, updated: nil, tickets: sprint)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: AppPaths.sprintFile) }
        store = Store()
    }

    // Deliberately NOT resetting `AppPaths.overrideDataDir` here: deinit timing is not ordered
    // against the next test's init, so a previous env's deinit could null the override in the
    // middle of a later test and send it at the REAL data directory. Each init claims the global
    // instead; the temp dir is left for the OS to reap.
    deinit { try? FileManager.default.removeItem(at: dir) }

    func attribution(_ config: Config) -> Attribution { Attribution(config: config, store: store) }
}

/// A config with the period knobs pinned to known values, so a default change in `Config` can't
/// silently alter what these tests are asserting.
func testConfig(
    dayStartHour: Double = 8,
    workdayHours: Double = 8,
    breakStartHour: Double = 12,
    breakDurationMinutes: Double = 20,
    periodRoundMinutes: Double = 5,
    periodMinMinutes: Double = 15,
    genericCodeReviewTicket: String = "",
    dailyStandupTicket: String = "",
    breakTicket: String = ""
) -> Config {
    var c = Config()
    c.issueProvider = .azureDevOps
    c.ollamaEnabled = false          // keep every test offline and deterministic
    c.dayStartHour = dayStartHour
    c.workdayHours = workdayHours
    c.breakStartHour = breakStartHour
    c.breakDurationMinutes = breakDurationMinutes
    c.periodRoundMinutes = periodRoundMinutes
    c.periodMinMinutes = periodMinMinutes
    c.genericCodeReviewTicket = genericCodeReviewTicket
    c.dailyStandupTicket = dailyStandupTicket
    c.breakTicket = breakTicket
    c.summerFridayEnabled = false
    return c
}

/// A fixed, non-Friday, non-DST-edge day, so `dailyTargetSeconds` and the break window are stable.
let testDay: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 11   // a Wednesday
    c.hour = 12; c.minute = 0
    return TimeBlocks.calendar.date(from: c)!
}()

func at(_ hour: Int, _ minute: Int = 0) -> Date {
    TimeBlocks.calendar.startOfDay(for: testDay).addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
}

func segment(_ from: Date, _ to: Date, ticket: String? = nil, source: String? = nil,
             app: String = "Code", title: String = "w", idle: Bool = false,
             meeting: String? = nil) -> Segment {
    Segment(start: from, end: to, bundleId: "com.test.\(app)", appName: app, windowTitle: title,
            idle: idle, ticket: ticket, ticketSource: source, category: nil, confidence: nil,
            contextDoc: "doc \(ticket ?? "none")", meeting: meeting)
}

func ticket(_ key: String, status: String = "Doing", category: String? = "InProgress",
            assignedToMe: Bool = true, done: Bool = false) -> Ticket {
    Ticket(key: key, summary: "summary of \(key)", text: "text of \(key)", status: status,
           updated: nil, done: done, inSprint: false, inQueue: false, common: false,
           issueId: key, statusCategory: category, assignedToMe: assignedToMe, project: nil)
}

extension Array where Element == Period {
    func first(kind: PeriodKind, ticket: String?) -> Period? {
        first { $0.kind == kind && $0.ticket == ticket }
    }
    var regularTickets: [String?] { filter { $0.kind == .regular }.map(\.ticket) }
}
