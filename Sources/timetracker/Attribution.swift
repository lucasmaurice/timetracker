import Foundation

struct Ticket: Codable, Equatable {
    var key: String
    var summary: String
    /// Rich text for matching: summary + epic + components + labels + description.
    /// Optional for backward-compat with older sprint.json files.
    var text: String?
    var status: String?       // e.g. "In Progress", "In Review", "New"
    var updated: String?      // ISO8601 timestamp of last update (changes on comments/edits)
    var done: Bool = false    // statusCategory == done
    var inSprint: Bool = false // member of the board's active sprint
    var inQueue: Bool = false  // member of a watched service-desk queue
    var common: Bool = false   // a configured catch-all ticket (always shown in pickers)
    var issueId: String?      // numeric Jira id (Tempo worklogs key by this, not the key)
    /// Provider-normalized status category, when the provider has one (Azure Boards: Proposed/
    /// InProgress/Resolved/Completed/Removed). Jira's own statusCategory (new/indeterminate/done)
    /// doesn't distinguish "in review" from "in progress", so Jira tickets leave this nil and fall
    /// back to the name-based heuristic below — this only takes over where it adds precision.
    var statusCategory: String?
    /// True for every ticket populated the normal way (Jira's JQL, Azure DevOps' WIQL both already
    /// mean "assigned to me"). Only ever `false` for a ticket resolved live via the PR-review path
    /// (`AzureDevOps.resolveWorkItem(forPullRequestId:)`), which is explicitly allowed to surface a
    /// teammate's work item — see `PeriodCompiler`'s regular-block candidate gate, which requires
    /// this to be true (code-review periods deliberately don't).
    var assignedToMe: Bool = true

    init(key: String, summary: String, text: String? = nil, status: String? = nil, updated: String? = nil,
         done: Bool = false, inSprint: Bool = false, inQueue: Bool = false, common: Bool = false,
         issueId: String? = nil, statusCategory: String? = nil, assignedToMe: Bool = true) {
        self.key = key; self.summary = summary; self.text = text; self.status = status; self.updated = updated
        self.done = done; self.inSprint = inSprint; self.inQueue = inQueue; self.common = common
        self.issueId = issueId; self.statusCategory = statusCategory; self.assignedToMe = assignedToMe
    }

    private enum CodingKeys: String, CodingKey {
        case key, summary, text, status, updated, done, inSprint, inQueue, common, issueId, statusCategory, assignedToMe
    }

