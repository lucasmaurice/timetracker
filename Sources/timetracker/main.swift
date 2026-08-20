import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let config = Config.load()
    private var store: Store!
    private var attribution: Attribution!
    private var monitor: FocusMonitor!
    private var summary: Summary!
    private var atlassian: Atlassian!
    private var azureDevOps: AzureDevOps!
    private var azurePRBridge: AzurePRBridge!
    private var ollama: Ollama!
    private var tempo: TempoClient!
    private var sevenPace: SevenPaceClient!
    private var embeddings: EmbeddingMatcher!
    /// The active issue/worklog provider per `config.issueProvider`/`worklogProvider`. Switching
    /// providers needs a restart (like every other setting), so these are simple dispatch, not
    /// mutable state — but every menu/refresh/submit path goes through them so both providers
    /// share one code path instead of duplicating it per concrete type.
    private var issueProvider: IssueProvider { config.issueProvider == .jira ? atlassian : azureDevOps }
    private var worklogProvider: WorklogProvider { config.worklogProvider == .tempo ? tempo : sevenPace }
    private var dashboardWindow: NSWindow?
    private var dashboardHost: NSHostingController<DashboardView>?
    private var reviewWindow: NSWindow?
    private var reviewHost: NSHostingController<ReviewView>?
    private var reviewModel: ReviewModel?
    private var reviewPeriods: [Period] = []
    /// The in-flight review compile, so a new one supersedes it instead of racing it — see
    /// `refreshReviewView`.
    private var reviewTask: Task<Void, Never>?
    private var reviewDay = Date()
    private var assignWindow: NSWindow?
    private var assignHost: NSHostingController<AssignView>?
    private var teachWindow: NSWindow?
    private var teachHost: NSHostingController<TeachView>?
    private var teachModel: TeachModel?
    private var teachCurrentSignatures: [String] = []
    private var teachCurrentDoc = ""
    private var settingsWindow: NSWindow?
    private var settingsHost: NSHostingController<SettingsView>?
    private var settingsModel: SettingsModel?
    private var inspectorWindow: NSWindow?
    private var inspectorHost: NSHostingController<InspectorView>?

    private var promptTimer: Timer?
    private var llmTimer: Timer?
    private var jiraTimer: Timer?
    private var refreshingJira = false
    private var lastPromptDismissal: Date?
    private var promptOpen = false
    /// When the current activity entered a continuous "can't guess at all" state (drives the nudge).
    private var abstainSince: Date?
    private var lastLLM: (key: String, reason: String, confidence: Double, at: Date)?
    /// Rolling buffer of distinct work contexts (timestamp, document) for the LLM arc.
    private var arc: [(at: Date, ctx: WorkContext)] = []
    private var embedTop: TicketGuess?
    private var embedCandidates: [TicketGuess] = []
    private var embedInFlight = false
    private var lastEmbedDoc: String?
    private var prReviewInFlight: Set<Int> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        store = Store()
        attribution = Attribution(config: config, store: store)
        summary = Summary(store: store, config: config, attribution: attribution)
        atlassian = Atlassian(config: config)
        azureDevOps = AzureDevOps(config: config)
        azurePRBridge = AzurePRBridge()
        ollama = Ollama(config: config)
        tempo = TempoClient(config: config, atlassian: atlassian)
        sevenPace = SevenPaceClient(config: config)
        embeddings = EmbeddingMatcher(config: config)
        let enricher = ContextEnricher(config: config, sessions: SessionReader())
        monitor = FocusMonitor(store: store, attribution: attribution, enricher: enricher, config: config)

        runStartupMigrationsIfNeeded()

        setupMainMenu()
        setupStatusItem()
        requestAccessibilityIfNeeded()
        if Self.canUseUserNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        monitor.onUpdate = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateStatus(state); self?.recordArc(state); self?.maybeEmbed(state); self?.maybeResolvePRReview(state)
            }
        }
        monitor.start()
        // Read the Keychain off-main (it can block on a permission prompt), then refresh. The
        // repo-bridge pass (which now also checks azureDevOps.configured, for the PR bridge) is
        // chained inside this same completion instead of independently scheduled, so it can't
        // race the preload and see credentials as "not configured" simply because it ran first.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.atlassian.preload()
            self?.tempo.preload()
            self?.azureDevOps.preload()
            self?.sevenPace.preload()
            DispatchQueue.main.async {
                self?.rebuildMenu(current: self?.monitor.currentState)
                self?.runRefresh(silent: true)   // freshen the ticket corpus on launch if connected
                self?.buildRepoBridgeAndBackfill()
                self?.notifyIfIssueProviderDisconnected()
            }
        }
        reindexEmbeddings()

        if config.jiraRefreshMinutes > 0 {
            jiraTimer = Timer.scheduledTimer(withTimeInterval: config.jiraRefreshMinutes * 60, repeats: true) { [weak self] _ in
                self?.runRefresh(silent: true)
            }
        }

        DispatchQueue.global(qos: .background).async { [weak self] in self?.housekeeping() }

        promptTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // A scheduled Timer fires on the main run loop, so this closure is main-thread by
            // construction — assumeIsolated states that to the compiler without a Task hop, which
            // would otherwise defer these checks by a turn for no reason.
            MainActor.assumeIsolated {
                self?.checkAbstainNudge()
                self?.checkUnknownBacklog()
                self?.checkReminders()
            }
        }
        // The LLM is now event-driven (fired by `maybeEmbed` when fusion is still ambiguous), but
        // keep a low-frequency safety pass for long single-context sessions where no focus change
        // ever re-triggers embedding. `llmRefine` no-ops unless the segment is still undecided.
        if config.ollamaEnabled, config.llmRefreshMinutes > 0 {
            llmTimer = Timer.scheduledTimer(withTimeInterval: config.llmRefreshMinutes * 60, repeats: true) { [weak self] _ in
                self?.llmRefine()
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        monitor?.flush()
    }

    /// Mine workspace git history into the repo→ticket bridge (every launch), and on first run
    /// seed `labels` from that history (warm-start). All git/store/network work is off the main
    /// thread; the in-memory label index is reloaded on main. Mirrors the housekeeping pattern.
    private func buildRepoBridgeAndBackfill() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.attribution.rebuildRepoBridge()
            // MUST run after rebuildRepoBridge (above): that call replaces the bridge's map
            // wholesale, so merging PR results first would have them silently wiped.
            if self.config.issueProvider == .azureDevOps, self.config.azurePRBridgeEnabled, self.azureDevOps.configured {
                let results = await self.azurePRBridge.resolve(
                    workspaceDirs: self.config.expandedWorkspaceDirs, azureDevOps: self.azureDevOps, now: Date())
                self.attribution.ingestPRBridgeResults(results)
            }
            let firstRun = !UserDefaults.standard.bool(forKey: "ttBackfilledV1")
            let inserted = firstRun ? self.attribution.backfillFromHistory() : 0
            if firstRun { UserDefaults.standard.set(true, forKey: "ttBackfilledV1") }
            await MainActor.run {
                // The bridge was (re)built after init's reloadSprint, so reload to widen the guess
                // pool with freshly-mined keys and re-index the matcher/embeddings.
                self.attribution.reloadSprint()
                if inserted > 0 {
                    self.attribution.reloadMemory()
                    NSLog("TimeTracker warm-start: seeded \(inserted) backfill labels from git history")
                }
                self.reindexEmbeddings()
                self.rebuildMenu(current: self.monitor.currentState)
            }
        }
    }

    /// One-time data hygiene + config moves, guarded by a version flag. Runs synchronously on
    /// the main thread before the monitor starts, so there's no concurrent DB access.
    private func runStartupMigrationsIfNeeded() {
        let key = "ttMigratedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let summary = attribution.runDataMigration()
        // The user opted into a wider guess pool; flip the (now unreliable) sprint-only gate
        // on disk so it persists. This session already falls back to the full not-done pool.
        var c = config
        if c.guessFromSprintOnly { c.guessFromSprintOnly = false; c.save() }
        UserDefaults.standard.set(true, forKey: key)
        NSLog("TimeTracker migration v1: \(summary)")
    }

    // MARK: - Status item

    /// Accessory (menu-bar-only) apps have no main menu, so ⌘C/⌘V/⌘X/⌘A are never
    /// routed to text fields (e.g. the Connect dialog). Install a minimal Edit menu so
    /// the standard editing shortcuts reach the first responder.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "TimeTracker")
            button.imagePosition = .imageLeading
            button.title = " ?"
        }
        rebuildMenu(current: nil)
    }

    private func updateStatus(_ state: LiveState?) {
        guard let button = statusItem.button else { return }
        let attr = state?.attribution
        // Track continuous "can't guess at all" (abstain) so the nudge can fire on sustained
        // un-attributed work — not just on a 2h block backlog.
        let abstaining = state != nil && !(state!.idle) && attr?.ticket == nil
            && (attr?.candidates.isEmpty ?? true) && !(state!.context.excluded) && attr?.category != "meeting"
        abstainSince = abstaining ? (abstainSince ?? Date()) : nil

        var symbol = "clock"
        if monitor.paused {
            button.title = " paused"; symbol = "pause.circle"
        } else if let t = attr?.ticket {
            button.title = t == config.noTicketLabel ? " no ticket" : " \(t)"
            symbol = t == config.noTicketLabel ? "minus.circle" : "clock"
        } else if let top = attr?.candidates.first {
            button.title = " ?\(top.key)"; symbol = "questionmark.circle"     // a guess awaits confirmation
        } else if abstaining {
            button.title = " ?"; symbol = "exclamationmark.circle"            // nothing to go on
        } else if let cat = attr?.category {
            button.title = " \(cat)"
        } else {
            button.title = " ?"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TimeTracker")
        rebuildMenu(current: state)
    }

    private func rebuildMenu(current: LiveState?) {
        let menu = NSMenu()

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠️ Grant Accessibility for window titles", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let attr = current?.attribution

        // Section 1 — the current ticket itself: description (itself the "open in browser" link,
        // when resolvable) and why it was picked. Only shown when a ticket is actually resolved
        // (not a bare guess).
        if let t = attr?.ticket, t != config.noTicketLabel {
            let summary = attribution.summary(for: t)
            let titleLine = "\(t)\(summary.map { " — \($0.prefix(60))" } ?? "")"
            let project = attribution.tickets(for: [t]).first?.project
            if let url = issueProvider.browserURL(forKey: t, project: project) {
                let item = NSMenuItem(title: titleLine, action: #selector(openTicketURL), keyEquivalent: "")
                item.target = self; item.representedObject = url
                menu.addItem(item)
            } else {
                menu.addItem(disabled(titleLine))
            }
            let src = attr?.source ?? "?"
            let conf = attr?.confidence.map { String(format: " · %.2f", $0) } ?? ""
            let why = Attribution.isExact(src) ? "from \(Attribution.sourceDescription(src))"
                : "\(Attribution.sourceDescription(src))\(conf)"
            menu.addItem(disabled("Why: \(why)"))
            menu.addItem(.separator())
        }

        // Section 2 — the raw signals behind that decision.
        let appLine = current.map { "\($0.appName)\($0.idle ? " (idle)" : "")" } ?? "—"
        menu.addItem(disabled("App: \(appLine)"))
        if let t = attr?.ticket {
            menu.addItem(disabled("Ticket: \(t)"))
        } else if let top = attr?.candidates.first {
            menu.addItem(disabled(String(format: "Guess: %@ (%.2f) — confirm below", top.key, top.score)))
        } else {
            menu.addItem(disabled("Ticket: unknown"))
        }
        if let cat = attr?.category {
            menu.addItem(disabled("Category: \(cat)"))
        }
        if let ctx = current?.context {
            if let b = ctx.branch { menu.addItem(disabled("Branch: \(b.prefix(44))")) }
            if let s = ctx.aiSession { menu.addItem(disabled("Session: \(s.prefix(52))")) }
        }
        if let t = current?.title, !t.isEmpty {
            menu.addItem(disabled("Window: \(t.prefix(60))"))
        }
        if let ctx = current?.context {
            if let u = ctx.url, let host = URL(string: u)?.host { menu.addItem(disabled("URL: \(host)")) }
            if let m = ctx.meeting { menu.addItem(disabled("Meeting: \(m.prefix(44))")) }
        }
        if let llm = lastLLM {
            menu.addItem(disabled("LLM: \(llm.key) (\(String(format: "%.2f", llm.confidence))) \(llm.reason.prefix(34))"))
        }
        if let e = embedTop {
            menu.addItem(disabled("Embed: \(e.key) (\(String(format: "%.2f", e.score)))"))
        }

        menu.addItem(.separator())
        if let pin = monitor.pinnedTicket {
            menu.addItem(disabled("📌 Pinned to \(pin)"))
            let unpin = NSMenuItem(title: "Unpin", action: #selector(unpinTicket), keyEquivalent: "")
            unpin.target = self; menu.addItem(unpin)
        }
        let assign = NSMenuItem(title: "Assign ticket (choose time span)…", action: #selector(openAssign), keyEquivalent: "")
        assign.target = self; menu.addItem(assign)
        menu.addItem(ticketSubmenuItem(title: "Quick-tag current activity", candidates: attr?.candidates ?? []))

        // No-guess affordances: accept the top suggestion, or declare the work non-billable.
        if attr?.ticket == nil, let top = attr?.candidates.first {
            let s = attribution.summary(for: top.key).map { " — \($0.prefix(36))" } ?? ""
            let accept = NSMenuItem(title: "✓ Accept \(top.key)\(s)", action: #selector(acceptTopGuess), keyEquivalent: "")
            accept.target = self; menu.addItem(accept)
        }
        if current != nil, !(current!.idle), attr?.ticket != config.noTicketLabel {
            let noTix = NSMenuItem(title: "Mark current work as no-ticket", action: #selector(markCurrentNoTicket), keyEquivalent: "")
            noTix.target = self; menu.addItem(noTix)
        }

        menu.addItem(.separator())
        let dash = NSMenuItem(title: "Dashboard…", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self; menu.addItem(dash)
        let teach = NSMenuItem(title: "Teach the guesser…  (\(attribution.labelCount))", action: #selector(openTeach), keyEquivalent: "t")
        teach.target = self; menu.addItem(teach)
        let inspect = NSMenuItem(title: "Inspector (microscope)…", action: #selector(openInspector), keyEquivalent: "i")
        inspect.target = self; menu.addItem(inspect)
        let review = NSMenuItem(title: "Review today…", action: #selector(openReview), keyEquivalent: "r")
        review.target = self; menu.addItem(review)
        let export = NSMenuItem(title: "Export today to timesheet-log.md", action: #selector(exportToday), keyEquivalent: "e")
        export.target = self; menu.addItem(export)
        let refresh = NSMenuItem(title: "Refresh sprint list", action: #selector(refreshSprint), keyEquivalent: "")
        refresh.target = self; refresh.isEnabled = issueProvider.configured; menu.addItem(refresh)

        menu.addItem(.separator())
        switch config.issueProvider {
        case .jira:
            if atlassian.configured {
                let logout = NSMenuItem(title: "Disconnect Atlassian", action: #selector(disconnectAtlassian), keyEquivalent: "")
                logout.target = self; menu.addItem(logout)
            } else {
                let connect = NSMenuItem(title: "Connect Atlassian (API token)…", action: #selector(connectAtlassian), keyEquivalent: "")
                connect.target = self; menu.addItem(connect)
            }
        case .azureDevOps:
            if azureDevOps.configured {
                if let org = azureDevOps.connectedOrg {
                    let who = azureDevOps.connectedUser.map { "as \($0) " } ?? ""
                    menu.addItem(disabled("Connected \(who)to \(org) (Azure DevOps)"))
                }
                let logout = NSMenuItem(title: "Disconnect Azure DevOps", action: #selector(disconnectAzureDevOps), keyEquivalent: "")
                logout.target = self; menu.addItem(logout)
            } else {
                let connect = NSMenuItem(title: "Connect Azure DevOps (PAT)…", action: #selector(connectAzureDevOps), keyEquivalent: "")
                connect.target = self; menu.addItem(connect)
            }
        }

        menu.addItem(.separator())
        let pause = NSMenuItem(title: monitor.paused ? "Resume tracking" : "Pause tracking", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self; menu.addItem(pause)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let folder = NSMenuItem(title: "Open data folder", action: #selector(openDataFolder), keyEquivalent: "")
        folder.target = self; menu.addItem(folder)

        menu.addItem(.separator())
        // TTBuildSHA, not CFBundleVersion: the latter is reserved for a digits-and-periods
        // version string (build.sh puts the commit count there), so the identifying SHA lives in
        // our own key. Fall back to CFBundleVersion for bundles built before that split.
        let info = Bundle.main.infoDictionary
        if let build = (info?["TTBuildSHA"] as? String ?? info?["CFBundleVersion"] as? String), !build.isEmpty {
            let time = info?["TTBuildTime"] as? String
            menu.addItem(disabled("Build \(build)" + (time.map { " (\($0))" } ?? "")))
        }
        let quit = NSMenuItem(title: "Quit TimeTracker", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)

        statusItem.menu = menu
    }

    private func disabled(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    private func ticketSubmenuItem(title: String, candidates: [TicketGuess]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()

        func add(_ key: String, _ label: String) {
            let item = NSMenuItem(title: label, action: #selector(pickTicket(_:)), keyEquivalent: "")
            item.representedObject = key; item.target = self; sub.addItem(item)
        }

        // Top semantic guesses first, with scores, so the likely ticket is one click away.
        let guessKeys = Set(candidates.map { $0.key })
        if !candidates.isEmpty {
            sub.addItem(disabled("Best guesses"))
            for g in candidates {
                let summary = attribution.summary(for: g.key) ?? ""
                add(g.key, String(format: "  %@ (%.2f) — %@", g.key, g.score, String(summary.prefix(44))))
            }
            sub.addItem(.separator())
        }

        // No-ticket sentinel.
        add(config.noTicketLabel, "⃠ \(config.noTicketLabel)")

        // Common / catch-all tickets — only here, never repeated under "All assigned".
        let common = attribution.commonTickets
        if !common.isEmpty {
            sub.addItem(.separator()); sub.addItem(disabled("Common"))
            for t in common { add(t.key, "\(t.key) — \(t.summary.prefix(50))") }
        }

        // Everything else assigned (excluding common + already-shown guesses).
        sub.addItem(.separator()); sub.addItem(disabled("All assigned"))
        for t in attribution.openTickets.prefix(80) where !t.common && !guessKeys.contains(t.key) {
            add(t.key, "\(t.key) — \(t.summary.prefix(50))")
        }
        if attribution.sprint.isEmpty {
            sub.addItem(disabled("(no tickets — Connect \(issueProvider.displayName), see README)"))
        }
        sub.addItem(.separator())
        let manual = NSMenuItem(title: "Enter ticket manually…", action: #selector(enterTicketManually), keyEquivalent: "")
        manual.target = self; sub.addItem(manual)
        parent.submenu = sub
        return parent
    }

    // MARK: - Actions

    @objc private func pickTicket(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        monitor.overrideCurrentTicket(key)
    }

    @objc private func enterTicketManually() {
        guard let key = promptForTicket(message: "Assign a ticket to the current activity") else { return }
        monitor.overrideCurrentTicket(key)
    }

    /// Confirm the top suggestion — tags the current activity and (manual source) records a
    /// correction the model learns from.
    @objc private func acceptTopGuess() {
        guard let key = monitor.currentState?.attribution.candidates.first?.key else { return }
        monitor.overrideCurrentTicket(key)
        abstainSince = nil
        rebuildMenu(current: monitor.currentState)
    }

    /// Declare the current work non-billable: tag it (no ticket), learn the negative example, and
    /// offer to make it a standing rule for this app/site.
    @objc private func markCurrentNoTicket() {
        guard let st = monitor.currentState, !st.idle else { return }
        monitor.overrideCurrentTicket(config.noTicketLabel)   // source manual → records the negative
        abstainSince = nil
        offerNoTicketRule(for: st.context)
        rebuildMenu(current: monitor.currentState)
    }

    /// After a no-ticket mark, offer a persistent "always no-ticket" rule for the best signature.
    private func offerNoTicketRule(for ctx: WorkContext) {
        guard let sig = attribution.noTicketRuleCandidate(for: ctx) else { return }
        let a = NSAlert()
        a.messageText = "Always treat this as no-ticket?"
        a.informativeText = "Automatically mark “\(sig)” as no-ticket from now on? (Editable in Settings → Always-no-ticket signatures.)"
        a.addButton(withTitle: "Always"); a.addButton(withTitle: "Just this time")
        if a.runModal() == .alertFirstButtonReturn { attribution.addNoTicketRule(sig) }
    }

    @objc private func openDashboard() {
        let view = makeDashboardView()
        if let host = dashboardHost, let win = dashboardWindow {
            host.rootView = view
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "TimeTracker Dashboard"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 780, height: 780))
        win.isReleasedWhenClosed = false
        win.center()
        dashboardHost = host
        dashboardWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func makeDashboardView() -> DashboardView {
        let data = DashboardBuilder(store: store, summary: summary, config: config).build()
        return DashboardView(data: data) { [weak self] in
            guard let self else { return }
            self.dashboardHost?.rootView = self.makeDashboardView()
        }
    }

    @MainActor @objc private func openReview() { presentReview(day: Date()) }

    @MainActor
    private func presentReview(day: Date) {
        reviewDay = day
        monitor.flush()   // persist the in-progress segment so today's latest work shows + can be learned
        refreshReviewView(day: reviewDay, present: true)
    }

    /// Compiles `day` and swaps it into the review window, cancelling any compile still running.
    ///
    /// Both guards matter. `PeriodCompiler.compile` awaits one Ollama round trip per meeting
    /// session, so it is easily seconds long: without cancellation, paging days quickly leaves
    /// several compiles in flight and the one that *finishes* last wins the view — not the one the
    /// user asked for last. And since `reviewDay` has already moved on by then, `saveReview` would
    /// write `TimeBlocks.dayString(reviewDay)` against a `reviewPeriods` array belonging to a
    /// different day. The staleness check is belt-and-braces for the same reason: cancellation is
    /// cooperative, so a task can still return a result after being cancelled.
    @MainActor
    private func refreshReviewView(day: Date, present: Bool) {
        reviewTask?.cancel()
        // Paint the synchronous result NOW. The full compile awaits one Ollama round trip per
        // meeting session, and blocking the window on that meant clicking "Review today…"
        // produced nothing at all — no window, no spinner — for as long as that took.
        show(makeReviewView(day: day, periods: PeriodCompiler.compileFast(
            day: day, config: config, store: store, attribution: attribution)), present: present)
        reviewTask = Task { @MainActor in
            let periods = await PeriodCompiler.compile(day: day, config: self.config, store: self.store,
                                                        attribution: self.attribution, ollama: self.ollama)
            // Cancellation is cooperative, so a superseded task can still get here; the day check
            // catches the case where the user paged on while this was in flight.
            guard !Task.isCancelled, day == self.reviewDay else { return }
            self.show(self.makeReviewView(day: day, periods: periods), present: false)
        }
    }

    /// Swap a freshly-built review view into the window, creating the window on first use.
    @MainActor
    private func show(_ view: ReviewView, present: Bool) {
        if let host = reviewHost, let win = reviewWindow {
            host.rootView = view
            if present { NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil) }
            return
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "TimeTracker Review"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 600, height: 560))
        win.isReleasedWhenClosed = false
        win.center()
        reviewHost = host; reviewWindow = win
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
    }

    /// `@MainActor` for the same reason `PeriodCompiler` is: this touches `reviewPeriods`,
    /// `reviewModel` and `attribution`, all main-owned. Being called from inside a
    /// `Task { @MainActor in }` does NOT confer isolation on a nonisolated `async` function — it
    /// would still hop to the cooperative pool at the await.
    @MainActor
    private func makeReviewView(day: Date, periods: [Period]) -> ReviewView {
        reviewPeriods = periods
        let reviewPeriodsUI = periods.map { p -> ReviewPeriod in
            let alts = (p.contextDoc.map { attribution.explain(doc: $0) } ?? [])
                .map { ReviewAlt(key: $0.key, summary: $0.summary, score: $0.score) }
            var why: String?
            if let src = p.guessSource {
                why = Attribution.isExact(src) ? "from \(Attribution.sourceDescription(src))"
                    : "\(Attribution.sourceDescription(src))" + (p.guessConfidence.map { String(format: " · %.2f", $0) } ?? "")
            }
            return ReviewPeriod(
                id: p.id, kind: p.kind,
                durationText: Summary.hm(p.reportedSeconds),
                activeSeconds: p.trueSeconds,
                slices: p.byTicket.map { Slice(label: $0.ticket ?? "untracked", seconds: $0.seconds) },
                recap: p.recap ?? "",
                guessKey: p.ticket,
                guessSummary: p.ticket.flatMap { attribution.summary(for: $0) },
                guessWhy: why,
                alternatives: alts,
                originalGuess: p.ticket ?? "",
                ticket: p.effectiveTicket ?? "",
                note: p.assignedNote ?? "")
        }
        let model = ReviewModel(dayText: TimeBlocks.dayString(day), periods: reviewPeriodsUI,
                                tickets: attribution.pickerTickets, noTicketLabel: config.noTicketLabel)
        reviewModel = model
        return ReviewView(model: model,
                          onSave: { [weak self] in self?.saveReview() },
                          onShift: { [weak self] d in self?.shiftReview(d) },
                          onSubmitTempo: { [weak self] in self?.submitToTempoFromReview() })
    }

    // MARK: - Housekeeping / pruning

    private func housekeeping() {
        let now = Date()
        if config.segmentRetentionDays > 0 {
            store.deleteSegments(before: now.addingTimeInterval(-config.segmentRetentionDays * 86400))
        }
        // Boxed (submitted) days get a shorter window.
        if config.submittedRetentionDays > 0 {
            let cutoff = now.addingTimeInterval(-config.submittedRetentionDays * 86400)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = .current
            let submitted = UserDefaults.standard.stringArray(forKey: "submittedDays") ?? []
            var remaining: [String] = []
            for d in submitted {
                if let date = f.date(from: d), date < cutoff {
                    let (s, e) = TimeBlocks.dayBounds(date)
                    store.deleteSegments(from: s, to: e)
                } else { remaining.append(d) }
            }
            UserDefaults.standard.set(remaining, forKey: "submittedDays")
        }
        store.pruneLabels(max: config.labelMaxCount)
        worklogProvider.pruneWorklogMap(olderThanDays: 90)   // resubmission no longer realistic past this
    }

    private func markSubmitted(day: String) {
        var s = UserDefaults.standard.stringArray(forKey: "submittedDays") ?? []
        if !s.contains(day) { s.append(day); UserDefaults.standard.set(s, forKey: "submittedDays") }
    }

    // MARK: - Tempo submission (manual, review-gated, with preview)

    private struct PlannedWorklog { var date: String; var block: String; var ticket: String; var startTime: String; var seconds: Int; var description: String }

    private func submitToTempoFromReview() {
        guard let model = reviewModel else { return }
        let dayStr = TimeBlocks.dayString(reviewDay)
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter TRAPS on a duplicate key, and
        // id uniqueness here holds only because `compile` runs `mergeByTicket` before returning —
        // a dependency nothing at this call site expresses. Reordering that pipeline should not be
        // able to turn into a hard crash in Submit.
        let periodsById = Dictionary(reviewPeriods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        let planned: [PlannedWorklog] = model.periods.compactMap { rp in
            guard let p = periodsById[rp.id] else { return nil }
            // Same predicate the timesheet export uses (`appendTimesheet(periods:day:)` filters on
            // `hasActivity`). They used to disagree: submit billed periods the export omitted, so a
            // sub-minute period clamped up to `periodMinMinutes` became a 15-minute worklog that
            // appeared nowhere in timesheet-log.md — impossible to reconcile after the fact.
            guard p.hasActivity else { return nil }
            let raw = rp.ticket.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            let ticket: String
            if raw.caseInsensitiveCompare(config.noTicketLabel) == .orderedSame {
                // "No ticket": map to the configured fallback, or skip Tempo for this period.
                let fb = config.noTicketTempoTicket.trimmingCharacters(in: .whitespaces).uppercased()
                guard !fb.isEmpty else { return nil }
                ticket = fb
            } else {
                ticket = raw.uppercased()
            }
            // REPORTED duration (rounded/padded, not a fixed blockHours) — the whole point of the
            // per-ticket day-total model. startTime is a formality some worklog APIs require; it's
            // not meaningful data here (exact clock time isn't tracked), so the earliest touch on
            // this ticket today is as good a placeholder as any.
            let startTime = tf.string(from: p.start)
            let seconds = Int(p.reportedSeconds)
            let desc = rp.note.trimmingCharacters(in: .whitespaces).isEmpty
                ? "\(ticket) — \(dayStr) \(p.kind.rawValue) (TimeTracker)" : rp.note
            return PlannedWorklog(date: dayStr, block: rp.id, ticket: ticket, startTime: startTime, seconds: seconds, description: desc)
        }
        guard !planned.isEmpty else { showInfo("Nothing to submit — assign a ticket to a period first."); return }

        // Preview exactly what will be posted.
        NSApp.activate(ignoringOtherApps: true)
        let preview = NSAlert()
        preview.messageText = "Submit \(planned.count) worklog(s) to \(worklogProvider.displayName)?"
        preview.informativeText = planned.map { "• \($0.date) · \($0.ticket) · \(Summary.hm(Double($0.seconds)))\n   “\($0.description)”" }
            .joined(separator: "\n") + "\n\nThis posts to your official \(worklogProvider.displayName) timesheet."
        preview.addButton(withTitle: "Submit to \(worklogProvider.displayName)")
        preview.addButton(withTitle: "Cancel")
        guard preview.runModal() == .alertFirstButtonReturn else { return }

        // This day may already carry worklogs posted under the OLD fixed-block model, whose map
        // keys the floating-period ids can't resolve (see `WorklogKey`). Posting on top of them
        // duplicates the whole day on an official timesheet, so make it an explicit, informed
        // choice rather than a silent one — we hold the old ids, so we can actually clean up.
        let legacy = worklogProvider.legacyFixedBlockWorklogIds(day: dayStr)
        if !legacy.isEmpty {
            let warn = NSAlert()
            warn.alertStyle = .warning
            warn.messageText = "\(dayStr) was already submitted under the previous timesheet model"
            warn.informativeText = "\(legacy.count) worklog(s) from the old fixed-block model still exist in "
                + "\(worklogProvider.displayName) for this day. They can't be matched to the new per-ticket "
                + "periods, so submitting now would ADD to them and bill the day twice.\n\n"
                + "Delete the old worklog(s) first, then submit the periods above?"
            warn.addButton(withTitle: "Delete \(legacy.count) old, then submit")
            warn.addButton(withTitle: "Cancel")
            guard warn.runModal() == .alertFirstButtonReturn else { return }
        }

        if !worklogProvider.configured {
            guard let token = promptForWorklogToken() else { return }
            worklogProvider.connect(token: token)
        }

        Task { @MainActor in
            // The author is resolved by whichever worklog provider is active — Tempo needs the
            // paired Jira accountId, 7pace needs its own identity; neither is hard-gated here.
            let author = await worklogProvider.resolveAuthor()
            var ok = 0
            var fails: [String] = []
            // Confirmed above. Clear the map entry as each one goes, so an interrupted run doesn't
            // re-prompt for worklogs that are already gone.
            for old in legacy {
                await worklogProvider.deleteWorklog(id: old.id)
                worklogProvider.setWorklogId(day: dayStr, block: old.block, id: nil)
            }
            for p in planned {
                var idStr = attribution.issueId(forKey: p.ticket)
                if idStr == nil { idStr = await issueProvider.fetchIssueId(forKey: p.ticket) }
                guard let idStr else { fails.append("\(p.ticket): couldn't resolve issue id"); continue }
                // Idempotent: replace any worklog we previously posted for this (day, block).
                if let old = worklogProvider.worklogId(day: p.date, block: p.block) { await worklogProvider.deleteWorklog(id: old) }
                do {
                    let newId = try await worklogProvider.createWorklog(issueId: idStr, author: author, date: p.date,
                                                                        startTime: p.startTime, seconds: p.seconds, description: p.description)
                    worklogProvider.setWorklogId(day: p.date, block: p.block, id: newId)
                    ok += 1
                } catch {
                    fails.append("\(p.ticket): " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
            }
            if ok > 0 { self.markSubmitted(day: dayStr) }
            let a = NSAlert()
            a.messageText = "\(worklogProvider.displayName): \(ok) submitted" + (fails.isEmpty ? "" : ", \(fails.count) failed")
            if !fails.isEmpty { a.alertStyle = .warning; a.informativeText = fails.joined(separator: "\n") }
            a.runModal()
        }
    }

    private func promptForWorklogToken() -> String? {
        switch config.worklogProvider {
        case .tempo: return promptForTempoToken()
        case .sevenPace: return promptForSevenPaceToken()
        }
    }

    private func promptForSevenPaceToken() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect 7pace"
        alert.informativeText = "Create a token in Timetracker Settings → Reporting and API → Reporting & API, "
            + "then paste it here. Requires sevenPaceOrg to already be set in Settings."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "7pace API token"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func promptForTempoToken() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect Tempo"
        alert.informativeText = "Create a Tempo API token in Tempo → Settings → API integration, then paste it here. (Separate from your Jira token.)"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 6
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Tempo API token"
        let openButton = linkButton("Open Tempo settings") { [weak self] in
            let site = self?.atlassian.site ?? "id.atlassian.com"
            NSWorkspace.shared.open(URL(string: "https://\(site)/plugins/servlet/ac/io.tempo.jira/tempo-app#!/configuration/api-integration")!)
        }
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(openButton)
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func saveReview() {
        guard let model = reviewModel else { return }
        let dayStr = TimeBlocks.dayString(reviewDay)
        let periodsById = Dictionary(reviewPeriods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var taught = 0
        for rp in model.periods {
            guard let p = periodsById[rp.id] else { continue }
            let raw = rp.ticket.trimmingCharacters(in: .whitespaces)
            // Normalize (pasted URL → key); the review stays authoritative for free-form keys.
            let key = raw.isEmpty ? nil : (attribution.normalizeTicketEntry(raw) ?? raw.uppercased())
            let note = rp.note.trimmingCharacters(in: .whitespaces)
            store.setPeriodAssignment(day: dayStr, kind: p.kind.rawValue, ticketKey: p.ticket ?? "",
                                      ticket: key, note: note.isEmpty ? nil : note)

            // Teach the guesser — but only from signal, never from silence: when the user changed
            // the system's guess, or explicitly confirmed it. This is the primary labeling pipeline.
            if let key, !key.isEmpty {
                let changed = key.caseInsensitiveCompare(rp.originalGuess) != .orderedSame
                if changed || rp.confirmed { taught += learnPeriod(p, ticket: key) }
            }
        }
        if taught > 0 { attribution.reloadMemory() }   // new labels feed content memory (k-NN)

        let rows = summary.appendTimesheet(periods: reviewPeriods, day: reviewDay)
        let alert = NSAlert()
        alert.messageText = rows.isEmpty ? "Nothing to export" : "Exported \(rows.count) row(s)"
        var info = rows.joined(separator: "\n")
        if taught > 0 { info += "\n\nLearned from \(taught) context\(taught == 1 ? "" : "s") this session." }
        alert.informativeText = info
        alert.runModal()
    }

    /// Turn a confirmed/corrected period into training examples from its REAL work contexts (the
    /// persisted `context_doc` of its OWN member segments — not re-queried from the store, so a
    /// floating regular block's skipped-over carve-outs are never pulled in). Capped to the few
    /// longest distinct contexts. Returns how many labels were written.
    @discardableResult
    private func learnPeriod(_ period: Period, ticket: String) -> Int {
        let segs = period.members.map { $0.segment }
        guard !segs.isEmpty else { return 0 }
        // Distinct rich contexts by total duration; fall back to a reconstructed app+title doc.
        var byDoc: [String: Double] = [:]
        for s in segs where !(s.contextDoc?.isEmpty ?? true) { byDoc[s.contextDoc!, default: 0] += s.duration }
        var docs = byDoc.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
        if docs.isEmpty, let s = segs.max(by: { $0.duration < $1.duration }) {
            docs = ["App: \(s.appName)" + (s.windowTitle.isEmpty ? "" : "\nWindow: \(s.windowTitle)")]
        }
        guard !docs.isEmpty else { return 0 }
        // Signature bias from the dominant segment (repo/app), attached to the top context only.
        let dominant = segs.max { $0.duration < $1.duration }
        var sigs: [String] = []
        if let s = dominant {
            if !s.bundleId.isEmpty { sigs.append("app:\(s.bundleId)") }
            if let d = s.contextDoc, let repo = Attribution.parseRepo(d) { sigs.append("repo:\(repo)") }
        }
        for (i, d) in docs.enumerated() {
            attribution.recordTraining(contextDoc: d, ticket: ticket, signatures: i == 0 ? sigs : [])
        }
        return docs.count
    }

    @MainActor
    private func shiftReview(_ delta: Int) {
        reviewDay = Calendar.current.date(byAdding: .day, value: delta, to: reviewDay) ?? reviewDay
        refreshReviewView(day: reviewDay, present: false)
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    // MARK: - Scoped ticket assignment

    @objc private func openAssign() {
        let now = Date()
        guard let block = TimeBlocks.block(for: now, config) else { return }
        let report = summary.report(day: now, block: block)
        let cands = monitor.currentState?.attribution.candidates.map { $0.key } ?? []
        let view = AssignView(
            tickets: attribution.pickerTickets,
            candidates: cands,
            blockName: "block \(block.id)",
            blockRange: block.label,
            blockActive: Summary.hm(report.activeSeconds),
            currentlyPinned: monitor.pinnedTicket,
            ticket: monitor.currentState?.attribution.ticket ?? (cands.first ?? ""),
            onApply: { [weak self] t, scope in self?.applyAssignment(t, scope) },
            onUnpin: { [weak self] in self?.unpinTicket(); self?.assignWindow?.close() },
            onCancel: { [weak self] in self?.assignWindow?.close() })

        assignWindow?.close()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Assign ticket"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        assignHost = host; assignWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func applyAssignment(_ ticket: String, _ scope: AssignScope) {
        guard !ticket.isEmpty else { return }
        let now = Date()
        switch scope {
        case .current:
            monitor.overrideCurrentTicket(ticket)
        case .lastHour:
            store.retag(from: now.addingTimeInterval(-3600), to: now, ticket: ticket)
            monitor.overrideCurrentTicket(ticket)
        case .thisBlock:
            if let block = TimeBlocks.block(for: now, config) {
                store.retag(from: block.start, to: block.end, ticket: ticket)
                store.setBlockAssignment(day: TimeBlocks.dayString(now), block: block.id, ticket: ticket, note: nil)
            }
            monitor.overrideCurrentTicket(ticket)
        case .pin:
            monitor.setPin(ticket)
        }
        assignWindow?.close()
        rebuildMenu(current: monitor.currentState)
    }

    @objc private func unpinTicket() {
        monitor.setPin(nil)
        rebuildMenu(current: monitor.currentState)
    }

    // MARK: - Inspector (microscope)

    @objc private func openInspector() {
        let view = makeInspectorView()
        if let host = inspectorHost, let win = inspectorWindow {
            host.rootView = view
            NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "TimeTracker Inspector"
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        inspectorHost = host; inspectorWindow = win
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
    }

    private func makeInspectorView() -> InspectorView {
        InspectorView(data: makeInspectorData()) { [weak self] in
            guard let self else { return }
            self.inspectorHost?.rootView = self.makeInspectorView()
        }
    }

    private func makeInspectorData() -> InspectorData {
        var d = InspectorData()
        guard let st = monitor.currentState, !st.idle else { return d }
        d.hasState = true
        let ctx = st.context
        d.contextDoc = ctx.document
        d.signatures = ctx.signatures()
        d.finalTicket = st.attribution.ticket
        d.finalSource = st.attribution.source
        d.finalConfidence = st.attribution.confidence
        d.category = st.attribution.category
        d.pinned = monitor.pinnedTicket
        d.lexical = attribution.lexicalRank(ctx)
        d.memory = attribution.memoryNearest(ctx)
        d.embedding = embedCandidates

        // Ranking-weight breakdown for the top candidates (and the final pick).
        var rkeys: [String] = d.lexical.prefix(4).map { $0.key }
        if let f = d.finalTicket, !rkeys.contains(f) { rkeys.insert(f, at: 0) }
        d.ranking = rkeys.compactMap { k in
            attribution.priorBreakdown(forKey: k).map { (key: k, factors: $0.factors, total: $0.total) }
        }

        if let llm = lastLLM {
            d.llmKey = llm.key; d.llmReason = llm.reason; d.llmConfidence = llm.confidence
            d.llmAge = Summary.hm(Date().timeIntervalSince(llm.at))
        }

        // Mirror exactly the inputs llmRefine builds, so the prompt shown is the real one.
        let arcText = buildArcSummary()
        var keys = st.attribution.candidates.map { $0.key }
        for g in embedCandidates where !keys.contains(g.key) { keys.append(g.key) }
        let shortlist = (keys.isEmpty ? Array(attribution.guessTickets.prefix(12))
                                      : attribution.tickets(for: keys)).filter { !$0.done }
        let previous = gatedPreviousGuess(arc: arcText, shortlistKeys: shortlist.map { $0.key })
        let hints = llmHints(st)
        let examples = attribution.fewShot(context: ctx.document, k: config.llmFewShot)
        d.llmPrompt = ollama.previewPrompt(arc: arcText, current: ctx.document, candidates: shortlist,
                                           previous: previous, hints: hints, examples: examples)
        return d
    }

    // MARK: - Settings

    @objc private func openSettings() {
        let model = SettingsModel(Config.load())   // reflect what's on disk
        settingsModel = model
        let view = SettingsView(model: model, onSave: { [weak self] in self?.saveSettings() })
        if let host = settingsHost, let win = settingsWindow {
            host.rootView = view
            NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "TimeTracker Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        settingsHost = host; settingsWindow = win
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
    }

    private func saveSettings() {
        guard let model = settingsModel else { return }
        model.config.save()
        let alert = NSAlert()
        alert.messageText = "Settings saved"
        alert.informativeText = "Restart TimeTracker to apply the changes."
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    private func relaunch() {
        monitor.flush()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]   // -n: new instance
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Teaching (label examples → SQLite)

    @objc private func openTeach() {
        let view = makeTeachView()
        if let host = teachHost, let win = teachWindow {
            host.rootView = view
            NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Teach the guesser"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 680, height: 580))
        win.isReleasedWhenClosed = false
        win.center()
        teachHost = host; teachWindow = win
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
    }

    private func makeTeachView() -> TeachView {
        let cs = monitor.currentState
        let hasCurrent = (cs != nil) && !(cs?.idle ?? true)
        teachCurrentDoc = cs?.context.document ?? ""
        teachCurrentSignatures = cs?.context.signatures() ?? []
        let curSummary = cs.map { "\($0.appName)" + ($0.title.isEmpty ? "" : " · " + String($0.title.prefix(60))) } ?? "—"
        let curTicket = cs?.attribution.ticket ?? (cs?.attribution.candidates.first?.key ?? "")

        // Recent distinct segments (last ~2 days) to label. Active-learning order: the UNTAGGED
        // (uncertain) ones come first — that's where a label adds the most signal — and each is
        // pre-filled with the guesser's best suggestion so confirming is one click.
        let start = Calendar.current.date(byAdding: .day, value: -1, to: TimeBlocks.dayBounds(Date()).start)!
        let segs = store.segments(from: start, to: Date()).filter { !$0.idle && $0.duration >= 120 }
        var seen = Set<String>(); var untaggedRows: [TeachRow] = []; var taggedRows: [TeachRow] = []
        for seg in segs.reversed() {
            let key = seg.appName + "|" + seg.windowTitle
            guard seen.insert(key).inserted else { continue }
            let summary = seg.appName + (seg.windowTitle.isEmpty ? "" : " · " + String(seg.windowTitle.prefix(50)))
            // Prefer the rich persisted context (repo/files/commits/AI-session) over the bare
            // app+title — both for a sharper suggestion and so the saved label captures real work.
            let doc = seg.contextDoc ?? ("App: \(seg.appName)" + (seg.windowTitle.isEmpty ? "" : "\nWindow: \(seg.windowTitle)"))
            let suggestion = seg.ticket ?? attribution.topGuess(forDoc: doc)
            let row = TeachRow(timeText: clock(seg.start), summary: summary, doc: doc,
                               guessed: suggestion ?? "?", ticket: suggestion ?? "")
            if seg.ticket == nil { untaggedRows.append(row) } else { taggedRows.append(row) }
            if untaggedRows.count + taggedRows.count >= 40 { break }
        }
        // Untagged first (highest learning value), each group newest-first (stable partition).
        let rows = untaggedRows + taggedRows

        let model = TeachModel(count: attribution.labelCount, currentSummary: curSummary,
                               currentTicket: curTicket, hasCurrent: hasCurrent, rows: rows,
                               tickets: attribution.pickerTickets)
        teachModel = model
        return TeachView(model: model,
                         onSaveCurrent: { [weak self] t in self?.saveCurrentLabel(t) },
                         onSaveRow: { [weak self] idx, t in self?.saveRowLabel(idx, t) },
                         onRefresh: { [weak self] in
                             guard let self else { return }
                             self.teachHost?.rootView = self.makeTeachView()
                         })
    }

    private func saveCurrentLabel(_ ticket: String) {
        guard let key = attribution.normalizeTicketEntry(ticket), !teachCurrentDoc.isEmpty else { return }
        attribution.recordTraining(contextDoc: teachCurrentDoc, ticket: key, signatures: teachCurrentSignatures)
        teachModel?.count = attribution.labelCount
        reindexEmbeddings()
    }

    private func saveRowLabel(_ index: Int, _ ticket: String) {
        guard let model = teachModel, index < model.rows.count,
              let key = attribution.normalizeTicketEntry(ticket) else { return }
        attribution.recordTraining(contextDoc: model.rows[index].doc, ticket: key)
        teachModel?.count = attribution.labelCount
    }

    @objc private func exportToday() {
        let rows = summary.appendTimesheet(day: Date())
        let alert = NSAlert()
        alert.messageText = rows.isEmpty ? "No activity to export yet" : "Appended \(rows.count) row(s) to timesheet-log.md"
        alert.informativeText = rows.joined(separator: "\n")
        alert.runModal()
    }

    @objc private func refreshSprint() { runRefresh(silent: false) }

    /// Refresh the ticket/work-item corpus via whichever issue provider is configured. Silent =
    /// no popup (used by the timer + launch). `issueProvider` already dispatches on
    /// `config.issueProvider`, so checking `.configured` here can't clobber the other provider's
    /// sprint.json even if stale credentials for it are still sitting in the Keychain.
    private func runRefresh(silent: Bool) {
        guard issueProvider.configured, !refreshingJira else { return }
        refreshingJira = true
        Task { @MainActor in
            defer { refreshingJira = false }
            do {
                let r = try await issueProvider.refreshSprint()
                attribution.reloadSprint()
                reindexEmbeddings()
                rebuildMenu(current: monitor.currentState)
                if !silent { showInfo("Refreshed: \(r.open) open / \(r.total) total ticket(s).") }
            } catch { if !silent { showError(error) } }
        }
    }

    @objc private func connectAtlassian() {
        guard let creds = promptForApiToken() else { return }
        Task { @MainActor in
            do {
                let who = try await atlassian.connect(site: creds.site, email: creds.email, token: creds.token)
                let r = try await atlassian.refreshSprint()
                attribution.reloadSprint()
                reindexEmbeddings()
                rebuildMenu(current: monitor.currentState)
                showInfo("Connected as \(who). Loaded \(r.open) open / \(r.total) total ticket(s).")
            } catch {
                atlassian.disconnect()   // don't keep bad credentials
                rebuildMenu(current: monitor.currentState)
                showError(error)
            }
        }
    }

    @objc private func connectAzureDevOps() {
        guard let creds = promptForAzureDevOpsPAT() else { return }
        Task { @MainActor in
            do {
                let who = try await azureDevOps.connect(org: creds.org, pat: creds.pat)
                let r = try await azureDevOps.refreshSprint()
                attribution.reloadSprint()
                reindexEmbeddings()
                rebuildMenu(current: monitor.currentState)
                // Remember the org on disk so it pre-fills next time (and survives a restart) —
                // re-read first, same as addNoTicketRule, so this doesn't clobber unrelated
                // Settings edits made since launch. AppDelegate's own `config` is a `let` (every
                // setting needs a restart to take effect, by design), so this only affects the
                // NEXT launch's prefill, not this session's live dialog.
                var disk = Config.load()
                if disk.azureOrg != creds.org { disk.azureOrg = creds.org; disk.save() }
                showInfo("Connected to \(who). Loaded \(r.open) open / \(r.total) total work item(s).")
            } catch {
                azureDevOps.disconnect()   // don't keep bad credentials
                rebuildMenu(current: monitor.currentState)
                showError(error)
            }
        }
    }

    @objc private func disconnectAzureDevOps() {
        azureDevOps.disconnect()
        rebuildMenu(current: monitor.currentState)
    }

    private func promptForAzureDevOpsPAT() -> (org: String, pat: String)? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect Azure DevOps (Personal Access Token)"
        alert.informativeText = """
        Enter your organization, then use “Open token page” below to create a token. Azure \
        DevOps has no way to preselect scopes via link — on the page, choose "Custom defined" \
        and check exactly:
          • Work Items — Read
          • Code — Read
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 6
        let orgField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        orgField.placeholderString = "Organization (e.g. contoso)"
        orgField.stringValue = config.azureOrg
        let openButton = linkButton("Open token page") { [orgField] in
            let org = orgField.stringValue.trimmingCharacters(in: .whitespaces)
            let path = org.isEmpty ? "https://dev.azure.com/_usersSettings/tokens" : "https://dev.azure.com/\(org)/_usersSettings/tokens"
            if let url = URL(string: path) { NSWorkspace.shared.open(url) }
        }
        let scopesLabel = NSTextField(labelWithString: "Required scopes: Work Items (Read), Code (Read)")
        scopesLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let patField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        patField.placeholderString = "Personal Access Token"
        stack.addArrangedSubview(orgField)
        stack.addArrangedSubview(openButton)
        stack.addArrangedSubview(scopesLabel)
        stack.addArrangedSubview(patField)
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 110)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = orgField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let org = orgField.stringValue.trimmingCharacters(in: .whitespaces)
        let pat = patField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !org.isEmpty, !pat.isEmpty else { return nil }
        return (org, pat)
    }

    /// A plain button inside an alert's accessory view, as opposed to one of `NSAlert`'s own
    /// `addButton`s — clicking one of THOSE always ends the modal session (that's how
    /// `runModal()` returns), which is what made "Open token page" close the whole connect
    /// dialog and lose anything already typed. A button that isn't wired through
    /// `addButton`/`runModal`'s return value can be clicked without ending the modal at all.
    /// NSButton needs an Objective-C target/action, not a Swift closure, hence the trampoline.
    private final class ActionTrampoline: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
    private static var trampolineKey: UInt8 = 0
    private func linkButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let trampoline = ActionTrampoline(action)
        let button = NSButton(title: title, target: trampoline, action: #selector(ActionTrampoline.invoke))
        button.bezelStyle = .inline
        // Retain the trampoline for as long as the button exists — NSButton's `target` is unowned.
        objc_setAssociatedObject(button, &Self.trampolineKey, trampoline, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    @objc private func disconnectAtlassian() {
        atlassian.disconnect()
        rebuildMenu(current: monitor.currentState)
    }

    private func showInfo(_ s: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "TimeTracker"; a.informativeText = s; a.runModal()
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Error"
        a.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        a.runModal()
    }

    /// Collect site / email / API token. Token field is masked.
    private func promptForApiToken() -> (site: String, email: String, token: String)? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect Atlassian (API token)"
        alert.informativeText = """
        Use “Open token page” below to create a token, then enter:
          • Site: your <site> (e.g. acme, or acme.atlassian.net)
          • Email: your Atlassian account email
          • API token: the token you created
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 6
        let siteField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        siteField.placeholderString = "Site (e.g. acme)"
        let emailField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        emailField.placeholderString = "you@company.com"
        let openButton = linkButton("Open token page") {
            NSWorkspace.shared.open(URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
        }
        let scopesLabel = NSTextField(labelWithString: "Required scopes: read:jira-work, read:jira-user (or read:me)")
        scopesLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let tokenField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        tokenField.placeholderString = "API token"
        stack.addArrangedSubview(siteField)
        stack.addArrangedSubview(emailField)
        stack.addArrangedSubview(openButton)
        stack.addArrangedSubview(scopesLabel)
        stack.addArrangedSubview(tokenField)
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 140)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = siteField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let site = siteField.stringValue.trimmingCharacters(in: .whitespaces)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty, !email.isEmpty, !token.isEmpty else { return nil }
        return (site, email, token)
    }
    @objc private func togglePause() { monitor.setPaused(!monitor.paused); updateStatus(monitor.currentState) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(AppPaths.dataDir) }
    @objc private func openTicketURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func quit() { monitor.flush(); NSApplication.shared.terminate(nil) }

    // MARK: - Accessibility

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// A silently-disconnected issue provider (e.g. a Keychain item that didn't survive a rebuild,
    /// or credentials never entered) otherwise shows up only as "Connect …" quietly sitting in the
    /// menu — easy to miss, and everything downstream (guessing, Review, submission) just degrades
    /// with no obvious cause. Called once preload() has actually run, so `configured` is reliable.
    /// `UNUserNotificationCenter.current()` raises `bundleProxyForCurrentProcess is nil` — a hard
    /// crash, not a throw — in any process without a real bundle. `swift build` + running
    /// `.build/debug/timetracker` directly is a documented dev path here (see CLAUDE.md), so every
    /// call site has to be gated on actually being bundled.
    private static var canUseUserNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    private func notifyIfIssueProviderDisconnected() {
        guard !issueProvider.configured else { return }
        guard Self.canUseUserNotifications else {
            // Un-bundled dev run: no notification centre, but don't swallow the signal entirely.
            FileHandle.standardError.write("timetracker: not connected to \(issueProvider.displayName)\n".data(using: .utf8)!)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "TimeTracker"
        content.body = "Not connected to \(issueProvider.displayName) — tickets won't be guessed until you reconnect."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "issue-provider-disconnected", content: content, trigger: nil))
    }

    // MARK: - Continuous embeddings (async, off the hot path)

    private func reindexEmbeddings() {
        guard embeddings.enabled else { return }
        let tickets = attribution.guessTickets   // embeddings only over the guessable pool
        Task.detached { [weak self] in await self?.embeddings.index(tickets) }
    }

    /// On context change, rank by embeddings async, then re-fuse all signals. Embedding is now a
    /// feature inside the fusion ranker (not a standalone auto-tagger): it can only push a ticket
    /// over the line in concert with a grounded signal. Never touches an exact/explicit segment.
    private func maybeEmbed(_ state: LiveState?) {
        guard embeddings.enabled, let st = state, !st.idle, !embedInFlight else { return }
        if Attribution.isExact(st.attribution.source) { return }
        let doc = st.context.document
        guard doc != lastEmbedDoc, !doc.isEmpty else { return }
        embedInFlight = true
        lastEmbedDoc = doc
        Task { @MainActor in
            embedCandidates = await embeddings.rank(context: doc, max: config.semanticMaxCandidates)
            embedInFlight = false
            embedTop = embedCandidates.first
            refineCurrent()
            // Still ambiguous after the deterministic + embedding fusion? Ask the local LLM to
            // break the tie (event-driven — no blind polling).
            if let cur = monitor.currentState, cur.attribution.ticket == nil, !cur.attribution.candidates.isEmpty {
                llmRefine()
            }
        }
    }

    /// If the focused window is a PR you're reviewing (title "Pull request NNNN: ... - Repos")
    /// and its linked work item hasn't been resolved yet this session, fetch it live regardless of
    /// who it's assigned to — a code review is real work on someone else's ticket, not something
    /// the "assigned to me" corpus should have to already contain. Guarded so this doesn't touch
    /// the network on every sample: `prReviewInFlight` avoids a duplicate request while one is
    /// outstanding, and `!Attribution.isExact` skips it entirely once resolved (from then on the
    /// exact-match check in `decideAttribution` fires purely from Attribution's in-memory cache).
    private func maybeResolvePRReview(_ state: LiveState?) {
        guard config.issueProvider == .azureDevOps, config.azurePRBridgeEnabled, azureDevOps.configured,
              let st = state, !st.idle, !Attribution.isExact(st.attribution.source),
              let prId = attribution.extractPRNumber(fromTitle: st.context.title),
              !prReviewInFlight.contains(prId)
        else { return }
        prReviewInFlight.insert(prId)
        Task { @MainActor in
            defer { self.prReviewInFlight.remove(prId) }
            // Cache the result either way — nil (no linked work item) still marks this PR as
            // "checked" so the segment reads as code-review activity instead of falling through
            // to ordinary fusion guessing (see PeriodCompiler's generic-code-review fallback).
            let ticket = await self.azureDevOps.resolveWorkItem(forPullRequestId: prId)
            self.attribution.cachePRReviewTicket(prId: prId, ticket: ticket)
            self.refineCurrent()
        }
    }

    /// Re-run the full fusion for the open segment with whatever async evidence we now have
    /// (embedding ranks + the latest LLM vote) and apply the result.
    private func refineCurrent() {
        guard let st = monitor.currentState, !st.idle, !monitor.paused, monitor.pinnedTicket == nil else { return }
        if Attribution.isExact(st.attribution.source) { return }
        let embedding = Dictionary(embedCandidates.map { ($0.key, $0.score) }, uniquingKeysWith: max)
        let result = attribution.decideAttribution(context: st.context, embedding: embedding, llm: currentLLMVote())
        monitor.applyRefinement(result)
        rebuildMenu(current: monitor.currentState)
    }

    /// The most recent LLM pick as a fusion vote, if it's fresh and still a guessable candidate.
    private func currentLLMVote() -> (key: String, confidence: Double)? {
        guard let l = lastLLM, Date().timeIntervalSince(l.at) < config.llmPreviousGuessTTLMinutes * 60 else { return nil }
        return (l.key, l.confidence)
    }

    // MARK: - LLM refinement (event-driven tie-break; folded into fusion)

    /// Dynamic, structured hints for the LLM (NOT raw vectors): scored candidates, what's
    /// already logged today, and the local time.
    private func llmHints(_ st: LiveState) -> String {
        var lines: [String] = []
        let lex = st.attribution.candidates.prefix(5).map { "\($0.key)=\(String(format: "%.2f", $0.score))" }
        if !lex.isEmpty { lines.append("Lexical candidate scores: " + lex.joined(separator: ", ")) }
        if !embedCandidates.isEmpty {
            lines.append("Embedding candidate scores: " + embedCandidates.prefix(5).map { "\($0.key)=\(String(format: "%.2f", $0.score))" }.joined(separator: ", "))
        }
        let day = TimeBlocks.dayString(Date())
        var logged: [String] = []
        for b in TimeBlocks.blocks(for: Date(), config) {
            if let t = store.blockAssignment(day: day, block: b.id)?.ticket { logged.append("\(b.label)=\(t)") }
        }
        if !logged.isEmpty { lines.append("Already logged today: " + logged.joined(separator: ", ")) }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        lines.append("Local time: \(f.string(from: Date()))")
        return lines.joined(separator: "\n")
    }

    private var lastLLMContext: String?

    /// Ask the local LLM to pick from the shortlist, then fold its vote into the fusion. Only
    /// fires when the deterministic+embedding fusion is still undecided, and skips a context it
    /// already judged (the Ollama client also memoizes identical prompts). Never auto-tags on its
    /// own — its pick is one weighted, agreement-trusted feature in `decideAttribution`.
    private func llmRefine() {
        guard config.ollamaEnabled, !monitor.paused, let st = monitor.currentState, !st.idle else { return }
        if Attribution.isExact(st.attribution.source) { return }
        let current = st.context.document
        guard !current.isEmpty else { return }
        // Dedupe: don't re-ask for a context we already have a fresh verdict on.
        if current == lastLLMContext, currentLLMVote() != nil { return }

        // Shortlist = current fused candidates ∪ embedding candidates, else the recent pool.
        var keys = st.attribution.candidates.map { $0.key }
        for g in embedCandidates where !keys.contains(g.key) { keys.append(g.key) }
        let shortlist = (keys.isEmpty ? Array(attribution.guessTickets.prefix(12))
                                      : attribution.tickets(for: keys)).filter { !$0.done }
        guard !shortlist.isEmpty else { return }

        let arcText = buildArcSummary()
        let previous = gatedPreviousGuess(arc: arcText, shortlistKeys: shortlist.map { $0.key })
        let hints = llmHints(st)
        let examples = attribution.fewShot(context: current, k: config.llmFewShot)
        lastLLMContext = current
        Task { @MainActor in
            guard let s = await self.ollama.suggest(arc: arcText, current: current, candidates: shortlist,
                                                    previous: previous, hints: hints, examples: examples) else { return }
            self.lastLLM = (s.key, s.reason, s.confidence ?? 0, Date())
            self.refineCurrent()   // fusion decides whether the LLM vote (plus the rest) auto-tags
        }
    }

    /// Record distinct work contexts into the rolling arc buffer (skips idle).
    private func recordArc(_ state: LiveState?) {
        guard let st = state, !st.idle else { return }
        guard !st.context.document.isEmpty else { return }
        if arc.last?.ctx.document != st.context.document { arc.append((Date(), st.context)) }
        let cutoff = Date().addingTimeInterval(-config.llmArcWindowMinutes * 60)
        arc.removeAll { $0.at < cutoff }
        if arc.count > 60 { arc.removeFirst(arc.count - 60) }
    }

    /// Deterministic digest of the last hour aggregated by *logical activity* (repo, else app),
    /// summing CUMULATIVE time across interleaved visits — so alternating between windows still
    /// adds up correctly instead of fragmenting. Time is summed in seconds so sub-minute visits
    /// aren't lost to rounding. Keeps the tags (files, AI-session meaning, URLs, meeting). No LLM.
    private func buildArcSummary() -> String {
        guard !arc.isEmpty else { return "(no recorded activity yet)" }
        let now = Date()

        struct Agg { var secs: Double = 0; var label: String; var files: [String] = []
                     var sessions: [String] = []; var urls: [String] = []; var meeting: String? }
        var byKey: [String: Agg] = [:]; var order: [String] = []
        for (i, e) in arc.enumerated() {
            let end = i + 1 < arc.count ? arc[i + 1].at : now
            let secs = max(0, end.timeIntervalSince(e.at))
            let c = e.ctx
            let key = c.repo.map { "repo:\($0)" } ?? "app:\(c.app)"
            if byKey[key] == nil { byKey[key] = Agg(label: c.repo ?? c.app); order.append(key) }
            byKey[key]!.secs += secs
            if let f = c.openFile, !byKey[key]!.files.contains(f) { byKey[key]!.files.append(f) }
            for f in c.changedFiles where !byKey[key]!.files.contains(f) { byKey[key]!.files.append(f) }
            if let s = c.aiSession, !byKey[key]!.sessions.contains(s) { byKey[key]!.sessions.append(s) }
            if let h = c.url.flatMap({ URL(string: $0)?.host }), !byKey[key]!.urls.contains(h) { byKey[key]!.urls.append(h) }
            if let m = c.meeting { byKey[key]!.meeting = m }
        }

        var lines: [String] = []
        for a in byKey.values.sorted(by: { $0.secs > $1.secs }) where a.secs >= 30 {
            var parts = [a.label]
            if !a.files.isEmpty { parts.append("files: " + a.files.prefix(6).joined(separator: ", ")) }
            if let s = a.sessions.first { parts.append("session: " + s.prefix(90)) }
            if !a.urls.isEmpty { parts.append("urls: " + a.urls.prefix(2).joined(separator: ", ")) }
            if let m = a.meeting { parts.append("meeting: " + m.prefix(40)) }
            lines.append("- \(Summary.hm(a.secs)) total · " + parts.joined(separator: " · "))
        }
        return lines.prefix(12).joined(separator: "\n")
    }

    /// Feed the previous guess back ONLY if recent AND still supported by current evidence,
    /// so a guess can't pin itself once work has moved on.
    private func gatedPreviousGuess(arc: String, shortlistKeys: [String]) -> (key: String, reason: String)? {
        guard let l = lastLLM,
              Date().timeIntervalSince(l.at) < config.llmPreviousGuessTTLMinutes * 60 else { return nil }
        let supported = shortlistKeys.contains(l.key) || arc.localizedCaseInsensitiveContains(l.key)
        return supported ? (l.key, l.reason) : nil
    }

    // MARK: - Timesheet fill reminders

    @MainActor
    private func checkReminders() {
        guard config.remindersEnabled, !monitor.paused, !promptOpen else { return }
        let now = Date()
        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        let today = TimeBlocks.dayString(now)
        let defaults = UserDefaults.standard

        // Morning: nudge once if the last active prior day isn't filled.
        if hour >= config.morningReminderHour, defaults.string(forKey: "lastMorningDay") != today {
            defaults.set(today, forKey: "lastMorningDay")   // checked once today either way
            if let d = priorDayNeedingFill() {
                remind(day: d, message: "\(TimeBlocks.dayString(d)) isn't filled in your timesheet. Review it?")
                return
            }
        }
        // Evening: nudge once to fill today (only if it actually needs it).
        if hour >= config.eveningReminderHour, defaults.string(forKey: "lastEveningDay") != today,
           dayNeedsFilling(now) {
            defaults.set(today, forKey: "lastEveningDay")
            remind(day: now, message: "Fill today's timesheet (\(today))?")
        }
    }

    /// True if the day has activity but Review was never saved for it. Deliberately coarser than
    /// the old per-block check (which read `block_assignments` directly) — now that Save writes
    /// `period_assignments` instead, per-block granularity doesn't carry over cleanly (a day's
    /// period shape is data-dependent, not a fixed list of ids), and "did you forget entirely" is
    /// what this reminder is actually for, not "did you assign every period."
    ///
    /// All three checks are needed. `period_assignments` is a new table, so on its own it reports
    /// EVERY day predating the floating-period compiler as unfilled — including days already
    /// reviewed and submitted under the fixed-block model. That isn't just noise: it nudges the
    /// user to reopen and re-submit historical days, which is exactly the path that duplicates
    /// worklogs (their old map keys no longer resolve — see `WorklogKey`).
    private func dayNeedsFilling(_ day: Date) -> Bool {
        guard summary.dayReports(day).contains(where: { $0.hasActivity }) else { return false }
        let dayStr = TimeBlocks.dayString(day)
        if !store.periodAssignments(day: dayStr).isEmpty { return false }
        if (UserDefaults.standard.stringArray(forKey: "submittedDays") ?? []).contains(dayStr) { return false }
        // Legacy: reviewed under the fixed-block model, before period_assignments existed.
        return !TimeBlocks.blocks(for: day, config).contains { store.blockAssignment(day: dayStr, block: $0.id)?.ticket?.isEmpty == false }
    }

    /// The most recent prior day that had activity; returned only if it still needs filling.
    private func priorDayNeedingFill() -> Date? {
        let start = TimeBlocks.dayBounds(Date()).start
        for back in 1...4 {
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: start) else { continue }
            if summary.dayReports(day).contains(where: { $0.hasActivity }) {
                return dayNeedsFilling(day) ? day : nil   // first active day decides
            }
        }
        return nil
    }

    // Runs a modal alert, so it is main-thread by construction anyway.
    @MainActor
    private func remind(day: Date, message: String) {
        promptOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "TimeTracker"
        a.informativeText = message
        a.addButton(withTitle: "Review now")
        a.addButton(withTitle: "Later")
        let review = a.runModal() == .alertFirstButtonReturn
        promptOpen = false
        if review { presentReview(day: day) }
    }

    // MARK: - Real-time unknown prompt

    /// Gentle nudge after sustained un-guessable work (fusion abstained — no candidate at all), so
    /// a block doesn't silently go un-attributed. Shares the prompt cooldown; offers assign / no-ticket.
    private func checkAbstainNudge() {
        guard config.abstainNudgeMinutes > 0, !monitor.paused, !promptOpen,
              let since = abstainSince, Date().timeIntervalSince(since) >= config.abstainNudgeMinutes * 60,
              let st = monitor.currentState, !st.idle, st.attribution.ticket == nil else { return }
        if let last = lastPromptDismissal, Date().timeIntervalSince(last) < config.promptCooldownMinutes * 60 { return }
        promptOpen = true
        abstainSince = nil   // reset so it won't immediately refire
        let a = NSAlert()
        a.messageText = "What are you working on?"
        a.informativeText = "\(Summary.hm(Date().timeIntervalSince(since))) of un-attributed work in \(st.appName)"
            + (st.title.isEmpty ? "" : " · \(st.title.prefix(50))") + ".\nAssign a ticket, or mark it no-ticket."
        a.addButton(withTitle: "Assign…"); a.addButton(withTitle: "No ticket"); a.addButton(withTitle: "Snooze")
        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        promptOpen = false
        lastPromptDismissal = Date()
        switch resp {
        case .alertFirstButtonReturn:
            if let key = promptForTicket(message: "Assign a ticket to the current activity") { monitor.overrideCurrentTicket(key) }
        case .alertSecondButtonReturn:
            markCurrentNoTicket()
        default: break   // snooze
        }
        rebuildMenu(current: monitor.currentState)
    }

    private func checkUnknownBacklog() {
        guard !monitor.paused, !promptOpen else { return }
        if let last = lastPromptDismissal, Date().timeIntervalSince(last) < config.promptCooldownMinutes * 60 { return }
        // Every block that has activity is already attributed → nothing to nag about.
        let reports = summary.dayReports(Date())
        if reports.allSatisfy({ !$0.hasActivity || $0.effectiveTicket != nil }) { return }
        // The current block was already answered (assigned) → don't keep asking for it.
        if let cur = TimeBlocks.block(for: Date(), config),
           store.blockAssignment(day: TimeBlocks.dayString(Date()), block: cur.id)?.ticket?.isEmpty == false { return }
        let unknown = summary.unknownActiveSeconds(inBlockContaining: Date())
        guard unknown >= config.promptAfterUnknownMinutes * 60 else { return }
        promptOpen = true

        Task { @MainActor in
            // Shortlist from the current lexical candidates (or recent tickets); LLM picks.
            let candidates = monitor.currentState?.attribution.candidates ?? []
            let shortlist = (candidates.isEmpty
                ? Array(attribution.guessTickets.prefix(12))
                : attribution.tickets(for: candidates.map { $0.key })).filter { !$0.done }
            let current = monitor.currentState?.context.document ?? ""
            let arcText = buildArcSummary()

            var prefill = candidates.first?.key
            var reason = ""
            let hints = monitor.currentState.map { llmHints($0) } ?? ""
            let examples = attribution.fewShot(context: current, k: config.llmFewShot)
            if ollama.enabled, !shortlist.isEmpty,
               let s = await ollama.suggest(arc: arcText, current: current, candidates: shortlist,
                                            previous: gatedPreviousGuess(arc: arcText, shortlistKeys: shortlist.map { $0.key }),
                                            hints: hints, examples: examples) {
                prefill = s.key; reason = s.reason
            }

            var msg = "\(Summary.hm(unknown)) of this block has no ticket. What were you working on?"
            if let p = prefill { msg += "\n\nSuggested: \(p)" + (reason.isEmpty ? "" : " — \(reason)") }

            if let key = self.promptForTicket(message: msg, prefill: prefill),
               let block = TimeBlocks.block(for: Date(), config) {
                self.store.setBlockAssignment(day: TimeBlocks.dayString(Date()), block: block.id, ticket: key, note: nil)
                // Re-tag the block's untracked segments so the unknown time actually clears
                // (otherwise the prompt keeps firing on the same backlog).
                self.store.retagUntracked(from: block.start, to: block.end, ticket: key)
            }
            self.lastPromptDismissal = Date()
            self.promptOpen = false
        }
    }

    /// Shared modal: a text field (optionally prefilled with a guess) plus a sprint picker.
    private func promptForTicket(message: String, prefill: String? = nil) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "TimeTracker"
        alert.informativeText = message
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Skip")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        stack.orientation = .vertical
        stack.spacing = 6
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. \(attribution.keyFormat.placeholderExample)"
        if let prefill { field.stringValue = prefill }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        popup.addItem(withTitle: "— pick from sprint —")
        for t in attribution.pickerTickets.prefix(60) {
            popup.addItem(withTitle: "\(t.key) — \(t.summary.prefix(40))")
            popup.lastItem?.representedObject = t.key
        }
        popup.target = self
        // When a sprint item is chosen, copy its key into the field.
        popup.action = #selector(popupChose(_:))
        objc_setAssociatedObject(popup, &Self.fieldKey, field, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(field)
        if !attribution.sprint.isEmpty { stack.addArrangedSubview(popup) }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        // Normalize (pasted URL → key, validate). Warn instead of silently storing garbage.
        guard let key = attribution.normalizeTicketEntry(raw) else {
            let warn = NSAlert()
            warn.messageText = "Not a valid ticket"
            warn.informativeText = "“\(raw)” isn’t a recognized ticket key (expected e.g. \(attribution.keyFormat.placeholderExample)). Nothing was assigned."
            warn.runModal()
            return nil
        }
        return key
    }

    private static var fieldKey: UInt8 = 0
    @objc private func popupChose(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0,
              let field = objc_getAssociatedObject(sender, &Self.fieldKey) as? NSTextField,
              let key = sender.selectedItem?.representedObject as? String else { return }
        field.stringValue = key
    }
}

// Headless evaluation mode: measure the guesser without launching the menu-bar UI.
if CommandLine.arguments.contains("--eval") {
    EvalHarness.run()
    exit(0)
}

// Headless period-compiler dump (`--dump-periods [--day yyyy-MM-dd]`): the manual-verification
// vehicle for PeriodCompiler against the real local DB, ahead of any Review UI risk. Temporary —
// remove once the Review UI is wired to periods and this is superseded by using the app directly.
if CommandLine.arguments.contains("--dump-periods") {
    let config = Config.load()
    let store = Store()
    let attribution = Attribution(config: config, store: store)
    let ollama = Ollama(config: config)
    var day = Date()
    if let idx = CommandLine.arguments.firstIndex(of: "--day"), idx + 1 < CommandLine.arguments.count {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: CommandLine.arguments[idx + 1]) { day = d }
    }
    // Pump the run loop rather than blocking on a semaphore: PeriodCompiler is @MainActor (see
    // its doc comment), so parking the main thread here would deadlock the very work we're
    // awaiting. Pumping also lets URLSession's delegate callbacks land for the Ollama pass.
    var done = false
    Task { @MainActor in
        let periods = await PeriodCompiler.compile(day: day, config: config, store: store, attribution: attribution, ollama: ollama)
        print("Periods for \(TimeBlocks.dayString(day)):")
        for p in periods {
            let kind = p.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let trueH = String(format: "%.2f", p.trueSeconds / 3600)
            let repH = String(format: "%.2f", p.reportedSeconds / 3600)
            print("  \(kind) true=\(trueH)h reported=\(repH)h  ticket=\(p.effectiveTicket ?? "—")  source=\(p.guessSource ?? "-")")
        }
        let totalTrue = periods.reduce(0.0) { $0 + $1.trueSeconds } / 3600
        let totalReported = periods.reduce(0.0) { $0 + $1.reportedSeconds } / 3600
        let target = TimeBlocks.dailyTargetSeconds(day, config) / 3600
        print(String(format: "Total: true=%.2fh reported=%.2fh target=%.2fh", totalTrue, totalReported, target))
        done = true
    }
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
