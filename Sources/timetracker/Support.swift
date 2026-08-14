import Foundation

enum AppPaths {
    static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimeTracker", isDirectory: true)
    }
    static var configFile: URL { dataDir.appendingPathComponent("config.json") }
    static var sprintFile: URL { dataDir.appendingPathComponent("sprint.json") }
    /// Where the on-demand timesheet rows are appended. Matches CLAUDE.md convention.
    static var timesheetLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("timesheet-log.md")
    }
}

/// Which issue tracker supplies the ticket/work-item corpus (`sprint.json`). Changing this needs
/// a restart — `Config` is loaded once at launch and copied by value into every component.
enum IssueProviderKind: String, Codable, CaseIterable {
    case jira, azureDevOps
}

/// Which time-tracking system worklogs are submitted to. Changing this needs a restart.
enum WorklogProviderKind: String, Codable, CaseIterable {
    case tempo, sevenPace
}

/// User-tunable settings, loaded from config.json with sane defaults.
struct Config: Codable {
    /// Where tickets/work items come from. See `IssueProviderKind`.
    var issueProvider: IssueProviderKind = .jira
    /// Where worklogs are submitted. See `WorklogProviderKind`.
    var worklogProvider: WorklogProviderKind = .tempo
    /// Azure Boards only: regex (first capture group = the numeric work-item id) recognizing a
    /// work item id embedded in a branch name, e.g. the default matches "feature/48210-fix-thing".
    var azureBranchKeyPattern: String = "(?:^|/)(\\d+)[-_]"

    /// User is "idle" after this many seconds with no input.
    var idleSeconds: Double = 300
    /// Timesheet block model: a workday of `workdayHours` starting at `dayStartHour`, divided
    /// into `blockHours`-long blocks (count = workdayHours / blockHours). First/last block
    /// absorb activity before/after the workday so nothing is lost.
    var dayStartHour: Double = 9
    var blockHours: Double = 4
    var workdayHours: Double = 8
    /// Real-time prompt fires once unknown active time in the current block exceeds this.
    var promptAfterUnknownMinutes: Double = 120
    /// Don't re-prompt for the same block within this many minutes after a dismissal.
    var promptCooldownMinutes: Double = 45
    /// Gently nudge after this many minutes of *continuous* un-guessable active work (fusion
    /// abstained — no candidate at all), so a block doesn't silently go un-attributed. 0 = off.
    /// Shares the prompt cooldown. Distinct from promptAfterUnknownMinutes (block backlog).
    var abstainNudgeMinutes: Double = 15
    /// Window-title sampling cadence (seconds). App switches are event-driven regardless.
    var sampleSeconds: Double = 10

    /// Apps to never watch (private). Matched against "<bundleId> <appName>", case-insensitive
    /// substring — e.g. "perplexity", "TrainingPeaks", "com.spotify.client".
    var excludedApps: [String] = []
    /// Window/URL patterns to never watch. Matched against "<app> <title> <url>", case-insensitive
    /// substring — e.g. a personal domain "facebook.com", or a Chrome profile name if it appears.
    var excludedWindowPatterns: [String] = []

    func isExcludedApp(bundleId: String, appName: String) -> Bool {
        guard !excludedApps.isEmpty else { return false }
        let hay = "\(bundleId) \(appName)".lowercased()
        return excludedApps.contains { hay.contains($0.lowercased()) }
    }

    func isExcludedWindow(_ text: String) -> Bool {
        guard !excludedWindowPatterns.isEmpty else { return false }
        let hay = text.lowercased()
        return excludedWindowPatterns.contains { hay.contains($0.lowercased()) }
    }

    /// Timesheet fill reminders.
    var remindersEnabled: Bool = true
    /// Local hour to remind (once) if the last active day isn't filled.
    var morningReminderHour: Double = 9
    /// Local hour to remind (once) to fill the current day.
    var eveningReminderHour: Double = 17
    /// Ticket key prefixes to recognize. Matches `<PREFIX>-<digits>`.
    var ticketPrefixes: [String] = ["CLOUDINFRA", "PES", "GEN"]
    /// Jira board ids used to detect active sprints (the number in each board URL). Empty = off.
    var jiraBoardIds: [Int] = [371]
    /// Service-desk queues to treat like an active sprint (boost + include), as "PROJECT/queueId",
    /// e.g. "PES/246" from .../servicedesk/projects/PES/queues/custom/246.
    var jiraQueues: [String] = []
    /// Auto-refresh the Jira ticket list every N minutes (also once on launch). 0 = manual only.
    var jiraRefreshMinutes: Double = 20
    /// Don't fetch tickets untouched (no update/comment) in more than this many days. 0 = no limit.
    var jiraMaxAgeDays: Double = 180

