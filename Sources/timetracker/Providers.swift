import Foundation

/// Which piece of context a candidate key was pulled from. Some formats need stricter matching
/// for noisy sources (a window title can contain any number) than for sources that only ever
/// contain a real reference (a browser URL pointing straight at the ticket).
enum KeySource {
    case url, branch, title, commit, session, freeText
}

/// Defines how ticket/work-item keys look for one issue-tracking provider: how to pull one out of
/// arbitrary text, whether a key belongs to the guessable pool, and how to canonicalize a
/// user-typed string. This is the seam that keeps `Attribution` provider-agnostic — everything
/// downstream of it works on opaque `Ticket.key` strings.
protocol TicketKeyFormat {
    /// Shown in placeholder text / help copy, e.g. "CLOUDINFRA-1234" or "AB#48210".
    var placeholderExample: String { get }
    /// Whether a bare number (e.g. skimmed from a window title) may be considered a candidate key
    /// at all — the caller still gates it against the live ticket corpus before trusting it, so
    /// this can't produce false positives on its own. Jira keys are never bare numbers.
    var allowsBareNumberFallback: Bool { get }
    /// Strict, source-aware extraction. Never matches a bare number — that path is handled
    /// separately (see `allowsBareNumberFallback`) precisely because it needs corpus gating that
    /// this format has no access to.
    func extract(from text: String, source: KeySource) -> String?
    /// True if a key's project/prefix is one the guesser is configured to choose from.
    func isGuessable(_ key: String) -> Bool
    /// Normalize a user-typed or machine-supplied string into this format's canonical key shape
    /// (case, punctuation) — WITHOUT consulting the ticket corpus. Returns nil if the string
    /// doesn't look like a key in this format at all.
    func canonicalize(_ raw: String) -> String?
}

/// `PREFIX-1234` (Jira). Applies the same regex regardless of source — a straight port of
/// TimeTracker's original single-regex behavior, kept byte-identical so existing Jira setups
/// don't regress.
struct JiraKeyFormat: TicketKeyFormat {
    private let regex: NSRegularExpression
    private let prefixes: [String]
    let placeholderExample: String
    let allowsBareNumberFallback = false

    init(prefixes: [String]) {
        self.prefixes = prefixes
        let escaped = prefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Word-bounded <PREFIX>-<digits>, prefixes are case-insensitive.
        self.regex = try! NSRegularExpression(pattern: "\\b(?:\(escaped))-\\d+\\b", options: [.caseInsensitive])
        self.placeholderExample = prefixes.first.map { "\($0)-1234" } ?? "PROJECT-1234"
    }

    func extract(from text: String, source: KeySource) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r]).uppercased()
    }

    /// True if a key's project prefix is one the guesser is configured to choose from — a plain
    /// prefix-string check, matching the original `hasGuessablePrefix` exactly (not derived from
    /// the regex, so odd historical keys that predate strict validation still behave the same).
    func isGuessable(_ key: String) -> Bool {
        let upper = key.uppercased()
        return prefixes.contains { upper.hasPrefix($0.uppercased() + "-") }
    }

    func canonicalize(_ raw: String) -> String? { extract(from: raw, source: .freeText) }
}

/// `AB#1234` (Azure Boards). Distinguishes by source because a bare number is dangerously
/// ambiguous in noisy text (window titles, terminal output) but unambiguous where Azure Boards
/// itself writes it (`_workitems/edit/1234`, `AB#1234` in commits/PR titles/branch names).
struct AzureBoardsKeyFormat: TicketKeyFormat {
    let placeholderExample = "AB#48210"
    let allowsBareNumberFallback = true

    private let urlRegex = try! NSRegularExpression(
        pattern: "(?:_workitems/edit/|[?&]workitem=)(\\d+)", options: [.caseInsensitive])
    private let hashRegex = try! NSRegularExpression(pattern: "AB#(\\d+)", options: [.caseInsensitive])
    private let branchRegex: NSRegularExpression