    /// A plain synthesized `Decodable` would throw on any `sprint.json` written before this field
    /// existed (missing key on a non-Optional property, unlike `text`'s Optional-driven backward
    /// compat above) — silently emptying the whole ticket corpus on the very next launch after an
    /// update, exactly the `Config.load()` bug this project already hit once. `decodeIfPresent` +
    /// the field's own default sidesteps it the same way.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        summary = try c.decode(String.self, forKey: .summary)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        inSprint = try c.decodeIfPresent(Bool.self, forKey: .inSprint) ?? false
        inQueue = try c.decodeIfPresent(Bool.self, forKey: .inQueue) ?? false
        common = try c.decodeIfPresent(Bool.self, forKey: .common) ?? false
        issueId = try c.decodeIfPresent(String.self, forKey: .issueId)
        statusCategory = try c.decodeIfPresent(String.self, forKey: .statusCategory)
        assignedToMe = try c.decodeIfPresent(Bool.self, forKey: .assignedToMe) ?? true
    }

    /// What the lexical/embedding matcher sees (rich, includes the description).
    var matchText: String { (text?.isEmpty == false ? text! : summary) }

    /// Shared text builder for every `IssueProvider`: joins the pieces each provider's own fields
    /// map onto (Jira: type/epic/components/labels/description; Azure Boards: work item type/
    /// parent title/area path/tags/description) into one `matchText`/`llmText` source. The
    /// `" · desc:"` marker `llmText` (below) strips on is produced HERE, in exactly one place, so
    /// a provider can't accidentally leak its description back into the LLM prompt by building the
    /// text a different way.
    static func buildMatchText(summary: String?, type: String?, epic: String?,
                               components: [String], labels: [String], description: String) -> String {
        var parts: [String] = []
        if let t = type { parts.append("[\(t)]") }
        if let s = summary { parts.append(s) }
        if let epic { parts.append("epic: \(epic)") }
        if !components.isEmpty { parts.append("components: \(components.joined(separator: ", "))") }
        if !labels.isEmpty { parts.append("labels: \(labels.joined(separator: ", "))") }
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { parts.append("desc: \(desc.prefix(600))") }
        return parts.joined(separator: " · ")
    }

    /// Leaner text for the LLM candidate list: type + summary + epic + components + labels, but
    /// WITHOUT the description — which is mostly GitHub blob URLs with commit SHAs (pure token
    /// noise for ticket selection). The discriminator between near-identical tickets is the
    /// service name in the summary, not the URLs.
    var llmText: String {
        let t = matchText
        if let r = t.range(of: " · desc:") { return String(t[..<r.lowerBound]) }
        return t
    }

    /// Ranking prior: not-done + active-sprint + recently-touched + In-Progress rank higher,
    /// so a large assigned backlog (incl. completed tickets kept for the data lake) doesn't
    /// dilute current work. Weights are configurable (Settings → Ranking weights).
    /// `preferredStates` — pre-lowercased, from Config.preferredTicketStates — is checked against
    /// the raw status name, one level more specific than `statusCategory` below can be.
    func priorWeight(now: Date, w: RankWeights, preferredStates: Set<String> = []) -> Double {
        priorBreakdown(now: now, w: w, preferredStates: preferredStates).reduce(1.0) { $0 * $1.factor }
    }

    /// Labeled multiplicative factors (for the Inspector). Only non-neutral factors are listed.
    func priorBreakdown(now: Date, w: RankWeights, preferredStates: Set<String> = []) -> [(label: String, factor: Double)] {
        var out: [(String, Double)] = []
        if done {
            out.append(("done", w.donePenalty))
        } else if let cat = statusCategory {
            if cat == "InProgress" { out.append(("In Progress", w.inProgressBoost)) }
            else if cat == "Resolved" { out.append(("In Review", w.inReviewBoost)) }
        } else {
            let s = (status ?? "").lowercased()
            if s.contains("progress") { out.append(("In Progress", w.inProgressBoost)) }
            else if s.contains("review") { out.append(("In Review", w.inReviewBoost)) }
        }
        // A raw-state-name preference, distinct from (and finer-grained than) the category boost
        // above: two states can share a category — e.g. Azure Boards' "Dev" and "Active" both
        // categorize as InProgress — but only one of them might actually mean "someone's coding
        // this right now" for your team. Not applied to a done ticket even if its literal state
        // name happens to match, so a preference never overrides the done penalty.
        if !done, let status, preferredStates.contains(status.lowercased()) {
            out.append(("preferred state (\(status))", w.preferredStateBoost))
        }
        if inSprint { out.append(("active sprint", w.sprintBoost)) }
        if inQueue { out.append(("queue", w.queueBoost)) }
        if let u = updated, let d = Self.parseUpdated(u) {
            let days = now.timeIntervalSince(d) / 86400
            if days < 3 { out.append(("updated <3d", w.recent3dBoost)) }
            else if days < 14 { out.append(("updated <14d", w.recent14dBoost)) }
            else if days > 60 { out.append(("stale >60d", w.stale60dPenalty)) }
        }
        return out
    }

    /// "Actively being worked" for `PeriodCompiler`'s regular-block candidate gate — mirrors the
    /// exact fallback chain `priorBreakdown` above already uses (statusCategory, else
    /// preferredTicketStates membership, else a name-based heuristic), since Jira tickets never
    /// have `statusCategory` set at all: gating on `statusCategory == "InProgress"` literally would
    /// make every Jira user's regular blocks abstain forever.
    func isInProgressLike(preferredStates: Set<String>) -> Bool {
        if done { return false }
        if let statusCategory { return statusCategory == "InProgress" }
        if let status, preferredStates.contains(status.lowercased()) { return true }
        return (status ?? "").lowercased().contains("progress")
    }

    /// Jira's `updated` (and Azure Boards' `ChangedDate`) include fractional seconds
    /// ("2026-08-14T12:33:21.190-0400"), which the default `ISO8601DateFormatter` — configured for
    /// `.withInternetDateTime` only — silently fails to parse (`date(from:)` returns nil). That
    /// means the recency boosts above have never actually fired. Try the strict format first, then
    /// fall back to fractional seconds.
    private static let isoStrict = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseUpdated(_ s: String) -> Date? {
        isoStrict.date(from: s) ?? isoFractional.date(from: s)
    }
}

struct SprintFile: Codable {
    /// Which `IssueProviderKind` wrote this file. Nil = predates this field (treated as "jira",
    /// the only provider that existed before). `reloadSprint` ignores a file stamped for a
    /// different provider than the one currently configured, instead of silently reusing stale
    /// cross-provider tickets after a switch.
    var provider: String?
    var updated: String?
    var tickets: [Ticket]
}

struct AttributionResult {
    var ticket: String?
    var source: String?   // "branch" | "title" | "semantic" | "manual" | nil
    var category: String?
    var confidence: Double?           // similarity of the top guess (semantic only)
    var candidates: [TicketGuess] = []  // ranked guesses for the menu / prompt
}

/// Infers a JIRA ticket and coarse category from the foreground app + window title.
/// Pure local logic: regex on titles, `git branch` on the active workspace repo,
/// and a locally-synced sprint picklist. No network.
final class Attribution {
    private var config: Config
    /// Provider-specific key extraction/validation — see Providers.swift. Built once at init from
    /// `config.issueProvider`; switching providers needs a restart, same as every other setting.
    let keyFormat: TicketKeyFormat
    private(set) var sprint: [Ticket] = []
    private var repoBranchCache: [String: (branch: String, at: Date)] = [:]
    private let branchTTL: TimeInterval = 30
    private let store: Store
    private let matcher = TicketMatcher()
    private let corrections = CorrectionStore()
    private let labelMemory: LabelMemory
    private let repoBridge = RepoTicketBridge()

    private let excludeRegexes: [NSRegularExpression]

