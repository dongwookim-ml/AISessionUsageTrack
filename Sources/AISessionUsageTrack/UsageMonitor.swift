import Foundation
import AppKit
import WebKit
import Combine
import SwiftUI

// MARK: - Service identity

enum Service: String, CaseIterable, Identifiable {
    case gemini, claude
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }

    var url: URL {
        switch self {
        case .gemini: return URL(string: "https://gemini.google.com/usage")!
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        }
    }

    // After login + redirect chain, the URL should still contain this substring.
    // If not, we treat the page as a login prompt.
    var loggedInURLMarker: String {
        switch self {
        case .gemini: return "gemini.google.com"
        case .claude: return "claude.ai"
        }
    }

    /// SF Symbol used in the menubar and section headers. Chosen to resemble
    /// each brand's actual mark: Google's Gemini logo is a sparkle, and
    /// Anthropic's Claude logo is an asterisk-style burst.
    var iconName: String {
        switch self {
        case .gemini: return "sparkles"
        case .claude: return "asterisk"
        }
    }

    /// Brand accent color used to tint the icon.
    var brandColor: Color {
        switch self {
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)   // Google blue
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)   // Anthropic coral
        }
    }

    // Pages are SPAs; the extraction script scrapes whatever text we can find
    // that looks usage-related. We deliberately keep this loose — the user can
    // refine selectors later once they see what their account renders. When
    // the filtered output is empty we fall back to a clipped dump of the
    // visible page text so we can see what was actually rendered.
    var extractionScript: String {
        return """
        (() => {
            // Scrape from <body>: Claude's usage card lives outside <main>,
            // and Gemini's page works either way.
            const root = document.body;
            if (!root) return '';
            const raw = (root.innerText || '').split('\\n')
                .map(s => s.trim())
                .filter(s => s.length > 0);
            const interesting = raw.filter(line =>
                /\\d+\\s*%/.test(line) ||
                /\\d+\\s*\\/\\s*\\d+/.test(line) ||
                /limit|usage|reset|remaining|messages|tokens|prompts|requests|week|hour/i.test(line)
            );
            const seen = new Set();
            const filtered = [];
            for (const line of interesting) {
                if (!seen.has(line)) { seen.add(line); filtered.push(line); }
                if (filtered.length >= 40) break;
            }
            if (filtered.length > 0) return filtered.join('\\n');
            // Fallback: dump page text (capped) so the user can see what's there.
            const dump = raw.join('\\n');
            const cap = 3000;
            return '[no keyword matches — raw page text below]\\n' +
                (dump.length > cap ? dump.slice(0, cap) + '\\n…(truncated)' : dump);
        })();
        """
    }
}

// MARK: - State per service

struct ServiceState {
    enum Status: Equatable {
        case unknown
        case loading
        case needsLogin
        case ok(text: String, percent: Int?)
        case error(String)
    }

    var status: Status = .unknown
    var lastUpdated: Date? = nil
    /// Human-readable reset time, e.g. "Resets at 2:02 PM". Parsed from the
    /// scraped page at refresh time. For Claude, the "Resets in X hr Y min"
    /// text is converted to an absolute time first.
    var resetText: String? = nil

    var shortLabel: String {
        switch status {
        case .unknown:    return "—"
        case .loading:    return "…"
        case .needsLogin: return "login"
        case .error:      return "err"
        case .ok(_, let pct):
            if let pct = pct { return "\(pct)%" }
            return "ok"
        }
    }

    /// Severity color for the current usage percent (green / orange / red).
    /// Used by both the menubar text and the in-menu progress bar.
    var severityColor: Color {
        if case .ok(_, let pct?) = status {
            if pct >= 80 { return .red }
            if pct >= 50 { return .orange }
            return .green
        }
        return .secondary
    }

    /// Percent value if known, else nil — for `ProgressView(value:)`.
    var percent: Int? {
        if case .ok(_, let pct) = status { return pct }
        return nil
    }
}

// MARK: - WebScraper

final class WebScraper: NSObject, WKNavigationDelegate, WKUIDelegate {
    let service: Service
    let webView: WKWebView

