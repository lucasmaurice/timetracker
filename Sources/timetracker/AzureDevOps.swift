import Foundation

/// Azure DevOps work-item client using a Personal Access Token (HTTP Basic, base64 of ":<PAT>").
/// Mirrors `Atlassian`'s shape (Credentials in the Keychain, preload-once, refreshSprint writes
/// sprint.json) so the rest of the app doesn't need to know which provider is active.
///
/// Two-call fetch, same as the WIQL REST contract requires: WIQL returns ids only regardless of
/// the SELECT list, so fields always come from a second `workitemsbatch` call. State→category
/// (done / prior boost) is resolved from each work item TYPE's real state metadata, never a
/// hardcoded state-name list — process templates vary per project (confirmed against a live
/// ProgiDev/DevOps project: Task and User Story states include "Dev" and "Resolved", neither of
/// which is a standard Agile-template name, and "Resolved" categorizes as InProgress there, not a
/// distinct Resolved category).
final class AzureDevOps: IssueProvider {
    var displayName: String { "Azure DevOps" }
    struct Credentials: Codable { var org: String; var pat: String }

    private static let account = "azdo_credentials"
    private let config: Config

    init(config: Config) { self.config = config }

    private var loaded = false
    private var cached: Credentials?
    private var credentials: Credentials? { cached }
    var configured: Bool { cached != nil }
    /// The connected organization, for `AzurePRBridge` to skip repos hosted in a different org
    /// than the PAT is scoped to (a PAT is always single-org).
    var connectedOrg: String? { cached?.org }
    /// The PAT owner's display name, for the menu's "Connected as … " line. Resolved lazily (once
    /// per session, from `refreshSprint`) rather than at `preload()` — preload must stay
    /// network-free (see CLAUDE.md's threading invariants), so this is nil until the first
    /// refresh (launch or manual) completes.
    private var cachedUser: String?
    var connectedUser: String? { cachedUser }

    func preload() {
        guard !loaded else { return }
        cached = Keychain.getCodable(Credentials.self, account: Self.account)
        loaded = true
    }

    func disconnect() {
        Keychain.delete(account: Self.account)
        cached = nil; loaded = true
    }

    @discardableResult
    func connect(org: String, pat: String) async throws -> String {
        let trimmedOrg = org.trimmingCharacters(in: .whitespaces)
        let creds = Credentials(org: trimmedOrg, pat: pat)
        // In memory first so testConnection() can use them, but persist ONLY once they're known
        // good. Writing first left an unverified PAT on disk whenever the test threw, recoverable
        // only because the caller happens to call disconnect() in its catch — an invariant about
        // secret storage shouldn't depend on every future call site's error handling.
        cached = creds; loaded = true
        let who = try await testConnection()
        Keychain.setCodable(creds, account: Self.account)   // own the item under THIS binary
        return who
    }

    // MARK: - Requests

