import SwiftUI
import AppKit
import WebKit

// MARK: - Login window with URL bar + nav controls

struct LoginWindowView: View {
    let webView: WKWebView
    let initialURL: URL

    @State private var urlText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!webView.canGoBack)
                Button { webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!webView.canGoForward)
                Button { webView.reload() } label: { Image(systemName: "arrow.clockwise") }

                TextField("Paste a URL (e.g. a magic-link from your email) and press Enter",
                          text: $urlText, onCommit: navigate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button("Go", action: navigate)
                Button("Home") { webView.load(URLRequest(url: initialURL)) }
            }
            .padding(8)
            .background(.bar)

            WebViewContainer(webView: webView)
        }
        .onAppear { urlText = (webView.url ?? initialURL).absoluteString }
    }

    private func navigate() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme) else { return }
        webView.load(URLRequest(url: url))
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Menu content

struct MenuContentView: View {
    @EnvironmentObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Service.allCases) { service in
                ServiceSection(service: service)
                    .environmentObject(monitor)
                if service != Service.allCases.last {
                    Divider()
                }
            }

            Divider()

            HStack {
                Button {
                    monitor.refreshAll()
                } label: {
                    Label("Refresh all", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Settings…") { openSettings() }
                    .buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 420)
    }

    private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

struct ServiceSection: View {
    let service: Service
    @EnvironmentObject var monitor: UsageMonitor

    var state: ServiceState { monitor.states[service] ?? ServiceState() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(service.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if case .ok(_, let pct) = state.status, let pct = pct {
                    Text("\(pct)%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(pct >= 80 ? .red : (pct >= 50 ? .orange : .primary))
                }
                Spacer()
                if let updated = state.lastUpdated {
                    Text(Self.relativeFormatter.localizedString(for: updated, relativeTo: Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            statusView

            HStack(spacing: 8) {
                Button("Refresh") { monitor.refreshNow(service) }
                    .buttonStyle(.borderless)
                Button("Open Login Window") { monitor.showLogin(for: service) }
                    .buttonStyle(.borderless)
                Button("Logout") { monitor.logout(service) }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.status {
        case .unknown:
            Text("No data yet.").foregroundStyle(.secondary).font(.system(size: 12))
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary).font(.system(size: 12))
            }
        case .needsLogin:
            Text("Not logged in. Click \"Open Login Window\".")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
        case .error(let msg):
            Text("Error: \(msg)")
                .foregroundStyle(.red)
                .font(.system(size: 11))
                .lineLimit(3)
        case .ok(let text, _):
            ScrollView {
                Text(text.isEmpty ? "(no usage info found)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var monitor: UsageMonitor

    var body: some View {
        Form {
            Section("Refresh") {
                Stepper(value: Binding(
                    get: { monitor.settings.refreshSeconds },
                    set: { monitor.settings.refreshSeconds = max(30, $0) }
                ), in: 30...3600, step: 30) {
                    Text("Base interval: \(monitor.settings.refreshSeconds) s "
                         + "(\(String(format: "%.1f", Double(monitor.settings.refreshSeconds)/60.0)) min)")
                }

                Stepper(value: Binding(
                    get: { monitor.settings.jitterSeconds },
                    set: { monitor.settings.jitterSeconds = max(0, $0) }
                ), in: 0...300, step: 5) {
                    Text("Random jitter: ±\(monitor.settings.jitterSeconds) s")
                }

                Text("Next refresh fires somewhere in [\(max(15, monitor.settings.refreshSeconds - monitor.settings.jitterSeconds)), \(monitor.settings.refreshSeconds + monitor.settings.jitterSeconds)] seconds after the previous one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show percentages next to icon",
                       isOn: Binding(
                        get: { monitor.settings.showLabelInMenuBar },
                        set: { monitor.settings.showLabelInMenuBar = $0 }
                       ))
            }

            Section("Accounts") {
                ForEach(Service.allCases) { service in
                    HStack {
                        Text(service.displayName)
                        Spacer()
                        Button("Open Login Window") { monitor.showLogin(for: service) }
                        Button("Logout") { monitor.logout(service) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