    // MARK: Housekeeping / pruning

    /// Delete raw focus segments older than this many days. 0 = keep forever.
    var segmentRetentionDays: Double = 60
    /// For days already submitted to Tempo (boxed), drop their segments after this many days.
    var submittedRetentionDays: Double = 14
    /// Keep at most this many labeled examples (most recent). 0 = unlimited.
    var labelMaxCount: Int = 2000
    /// Tickets/patterns to NEVER track or suggest. Exact keys or globs, e.g. "EXCL-*", "GEN-9".
    var excludedTickets: [String] = []
    /// Catch-all / common tickets always shown in the pickers (even if unassigned/old/done),
    /// e.g. the quarterly Continuous-Improvement epic "CLOUDINFRA-6081". Manual-pick only.
    var commonTickets: [String] = []
    /// JQL whose results are ALSO treated as common tickets — auto-updates as epics rotate,
    /// e.g. "parent = PES-204" to pull all epics under that parent. Empty = off.
    var commonTicketsJQL: String = ""
    /// Label used for "this work has no JIRA". Picking it fills the block (no nagging) and is
    /// readable in the timesheet. Stays out of guessing.
    var noTicketLabel: String = "(no ticket)"
    /// Context signatures (repo:/host:/app:) that ALWAYS resolve to no-ticket — non-billable work
    /// you've told us never maps to a ticket (e.g. "app:com.spotify.client", "host:news.ycombinator.com").
    /// Unlike excludedApps (which records nothing), this still logs the time as no-ticket.
    var noTicketRules: [String] = []
    /// Where to log "no ticket" time in Tempo. Empty = skip those blocks (don't submit them).
    var noTicketTempoTicket: String = ""
    /// Restrict the GUESS (lexical/embedding/memory/LLM) to assigned tickets in the current
    /// board sprint only. Exact signals (branch/URL/key) and the picker are unaffected.
    /// Default false: sprint detection (Agile API) is unreliable, and gating the pool on it
    /// starves the guesser to a handful of tickets. The ranking prior still boosts sprint
    /// members; this only controls who's *eligible*, not who ranks first.
    var guessFromSprintOnly: Bool = false
    /// Folders that contain git repos whose branch may name a ticket.
    var workspaceGlobs: [String] = ["~/Workspace"]
    /// Bundle-id / keyword → coarse category. First match wins (checked in order).
    var categoryRules: [CategoryRule] = CategoryRule.defaults

    /// Multiplicative ranking weights — how much each ticket attribute boosts/lowers its rank.
    var rankWeights = RankWeights()

    /// Late-fusion ranker tuning (signal reliabilities + auto-tag/suggest policy).
    var fusionWeights = FusionWeights()

    // MARK: Semantic guessing (Apple NLEmbedding) + optional Ollama LLM

    /// Enable token-overlap ticket guessing when exact signals (branch/title key) miss.
    var semanticEnabled: Bool = true
    /// TF-IDF cosine at/above which a guess is auto-applied (if also unambiguous).
    var semanticAutoTagThreshold: Double = 0.18
    /// TF-IDF cosine at/above which a guess is offered as a suggestion (not auto-applied).
    var semanticSuggestThreshold: Double = 0.08
    /// Auto-tag only if the top score beats the runner-up by at least this factor
    /// (or the runner-up is zero). Prevents auto-tagging between two similar tickets.
    var semanticAutoTagMargin: Double = 1.5
    /// How many ranked candidates to keep for the menu / prompt.
    var semanticMaxCandidates: Int = 5
    /// Global confidence floor: NOTHING is auto-tagged below this (it stays a suggestion for
    /// you to assign manually). Applies to every guess layer (lexical/memory/embedding/LLM).
    /// Exact signals (branch/URL/key) are unaffected. 0 = no floor.
    var minGuessConfidence: Double = 0.6
    /// Also auto-tag when ≥2 independent layers (lexical / embedding / LLM) agree on the same
    /// ticket, even if no single one clears the floor — consensus beats a single score.
    var agreementAutoTag: Bool = true
    /// Similarity to a past labeled example at/above which it auto-tags (content memory).
    var memoryAutoTagThreshold: Double = 0.45
    /// Few-shot examples (from your labels) to show the LLM.
    var llmFewShot: Int = 4