    private func authedRequest(url: URL) throws -> URLRequest {
        guard let creds = credentials else { throw AzureDevOpsError.notConfigured }
        let basic = Data(":\(creds.pat)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func orgBase() throws -> String {
        guard let org = credentials?.org, !org.isEmpty else { throw AzureDevOpsError.notConfigured }
        return "https://dev.azure.com/\(org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org)"
    }

    /// Validate the PAT against a cheap org-level call. Returns a display string.
    @discardableResult
    func testConnection() async throws -> String {
        guard let url = URL(string: "\(try orgBase())/_apis/projects?api-version=7.1&$top=1") else {
            throw AzureDevOpsError.badURL
        }
        let (data, resp) = try await URLSession.shared.data(for: try authedRequest(url: url))
        try Self.check(resp, data)
        return credentials?.org ?? "connected"
    }

    private struct ConnectionData: Decodable {
        struct AuthenticatedUser: Decodable { var providerDisplayName: String?; var customDisplayName: String? }
        var authenticatedUser: AuthenticatedUser?
    }

    /// The PAT owner's identity, via the same connection-negotiation endpoint AzDO's own tooling
    /// (e.g. the git credential helper) uses to validate a PAT — confirmed needing no scope beyond
    /// what's already granted for Work Items/Code, unlike the Profile API
    /// (app.vssps.visualstudio.com/_apis/profile/profiles/me), which 401'd against a real PAT
    /// scoped exactly as this app's own connect dialog instructs. Reuses `orgBase()` (same host as
    /// every other call in this file). Cached for the session; a failure just means the menu omits
    /// the "as <user>" part (cosmetic, not functional), but logs the actual status/body to stderr
    /// (~/Library/Application Support/TimeTracker/stderr.log when run via the LaunchAgent).
    private func resolveIdentity() async {
        guard cachedUser == nil else { return }
        // connectionData is a preview-only resource — confirmed via a real 400
        // (VssInvalidPreviewVersionException) against plain api-version=7.1. Pin the REVISION
        // (-preview.1), not a bare -preview: Microsoft deprecates a preview once its released
        // version ships and deactivates it ~12 weeks later, after which requests naming a preview
        // version are rejected outright. A bare -preview is the least specific form there is, so
        // it's the first to break.
        guard let url = URL(string: "\((try? orgBase()) ?? "")/_apis/connectionData?api-version=7.1-preview.1"),
              let req = try? authedRequest(url: url)
        else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            FileHandle.standardError.write("azdo identity: request failed (network)\n".data(using: .utf8)!)
            return
        }
        do {
            try Self.check(resp, data)
        } catch {
            let body = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            FileHandle.standardError.write("azdo identity: \(error.localizedDescription) — body: \(body)\n".data(using: .utf8)!)
            return
        }
        guard let profile = (try? JSONDecoder().decode(ConnectionData.self, from: data))?.authenticatedUser else {
            let body = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            FileHandle.standardError.write("azdo identity: decode failed — body: \(body)\n".data(using: .utf8)!)
            return
        }
        cachedUser = profile.customDisplayName ?? profile.providerDisplayName
        if cachedUser == nil {
            FileHandle.standardError.write("azdo identity: decoded authenticatedUser had no display name\n".data(using: .utf8)!)
        }
    }

    /// 7pace and worklog submission need no AzDO identity — `resolveAuthor` on `WorklogProvider`
    /// only matters for Tempo. `fetchIssueId` for AzDO is just the numeric part of "AB#12345",
    /// already known locally — no network round trip needed, unlike Jira where the corpus doesn't
    /// always carry a resolvable id for a key typed by hand.
    func fetchIssueId(forKey key: String) async -> String? {
        AzureBoardsKeyFormat(branchPattern: config.azureBranchKeyPattern).canonicalize(key)
            .flatMap { $0.hasPrefix("AB#") ? String($0.dropFirst(3)) : nil }
    }

    /// Unlike the PR→work-item API lookups (which accept a bare id org-wide), the web UI edit URL
    /// genuinely needs a project segment to resolve — confirmed against a real link
    /// (https://dev.azure.com/ProgiDev/DevOps/_workitems/edit/59482). `project` should be the
    /// ticket's own stored `Ticket.project`; falls back to `config.azureProject` if that's nil
    /// (e.g. a single-project setup, or a ticket predating this field), and gives up rather than
    /// guess wrong if neither is known.
    func browserURL(forKey key: String, project: String?) -> URL? {
        let proj = (project?.isEmpty == false ? project : nil) ?? config.azureProject
        guard let org = connectedOrg, !proj.isEmpty,
              let id = AzureBoardsKeyFormat(branchPattern: config.azureBranchKeyPattern).canonicalize(key)
                  .flatMap({ $0.hasPrefix("AB#") ? String($0.dropFirst(3)) : nil })
        else { return nil }
        let encodedOrg = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org
        let encodedProject = proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj
        return URL(string: "https://dev.azure.com/\(encodedOrg)/\(encodedProject)/_workitems/edit/\(id)")
    }

    // MARK: - Pull requests (for AzurePRBridge)

    struct PullRequestSummary { var id: Int; var title: String; var description: String; var sourceBranch: String; var closedDate: String? }