    /// Returns a per-service persistent `WKWebsiteDataStore`. The identifier
    /// is generated on first use and persisted in `UserDefaults` so the same
    /// store (and therefore the same cookies / logins) is reused on relaunch.
    static func dataStore(for service: Service) -> WKWebsiteDataStore {
        let key = "WebsiteDataStoreUUID.\(service.rawValue)"
        let uuid: UUID
        if let s = UserDefaults.standard.string(forKey: key), let parsed = UUID(uuidString: s) {
            uuid = parsed
        } else {
            uuid = UUID()
            UserDefaults.standard.set(uuid.uuidString, forKey: key)
        }
        return WKWebsiteDataStore(forIdentifier: uuid)
    }

    private var hiddenWindow: NSWindow?
    private var popupWebViews: [WKWebView] = []   // retain OAuth popup webviews
    private var popupWindows: [NSWindow] = []
    private var completion: ((Result<(text: String, currentURL: URL?), Error>) -> Void)?
    private var pollTimer: Timer?
    private var navigationStart: Date?

    init(service: Service) {
        self.service = service
        let config = WKWebViewConfiguration()
        // Per-service persistent store so cookies (esp. Google's auth cookies)
        // don't leak between Gemini and Claude. The UUID is stored in
        // UserDefaults so the same store is reused across app launches.
        config.websiteDataStore = WebScraper.dataStore(for: service)
        // OAuth flows sometimes use window.open() popups; allow them.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: config
        )
        // Real Safari UA reduces "browser not supported" pages.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        // Enable Safari's Web Inspector against this webview for debugging.
        // Open Safari → Develop → <Mac name> → AISessionUsageTrack → <url>.
        if #available(macOS 13.3, *) {
            view.isInspectable = true
        }
        self.webView = view
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        attachToHiddenWindowIfNeeded()
    }

    // MARK: - WKUIDelegate (popup windows for OAuth)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Reuse the same data store so cookies set in the popup carry over.
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let win = NSWindow(
            contentRect: popup.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign in"
        win.contentView = popup
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)

        popupWebViews.append(popup)
        popupWindows.append(win)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let idx = popupWebViews.firstIndex(of: webView) {
            popupWindows[idx].close()
            popupWindows.remove(at: idx)
            popupWebViews.remove(at: idx)
        }
    }

    /// Host the WKWebView in a panel the WindowServer treats as visible (so
    /// WebKit renders and does NOT flip `document.hidden = true`, which would
    /// throttle / pause SPA fetches on Claude and Gemini) — but the panel is
    /// transparent, non-focusable, non-clickable, off cmd-tab and Mission
    /// Control, and parked at the corner of the screen.
    ///
    /// An `orderOut`'d window causes Claude's React app to never finish
    /// hydrating during background polls; scraping then only worked while the
    /// login window was open.
    private func attachToHiddenWindowIfNeeded() {
        let panel = NSPanel(
            contentRect: webView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .transient
        ]
        panel.level = .normal
        panel.contentView = webView

        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 1, y: f.minY))
        }
        panel.orderFrontRegardless()
        hiddenWindow = panel
    }

    /// Temporarily move the webView into the given window (for login).
    /// Call `returnWebViewToHidden()` afterward.
    func detachFromHidden() {
        webView.removeFromSuperview()
    }

    func returnWebViewToHidden() {
        guard let window = hiddenWindow else { return }
        if webView.superview !== window.contentView {
            window.contentView = webView
        }
        // Re-order so the WindowServer keeps it "visible" and WebKit keeps
        // rendering after a login window closes.
        window.orderFrontRegardless()
    }

    func fetch(completion: @escaping (Result<(text: String, currentURL: URL?), Error>) -> Void) {
        // If something is already in flight, replace the completion.
        self.completion = completion
        self.navigationStart = Date()
        let req = URLRequest(url: service.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView.load(req)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Poll for the SPA to actually paint the usage data. The previous
        // loose keyword check (matching "Usage" / "limit" / etc.) fired as
        // soon as Claude rendered the page heading, before the API-driven
        // usage card hydrated. Require a literal `digit-%` or `digit/digit`
        // so we only extract once the real numbers are on the page.
        var elapsed = 0.0
        pollTimer?.invalidate()
        let readyCheck = """
        (() => {
            const r = document.body;
            if (!r) return false;
            const t = r.innerText || '';
            if (t.length < 100) return false;
            return /\\d+\\s*%|\\d+\\s*\\/\\s*\\d+/.test(t);
        })();
        """
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += 0.6
            webView.evaluateJavaScript(readyCheck) { result, _ in
                let ready = (result as? Bool) ?? false
                if ready || elapsed > 45 {
                    timer.invalidate()
                    self.pollTimer = nil
                    self.runExtraction()
                }
            }
        }
    }

    private func runExtraction() {
        webView.evaluateJavaScript(service.extractionScript) { [weak self] result, error in
            guard let self = self else { return }
            let text = (result as? String) ?? ""
            if let error = error, text.isEmpty {
                self.completion?(.failure(error))
            } else {
                self.completion?(.success((text: text, currentURL: self.webView.url)))
            }
            self.completion = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?(.failure(error)); completion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?(.failure(error)); completion = nil
    }
}

