import AppKit
import ApplicationServices
import CoreGraphics

/// Snapshot of what the user is doing right now.
struct LiveState {
    var bundleId: String
    var appName: String
    var title: String
    var idle: Bool
    var attribution: AttributionResult
    var since: Date
    var context: WorkContext
}

/// Watches foreground app + focused-window title, segments the timeline,
/// and persists closed segments. Accessibility-only (no Apple Events).
final class FocusMonitor {
    private let store: Store
    private let attribution: Attribution
    private let enricher: ContextEnricher
    private let config: Config

    private(set) var paused = false
    /// When set, every active segment is tagged with this ticket until unpinned — the user's
    /// explicit "I'm on this for a while" override (covers the next hours, no guessing).
    private(set) var pinnedTicket: String?
    private var sampleTimer: Timer?
    /// Enrichment (AppleScript, git, lsof, kubectl, ps) runs here — NEVER on the main
    /// thread, or it freezes the menu-bar UI. Serial, so the enricher's caches stay safe.
    private let enrichQueue = DispatchQueue(label: "ca.justereseau.timetracker.enrich", qos: .utility)
    private var sampling = false

    private var openStart: Date?
    private var openState: LiveState?

    /// Called after every sample with the latest live state (nil when paused/idle-with-no-app).
    var onUpdate: ((LiveState?) -> Void)?

    init(store: Store, attribution: Attribution, enricher: ContextEnricher, config: Config) {
        self.store = store
        self.attribution = attribution
        self.enricher = enricher
        self.config = config
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        sampleTimer = Timer.scheduledTimer(withTimeInterval: config.sampleSeconds, repeats: true) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    func setPaused(_ p: Bool) {
        paused = p
        if p { flush() } else { sample() }
        if p { onUpdate?(nil) }
    }

    /// Apply a ticket to the in-progress segment. `retag` also updates already-persisted
    /// segments with the same title today (used for explicit manual assignment).
    func overrideCurrentTicket(_ rawTicket: String, source: String = "manual", retag: Bool = true) {
        // Normalize at the single live-override chokepoint: a pasted URL becomes its key,
        // garbage is rejected. Keeps poison out of segments + the learned correction/label store.
        guard let ticket = attribution.normalizeTicketEntry(rawTicket) else { return }
        if var st = openState {
            st.attribution.ticket = ticket
            st.attribution.source = source
            openState = st
            if retag { store.retagToday(matchingWindowTitle: st.title, ticket: ticket) }
            // Learn from explicit user assignments (not the LLM's own auto-tags).
            if source == "manual" { attribution.recordCorrection(context: st.context, ticket: ticket) }
            onUpdate?(st)
        }
    }

    /// Apply an async re-fusion (embedding/LLM arrived) to the open segment: always refresh the
    /// ranked candidates + confidence for the menu/Inspector, and adopt the new ticket only when
    /// fusion auto-tagged one. Never overrides a pin or an exact/explicit attribution.
    func applyRefinement(_ result: AttributionResult) {
        guard var st = openState, !st.idle, pinnedTicket == nil else { return }
        if Attribution.isExact(st.attribution.source) { return }
        st.attribution.candidates = result.candidates
        st.attribution.confidence = result.confidence
        if let t = result.ticket {
            st.attribution.ticket = t
            st.attribution.source = result.source
        }
        openState = st
        onUpdate?(st)
    }

    var currentState: LiveState? { openState }

    @objc private func appActivated(_ note: Notification) { sample() }
    @objc private func willSleep() { flush() }
    @objc private func didWake() { sample() }

    /// Whether the screen is locked (login window / lock screen), via the session dictionary.
    private static func screenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    private func idleSeconds() -> Double {
        // Seconds since the last HID event of any type.
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }

    private func focusedWindowTitle(pid: pid_t) -> String {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef else { return "" }
        let window = winRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return "" }
        return title
    }