    /// Recently completed PRs for a repo — one call, not paginated further; a repo→ticket signal
    /// only needs recent history, and the decay in `RepoTicketBridge` makes old PRs contribute
    /// almost nothing anyway. `repo` accepts the repository name directly (the API takes name or
    /// GUID interchangeably), so no separate name→id lookup is needed.
    func listCompletedPullRequests(project: String, repo: String, top: Int = 200) async -> [PullRequestSummary]? {
        guard let base = try? orgBase() else { return nil }
        let projPath = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        let repoPath = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        guard let url = URL(string: "\(base)/\(projPath)/_apis/git/repositories/\(repoPath)/pullrequests"
            + "?searchCriteria.status=completed&$top=\(top)&api-version=7.1") else { return nil }
        struct Resp: Decodable {
            struct PR: Decodable { var pullRequestId: Int; var title: String?; var description: String?; var sourceRefName: String?; var closedDate: String? }
            var value: [PR]
        }
        guard let req = try? authedRequest(url: url),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (try? Self.check(resp, data)) != nil,
              let parsed = try? JSONDecoder().decode(Resp.self, from: data)
        else { return nil }
        return parsed.value.map {
            PullRequestSummary(id: $0.pullRequestId, title: $0.title ?? "", description: $0.description ?? "",
                               sourceBranch: $0.sourceRefName ?? "", closedDate: $0.closedDate)
        }
    }

    /// Work items linked to one PR — the fallback for PRs where no key was found in
    /// title/description/branch text. Bounded to the unresolved remainder by the caller
    /// (`AzurePRBridge`), since this is one call per PR and AzDO throttles aggressively.
    func workItemsLinkedToPullRequest(project: String, repo: String, pullRequestId: Int) async -> [String] {
        guard let base = try? orgBase() else { return [] }
        let projPath = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        let repoPath = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        guard let url = URL(string: "\(base)/\(projPath)/_apis/git/repositories/\(repoPath)/pullRequests/\(pullRequestId)/workitems?api-version=7.1")
        else { return [] }
        struct Resp: Decodable { struct Ref: Decodable { var id: String }; var value: [Ref] }
        guard let req = try? authedRequest(url: url),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (try? Self.check(resp, data)) != nil,
              let parsed = try? JSONDecoder().decode(Resp.self, from: data)
        else { return [] }
        return parsed.value.map { "AB#\($0.id)" }
    }

    // MARK: - Live PR-review resolution (for the "reviewing someone else's ticket" exact match)

    private struct PRLookup: Decodable {
        struct Repo: Decodable { var id: String; var project: Proj }
        struct Proj: Decodable { var name: String }
        var repository: Repo
    }

    private var prResolutionCache: [Int: (ticket: Ticket?, ts: Date)] = [:]
    private static let prCacheTTL: TimeInterval = 600  // 10 min — covers one review session

    /// Live, on-demand resolution of the work item linked to a PR you're actively reviewing
    /// (window title "Pull request NNNN: ... - Repos") — regardless of who it's assigned to.
    /// Deliberately NOT part of `refreshSprint`'s "assigned to me" corpus: this is a narrow
    /// exception carved out for the moment you're reviewing someone else's PR, not a general
    /// widening of the guess pool to the whole team's backlog. Cached briefly per PR id so
    /// repeated attribution samples during one review don't re-hit the API on every tick.
    func resolveWorkItem(forPullRequestId prId: Int) async -> Ticket? {
        if let cached = prResolutionCache[prId], Date().timeIntervalSince(cached.ts) < Self.prCacheTTL {
            return cached.ticket
        }
        let ticket = await fetchWorkItemForPR(prId)
        prResolutionCache[prId] = (ticket, Date())
        return ticket
    }

