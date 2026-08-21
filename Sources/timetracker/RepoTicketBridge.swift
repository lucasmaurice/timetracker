import Foundation

/// Maps each workspace repo to the tickets recently worked *in that repo*, mined from local
/// git history (branch names + commit subjects). This is the single strongest grounded signal
/// for infra work: you're almost always in a repo, and a repo maps to a small, recency-skewed
/// set of tickets — even when the *current* branch/commit names no key.
///
/// Weights are **recency-decayed** (a ticket you touched here last week beats one from last
/// quarter) and normalized to [0,1] per repo. Persisted to `repo-tickets.json`; rebuilt in the
/// background on launch and after each sprint refresh. Fully local, zero dependencies.
/// `@unchecked Sendable`: every access to `map` goes through the serial `queue` below, and the
/// remaining stored properties are `let`. This is what lets the launch mining pass hold it
/// directly instead of capturing `Attribution`, whose `sprint`/`guessKeys` are main-owned and
/// genuinely unguarded.
final class RepoTicketBridge: @unchecked Sendable {
    struct Stat: Codable { var score: Double; var lastSeen: Double }  // decayed weight + newest unix ts

    private var map: [String: [String: Stat]] = [:]   // repoName -> (ticket -> stat)
    private let file = AppPaths.dataDir.appendingPathComponent("repo-tickets.json")
    private let queue = DispatchQueue(label: "ca.justereseau.timetracker.repobridge")

    /// Half-life of a git occurrence's contribution, in days. ~6 weeks: recent work dominates
    /// but a steady-state repo still accumulates its long-running ticket.
    private let halfLifeDays: Double = 42

    init() { load() }

    /// Recency-decayed candidates for a repo as a **share** of the repo's total ticket mass —
    /// i.e. ≈ P(ticket | working in this repo, weighted by recency), in [0,1]. A repo that maps
    /// overwhelmingly to one ticket yields a high share (strong); a repo spread across many
    /// yields low shares (weak). This absolute confidence is what fusion needs (max-normalization
    /// would make the top always 1.0). `keep` filters to the guessable pool.
    func score(repo: String?, keep: (String) -> Bool) -> [TicketGuess] {
        guard let repo, let stats = queue.sync(execute: { map[repo] }) else { return [] }
        let usable = stats.filter { keep($0.key) }
        let total = usable.values.reduce(0) { $0 + $1.score }
        guard total > 0 else { return [] }
        return usable
            .map { TicketGuess(key: $0.key, score: $0.value.score / total) }
            .sorted { $0.score > $1.score }
    }

    /// Top tickets per repo (raw decayed scores), for diagnostics / the eval harness.
    func summary(topPerRepo: Int = 3) -> [(repo: String, tickets: [(String, Double)])] {
        let snapshot = queue.sync { map }
        return snapshot
            .map { (repo: $0.key, tickets: $0.value.sorted { $0.value.score > $1.value.score }
                        .prefix(topPerRepo).map { ($0.key, $0.value.score) }) }
            .sorted { $0.repo < $1.repo }
    }

    /// Every ticket key mined from any repo's history — used to widen the guess pool so a ticket
    /// you've actually worked on is eligible even if it isn't in your assigned-open set.
    func allMinedKeys() -> Set<String> {
        queue.sync { Set(map.values.flatMap { $0.keys }) }
    }

    /// True if we have any mined history for this repo.
    func has(repo: String?) -> Bool {
        guard let repo else { return false }
        return queue.sync { map[repo]?.isEmpty == false }
    }