    private func sample() {
        guard !paused, !sampling else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let now = Date()

        // Cheap, main-thread-safe bits up front.
        let bundleId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? bundleId
        let pid = app.processIdentifier
        // Locked screen / login window = away (the lock screen emits HID events, so the idle
        // timer alone won't catch it — this otherwise logged 11h of "active" overnight time).
        let away = bundleId == "com.apple.loginwindow" || appName == "loginwindow" || Self.screenLocked()
        let idle = away || idleSeconds() >= config.idleSeconds
        // For excluded apps, don't even read the window title (privacy).
        let excludedApp = config.isExcludedApp(bundleId: bundleId, appName: appName)
        let title = (idle || excludedApp) ? "" : focusedWindowTitle(pid: pid)

        // Heavy enrichment off the main thread; commit back on main.
        sampling = true
        enrichQueue.async { [weak self] in
            guard let self else { return }
            let ctx = self.enricher.enrich(bundleId: bundleId, appName: appName, title: title,
                                           idle: idle, pid: pid, now: now, forcedExclude: excludedApp)
            DispatchQueue.main.async {
                self.sampling = false
                guard !self.paused else { return }
                self.commit(idle: idle, ctx: ctx, now: now)
            }
        }
    }

    /// Set/clear the pinned ticket. While pinned, all active segments use it.
    func setPin(_ ticket: String?) {
        pinnedTicket = ticket
        if let ticket { overrideCurrentTicket(ticket, source: "pinned", retag: false) }
    }

    /// Runs on the main thread: attribute (touches matcher/corrections), segment, persist.
    private func commit(idle: Bool, ctx: WorkContext, now: Date) {
        // Private/excluded context: persist the prior segment, then record nothing for this one.
        if ctx.excluded {
            flush()
            openStart = nil
            openState = LiveState(bundleId: "private", appName: "Private", title: "", idle: false,
                                  attribution: AttributionResult(ticket: nil, source: nil, category: "private"),
                                  since: now, context: ctx)
            onUpdate?(openState)
            return
        }
        var attr = idle ? AttributionResult(ticket: nil, source: nil, category: nil)
                        : attribution.attribute(context: ctx)
        // An explicit pin wins over everything (except idle).
        if !idle, let pin = pinnedTicket {
            attr.ticket = pin; attr.source = "pinned"
        }
        let new = LiveState(bundleId: ctx.bundleId, appName: ctx.app, title: ctx.title,
                            idle: idle, attribution: attr, since: openStart ?? now, context: ctx)
        if !sameSignature(openState, new) {
            flush()
            openStart = now
            var n = new; n.since = openStart!
            openState = n
        } else {
            var n = openState!; n.context = ctx; n.attribution = attr; openState = n
        }
        onUpdate?(openState)
    }

    private func sameSignature(_ a: LiveState?, _ b: LiveState) -> Bool {
        guard let a else { return false }
        return a.bundleId == b.bundleId && a.title == b.title && a.idle == b.idle
            && a.context.url == b.context.url
    }

    /// Persist the currently-open segment, if any (idempotent).
    func flush() {
        guard let start = openStart, let st = openState else { return }
        let end = Date()
        // Ignore sub-second noise.
        if end.timeIntervalSince(start) >= 1 {
            // Persist the enriched context (capped) — for idle/excluded segments it's empty, so
            // nothing sensitive about a private window is stored.
            let doc = (st.idle || st.context.excluded) ? nil : String(st.context.document.prefix(4000))
            store.insert(Segment(
                start: start, end: end,
                bundleId: st.bundleId, appName: st.appName, windowTitle: st.title,
                idle: st.idle, ticket: st.attribution.ticket,
                ticketSource: st.attribution.source, category: st.attribution.category,
                confidence: st.attribution.confidence,
                contextDoc: doc?.isEmpty == true ? nil : doc,
                meeting: (st.idle || st.context.excluded) ? nil : st.context.meeting))
        }
        openStart = nil
        openState = nil
    }
}
