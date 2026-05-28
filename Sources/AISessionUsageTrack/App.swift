import SwiftUI
import AppKit

@main
struct AISessionUsageTrackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)

        // No SwiftUI `Settings` scene: showSettingsWindow: is unreliable for
        // accessory (LSUIElement) apps. SettingsView is opened by
        // UsageMonitor.showSettings() in its own NSWindow instead.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: Info.plist already sets LSUIElement=true.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The text/icon that lives in the macOS menubar.
///
/// MenuBarExtra strips SwiftUI `Image` views from its label (both inside
/// HStack and inside concatenated `Text(Image(...))`). Unicode glyphs are
/// just text, so the system can't drop them and per-segment colors still
/// apply. The dropdown panel keeps SF Symbols since it renders Image fine.
struct MenuBarLabel: View {
    @EnvironmentObject var monitor: UsageMonitor

    // Glyphs chosen to resemble each brand's actual mark.
    private static let geminiGlyph = "✦"   // U+2726 — 4-pointed star, like Google's sparkle
    private static let claudeGlyph = "✱"   // U+2731 — heavy asterisk burst

    var body: some View {
        if monitor.settings.showLabelInMenuBar {
            let g = monitor.states[.gemini] ?? ServiceState()
            let c = monitor.states[.claude] ?? ServiceState()

            (
                Text("\(Self.geminiGlyph) ")
                    .foregroundColor(Service.gemini.brandColor)
                + Text("\(g.shortLabel)  ")
                    .foregroundColor(g.severityColor)
                + Text("\(Self.claudeGlyph) ")
                    .foregroundColor(Service.claude.brandColor)
                + Text(c.shortLabel)
                    .foregroundColor(c.severityColor)
            )
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }
}