    /// Two calls: the PR is looked up org-wide by id alone (no repo/project known yet from a
    /// window title), which yields the repo + project needed for the existing linked-work-items
    /// lookup; then one work item's fields are fetched to build a real `Ticket` (state category,
    /// match text) instead of a bare key.
    private func fetchWorkItemForPR(_ prId: Int) async -> Ticket? {
        guard let base = try? orgBase(),
              let lookupURL = URL(string: "\(base)/_apis/git/pullrequests/\(prId)?api-version=7.1"),
              let req = try? authedRequest(url: lookupURL),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (try? Self.check(resp, data)) != nil,
              let pr = try? JSONDecoder().decode(PRLookup.self, from: data)
        else { return nil }

        let keys = await workItemsLinkedToPullRequest(project: pr.repository.project.name, repo: pr.repository.id, pullRequestId: prId)
        guard let workItemId = keys.first.flatMap({ $0.hasPrefix("AB#") ? Int($0.dropFirst(3)) : nil }),
              let items = try? await batchFetch(ids: [workItemId], fields: Self.fetchFields),
              let item = items.first
        else { return nil }
        // false: this is the one path that resolves a work item regardless of who it's assigned
        // to — see `Ticket.assignedToMe`'s doc comment.
        return await ticket(fromBatchItem: item, assignedToMe: false)
    }

    /// Field-mapping shared with `refreshSprint` below, minus area-exclusion/parent-epic lookup
    /// (not worth another round trip for a single ad hoc ticket resolved this way).
    private func ticket(fromBatchItem item: BatchItem, assignedToMe: Bool) async -> Ticket {
        let f = item.fields
        let areaPath = f["System.AreaPath"]?.stringValue ?? ""
        let project = areaPath.split(separator: "\\").first.map(String.init) ?? config.azureProject
        let type = f["System.WorkItemType"]?.stringValue ?? ""
        let state = f["System.State"]?.stringValue ?? ""
        let categories = await stateCategories(forType: type, project: project)
        let category = categories[state]
        let done = category == "Completed" || category == "Removed"
        let title = f["System.Title"]?.stringValue ?? ""
        let tags = (f["System.Tags"]?.stringValue ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let description = Self.stripHTML(f["System.Description"]?.stringValue ?? f["Microsoft.VSTS.TCM.ReproSteps"]?.stringValue ?? "")
        let text = Ticket.buildMatchText(summary: title, type: type, epic: nil, components: [areaPath], labels: tags, description: description)
        return Ticket(key: "AB#\(item.id)", summary: title, text: text, status: state,
                      updated: f["System.ChangedDate"]?.stringValue, done: done,
                      inSprint: false, inQueue: false, common: false,
                      issueId: "\(item.id)", statusCategory: category, assignedToMe: assignedToMe,
                      project: project.isEmpty ? nil : project)
    }

    // MARK: - WIQL → workitemsbatch → sprint.json

    private struct WiqlResponse: Decodable { struct Ref: Decodable { var id: Int }; var workItems: [Ref] }
    private struct BatchRequest: Encodable { var ids: [Int]; var fields: [String] }
    private struct BatchItem: Decodable { var id: Int; var fields: [String: AnyDecodableValue] }
    private struct BatchResponse: Decodable { var value: [BatchItem] }

    /// Loosely-typed JSON value — work item fields come back as string/number/null with no fixed
    /// schema across custom process templates.
    private enum AnyDecodableValue: Decodable {
        case string(String), number(Double), object([String: AnyDecodableValue]), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else if let o = try? c.decode([String: AnyDecodableValue].self) { self = .object(o) }
            else { self = .null }
        }
        var stringValue: String? {
            switch self {
            case .string(let s): return s
            case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
            case .object(let o): return (o["displayName"] ?? o["name"])?.stringValue
            case .null: return nil
            }
        }
    }

    private func wiql() -> String {
        let override = config.azureWiql.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        var q = "SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me"
        let project = config.azureProject.trimmingCharacters(in: .whitespaces)
        if !project.isEmpty { q += " AND [System.TeamProject] = '\(project.replacingOccurrences(of: "'", with: ""))'" }
        q += " ORDER BY [System.ChangedDate] DESC"
        return q
    }

    private func wiqlIds() async throws -> [Int] {
        let project = config.azureProject.trimmingCharacters(in: .whitespaces)
        let path = project.isEmpty ? "" : "/\(project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project)"
        guard let url = URL(string: "\(try orgBase())\(path)/_apis/wit/wiql?api-version=7.1") else {
            throw AzureDevOpsError.badURL
        }
        var req = try authedRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["query": wiql()])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return try JSONDecoder().decode(WiqlResponse.self, from: data).workItems.map { $0.id }
    }