    init(branchPattern: String) {
        self.branchRegex = (try? NSRegularExpression(pattern: branchPattern, options: [.caseInsensitive]))
            ?? (try! NSRegularExpression(pattern: "(?:^|/)(\\d+)[-_]", options: [.caseInsensitive]))
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    func extract(from text: String, source: KeySource) -> String? {
        let id: String?
        switch source {
        case .url: id = Self.firstGroup(urlRegex, in: text) ?? Self.firstGroup(hashRegex, in: text)
        case .branch: id = Self.firstGroup(hashRegex, in: text) ?? Self.firstGroup(branchRegex, in: text)
        case .title, .commit, .session, .freeText: id = Self.firstGroup(hashRegex, in: text)
        }
        return id.map { "AB#\($0)" }
    }

    func isGuessable(_ key: String) -> Bool { key.uppercased().hasPrefix("AB#") }

    /// Accepts "AB#1234", "ab#1234", or a bare "1234" (as commonly copied straight from the AzDO
    /// UI, which shows the numeric id everywhere but rarely the "AB#" form). The bare-digits case
    /// is intentionally NOT corpus-checked here — callers using this for the live bare-number
    /// fallback path must check the result against the current ticket pool themselves.
    func canonicalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Self.firstGroup(hashRegex, in: t) { return "AB#\(id)" }
        if t.range(of: "^\\d{1,9}$", options: .regularExpression) != nil { return "AB#\(t)" }
        return nil
    }
}

/// Result of a full corpus refresh — how many tickets/work items total, and how many are open.
struct RefreshResult { var total: Int; var open: Int }

/// A source of tickets/work items: fetches the corpus into `sprint.json` and resolves a key to
/// its numeric issue id (for worklog submission). `connect`/disconnect dialogs stay on the
/// concrete type in main.swift — this protocol only covers what `Attribution`'s callers need
/// generically, so the same menu/refresh/submit code paths work regardless of which is active.
protocol IssueProvider: AnyObject {
    var displayName: String { get }
    var configured: Bool { get }
    func preload()
    func disconnect()
    func refreshSprint() async throws -> RefreshResult
    func fetchIssueId(forKey: String) async -> String?
    /// The ticket/work-item's browser page, for a menu "Open in browser" action. Nil when not
    /// connected (no site/org known yet) or the key doesn't parse for this provider. `project` is
    /// Azure Boards' `Ticket.project` (ignored by Jira) — its work-item URL needs a project
    /// segment (`/{org}/{project}/_workitems/edit/{id}`) and this org's work spans multiple
    /// projects, so it can't be assumed from `config.azureProject` alone.
    func browserURL(forKey key: String, project: String?) -> URL?
}

/// The `(day|block)` worklog-map key shape, shared by every `WorklogProvider`.
///
/// Fixed blocks keyed on a bare block id ("2026-08-18|3"); floating periods key on `Period.id`
/// ("2026-08-18|regular|CLOUD-1234"). The two shapes never collide, which is what makes the switch
/// detectable — but it also means a day submitted under the old model has ids the new keys can't
/// find, so a re-submit would CREATE a second full set of worklogs on someone's official timesheet
/// rather than replace the first. There is no lossless key migration (N time-sliced blocks don't
/// map onto per-ticket day totals), so the submit path detects the legacy rows and offers to delete
/// them instead.
enum WorklogKey {
    /// True for an old fixed-block key component: `TimeBlocks.Block.id` is always "1"..."N".
    static func isLegacyFixedBlock(_ block: String) -> Bool { !block.isEmpty && block.allSatisfy(\.isNumber) }

    /// Legacy `(block, id)` pairs for `day`, out of a provider's raw map. Generic over the id type
    /// so Tempo's `Int` ids and 7pace's UUID strings share one implementation.
    static func legacyIds<V>(in map: [String: V], day: String) -> [(block: String, id: String)] {
        map.compactMap { kv in
            let parts = kv.key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == day, isLegacyFixedBlock(String(parts[1])) else { return nil }
            return (String(parts[1]), "\(kv.value)")
        }.sorted { $0.block.localizedStandardCompare($1.block) == .orderedAscending }
    }
}

/// A destination for worklogs. `resolveAuthor` puts "whose identity does this worklog need" on
/// the provider that owns that identity (Tempo: the paired Jira account; 7pace: its own user)
/// instead of hard-coding one provider's accountId call at the main.swift submit site.
protocol WorklogProvider: AnyObject {
    var displayName: String { get }
    var configured: Bool { get }
    func preload()
    func disconnect()
    func connect(token: String)
    func resolveAuthor() async -> String?
    func worklogId(day: String, block: String) -> String?
    func setWorklogId(day: String, block: String, id: String?)
    /// Worklogs this app posted for `day` under the OLD fixed-block model — see `WorklogKey`.
    /// Returned so the submit path can delete them before posting floating periods, instead of
    /// silently double-billing the day.
    func legacyFixedBlockWorklogIds(day: String) -> [(block: String, id: String)]
    func pruneWorklogMap(olderThanDays: Double)
    func createWorklog(issueId: String, author: String?, date: String, startTime: String,
                       seconds: Int, description: String) async throws -> String?
    func deleteWorklog(id: String) async
}