    /// Mine each workspace repo's branches + commits for ticket keys and persist. Heavy (spawns
    /// git per repo) — call off the main thread. `extract` pulls a key from a string (reuses the
    /// app's ticket regex); `now` is injected for deterministic decay.
    func rebuild(workspaceDirs: [URL], now: Date, extract: (String) -> String?) {
        let fm = FileManager.default
        var fresh: [String: [String: Stat]] = [:]

        for dir in workspaceDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in entries {
                let repoPath = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: repoPath.appendingPathComponent(".git").path) else { continue }
                var stats: [String: Stat] = [:]
                ingest(into: &stats, occurrences: branchOccurrences(repoPath.path), now: now, extract: extract)
                ingest(into: &stats, occurrences: commitOccurrences(repoPath.path), now: now, extract: extract)
                if !stats.isEmpty { fresh[name] = stats }
            }
        }
        queue.sync { map = fresh }
        save()
    }

    /// All (repo, ticket, commitSubjects) triples for the history backfill — one entry per
    /// (repo, ticket) with a few representative commit subjects, so LabelMemory gets repo +
    /// commit-subject vocabulary mapped to the ticket.
    func backfillExamples(workspaceDirs: [URL], extract: (String) -> String?) -> [(repo: String, ticket: String, branch: String?, subjects: [String])] {
        let fm = FileManager.default
        var out: [(repo: String, ticket: String, branch: String?, subjects: [String])] = []
        for dir in workspaceDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in entries {
                let repoPath = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: repoPath.appendingPathComponent(".git").path) else { continue }
                var byTicket: [String: (branch: String?, subjects: [String])] = [:]
                for (ref, _) in branchOccurrences(repoPath.path) {
                    if let key = extract(ref) {
                        var e = byTicket[key] ?? (branch: nil, subjects: [])
                        if e.branch == nil { e.branch = ref }
                        byTicket[key] = e
                    }
                }
                for (subject, _) in commitOccurrences(repoPath.path) {
                    if let key = extract(subject) {
                        var e = byTicket[key] ?? (branch: nil, subjects: [])
                        if e.subjects.count < 4, !e.subjects.contains(subject) { e.subjects.append(subject) }
                        byTicket[key] = e
                    }
                }
                for (ticket, e) in byTicket { out.append((name, ticket, e.branch, e.subjects)) }
            }
        }
        return out
    }

    /// Temporal backtest of the repo signal: build each repo's ticket ranking from commits OLDER
    /// than `cutoffDays`, then check whether it predicts the ticket of each NEWER commit. This is
    /// leakage-free (test commits aren't in the training window) and answers the real runtime
    /// question: "from past history in this repo, can we name the ticket of current work?"
    func backtest(workspaceDirs: [URL], cutoffDays: Double, now: Date, extract: (String) -> String?)
        -> (n: Int, top1: Int, top3: Int, recurring: Int, recurringTop1: Int) {
        let fm = FileManager.default
        let cutoff = now.timeIntervalSince1970 - cutoffDays * 86400
        let halfLifeSecs = halfLifeDays * 86400
        var n = 0, t1 = 0, t3 = 0, rec = 0, recT1 = 0
        for dir in workspaceDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in entries {
                let repoPath = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: repoPath.appendingPathComponent(".git").path) else { continue }
                var train: [String: Double] = [:]
                var test: [String] = []
                for (subject, ts) in commitOccurrences(repoPath.path) {
                    guard let key = extract(subject) else { continue }
                    if ts < cutoff { train[key, default: 0] += pow(0.5, (cutoff - ts) / halfLifeSecs) }
                    else { test.append(key) }
                }
                guard !train.isEmpty, !test.isEmpty else { continue }
                let ranked = train.sorted { $0.value > $1.value }.map(\.key)
                let top3 = Set(ranked.prefix(3))
                for trueKey in test {
                    n += 1
                    let seen = train[trueKey] != nil
                    if ranked.first == trueKey { t1 += 1 }
                    if top3.contains(trueKey) { t3 += 1 }
                    if seen { rec += 1; if ranked.first == trueKey { recT1 += 1 } }
                }
            }
        }
        return (n, t1, t3, rec, recT1)
    }

    // MARK: - Git mining

    /// (branch-name, committer-unix-ts) for local heads.
    private func branchOccurrences(_ repoPath: String) -> [(String, Double)] {
        guard let out = Shell.git(["-C", repoPath, "for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)", "refs/heads"]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard let name = parts.first else { return nil }
            let ts = parts.count > 1 ? Double(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
            return (String(name), ts)
        }
    }

    /// (commit-subject, commit-unix-ts) for the last N commits across all refs.
    private func commitOccurrences(_ repoPath: String, limit: Int = 500) -> [(String, Double)] {
        guard let out = Shell.git(["-C", repoPath, "log", "--all", "--no-merges", "-n", "\(limit)", "--pretty=%ct\t%s"]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[1]), Double(parts[0]) ?? 0)
        }
    }

    private func ingest(into stats: inout [String: Stat], occurrences: [(String, Double)],
                        now: Date, extract: (String) -> String?) {
        ingestKeyed(into: &stats, occurrences: occurrences.compactMap { text, ts in
            extract(text).map { (key: $0, ts: ts) }
        }, now: now)
    }

    private func ingestKeyed(into stats: inout [String: Stat], occurrences: [(key: String, ts: Double)], now: Date) {
        let nowTs = now.timeIntervalSince1970
        let halfLifeSecs = halfLifeDays * 86400
        for (key, ts) in occurrences {
            let age = max(0, nowTs - ts)
            let decay = ts > 0 ? pow(0.5, age / halfLifeSecs) : 0.25  // undated ref: small flat weight
            var s = stats[key] ?? Stat(score: 0, lastSeen: 0)
            s.score += decay
            s.lastSeen = Swift.max(s.lastSeen, ts)
            stats[key] = s
        }
    }

    /// Merge externally-resolved (key, timestamp) pairs into a repo's stats — used by the Azure
    /// Repos PR→work-item bridge, whose keys come from a network lookup rather than a regex over
    /// local text, so they can't flow through `rebuild`'s synchronous `extract` closure. MUST run
    /// **after** `rebuild()` for the same repos: `rebuild` replaces `map` wholesale, so calling
    /// this first would have its merge silently wiped.
    func ingestResolvedKeys(repo: String, keys: [(key: String, ts: Double)], now: Date) {
        guard !keys.isEmpty else { return }
        queue.sync {
            var stats = map[repo] ?? [:]
            ingestKeyed(into: &stats, occurrences: keys, now: now)
            map[repo] = stats
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode([String: [String: Stat]].self, from: data) else { return }
        queue.sync { map = m }
    }

    private func save() {
        let snapshot = queue.sync { map }
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: [.atomic]) }
    }
}