// MARK: - UsageMonitor

@MainActor
final class UsageMonitor: ObservableObject {
    @Published var states: [Service: ServiceState] = [
        .gemini: ServiceState(),
        .claude: ServiceState()
    ]

    @Published var settings = AppSettings.load() {
        didSet { settings.save(); rescheduleTimer() }
    }

    let scrapers: [Service: WebScraper]
    private var timer: Timer?

    init() {
        var dict: [Service: WebScraper] = [:]
        for s in Service.allCases { dict[s] = WebScraper(service: s) }
        self.scrapers = dict
        rescheduleTimer()
        // First refresh shortly after launch (gives login state a chance).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshAll()
        }
    }

    func rescheduleTimer() {
        timer?.invalidate()
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        let base = TimeInterval(settings.refreshSeconds)
        let jitter = Double.random(in: -Double(settings.jitterSeconds)...Double(settings.jitterSeconds))
        let delay = max(15.0, base + jitter)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
                self?.scheduleNextTick()
            }
        }
    }

    func refreshAll() {
        for s in Service.allCases { refreshNow(s) }
    }

    func refreshNow(_ service: Service) {
        states[service]?.status = .loading
        guard let scraper = scrapers[service] else { return }
        scraper.fetch { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                var st = self.states[service] ?? ServiceState()
                st.lastUpdated = Date()
                switch result {
                case .failure(let err):
                    st.status = .error(err.localizedDescription)
                case .success(let payload):
                    if !payload.currentURL.map({ $0.absoluteString.contains(service.loggedInURLMarker) }).orFalse {
                        st.status = .needsLogin
                    } else if payload.text.isEmpty {
                        // Loaded but found no usage-like lines. Could mean login wall
                        // or simply that our heuristics missed; flag as needsLogin
                        // if we see "sign in" patterns, else surface as ok with no pct.
                        let host = payload.currentURL?.host ?? ""
                        if host.contains("accounts.google.com") || host.contains("login") {
                            st.status = .needsLogin
                        } else {
                            st.status = .ok(text: "(no usage info found)", percent: nil)
                        }
                    } else {
                        let pct = Self.firstPercent(in: payload.text)
                        st.status = .ok(text: payload.text, percent: pct)
                        st.resetText = Self.parseResetText(in: payload.text, service: service)
                    }
                }
                self.states[service] = st
            }
        }
    }

    /// Parse a "Resets …" string from the scraped page. Gemini's page renders
    /// "Resets at H:MM AM/PM" directly; Claude's page renders "Resets in X hr
    /// Y min", which we convert to an absolute clock time so both services
    /// display the same shape.
    static func parseResetText(in text: String, service: Service) -> String? {
        switch service {
        case .gemini:
            // Look for "Resets at H:MM AM/PM" anywhere in the page.
            let pattern = #"Resets at \d{1,2}:\d{2}\s*(?:AM|PM|am|pm)"#
            if let r = text.range(of: pattern, options: .regularExpression) {
                return String(text[r])
            }
            return nil
        case .claude:
            // Parse "Resets in X hr Y min" / "in Y min" / "in X hr" and add
            // to the current time to produce an absolute "Resets at H:MM AM/PM".
            let pattern = #"Resets in(?:\s+(\d+)\s*hr)?(?:\s+(\d+)\s*min)?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { return nil }
            var minutes = 0
            if let r = Range(m.range(at: 1), in: text), let h = Int(text[r]) { minutes += h * 60 }
            if let r = Range(m.range(at: 2), in: text), let mm = Int(text[r]) { minutes += mm }
            guard minutes > 0 else { return nil }
            let target = Date().addingTimeInterval(TimeInterval(minutes * 60))
            return "Resets at \(claudeResetFormatter.string(from: target))"
        }
    }

    private static let claudeResetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})\s*%"#)
    static func firstPercent(in s: String) -> Int? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = percentRegex.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    // MARK: - Window flow

    private var loginWindows: [Service: NSWindow] = [:]
    private var settingsWindow: NSWindow?

    /// True when at least one user-facing window is open (login or settings),
    /// so we should keep the app's activation policy as `.regular`.
    private var hasOpenWindow: Bool { !loginWindows.isEmpty || settingsWindow != nil }

    /// Show the Settings window. We host SettingsView in our own NSWindow
    /// instead of using SwiftUI's `Settings` scene because `showSettingsWindow:`
    /// is unreliable for accessory apps (LSUIElement=true) — the action
    /// often finds no responder when sent from a MenuBarExtra button.
    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // NSHostingController auto-sizes the window to the SwiftUI content's
        // intrinsic size, so there's no slack space at the bottom of the panel.
        let controller = NSHostingController(rootView: SettingsView().environmentObject(self))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "AI Session Usage — Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let delegate = LoginWindowDelegate { [weak self] in
            guard let self = self else { return }
            self.settingsWindow = nil
            if !self.hasOpenWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        window.delegate = delegate
        objc_setAssociatedObject(window, &LoginWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func showLogin(for service: Service) {
        guard let scraper = scrapers[service] else { return }
        // Bring app forward so the window can take focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = loginWindows[service] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(service.displayName) — Login"
        window.center()
        window.isReleasedWhenClosed = false

        // Detach the webView from the hidden window so we can host it in the login window.
        scraper.detachFromHidden()

        // Wrap the WKWebView with a URL bar + back/forward/reload so the user
        // can paste magic-link URLs (Google OAuth is blocked in WebViews; email
        // magic-link is the fallback).
        let hosting = NSHostingView(rootView: LoginWindowView(
            webView: scraper.webView,
            initialURL: service.url
        ))
        window.contentView = hosting
        scraper.webView.load(URLRequest(url: service.url))

        let delegate = LoginWindowDelegate { [weak self] in
            guard let self = self else { return }
            scraper.returnWebViewToHidden()
            self.loginWindows.removeValue(forKey: service)
            // Drop back to accessory mode if no other user-facing window
            // (login or settings) is still open.
            if !self.hasOpenWindow {
                NSApp.setActivationPolicy(.accessory)
            }
            // Try a refresh now that cookies should be in place.
            self.refreshNow(service)
        }
        // Retain delegate via associated object pattern: store in window.
        window.delegate = delegate
        objc_setAssociatedObject(window, &LoginWindowDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        loginWindows[service] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Clear ALL cookies / storage in this service's data store so the user
    /// can re-login as someone else. Per-service stores are isolated, so this
    /// won't affect the other service.
    func logout(_ service: Service) {
        guard let store = scrapers[service]?.webView.configuration.websiteDataStore else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {
                Task { @MainActor in
                    self.states[service]?.status = .needsLogin
                }
            }
        }
    }
}

private var LoginWindowDelegateKey: UInt8 = 0

final class LoginWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - Settings

struct AppSettings: Codable {
    var refreshSeconds: Int
    var jitterSeconds: Int
    var showLabelInMenuBar: Bool

    static let defaults = AppSettings(
        refreshSeconds: 180,
        jitterSeconds: 30,
        showLabelInMenuBar: true
    )

    static let storeKey = "AppSettings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return defaults
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.storeKey)
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