    /// Use a local Ollama model to phrase a suggestion at prompt-time (never continuous).
    var ollamaEnabled: Bool = true
    var ollamaURL: String = "http://localhost:11434"
    /// Local model for prompt-time reasoning, e.g. "qwen3:4b", "qwen3:1.7b", "gemma3:4b".
    var ollamaModel: String = "qwen3:4b"
    /// Static description of your work, injected into the LLM system prompt to ground its
    /// reasoning (role, projects, what repos/tools/meetings map to). Edit freely.
    var workflowContext: String = """
    Describe your role, Jira projects, and how repos/tools/meetings map to tickets here — this \
    grounds the LLM's guesses in your actual workflow. Example: "The user is a cloud \
    infrastructure engineer. Jira projects: CLOUDINFRA (AWS/EKS Kubernetes infrastructure, \
    monitoring, SLOs), PES (platform engineering), GEN (general). Repos live under ~/Workspace \
    and usually map to an infra area (e.g. infra-kubernetes, monitoring, infra-irsa-poc). AWS \
    console, Grafana, k8s/Lens, kubectl/terraform usually mean infrastructure troubleshooting. \
    Meetings on Zoom/Meet/Slack-huddle usually relate to the ticket or epic being discussed. \
    Prefer the ticket whose summary/components match the tools and repos currently in use."
    """
    /// Minutes between background LLM refinement passes (0 = prompt-time only).
    var llmRefreshMinutes: Double = 5
    /// LLM confidence at/above which its pick auto-tags the current segment.
    var llmAutoTagConfidence: Double = 0.7
    /// How much recent history (minutes) to summarize for the LLM "arc of work".
    var llmArcWindowMinutes: Double = 60
    /// The previous guess is fed back only if newer than this AND still supported by current
    /// evidence — prevents a guess from pinning itself indefinitely as work moves on.
    var llmPreviousGuessTTLMinutes: Double = 20

    /// Continuous semantic matching via a local Ollama embedding model (catches synonyms
    /// the lexical matcher misses). Runs async off the hot path.
    var embeddingsEnabled: Bool = true
    var embeddingModel: String = "nomic-embed-text"
    /// Cosine at/above which the embedding pick auto-tags — but only when it AGREES with
    /// the lexical top (agreement is the confidence signal).
    var embeddingAutoTagThreshold: Double = 0.62

    static func load() -> Config {
        guard let data = try? Data(contentsOf: AppPaths.configFile) else {
            let cfg = Config()
            cfg.saveIfAbsent()
            return cfg
        }
        // JSONDecoder throws on ANY missing key, even when the Swift property has a default value
        // (`decode(Config.self, ...)` alone would have silently discarded every existing setting
        // the first time a new field like `issueProvider` was added and an older config.json on
        // disk didn't have it). Layer the on-disk JSON over a freshly-serialized default Config's
        // JSON first, so old files pick up new fields' defaults without losing anything else.
        if let defaultsData = try? JSONEncoder().encode(Config()),
           var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
           let onDisk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in onDisk { merged[k] = v }
            if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
               let cfg = try? JSONDecoder().decode(Config.self, from: mergedData) {
                return cfg
            }
        }
        guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let cfg = Config()
            cfg.saveIfAbsent()
            return cfg
        }
        return cfg
    }

    func saveIfAbsent() {
        guard !FileManager.default.fileExists(atPath: AppPaths.configFile.path) else { return }
        save()
    }

    func save() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: AppPaths.configFile)
    }

    var expandedWorkspaceDirs: [URL] {
        workspaceGlobs.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }
}

/// Late-fusion ranker tuning. Each signal is squashed to [0,1], scaled by its reliability,
/// then combined by noisy-OR per candidate ticket — so independent signals that agree on the
/// same ticket reinforce, and a single signal can only carry so far. Precision-first defaults:
/// one signal alone lands in the "suggest" band; auto-tag generally needs corroboration.
struct FusionWeights: Codable {
    // Per-signal reliability (how much an at-threshold signal contributes). 0–1.
    var lexical: Double = 0.70
    var memory: Double = 0.85        // user-confirmed content memory — the strongest learned signal
    var repo: Double = 0.68          // repo→ticket history (grounded, but a repo maps to several)
    var embedding: Double = 0.50     // synonym corroborator
    var llm: Double = 0.60           // reasoning corroborator (only counted when it agrees)
    var correction: Double = 0.90    // signature-confirmed assignments
    var statusRecency: Double = 0.20 // mild prior; most of it already rides inside lexical*prior

    // Decision policy (on the fused [0,1] probability).
    var autoTagThreshold: Double = 0.80     // τ_auto — precision-first
    var suggestThreshold: Double = 0.40     // τ_suggest — below this we abstain (no menu noise)
    var margin: Double = 0.12               // top must beat the runner-up by this much to auto-tag

