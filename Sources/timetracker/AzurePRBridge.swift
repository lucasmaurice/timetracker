import Foundation

/// Resolves Azure Repos pull requests to their linked work items, restoring the git-mined
/// repo→ticket signal for Azure DevOps. Jira gets this signal for free from branch/commit ticket
/// keys; a real Azure Repos org checked while building this has commits that read
/// `Merged PR <id>: ...` (a merge-commit completion strategy) with no `AB#` reference anywhere,
/// so `RepoTicketBridge`'s local text-mining alone finds nothing to work with.
///
/// One list-PRs call per repo (cheap, recent history only — the decay in `RepoTicketBridge` makes
/// old PRs contribute almost nothing regardless), falling back to a per-PR `/workitems` lookup
/// only for PRs where no key was found in title/description/branch text — bounded, and negative
/// results are cached too, so unresolvable PRs aren't re-requested on every launch.
/// `@unchecked Sendable`: `cache` is guarded by `cacheQueue`; everything else is immutable.
final class AzurePRBridge: @unchecked Sendable {
    private struct CacheEntry: Codable { var workItemKeys: [String]; var closedAt: Double }
    /// repo -> prId -> resolved keys (+ closed timestamp). Empty `workItemKeys` = confirmed
    /// unresolved (the negative cache).
    private var cache: [String: [String: CacheEntry]] = [:]
    /// Guards `cache`. Today this runs only from the single launch mining pass, so the map is
    /// never touched concurrently — but "safe because only one caller exists" is a property of the
    /// callers, not of this type, and it is one refactor from being false.
    private let cacheQueue = DispatchQueue(label: "ca.justereseau.timetracker.prbridge")
    private let file = AppPaths.dataDir.appendingPathComponent("pr-workitems.json")
    /// Strict extraction only (AB#1234 or a leading-digit branch name) — no corpus-gated bare
    /// number fallback here, since that needs the live guess pool this bridge doesn't have access
    /// to and isn't needed: PR titles/descriptions reliably carry the AB# form when they carry one.
    private let keyFormat = AzureBoardsKeyFormat(branchPattern: "(?:^|/)(\\d+)[-_]")

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode([String: [String: CacheEntry]].self, from: data) else { return }
        cache = m
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: [.atomic]) }
    }

    /// Resolve every workspace repo hosted on Azure Repos to (key, timestamp) pairs ready for
    /// `RepoTicketBridge.ingestResolvedKeys`. Network work; call off the main thread, and call it
    /// AFTER `RepoTicketBridge.rebuild` for the same repos — `rebuild` replaces its map wholesale,
    /// so ingesting before it would have the merge silently wiped.
    func resolve(workspaceDirs: [URL], azureDevOps: AzureDevOps, now: Date) async -> [(repo: String, keys: [(key: String, ts: Double)])] {
        guard let connectedOrg = azureDevOps.connectedOrg else { return [] }
        let fm = FileManager.default
        var out: [(repo: String, keys: [(key: String, ts: Double)])] = []
        for dir in workspaceDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in entries {
                let repoPath = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: repoPath.appendingPathComponent(".git").path) else { continue }
                guard let remote = Self.azureRemote(repoPath: repoPath.path),
                      remote.org.caseInsensitiveCompare(connectedOrg) == .orderedSame
                else { continue }   // not an Azure Repos remote, or hosted in a different org than the PAT
                let keys = await resolveRepo(project: remote.project, repo: remote.repo, azureDevOps: azureDevOps, now: now)
                if !keys.isEmpty { out.append((name, keys)) }
            }
        }
        save()
        return out
    }

    // MARK: - git remote parsing

    private struct Remote { var org: String; var project: String; var repo: String }

    /// Parse `git remote -v` for an Azure Repos URL, in either HTTPS or SSH form:
    ///   https://{org}@dev.azure.com/{org}/{project}/_git/{repo}   (note the `{org}@` userinfo)
    ///   https://dev.azure.com/{org}/{project}/_git/{repo}
    ///   git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
    /// Project/repo segments may be percent-encoded ("My%20Project").
    private static func azureRemote(repoPath: String) -> Remote? {
        guard let out = Shell.git(["-C", repoPath, "remote", "-v"]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count > 1, let urlPart = parts[1].split(separator: " ").first else { continue }
            let url = String(urlPart)
            if let m = firstMatch(httpsRegex, in: url) { return m }
            if let m = firstMatch(sshRegex, in: url) { return m }
        }
        return nil
    }

    private static let httpsRegex = try! NSRegularExpression(
        pattern: "dev\\.azure\\.com/(?:[^/@\\s]+@)?([^/\\s]+)/([^/\\s]+)/_git/([^/\\s]+)", options: [.caseInsensitive])
    private static let sshRegex = try! NSRegularExpression(
        pattern: "ssh\\.dev\\.azure\\.com:v3/([^/\\s]+)/([^/\\s]+)/([^/\\s]+)", options: [.caseInsensitive])

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Remote? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges == 4 else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r]).removingPercentEncoding ?? String(text[r])
        }
        guard let org = group(1), let project = group(2), var repo = group(3) else { return nil }
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return Remote(org: org, project: project, repo: repo)
    }

    // MARK: - Resolution

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func parseDate(_ s: String?) -> Double? {
        guard let s else { return nil }
        return (ISO8601DateFormatter().date(from: s) ?? isoFractional.date(from: s))?.timeIntervalSince1970
    }

    private func resolveRepo(project: String, repo: String, azureDevOps: AzureDevOps, now: Date) async -> [(key: String, ts: Double)] {
        guard let prs = await azureDevOps.listCompletedPullRequests(project: project, repo: repo) else { return [] }
        var repoCache = cacheQueue.sync { cache[repo] ?? [:] }
        var out: [(key: String, ts: Double)] = []
        var unresolvedIds: [Int] = []
        var tsById: [Int: Double] = [:]

        for pr in prs {
            let ts = Self.parseDate(pr.closedDate) ?? now.timeIntervalSince1970
            tsById[pr.id] = ts
            let prIdStr = "\(pr.id)"
            if let cached = repoCache[prIdStr] {
                for k in cached.workItemKeys { out.append((k, ts)) }
                continue
            }
            // Title/description only ever carry the explicit "AB#1234" form; the branch name is
            // checked separately with the branch-specific pattern (a leading-digit branch like
            // "users/lm/48210-fix" has no "AB#" anywhere, so folding it into the .commit-source
            // text above would silently miss it — .commit only tries the AB# regex).
            let text = "\(pr.title) \(pr.description)"
            if let key = keyFormat.extract(from: text, source: .commit) ?? keyFormat.extract(from: pr.sourceBranch, source: .branch) {
                out.append((key, ts))
                repoCache[prIdStr] = CacheEntry(workItemKeys: [key], closedAt: ts)
            } else {
                unresolvedIds.append(pr.id)
            }
        }

        // Fall back to the per-PR endpoint only for the unresolved remainder, capped — one
        // network call each, and AzDO throttles aggressively.
        for prId in unresolvedIds.prefix(30) {
            let ts = tsById[prId] ?? now.timeIntervalSince1970
            let keys = await azureDevOps.workItemsLinkedToPullRequest(project: project, repo: repo, pullRequestId: prId)
            repoCache["\(prId)"] = CacheEntry(workItemKeys: keys, closedAt: ts)   // cached even when empty (negative cache)
            for k in keys { out.append((k, ts)) }
        }

        cacheQueue.sync { cache[repo] = repoCache }
        return out
    }
}
