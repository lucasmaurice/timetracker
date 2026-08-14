import AppKit
import Foundation

/// Everything we know about the current moment of work, gathered without keylogging or
/// screen capture. Flattened into `document` for the lexical matcher and the LLM.
struct WorkContext {
    var app = ""
    var bundleId = ""
    var title = ""
    var url: String?
    var repo: String?
    var branch: String?
    var openFile: String?
    var changedFiles: [String] = []
    var commits: [String] = []
    var kubeContext: String?
    var processes: [String] = []
    var recentRepos: [String] = []
    var meeting: String?
    var aiSession: String?
    // From the editor extension (VS Code / Kiro), when present: the symbol being edited, the
    // active task, and recent integrated-terminal commands.
    var symbol: String?
    var task: String?
    var editorCommands: [String] = []
    var scmMessage: String?   // commit message being typed in the editor (your words → strong signal)
    var excluded = false   // private app / window — not recorded

    /// Human-readable, token-rich context for embedding/LLM. Only non-empty parts.
    var document: String {
        var lines: [String] = []
        lines.append("App: \(app)")
        if !title.isEmpty { lines.append("Window: \(title)") }
        if let u = url { lines.append("URL: \(u)") }
        if let s = aiSession { lines.append("AI session: \(s)") }
        if let m = meeting { lines.append("Meeting: \(m)") }
        if let r = repo { lines.append("Repo: \(r)" + (branch.map { " (branch \($0))" } ?? "")) }
        if let f = openFile { lines.append("Editing: \(f)" + (symbol.map { " · symbol \($0)" } ?? "")) }
        if !changedFiles.isEmpty { lines.append("Changed files: \(changedFiles.prefix(12).joined(separator: ", "))") }
        if let m = scmMessage { lines.append("Commit draft: \(m)") }
        if !commits.isEmpty { lines.append("Recent commits: \(commits.prefix(6).joined(separator: " | "))") }
        if let t = task { lines.append("Task: \(t)") }
        if !editorCommands.isEmpty { lines.append("Editor terminal: \(editorCommands.suffix(6).joined(separator: " ; "))") }
        if let k = kubeContext { lines.append("Kubernetes context: \(k)") }
        if !processes.isEmpty { lines.append("Running: \(processes.joined(separator: ", "))") }
        if !recentRepos.isEmpty { lines.append("Recently active repos: \(recentRepos.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// Free text the ticket-key regex should scan (URL first — it often holds the key).
    var keyScanText: String { [url, title, branch, commits.first, scmMessage].compactMap { $0 }.joined(separator: " ") }

    /// Coarse signatures for the correction-learning store (repo / URL host / app).
    func signatures() -> [String] {
        var s: [String] = []
        if let r = repo { s.append("repo:\(r)") }
        if let u = url, let host = URL(string: u)?.host { s.append("host:\(host)") }
        if !bundleId.isEmpty { s.append("app:\(bundleId)") }
        return s
    }
}

/// Builds a WorkContext from the foreground app + window title, enriching with local
/// signals. Each expensive source is cached with its own TTL so sampling stays cheap.
final class ContextEnricher {
    private let config: Config
    private let sessions: SessionReader

    private var gitCache: [String: (info: GitInfo, at: Date)] = [:]
    private var kubeCache: (value: String?, at: Date)?
    private var procCache: (value: [String], at: Date)?
    private var recentCache: (value: [String], at: Date)?
    private var urlCache: (bundle: String, value: String?, at: Date)?

    private let gitTTL: TimeInterval = 30
    private let slowTTL: TimeInterval = 60
    private let urlTTL: TimeInterval = 5

    private struct GitInfo { var repo: String; var branch: String?; var changed: [String]; var commits: [String] }

    init(config: Config, sessions: SessionReader) {
        self.config = config
        self.sessions = sessions
    }

    /// Meeting apps whose foreground presence means "in a meeting" (no calendar needed).
    private static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
    ]

    /// Infer the current meeting from the foreground app/title/URL (calendar dropped — Outlook
    /// isn't synced to macOS Calendar). Returns the window/tab title when it looks like a meeting.
    private func meetingLabel(bundleId: String, appName: String, title: String, url: String?) -> String? {
        let hay = "\(bundleId) \(appName) \(url ?? "") \(title)".lowercased()
        let isMeeting = Self.meetingApps.contains(bundleId)
            || hay.contains("zoom.us") || hay.contains("webex")
            || (url?.contains("meet.google.com") ?? false)
            || hay.contains("huddle")
        guard isMeeting else { return nil }
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? appName : t
    }

    func enrich(bundleId: String, appName: String, title: String, idle: Bool, pid: pid_t,
                now: Date, forcedExclude: Bool) -> WorkContext {
        var ctx = WorkContext()
        ctx.app = appName
        ctx.bundleId = bundleId
        if idle { return ctx }   // don't gather signals while the user is away

        // Browser URL (Automation). Only for known browsers — also needed to evaluate
        // window/URL exclusion patterns (e.g. a personal domain or profile).
        let url = browserURL(bundleId: bundleId, now: now)

        // Privacy exclusion: app-level (no title even read) or window/URL pattern. When
        // excluded, store nothing about it — the segment is suppressed entirely.
        if forcedExclude || config.isExcludedWindow("\(bundleId) \(appName) \(title) \(url ?? "")") {
            ctx.excluded = true
            return ctx
        }

        ctx.title = title
        if let url, !url.isEmpty { ctx.url = url }

        // The editor extension (VS Code / Kiro), when frontmost, gives authoritative repo/branch/
        // file plus signal we can't see from outside (symbol, terminal commands, active task).
        let editor = editorContext(bundleId: bundleId, title: title, now: now)

        // Git depth for the active repo: editor's workspace root → editor title → terminal cwd.
        let repoPath = editor?.workspaceRoot ?? resolveRepo(fromTitle: title)
            ?? terminalRepo(bundleId: bundleId, pid: pid, now: now)
        if let repoPath {
            let g = gitInfo(repoPath: repoPath, now: now)
            ctx.repo = editor?.repo ?? (repoPath as NSString).lastPathComponent
            ctx.branch = editor?.branch ?? g.branch
            ctx.changedFiles = g.changed
            ctx.commits = g.commits
            ctx.openFile = editor?.file.map { ($0 as NSString).lastPathComponent } ?? openFile(fromTitle: title)
        }
        if let editor {
            ctx.symbol = editor.symbol
            ctx.editorCommands = editor.terminalCmds
            ctx.scmMessage = editor.scmMessage
            ctx.task = editor.task ?? editor.debugSession.map { "debug: \($0)" }
            // Merge the editor's truth — files being modified (relative paths, dir context) and
            // recently-open files — with git's changed set. Relative paths carry service/component
            // tokens that match ticket summaries.
            var merged = ctx.changedFiles
            for f in (editor.changes ?? []) + (editor.recentFiles ?? []) where !merged.contains(f) { merged.append(f) }
            ctx.changedFiles = Array(merged.prefix(14))
        }

        // Your own AI-session prompts (Claude Code / Copilot / Kiro) — highest signal.
        ctx.aiSession = sessions.recentWork(repoPath: repoPath, now: now)

        ctx.kubeContext = kubeContext(now: now)
        ctx.processes = devCommands(now: now)
        ctx.recentRepos = recentRepos(now: now)
        ctx.meeting = meetingLabel(bundleId: bundleId, appName: appName, title: title, url: ctx.url)
        return ctx
    }

    // MARK: - Editor extension heartbeat (VS Code / Kiro)

    struct EditorContext: Decodable {
        var ts: Double
        var focused: Bool
        var app: String?
        var workspaceRoot: String?
        var repo: String?
        var branch: String?
        var file: String?
        var language: String?
        var symbol: String?
        var recentFiles: [String]?
        var changes: [String]?       // files being modified (repo-relative)
        var scmMessage: String?      // commit message being typed
        var terminalCmds: [String]
        var task: String?
        var debugSession: String?
    }

    /// Bundle ids whose context the editor extension can supply, mapped to `vscode.env.appName`
    /// (so a heartbeat can be tied to the actually-frontmost editor — multiple editors each report
    /// their own window as "focused", so freshest-focused alone picks the wrong one).
    private static let editorApps: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.microsoft.VSCodeInsiders": "Visual Studio Code - Insiders",
        "com.vscodium": "VSCodium",
        "dev.kiro.desktop": "Kiro", "dev.kiro": "Kiro",
    ]
    private var editorContextDir: URL {
        AppPaths.dataDir.appendingPathComponent("editor-context", isDirectory: true)
    }

    /// The editor heartbeat for the *frontmost* window: scoped to the frontmost editor app, then
    /// disambiguated among that editor's windows by which workspace name appears in the window
    /// title (then focus, then recency). Nil unless an editor is frontmost with a fresh heartbeat.
    private func editorContext(bundleId: String, title: String, now: Date) -> EditorContext? {
        guard let app = Self.editorApps[bundleId] else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: editorContextDir, includingPropertiesForKeys: nil) else { return nil }
        let lowerTitle = title.lowercased()
        var best: (rank: Int, ts: Double, ctx: EditorContext)?
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let ctx = try? JSONDecoder().decode(EditorContext.self, from: data),
                  ctx.app == app,                                    // same editor as the frontmost app
                  now.timeIntervalSince1970 - ctx.ts < 30 else { continue }
            let titleMatch = ctx.workspaceRoot
                .map { ($0 as NSString).lastPathComponent.lowercased() }
                .map { !$0.isEmpty && lowerTitle.contains($0) } ?? false
            let rank = (titleMatch ? 2 : 0) + (ctx.focused ? 1 : 0)
            if best == nil || rank > best!.rank || (rank == best!.rank && ctx.ts > best!.ts) {
                best = (rank, ctx.ts, ctx)
            }
        }
        return best?.ctx
    }

    // MARK: - Browser URL via AppleScript (Automation permission)

    private static let chromeFamily: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser",
    ]

    private func browserURL(bundleId: String, now: Date) -> String? {
        if let c = urlCache, c.bundle == bundleId, now.timeIntervalSince(c.at) < urlTTL { return c.value }
        var script: String?
        if Self.chromeFamily.contains(bundleId) {
            // Skip incognito windows (Chrome exposes window `mode`).
            script = """
            tell application id "\(bundleId)"
                if (count of windows) is 0 then return ""
                set w to front window
                try
                    if (mode of w) is "incognito" then return ""
                end try
                set t to active tab of w
                return (URL of t) & " " & (title of t)
            end tell
            """
        } else if bundleId == "com.apple.Safari" || bundleId == "com.apple.SafariTechnologyPreview" {
            script = """
            tell application id "\(bundleId)"
                if (count of documents) is 0 then return ""
                return (URL of front document) & " " & (name of front document)
            end tell
            """
        }
        guard let script else { urlCache = (bundleId, nil, now); return nil }

        var err: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
        let value = (out?.isEmpty == false) ? out : nil
        urlCache = (bundleId, value, now)
        return value
    }

    // MARK: - Git

    private func resolveRepo(fromTitle title: String) -> String? {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "—–-|")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let fm = FileManager.default
        for dir in config.expandedWorkspaceDirs {
            for part in parts where !part.isEmpty {
                let candidate = dir.appendingPathComponent(part)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue,
                   fm.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                    return candidate.path
                }
            }
        }
        return nil
    }

    private func openFile(fromTitle title: String) -> String? {
        // Editor titles start with the file: "● handler.py — repo — Visual Studio Code".
        let first = title.components(separatedBy: CharacterSet(charactersIn: "—–|")).first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " ●*"))
        return (first?.isEmpty == false) ? first : nil
    }

    private func gitInfo(repoPath: String, now: Date) -> GitInfo {
        if let c = gitCache[repoPath], now.timeIntervalSince(c.at) < gitTTL { return c.info }
        let branch = git(["-C", repoPath, "branch", "--show-current"], repoPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let changedRaw = git(["-C", repoPath, "status", "--porcelain", "--untracked-files=no"], repoPath) ?? ""
        let changed = changedRaw.split(separator: "\n").compactMap { line -> String? in
            let path = line.dropFirst(3)  // status code + space
            return (path as Substring).split(separator: "/").last.map(String.init)
        }
        let commitsRaw = git(["-C", repoPath, "log", "-8", "--pretty=%s"], repoPath) ?? ""
        let commits = commitsRaw.split(separator: "\n").map(String.init)
        let info = GitInfo(repo: repoPath, branch: (branch?.isEmpty == false) ? branch : nil,
                           changed: Array(changed.prefix(12)), commits: commits)
        gitCache[repoPath] = (info, now)
        return info
    }

    private func git(_ args: [String], _ cwd: String) -> String? {
        Self.run("/usr/bin/git", args)
    }

    // MARK: - Kubernetes / processes / recent repos

    private func kubeContext(now: Date) -> String? {
        if let c = kubeCache, now.timeIntervalSince(c.at) < slowTTL { return c.value }
        var value: String?
        if let kubectl = Self.locate("kubectl") {
            // The static cluster/context name (e.g. "…-cluster-admin") is the same regardless of
            // ticket — noise. The *namespace* maps to a service/team, so keep only that.
            let ns = Self.run(kubectl, ["config", "view", "--minify", "-o", "jsonpath={..namespace}"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let ns, !ns.isEmpty, ns != "default" { value = "namespace \(ns)" }
        }
        kubeCache = (value, now)
        return value
    }

    private static let devTools: Set<String> = [
        "terraform", "terragrunt", "tofu", "helm", "k9s", "vault", "packer",
        "ansible-playbook", "kubectl", "aws", "aws-vault", "docker", "kustomize",
    ]

    /// Persistent background tooling that runs in EVERY context (MCP servers, the IDE's bundled
    /// kubectl, agent helpers) — pure noise that dilutes the signal, so it's filtered out.
    private static let cmdNoise: [String] = [
        "mcp-server", "mcp/", "modelcontextprotocol", "-mcp", "Lens.app", "kubeconfig-direct",
        "GITHUB_PERSONAL_ACCESS_TOKEN", "GRAFANA_SERVICE_ACCOUNT_TOKEN", "GRAFANA_URL", "/Library/Application Support/",
    ]

    /// Full command lines of running dev tools — args carry cluster/namespace/dir signal
    /// (e.g. `kubectl --context prod1 -n search …`, `terraform -chdir=monitoring …`). Background
    /// daemons (MCP servers, Lens kubectl) are stripped; the real commands you run in the editor
    /// terminal come through the editor extension instead. Reads process args (like `ps`), never keystrokes.
    private func devCommands(now: Date) -> [String] {
        if let c = procCache, now.timeIntervalSince(c.at) < gitTTL { return c.value }
        var found: [String] = []
        if let out = Self.run("/bin/ps", ["-axww", "-o", "command="]) {
            for line in out.split(separator: "\n") {
                let cmd = line.trimmingCharacters(in: .whitespaces)
                guard let first = cmd.split(separator: " ").first else { continue }
                let base = (String(first) as NSString).lastPathComponent
                guard Self.devTools.contains(base) else { continue }
                if Self.cmdNoise.contains(where: { cmd.contains($0) }) { continue }   // drop daemons
                found.append(String(cmd.prefix(160)))
            }
        }
        let value = Array(Set(found)).prefix(6).map { $0 }
        procCache = (Array(value), now)
        return Array(value)
    }

    // MARK: - Terminal working directory

    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]
    private var terminalRepoCache: [pid_t: (value: String?, at: Date)] = [:]

    /// If a terminal is frontmost, resolve a descendant shell's cwd to a workspace repo.
    private func terminalRepo(bundleId: String, pid: pid_t, now: Date) -> String? {
        guard Self.terminals.contains(bundleId) else { return nil }
        if let c = terminalRepoCache[pid], now.timeIntervalSince(c.at) < gitTTL { return c.value }
        var pids = childPids(of: pid)
        pids += pids.flatMap { childPids(of: $0) }   // shells are usually 1–2 levels down
        var repo: String?
        for p in pids {
            if let cwd = cwdOf(p), let r = repoForPath(cwd) { repo = r; break }
        }
        terminalRepoCache[pid] = (repo, now)
        return repo
    }

    private func childPids(of pid: pid_t) -> [pid_t] {
        guard let out = Self.run("/usr/bin/pgrep", ["-P", "\(pid)"]) else { return [] }
        return out.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { pid_t($0) }
    }

    private func cwdOf(_ pid: pid_t) -> String? {
        guard let out = Self.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        // Output lines like "p1234", "fcwd", "n/Users/.../Workspace/monitoring".
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// Map an absolute path to the workspace repo dir that contains it (must be a git repo).
    private func repoForPath(_ path: String) -> String? {
        let fm = FileManager.default
        for dir in config.expandedWorkspaceDirs {
            let base = dir.path + "/"
            guard path.hasPrefix(base) else { continue }
            let rest = path.dropFirst(base.count)
            guard let repoName = rest.split(separator: "/").first else { continue }
            let repoPath = dir.appendingPathComponent(String(repoName))
            if fm.fileExists(atPath: repoPath.appendingPathComponent(".git").path) { return repoPath.path }
        }
        return nil
    }

    private func recentRepos(now: Date) -> [String] {
        if let c = recentCache, now.timeIntervalSince(c.at) < slowTTL { return c.value }
        let fm = FileManager.default
        var scored: [(name: String, mtime: Date)] = []
        for dir in config.expandedWorkspaceDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in entries {
                let p = dir.appendingPathComponent(name)
                // Use the git index mtime when present (tracks real activity), else dir mtime.
                let probe = fm.fileExists(atPath: p.appendingPathComponent(".git/index").path)
                    ? p.appendingPathComponent(".git/index").path : p.path
                if let attrs = try? fm.attributesOfItem(atPath: probe),
                   let m = attrs[.modificationDate] as? Date,
                   now.timeIntervalSince(m) < 1800 {   // touched in last 30 min
                    scored.append((name, m))
                }
            }
        }
        let value = scored.sorted { $0.mtime > $1.mtime }.prefix(4).map { $0.name }
        recentCache = (Array(value), now)
        return Array(value)
    }

    // MARK: - Process helpers (launchd apps have a minimal PATH; use absolute paths)

    private static func locate(_ name: String) -> String? { Shell.locate(name) }

    /// Run a command with a hard timeout (delegates to the shared `Shell` runner).
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> String? {
        Shell.run(path, args, timeout: timeout)
    }
}