    // Per-context tier multipliers on τ_auto (≥1 = stricter). Noisy contexts only ever suggest.
    var tierBrowserMessaging: Double = 1.20 // browser/slack/email with no active repo
    var tierWebDocs: Double = 1.08          // jira/confluence/web pages

    /// When the active repo is entirely outside the ticket universe (no mined ticket history AND
    /// no ticket text references it — e.g. a local tool/no-Jira project), scale every candidate's
    /// fused confidence by this, so ambient/pasted session text can't produce a confident wrong
    /// guess. <1 pushes toward abstain (→ the no-ticket nudge).
    var ungroundedRepoDamp: Double = 0.5
}

/// How strongly each ticket attribute multiplies its match score. 1.0 = neutral.
struct RankWeights: Codable {
    var donePenalty: Double = 0.25      // completed tickets pushed down
    var inProgressBoost: Double = 1.5
    var inReviewBoost: Double = 1.35
    var sprintBoost: Double = 1.4       // member of the board's active sprint
    var queueBoost: Double = 1.3        // member of a watched service-desk queue
    var recent3dBoost: Double = 1.3     // updated in last 3 days
    var recent14dBoost: Double = 1.1    // updated in last 14 days
    var stale60dPenalty: Double = 0.8   // untouched > 60 days
}

struct CategoryRule: Codable {
    var category: String
    /// Matched (case-insensitive) against "<bundleId> <appName> <windowTitle>".
    var anyOf: [String]

    static let defaults: [CategoryRule] = [
        .init(category: "meeting", anyOf: ["zoom.us", "us.zoom", "Google Meet", "meet.google", "Slack | Huddle", "Webex"]),
        .init(category: "messaging", anyOf: ["com.tinyspeck.slackmacgap", "Slack", "Microsoft Teams"]),
        .init(category: "infra", anyOf: ["Grafana", "Lens", "k9s", "kubectl", "AWS Management Console", "console.aws", "OpenLens", "Spinnaker"]),
        .init(category: "docs", anyOf: ["Confluence", "atlassian.net/wiki", "Notion"]),
        .init(category: "jira", anyOf: ["atlassian.net/browse", "Jira"]),
        .init(category: "coding", anyOf: ["com.microsoft.VSCode", "Code", "dev.kiro", "Kiro", "com.apple.Terminal", "iTerm", "Ghostty"]),
        .init(category: "email", anyOf: ["com.apple.mail", "Outlook", "Gmail"]),
        .init(category: "browsing", anyOf: ["com.google.Chrome", "com.apple.Safari", "Firefox", "Arc"]),
    ]
}

enum TimeBlocks {
    static var calendar: Calendar { Calendar.current }

    static func dayBounds(_ date: Date) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return (start, end)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = calendar
        return f.string(from: date)
    }

    struct Block: Identifiable {
        var id: String        // stable per config: "1"..."N"
        var index: Int
        var start: Date       // actual bounds (first absorbs early, last absorbs late)
        var end: Date
        var label: String     // nominal clock window, e.g. "09:00–10:00"
        var nominalStartHour: Double
    }

    static func blockCount(_ c: Config) -> Int {
        max(1, Int((c.workdayHours / max(0.25, c.blockHours)).rounded()))
    }

    private static func clock(_ hours: Double) -> String {
        let h = Int(hours.rounded(.down)) % 24
        let m = Int(((hours - hours.rounded(.down)) * 60).rounded())
        return String(format: "%02d:%02d", (h + 24) % 24, m)
    }

    /// The day's blocks. Internal cuts at dayStart + i*blockHours; block 0 starts at 00:00 and
    /// the last ends at 24:00 so early/late activity is absorbed (nothing lost).
    static func blocks(for day: Date, _ c: Config) -> [Block] {
        let sod = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: sod)!
        let n = blockCount(c)
        return (0..<n).map { i in
            let nominalStart = c.dayStartHour + Double(i) * c.blockHours
            let nominalEnd = nominalStart + c.blockHours
            let start = i == 0 ? sod : sod.addingTimeInterval(nominalStart * 3600)
            let end = i == n - 1 ? dayEnd : sod.addingTimeInterval(nominalEnd * 3600)
            return Block(id: "\(i + 1)", index: i, start: start, end: end,
                         label: "\(clock(nominalStart))–\(clock(nominalEnd))", nominalStartHour: nominalStart)
        }
    }

    static func block(for date: Date, _ c: Config) -> Block? {
        blocks(for: date, c).first { date >= $0.start && date < $0.end }
    }

    static func bounds(day: Date, id: String, _ c: Config) -> (start: Date, end: Date)? {
        blocks(for: day, c).first { $0.id == id }.map { ($0.start, $0.end) }
    }
}