    init(config: Config, store: Store) {
        self.config = config
        self.labelMemory = LabelMemory(store: store)
        self.store = store
        switch config.issueProvider {
        case .jira: self.keyFormat = JiraKeyFormat(prefixes: config.ticketPrefixes)
        case .azureDevOps: self.keyFormat = AzureBoardsKeyFormat(branchPattern: config.azureBranchKeyPattern)
        }
        // Exclusion patterns: glob `*` → `.*`, anchored, case-insensitive (e.g. "EXCL-*").
        self.excludeRegexes = config.excludedTickets.compactMap { pat in
            let escaped = pat.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
            return try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive])
        }
        reloadSprint()
    }

    /// Attribution sources that must never be overridden by an async refinement (embedding/LLM):
    /// the exact-key matches plus explicit human/learned signals. Fused sources
    /// (semantic/memory/repo/embed/llm/guess) are refinable as more evidence arrives.
    static let exactSources: Set<String> = ["url", "branch", "title", "commit", "session", "learned", "manual", "pinned", "prReview"]
    static func isExact(_ source: String?) -> Bool { source.map { exactSources.contains($0) } ?? false }

    /// Human-readable phrase for an attribution source, for the menu-bar "Why" line and anywhere
    /// else a raw `ticket_source`/`guessSource` value needs to read as a sentence, not a keyword.
    private static let sourceDescriptions: [String: String] = [
        "url": "the page URL", "branch": "your git branch", "title": "the window title",
        "commit": "a commit message", "session": "your AI session", "prReview": "reviewing this PR",
        "learned": "a correction you confirmed before", "manual": "set manually", "pinned": "pinned",
        "rule": "a no-ticket rule", "semantic": "lexical match", "memory": "similar past work",
        "repo": "repo history", "embed": "embedding match", "llm": "the local LLM", "guess": "best guess",
    ]
    static func sourceDescription(_ source: String) -> String { sourceDescriptions[source] ?? source }

    /// True if a ticket key is on the exclusion list (exact or glob match).
    func isExcluded(_ key: String) -> Bool {
        let r = NSRange(key.startIndex..., in: key)
        return excludeRegexes.contains { $0.firstMatch(in: key, range: r) != nil }
    }

    /// The pool the guesser may choose from (lexical/embedding/memory/LLM). Exact signals and
    /// the manual picker are NOT limited to this.
    private(set) var guessTickets: [Ticket] = []
    private var guessKeys: Set<String> = []

    func reloadSprint() {
        guard let data = try? Data(contentsOf: AppPaths.sprintFile),
              let f = try? JSONDecoder().decode(SprintFile.self, from: data) else { return }
        // A file predating the `provider` field is treated as "jira" (the only provider that
        // existed before). A file stamped for a DIFFERENT provider than the one configured now is
        // stale cross-provider data — clear the corpus instead of silently reusing it (it would
        // otherwise still validate through `normalizeTicketEntry`'s corpus branch and get written
        // into new segments under the wrong provider).
        let fileProvider = f.provider ?? IssueProviderKind.jira.rawValue
        guard fileProvider == config.issueProvider.rawValue else {
            sprint = []; guessTickets = []; guessKeys = []
            if config.semanticEnabled { matcher.index([], weights: config.rankWeights, preferredStates: config.preferredTicketStatesLower) }
            return
        }
        sprint = f.tickets.filter { !isExcluded($0.key) }   // drop excluded from the whole corpus

        // The guesser may only choose tickets whose project prefix is configured. `assignee =
        // currentUser()` pulls EVERY assigned project (e.g. 41 auto-generated "TEMPA" temporary-
        // access incident tickets) into the corpus; those are noise that the lexical matcher was
        // spuriously auto-tagging. They stay in `sprint` (data lake / memory) but are barred from
        // guessing. Common tickets are always allowed regardless of prefix.
        let guessable = sprint.filter { keyFormat.isGuessable($0.key) || $0.common }

        // Guess pool: assigned + current board sprint when enabled; otherwise all not-done.
        var pool = config.guessFromSprintOnly ? guessable.filter { $0.inSprint && !$0.done }
                                              : guessable.filter { !$0.done }
        if pool.isEmpty { pool = guessable.filter { !$0.done } }   // fallback if no sprint detected

        // Widen with tickets you've actually worked on locally (mined from git history) that are in
        // the corpus and still open — so a ticket you're clearly working in a repo is eligible even
        // if it never landed in your assigned-open set.
        let mined = repoBridge.allMinedKeys()
        if !mined.isEmpty {
            let have = Set(pool.map { $0.key })
            pool += guessable.filter { !$0.done && !have.contains($0.key) && mined.contains($0.key) }
        }

        guessTickets = pool
        guessKeys = Set(pool.map { $0.key })

        if config.semanticEnabled { matcher.index(guessTickets, weights: config.rankWeights, preferredStates: config.preferredTicketStatesLower) }
    }

    // MARK: - Repo → ticket bridge (git history)

    /// Extract a guessable, non-excluded ticket key from arbitrary text (branch / commit).
    /// Strict extraction only — no corpus-gated bare-number fallback here, since that would bias
    /// history mining toward tickets that happen to be currently assigned rather than what the
    /// history actually shows. The text could be either a branch name or a commit subject (the
    /// bridge scans both through this same closure), so try both source-specific rules.
    private func guessableExtract(_ text: String) -> String? {
        for source: KeySource in [.commit, .branch] {
            if let key = keyFormat.extract(from: text, source: source), !isExcluded(key) { return key }
        }
        return nil
    }

    /// Re-mine workspace git history into the repo→ticket bridge. Heavy (spawns git per repo);
    /// call off the main thread. Thread-safe: the bridge guards its own state.
    func rebuildRepoBridge(now: Date = Date()) {
        repoBridge.rebuild(workspaceDirs: config.expandedWorkspaceDirs, now: now) { self.guessableExtract($0) }
    }

    /// Merge `AzurePRBridge`-resolved (repo, [(key, ts)]) pairs into the repo→ticket bridge. MUST
    /// be called after `rebuildRepoBridge` in the same pass — that call replaces the bridge's map
    /// wholesale, which would silently wipe an earlier merge.
    func ingestPRBridgeResults(_ results: [(repo: String, keys: [(key: String, ts: Double)])], now: Date = Date()) {
        for r in results { repoBridge.ingestResolvedKeys(repo: r.repo, keys: r.keys, now: now) }
    }

    /// Recency-decayed repo→ticket candidates for the current context, restricted to the
    /// guessable pool. The single strongest grounded signal when the branch names no key.
    func repoRank(_ ctx: WorkContext) -> [TicketGuess] { repoScore(repoName: ctx.repo) }

    /// Repo→ticket candidates by repo name (used by `repoRank` and the offline evaluator).
    func repoScore(repoName: String?) -> [TicketGuess] {
        repoBridge.score(repo: repoName) { self.guessKeys.contains($0) }
    }

    /// Top mined repo→ticket mappings, for the eval harness / diagnostics.
    func repoBridgeSummary(topPerRepo: Int = 3) -> [(repo: String, tickets: [(String, Double)])] {
        repoBridge.summary(topPerRepo: topPerRepo)
    }

    /// Leakage-free temporal backtest of the repo signal (for the eval harness).
    func repoBacktest(cutoffDays: Double, now: Date = Date())
        -> (n: Int, top1: Int, top3: Int, recurring: Int, recurringTop1: Int) {
        repoBridge.backtest(workspaceDirs: config.expandedWorkspaceDirs, cutoffDays: cutoffDays,
                            now: now) { self.guessableExtract($0) }
    }

    /// Build the per-candidate fusion feature vectors from a context document. Shared by live
    /// attribution and the offline evaluator. `excludingMemoryDoc` drops an exact label doc from
    /// the memory lookup (leave-one-out evaluation).
    private func buildFeatures(doc: String, repoName: String?, embedding: [String: Double],
                               llm: (key: String, confidence: Double)?,
                               learned: (ticket: String, count: Int)?,
                               excludingMemoryDoc: String? = nil) -> [String: FusionRanker.Features] {
        var feats: [String: FusionRanker.Features] = [:]
        func upd(_ key: String, _ f: (inout FusionRanker.Features) -> Void) {
            var x = feats[key] ?? FusionRanker.Features(); f(&x); feats[key] = x
        }
        let allow: (String) -> Bool = { !self.isExcluded($0) && (self.guessKeys.contains($0) || $0 == self.config.noTicketLabel) }

        if config.semanticEnabled {
            for g in matcher.rank(context: doc, max: 12) where allow(g.key) { upd(g.key) { $0.lexical = g.score } }
        }
        for m in labelMemory.nearest(context: doc, k: 8, excludingDoc: excludingMemoryDoc) where allow(m.ticket) {
            upd(m.ticket) { $0.memory = Swift.max($0.memory, m.score) }
        }
        for g in repoScore(repoName: repoName) where allow(g.key) { upd(g.key) { $0.repo = g.score } }
        for (k, s) in embedding where allow(k) { upd(k) { $0.embedding = s } }
        if let llm, allow(llm.key) { upd(llm.key) { $0.llmAgrees = true; $0.llmConfidence = llm.confidence } }
        if let l = learned, allow(l.ticket) { upd(l.ticket) { $0.correctionCount = Double(l.count) } }
        for key in feats.keys { upd(key) { $0.statusRecency = self.normalizedPrior(forKey: key) } }
        return feats
    }

    /// Offline evaluation of the text guesser on a labeled doc: lexical + leave-one-out memory +
    /// repo (parsed from the doc). Returns whether the true ticket is the top pick / within top 3,
    /// the fused probability, and whether the policy would auto-tag it. No embedding/LLM (those
    /// aren't reproducible offline). Used by `EvalHarness`.
    func evaluateDoc(_ doc: String, trueTicket: String) -> (top1: Bool, top3: Bool, p: Double, autoTagged: Bool) {
        let feats = buildFeatures(doc: doc, repoName: Self.parseRepo(doc), embedding: [:],
                                  llm: nil, learned: nil, excludingMemoryDoc: doc)
        let ranked = feats.map { (key: $0.key, p: FusionRanker.fuse($0.value, config.fusionWeights)) }
            .filter { $0.p > 0 }.sorted { $0.p > $1.p }
        guard let top = ranked.first else { return (false, false, 0, false) }
        let runner = ranked.dropFirst().first?.p ?? 0
        let names = ranked.map { $0.key }
        let decision = FusionRanker.decide(top: top.p, runnerUp: runner, tierFactor: 1.0, config.fusionWeights)
        return (names.first == trueTicket, names.prefix(3).contains(trueTicket), top.p, decision == .autoTag)
    }

    /// Best fused guess for a raw context document — used to pre-fill the guided Teach UI so the
    /// user can confirm with one click. Returns the top key when it clears the suggest threshold.
    func topGuess(forDoc doc: String) -> String? {
        let feats = buildFeatures(doc: doc, repoName: Self.parseRepo(doc), embedding: [:], llm: nil, learned: nil)
        let ranked = feats.map { (key: $0.key, p: FusionRanker.fuse($0.value, config.fusionWeights)) }
            .filter { $0.p > 0 }.sorted { $0.p > $1.p }
        guard let top = ranked.first, top.p >= config.fusionWeights.suggestThreshold else { return nil }
        return top.key
    }

    /// Pull the repo name out of a context document line "Repo: NAME (branch …)".
    static func parseRepo(_ doc: String) -> String? {
        for line in doc.split(separator: "\n") where line.hasPrefix("Repo: ") {
            let rest = line.dropFirst("Repo: ".count)
            return rest.split(separator: "(").first?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Seed `labels` from git history: each (repo, ticket) mined from branches/commits becomes a
    /// weak `backfill` example mapping a repo+commit-subject context to the ticket. Off-main
    /// (git + store writes). Returns rows inserted. Caller reloads memory on the main thread.
    @discardableResult
    func backfillFromHistory() -> Int {
        let examples = repoBridge.backfillExamples(workspaceDirs: config.expandedWorkspaceDirs) { self.guessableExtract($0) }
        var inserted = 0
        for e in examples where !isExcluded(e.ticket) {
            var lines = ["Repo: \(e.repo)" + (e.branch.map { " (branch \($0))" } ?? "")]
            if !e.subjects.isEmpty { lines.append("Recent commits: " + e.subjects.prefix(4).joined(separator: " | ")) }
            store.insertLabel(contextDoc: lines.joined(separator: "\n"), ticket: e.ticket, kind: "backfill")
            inserted += 1
        }
        return inserted
    }

    /// Rebuild the in-memory label index (call on the main thread after backfill/import).
    func reloadMemory() { labelMemory.reload() }

    /// Prior-weight breakdown for a ticket key (for the Inspector). Returns labeled factors + total.
    func priorBreakdown(forKey key: String) -> (factors: [(label: String, factor: Double)], total: Double)? {
        guard let t = sprint.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
        let factors = t.priorBreakdown(now: Date(), w: config.rankWeights, preferredStates: config.preferredTicketStatesLower)
        return (factors, factors.reduce(1.0) { $0 * $1.factor })
    }

    /// All assigned tickets (data lake / matcher corpus).
    /// Not-completed tickets (plus configured common tickets even if done) — for UI/LLM.
    var openTickets: [Ticket] { sprint.filter { !$0.done || $0.common } }

    /// Configured catch-all tickets present in the corpus.
    var commonTickets: [Ticket] { sprint.filter { $0.common } }

    /// Ordered list for the manual pickers: "(no ticket)" first, then common, then assigned.
    var pickerTickets: [Ticket] {
        var out = [Ticket(key: config.noTicketLabel, summary: "this work has no JIRA")]
        out += sprint.filter { $0.common }
        out += sprint.filter { !$0.done && !$0.common }
        return out
    }

    /// Numeric Jira issue id for a key, from the corpus (nil if not fetched).
    func issueId(forKey key: String) -> String? {
        sprint.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.issueId
    }

    /// Ticket objects for a list of keys (preserving order), for the LLM/UI layers.
    func tickets(for keys: [String]) -> [Ticket] {
        keys.compactMap { key in sprint.first { $0.key.caseInsensitiveCompare(key) == .orderedSame } }
    }

    /// Free-text extraction (no source hint) — used by `normalizeTicketEntry` and the data
    /// migration, where the caller has an arbitrary user/machine-supplied string, not a specific
    /// context field.
    func extractTicket(from text: String) -> String? {
        keyFormat.extract(from: text, source: .freeText)
    }

    /// Canonicalize a user/machine-supplied ticket string to a real key (or the no-ticket
    /// sentinel), returning nil for anything that isn't a valid ticket. This is the single
    /// chokepoint that keeps poison out of the store: a pasted Jira URL becomes "CLOUDINFRA-5119"
    /// (not the whole URL), an empty/garbage entry is rejected so callers can ignore it.
    /// Order: no-ticket sentinel → known corpus key (case-fixed) → format-canonicalized corpus
    /// match (e.g. a bare "48210" typed against an Azure Boards corpus) → key extracted from
    /// anywhere in the string → reject.
    func normalizeTicketEntry(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.caseInsensitiveCompare(config.noTicketLabel) == .orderedSame { return config.noTicketLabel }
        if let known = sprint.first(where: { $0.key.caseInsensitiveCompare(t) == .orderedSame }) { return known.key }
        if let canon = keyFormat.canonicalize(t),
           let known = sprint.first(where: { $0.key.caseInsensitiveCompare(canon) == .orderedSame }) {
            return known.key
        }
        if let key = extractTicket(from: t), !isExcluded(key) { return key }
        return nil
    }

    /// Strict source-aware extraction, non-excluded. When the format allows it, also accepts a
    /// bare number IFF it canonicalizes to a key that's actually in the live guess pool — this is
    /// what recovers e.g. a window title "48210: Fix the thing - Boards" without opening up bare
    /// numbers as a general false-positive magnet (a random number that isn't one of your open
    /// work items is simply ignored).
    private static let bareNumberRegex = try! NSRegularExpression(pattern: "\\d{3,7}")
    private func exactTicket(from text: String, source: KeySource) -> String? {
        if let strict = keyFormat.extract(from: text, source: source), !isExcluded(strict) { return strict }
        guard keyFormat.allowsBareNumberFallback else { return nil }
        // Try every bare number in the text (not just the first) against the live guess pool, so
        // e.g. "Q3 2026 Planning — 48210: Fix the thing" still resolves on the second number.
        let range = NSRange(text.startIndex..., in: text)
        for m in Self.bareNumberRegex.matches(in: text, range: range) {
            guard let r = Range(m.range, in: text) else { continue }
            let bare = String(text[r])
            if let canon = keyFormat.canonicalize(bare), !isExcluded(canon), guessKeys.contains(canon) {
                return canon
            }
        }
        return nil
    }

    private func category(text: String) -> String? {
        let hay = text.lowercased()
        for rule in config.categoryRules {
            if rule.anyOf.contains(where: { hay.contains($0.lowercased()) }) { return rule.category }
        }
        return nil
    }

    /// Matches Azure Repos' PR-review window title ("Pull request 32068: Add new php7.4 node 24
    /// image - Repos"), both the web UI and VS Code use this format. Only the PR number matters
    /// here — the resolved work item is a DIFFERENT id space than a ticket key, so this can't
    /// reuse `keyFormat.extract`.
    private static let prTitleRegex = try! NSRegularExpression(pattern: "(?i)pull request (\\d+)")
    func extractPRNumber(fromTitle title: String) -> Int? {
        let range = NSRange(title.startIndex..., in: title)
        guard let m = Self.prTitleRegex.firstMatch(in: title, range: range),
              let r = Range(m.range(at: 1), in: title) else { return nil }
        return Int(title[r])
    }

    /// PR id -> its linked work item, resolved live and kept only for this run (never persisted
    /// to sprint.json — it's a narrow, moment-specific exception, not a corpus widening). Set by
    /// the async resolver in main.swift once the network round trip completes; from then on the
    /// exact-match check in `decideAttribution` below fires purely from this in-memory map, no
    /// further network on the hot attribution path. The value is `Ticket??` (present-but-nil means
    /// "checked, no linked work item" — still worth remembering as code-review activity for
    /// `PeriodCompiler`'s generic-code-review fallback — vs. key-absent meaning "not checked yet").
    private var prReviewTickets: [Int: Ticket?] = [:]

    /// Called once a PR's linked-work-item lookup completes, successful or not. Merges a found
    /// ticket into the live guess pool too (not just the PR-id cache) so ranking/lexical-match/
    /// priorBreakdown treat it like any other candidate if it also turns up via other signals —
    /// e.g. its own title/branch. A nil `ticket` still records the PR as checked (source
    /// "prReview" fires with no key), so a PR with no board work item is recognized as code-review
    /// activity rather than falling through to ordinary fusion guessing.
    func cachePRReviewTicket(prId: Int, ticket: Ticket?) {
        prReviewTickets[prId] = ticket
        guard let ticket else { return }
        if !guessKeys.contains(ticket.key) {
            guessKeys.insert(ticket.key)
            guessTickets.append(ticket)
            if config.semanticEnabled { matcher.index(guessTickets, weights: config.rankWeights, preferredStates: config.preferredTicketStatesLower) }
        }
        if !sprint.contains(where: { $0.key == ticket.key }) { sprint.append(ticket) }
    }

    /// Attribute a moment of work from its enriched context, using only the synchronous
    /// (deterministic) signals. The async layers (embedding, LLM) re-run `decideAttribution`
    /// with their extra evidence once available.
    /// Exact ticket keys (URL → branch → title → commit → session) always beat the fused guess.
    func attribute(context ctx: WorkContext) -> AttributionResult {
        decideAttribution(context: ctx, embedding: [:], llm: nil)
    }

    /// The full attribution decision: exact-key short-circuits, then a calibrated late-fusion
    /// over every available signal. `embedding`/`llm` are the async corroborators, empty/nil on
    /// the synchronous path and supplied when those layers complete.
    func decideAttribution(context ctx: WorkContext,
                           embedding: [String: Double],
                           llm: (key: String, confidence: Double)?) -> AttributionResult {
        let cat = category(text: "\(ctx.app) \(ctx.title) \(ctx.url ?? "") \(ctx.meeting ?? "")")

        // 1) Exact keys — highest precision, always win.
        if let t = ctx.url.flatMap({ exactTicket(from: $0, source: .url) }) { return .init(ticket: t, source: "url", category: cat) }
        if let t = ctx.branch.flatMap({ exactTicket(from: $0, source: .branch) }) { return .init(ticket: t, source: "branch", category: cat) }
        if let t = exactTicket(from: ctx.title, source: .title) { return .init(ticket: t, source: "title", category: cat) }
        for c in ctx.commits {
            if let t = exactTicket(from: c, source: .commit) { return .init(ticket: t, source: "commit", category: cat) }
        }
        // The commit message you're typing right now often names the ticket — strong + current.
        if let t = ctx.scmMessage.flatMap({ exactTicket(from: $0, source: .commit) }) { return .init(ticket: t, source: "commit", category: cat) }
        if let t = ctx.aiSession.flatMap({ exactTicket(from: $0, source: .session) }) { return .init(ticket: t, source: "session", category: cat) }

        // 1a) Reviewing someone else's PR (window title "Pull request NNNN: ... - Repos") is an
        // exception to "only your own assigned tickets get exact treatment" — the work item was
        // resolved live via the AzDO API (see main.swift's PR-review resolver) specifically
        // because you're looking at it right now, regardless of who it's assigned to. A PR with no
        // linked work item still resolves the source to "prReview" (ticket nil, an abstain) rather
        // than falling through to fusion — PeriodCompiler recognizes it as code review either way.
        if let prId = extractPRNumber(fromTitle: ctx.title), let resolution = prReviewTickets[prId] {
            return .init(ticket: resolution?.key, source: "prReview", category: cat)
        }

        // 1b) A standing "this context is non-billable" rule resolves to no-ticket (still logged).
        // After exact keys, so an explicit key on a no-ticket app still wins.
        if !config.noTicketRules.isEmpty {
            let sigs = ctx.signatures()
            if config.noTicketRules.contains(where: { sigs.contains($0) }) {
                return .init(ticket: config.noTicketLabel, source: "rule", category: cat)
            }
        }

        // 2) A repeatedly-confirmed correction for this context short-circuits fusion. Gated by
        // guessKeys/noTicketLabel like every other signal (buildFeatures' `allow`, below) — without
        // this, a correction learned under a PREVIOUSLY configured provider would resolve as an
        // exact, never-overridden attribution to a key the current corpus can't even recognize.
        let learned = corrections.best(forSignatures: ctx.signatures())
        if let l = learned, l.count >= 2, !isExcluded(l.ticket),
           guessKeys.contains(l.ticket) || l.ticket == config.noTicketLabel {
            return .init(ticket: l.ticket, source: "learned", category: cat,
                         confidence: 1.0, candidates: [TicketGuess(key: l.ticket, score: 1.0)])
        }

        // 3) Gather every signal as per-candidate features.
        let feats = buildFeatures(doc: ctx.document, repoName: ctx.repo, embedding: embedding,
                                  llm: llm, learned: learned)
        guard !feats.isEmpty else { return .init(ticket: nil, source: nil, category: cat) }

        // 4) Fuse → rank. If we're in a repo that's entirely outside the ticket universe (no mined
        // ticket history AND no ticket names it — e.g. a local no-Jira tool project), damp every
        // candidate so ambient session text can't drive a confident wrong guess.
        let damp = repoOutsideTicketUniverse(ctx.repo) ? config.fusionWeights.ungroundedRepoDamp : 1.0
        let ranked = feats.map { (key: $0.key, p: FusionRanker.fuse($0.value, config.fusionWeights) * damp, f: $0.value) }
            .filter { $0.p > 0 }
            .sorted { $0.p > $1.p }
        guard let top = ranked.first else { return .init(ticket: nil, source: nil, category: cat) }
        let runner = ranked.dropFirst().first?.p ?? 0
        let candidates = ranked.prefix(config.semanticMaxCandidates).map { TicketGuess(key: $0.key, score: $0.p) }

        // 5) Precision-first decision, stricter in noisy contexts.
        switch FusionRanker.decide(top: top.p, runnerUp: runner, tierFactor: tierFactor(ctx, cat), config.fusionWeights) {
        case .autoTag:
            return .init(ticket: top.key, source: dominantSource(top.f), category: cat,
                         confidence: top.p, candidates: candidates)
        case .suggest:
            return .init(ticket: nil, source: nil, category: cat, confidence: top.p, candidates: candidates)
        case .abstain:
            return .init(ticket: nil, source: nil, category: cat)
        }
    }

    /// Ticket prior (status/sprint/recency) mapped to a mild [0,1] fusion feature: 0 for a
    /// neutral/penalized ticket, rising as boosts (In Progress, active sprint, recently updated)
    /// stack. Kept small via its low reliability so it only breaks near-ties.
    private func normalizedPrior(forKey key: String) -> Double {
        guard let t = sprint.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { return 0 }
        return Swift.max(0, Swift.min(1, t.priorWeight(now: Date(), w: config.rankWeights, preferredStates: config.preferredTicketStatesLower) - 1.0))
    }

    /// Stiffen the auto-tag bar in noisy contexts: a workspace repo is trustworthy (1.0), web
    /// pages a bit less, and browser/Slack/email with no repo should effectively only suggest.
    private func tierFactor(_ ctx: WorkContext, _ cat: String?) -> Double {
        if ctx.repo != nil { return 1.0 }
        switch cat {
        case "browsing", "messaging", "email", "meeting": return config.fusionWeights.tierBrowserMessaging
        case "jira", "docs": return config.fusionWeights.tierWebDocs
        default: return ctx.url != nil ? config.fusionWeights.tierWebDocs : 1.0
        }
    }

    /// Name the signal that contributed most to a fused pick, for the segment's `ticket_source`
    /// and the Inspector. Mirrors FusionRanker's reliabilities.
    private func dominantSource(_ f: FusionRanker.Features) -> String {
        let w = config.fusionWeights
        var best = ("guess", 0.0)
        func consider(_ name: String, _ v: Double) { if v > best.1 { best = (name, v) } }
        consider("semantic", w.lexical * f.lexical)
        consider("memory", w.memory * f.memory)
        consider("repo", w.repo * f.repo)
        consider("embed", w.embedding * f.embedding)
        consider("llm", w.llm * (f.llmAgrees ? Swift.max(0.5, f.llmConfidence) : 0))
        consider("learned", w.correction * (f.correctionCount > 0 ? 1 : 0))
        return best.0
    }

    /// One-time data hygiene across labels, segments, and the correction store: repairs pasted
    /// URLs to their key and drops un-parseable entries (the source of the poisoned
    /// "HTTPS://…/BROWSE/CLOUDINFRA-5119" rows). Idempotent — safe to re-run.
    @discardableResult
    func runDataMigration() -> String {
        let l = store.sanitizeLabels { self.normalizeTicketEntry($0) }
        let s = store.sanitizeSegmentTickets { self.normalizeTicketEntry($0) }
        let c = corrections.sanitize { self.normalizeTicketEntry($0) }
        labelMemory.reload()
        return "labels(deleted \(l.deleted), repaired \(l.repaired)) · segments(nulled \(s.nulled), repaired \(s.repaired)) · corrections(changed \(c))"
    }

    /// Mark a context as non-billable no-ticket and learn it (negative content example + signature
    /// bias), so similar future work resolves to no-ticket instead of nagging.
    func recordNoTicket(context: WorkContext) {
        recordCorrection(context: context, ticket: config.noTicketLabel)
    }

    /// Add a persistent "always no-ticket" rule. Takes effect immediately (in-memory) and persists
    /// to disk without clobbering unrelated settings edits made since launch.
    func addNoTicketRule(_ signature: String) {
        if !config.noTicketRules.contains(signature) { config.noTicketRules.append(signature) }
        var disk = Config.load()
        if !disk.noTicketRules.contains(signature) { disk.noTicketRules.append(signature); disk.save() }
    }

    /// The best signature to offer as a persistent "always no-ticket" rule. A repo with no ticket
    /// history anywhere is the canonical no-Jira project, so offer it first; otherwise a URL host
    /// or app. Nil if already covered / nothing fitting.
    func noTicketRuleCandidate(for ctx: WorkContext) -> String? {
        if let repo = ctx.repo, !repoBridge.has(repo: repo) {
            let sig = "repo:\(repo)"
            if !config.noTicketRules.contains(sig) { return sig }
        }
        let sigs = ctx.signatures()
        let pick = sigs.first { $0.hasPrefix("host:") } ?? sigs.first { $0.hasPrefix("app:") }
        guard let pick, !config.noTicketRules.contains(pick) else { return nil }
        return pick
    }

    /// True if the active repo has no connection to any ticket: not in the mined git→ticket bridge
    /// AND not named by any guessable ticket's text. Such work (a local tool, a no-Jira project)
    /// shouldn't get a confident guess from ambient text.
    private func repoOutsideTicketUniverse(_ repo: String?) -> Bool {
        guard let repo, !repo.isEmpty else { return false }
        if repoBridge.has(repo: repo) { return false }
        let r = repo.lowercased()
        guard r.count > 2 else { return true }
        return !guessTickets.contains { $0.matchText.lowercased().contains(r) }
    }

    /// Ranked candidates for a context doc with descriptions + dominant signal — for the review's
    /// "why / alternatives" UI. Deterministic signals only (embedding/LLM are live-only).
    func explain(doc: String) -> [(key: String, summary: String, score: Double, source: String)] {
        let feats = buildFeatures(doc: doc, repoName: Self.parseRepo(doc), embedding: [:], llm: nil, learned: nil)
        return feats.map { (key: $0.key, p: FusionRanker.fuse($0.value, config.fusionWeights), f: $0.value) }
            .filter { $0.p > 0 }.sorted { $0.p > $1.p }.prefix(5)
            .map { (key: $0.key, summary: self.summary(for: $0.key) ?? "", score: $0.p, source: self.dominantSource($0.f)) }
    }

    /// Persist a user-confirmed (context → ticket) example: signature bias + content memory.
    func recordCorrection(context: WorkContext, ticket: String) {
        guard !ticket.isEmpty else { return }
        corrections.record(signatures: context.signatures(), ticket: ticket)
        store.insertLabel(contextDoc: context.document, ticket: ticket, kind: "correction")
        labelMemory.reload()
    }

    /// Explicit teaching example (from the Teach UI). `signatures` optional for signature bias.
    func recordTraining(contextDoc: String, ticket: String, signatures: [String] = []) {
        guard !ticket.isEmpty else { return }
        if !signatures.isEmpty { corrections.record(signatures: signatures, ticket: ticket) }
        store.insertLabel(contextDoc: contextDoc, ticket: ticket, kind: "training")
        labelMemory.reload()
    }

    var labelCount: Int { labelMemory.count }

    // MARK: - Introspection (for the Inspector view)

    func lexicalRank(_ ctx: WorkContext) -> [TicketGuess] {
        matcher.rank(context: ctx.document, max: 8)
    }
    func memoryNearest(_ ctx: WorkContext, k: Int = 6) -> [(ticket: String, score: Double, doc: String)] {
        labelMemory.nearest(context: ctx.document, k: k)
    }

    /// Few-shot examples (similar past labels) to ground the LLM.
    func fewShot(context: String, k: Int) -> [(context: String, ticket: String)] {
        labelMemory.fewShot(context: context, k: k)
    }

    /// Resolve a key to a sprint summary if known.
    func summary(for key: String) -> String? {
        sprint.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.summary
    }
}