    private static let fetchFields = [
        "System.Id", "System.Title", "System.State", "System.WorkItemType", "System.ChangedDate",
        "System.AreaPath", "System.IterationPath", "System.Tags", "System.Description",
        "Microsoft.VSTS.TCM.ReproSteps", "System.Parent",
    ]

    /// Fetch fields for a batch of ids, chunked at 200 (the API's hard per-request cap).
    private func batchFetch(ids: [Int], fields: [String]) async throws -> [BatchItem] {
        guard !ids.isEmpty else { return [] }
        guard let url = URL(string: "\(try orgBase())/_apis/wit/workitemsbatch?api-version=7.1") else {
            throw AzureDevOpsError.badURL
        }
        var out: [BatchItem] = []
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 200, ids.count)])
            var req = try authedRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(BatchRequest(ids: chunk, fields: fields))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp, data)
            out += try JSONDecoder().decode(BatchResponse.self, from: data).value
            i += 200
        }
        return out
    }

    /// Per-work-item-type state → category (Proposed/InProgress/Resolved/Completed/Removed),
    /// cached per refresh. Never hardcode state names — they vary per process template (verified:
    /// this org's Task/User Story states include "Dev", and "Resolved" categorizes as InProgress,
    /// not a distinct Resolved category).
    private struct TypeStates: Decodable { struct S: Decodable { var name: String; var category: String }; var states: [S] }
    private var stateCategoryCache: [String: [String: String]] = [:]  // workItemType -> state -> category

    private func stateCategories(forType type: String, project: String) async -> [String: String] {
        if let cached = stateCategoryCache[type] { return cached }
        guard let base = try? orgBase() else { return [:] }
        let projPath = project.isEmpty ? "" : "/\(project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project)"
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        guard let url = URL(string: "\(base)\(projPath)/_apis/wit/workitemtypes/\(encodedType)/states?api-version=7.1"),
              let req = try? authedRequest(url: url),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (try? Self.check(resp, data)) != nil,
              let parsed = try? JSONDecoder().decode(TypeStates.self, from: data)
        else { return [:] }
        var map: [String: String] = [:]
        for s in parsed.states { map[s.name] = s.category }
        stateCategoryCache[type] = map
        return map
    }

    /// Strip HTML tags/entities from a work-item description, plus markdown-table-breaking
    /// characters (`|`, newlines) — Azure Boards descriptions are real HTML far more often than
    /// Jira's ADF, and an unstripped `|` breaks the `~/timesheet-log.md` table.
    private static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch every assigned work item, resolve categories/parent titles, filter excluded areas,
    /// and (over)write sprint.json stamped for this provider. Mirrors `Atlassian.refreshSprint()`.
    @discardableResult
    func refreshSprint() async throws -> RefreshResult {
        async let identity: () = resolveIdentity()   // independent of the WIQL/batch fetch below
        let ids = try await wiqlIds()
        let items = try await batchFetch(ids: ids, fields: Self.fetchFields)
        await identity

        // Resolve parent titles in a second batch call — workitemsbatch doesn't expand relations.
        let parentIds = Set(items.compactMap { $0.fields["System.Parent"]?.stringValue.flatMap(Int.init) })
        let parentTitles = try await batchFetch(ids: Array(parentIds), fields: ["System.Title"])
        var parentTitleById: [Int: String] = [:]
        for p in parentTitles { parentTitleById[p.id] = p.fields["System.Title"]?.stringValue }

        let excludedAreas = config.azureExcludedAreas.map { $0.lowercased() }
        var tickets: [Ticket] = []
        var iterationPathByKey: [String: String] = [:]
        for item in items {
            let f = item.fields
            let areaPath = f["System.AreaPath"]?.stringValue ?? ""
            if excludedAreas.contains(where: { !$0.isEmpty && areaPath.lowercased().hasPrefix($0) }) { continue }

            let project = areaPath.split(separator: "\\").first.map(String.init) ?? config.azureProject
            let type = f["System.WorkItemType"]?.stringValue ?? ""
            let state = f["System.State"]?.stringValue ?? ""
            let categories = await stateCategories(forType: type, project: project)
            let category = categories[state]
            let done = category == "Completed" || category == "Removed"

            let title = f["System.Title"]?.stringValue ?? ""
            let tags = (f["System.Tags"]?.stringValue ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let description = Self.stripHTML(f["System.Description"]?.stringValue ?? f["Microsoft.VSTS.TCM.ReproSteps"]?.stringValue ?? "")
            let epic = f["System.Parent"]?.stringValue.flatMap(Int.init).flatMap { parentTitleById[$0] }
            let text = Ticket.buildMatchText(summary: title, type: type, epic: epic,
                                             components: [areaPath], labels: tags, description: description)

            let key = "AB#\(item.id)"
            iterationPathByKey[key] = f["System.IterationPath"]?.stringValue
            tickets.append(Ticket(
                key: key, summary: title, text: text, status: state,
                updated: f["System.ChangedDate"]?.stringValue, done: done,
                inSprint: false,  // resolved below, once, from the team's current iteration
                inQueue: false, common: false, issueId: "\(item.id)", statusCategory: category,
                assignedToMe: true,  // the WIQL is always "AssignedTo = @Me" — explicit for clarity
                project: project.isEmpty ? nil : project))
        }

        if let currentPath = await currentIterationPath() {
            tickets = tickets.map { t in
                var t = t; t.inSprint = (iterationPathByKey[t.key] == currentPath); return t
            }
        }

        let f = ISO8601DateFormatter()
        let file = SprintFile(provider: IssueProviderKind.azureDevOps.rawValue, updated: f.string(from: Date()), tickets: tickets)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        try enc.encode(file).write(to: AppPaths.sprintFile)
        return RefreshResult(total: tickets.count, open: tickets.filter { !$0.done }.count)
    }

    /// The team's current iteration path (e.g. "DevOps\Sprint 1"), compared directly against each
    /// work item's `System.IterationPath`. Requires `azureTeam` + `azureProject`; without either,
    /// `inSprint` just stays false rather than guessing — consistent with the app's existing note
    /// that sprint detection is unreliable in general, and this team's own current iteration
    /// (verified) has no start/finish dates set, so the boost wouldn't be meaningful here anyway.
    private func currentIterationPath() async -> String? {
        let team = config.azureTeam.trimmingCharacters(in: .whitespaces)
        let project = config.azureProject.trimmingCharacters(in: .whitespaces)
        guard !team.isEmpty, !project.isEmpty else { return nil }
        let projPath = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        let teamPath = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team
        guard let base = try? orgBase(),
              let url = URL(string: "\(base)/\(projPath)/\(teamPath)/_apis/work/teamsettings/iterations?$timeframe=current&api-version=7.1"),
              let req = try? authedRequest(url: url),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (try? Self.check(resp, data)) != nil
        else { return nil }
        struct IterationList: Decodable { struct It: Decodable { var path: String }; var value: [It] }
        return try? JSONDecoder().decode(IterationList.self, from: data).value.first?.path
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw AzureDevOpsError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            // AzDO answers 203 with an HTML sign-in page (not 401) when the PAT is missing/expired.
            if http.statusCode == 203 {
                throw AzureDevOpsError.http(203, "Sign-in required — check the PAT hasn't expired")
            }
            throw AzureDevOpsError.http(http.statusCode, String(String(data: data, encoding: .utf8)?.prefix(400) ?? ""))
        }
    }
}

enum AzureDevOpsError: LocalizedError {
    case notConfigured, badURL, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Azure DevOps credentials. Use “Connect Azure DevOps…” first."
        case .badURL: return "Invalid Azure DevOps request."
        case .http(let c, let m):
            let hint = c == 401 || c == 203 ? " (check org name + PAT)" : ""
            return "Azure DevOps HTTP \(c)\(hint): \(m)"
        }
    }
}
