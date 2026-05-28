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

        Settings {
            SettingsView()
                .environmentObject(monitor)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: Info.plist already sets LSUIElement=true.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The text/icon that lives in the macOS menubar.
struct MenuBarLabel: View {
    @EnvironmentObject var monitor: UsageMonitor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if monitor.settings.showLabelInMenuBar {
                let g = monitor.states[.gemini]?.shortLabel ?? "—"
                let c = monitor.states[.claude]?.shortLabel ?? "—"
                Text("G:\(g) C:\(c)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}
