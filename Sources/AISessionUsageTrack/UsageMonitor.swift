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

    // Pages are SPAs; the extraction script scrapes whatever text we can find
    // that looks usage-related. We deliberately keep this loose — the user can
    // refine selectors later once they see what their account renders.
    var extractionScript: String {
        return """
        (() => {
            const root = document.querySelector('main') || document.body;
            if (!root) return '';
            const raw = (root.innerText || '').split('\\n')
                .map(s => s.trim())
                .filter(s => s.length > 0);
            const interesting = raw.filter(line =>
                /\\d+\\s*%/.test(line) ||
                /\\d+\\s*\\/\\s*\\d+/.test(line) ||
                /limit|usage|reset|remaining|messages|tokens|prompts|requests|week|hour/i.test(line)
            );
            // De-dupe while keeping order.
            const seen = new Set();
            const out = [];
            for (const line of interesting) {
                if (!seen.has(line)) { seen.add(line); out.push(line); }
                if (out.length >= 40) break;
            }
            return out.join('\\n');
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
}

// MARK: - WebScraper

final class WebScraper: NSObject, WKNavigationDelegate, WKUIDelegate {
    let service: Service
    let webView: WKWebView

    private var hiddenWindow: NSWindow?
    private var popupWebViews: [WKWebView] = []   // retain OAuth popup webviews
    private var popupWindows: [NSWindow] = []
    private var completion: ((Result<(text: String, currentURL: URL?), Error>) -> Void)?
    private var pollTimer: Timer?
    private var navigationStart: Date?

    init(service: Service) {
        self.service = service
        let config = WKWebViewConfiguration()
        // .default() persists cookies to the app's data store across launches.
        config.websiteDataStore = .default()
        // OAuth flows sometimes use window.open() popups; allow them.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: config
        )
        // Real Safari UA reduces "browser not supported" pages.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
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

    /// WKWebView layout/JS sometimes misbehaves when not attached to a window;
    /// keep one offscreen so headless polling stays reliable.
    private func attachToHiddenWindowIfNeeded() {
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = webView
        // Place far offscreen.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderOut(nil)
        hiddenWindow = window
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
        // Poll until either body has noticeable text or we time out.
        var elapsed = 0.0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += 0.6
            let check = "(() => { const r = document.querySelector('main') || document.body; return r ? (r.innerText || '').length : 0; })();"
            webView.evaluateJavaScript(check) { result, _ in
                let length = (result as? Int) ?? 0
                if length > 200 || elapsed > 15 {
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
                    }
                }
                self.states[service] = st
            }
        }
    }

    private static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})\s*%"#)
    static func firstPercent(in s: String) -> Int? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = percentRegex.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    // MARK: - Login flow

    private var loginWindows: [Service: NSWindow] = [:]

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
            // Drop back to accessory mode if no more login windows are open.
            if self.loginWindows.isEmpty {
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

    /// Clear cookies for a given service so the user can re-login as someone else.
    func logout(_ service: Service) {
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage]
        let host = service.url.host ?? ""
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { $0.displayName.contains(host) || host.contains($0.displayName) }
            store.removeData(ofTypes: types, for: matching) {
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
