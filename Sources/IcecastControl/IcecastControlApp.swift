import AppKit
import SwiftUI
import UserNotifications

@main
struct IcecastControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model.prefs)
                .environmentObject(model.store)
                .environmentObject(model.monitor)
                .environmentObject(model.broadcaster)
                .environmentObject(model)
        } label: {
            MenuBarLabel(monitor: model.monitor, prefs: model.prefs)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let prefs: AppPreferences
    let store: ConfigStore
    let monitor: ServerMonitor
    let broadcaster: Broadcaster

    init() {
        // Writing to an encoder that just quit must not crash the app.
        signal(SIGPIPE, SIG_IGN)
        prefs = AppPreferences()
        store = ConfigStore()
        // The bundled server's web pages live inside the app; follow it if it was moved.
        ServerSetup.refreshBundledPaths(configPath: prefs.configPath)
        store.load(path: prefs.configPath)
        monitor = ServerMonitor(prefs: prefs, store: store)
        broadcaster = Broadcaster(prefs: prefs, store: store, monitor: monitor)
        monitor.begin()
        broadcaster.begin()
        if !prefs.setupComplete {
            DispatchQueue.main.async { [self] in WelcomeWindow.show(model: self) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, also when run outside an .app bundle during development.
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    // Show notifications even while the panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// The icon in the menu bar: colour shows the state at a glance.
struct MenuBarLabel: View {
    @ObservedObject var monitor: ServerMonitor
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        let image = Self.icon(for: monitor.phase)
        if prefs.showTextInMenuBar, let text = monitor.menuBarText {
            HStack(spacing: 4) {
                Image(nsImage: image)
                Text(text)
            }
        } else {
            Image(nsImage: image)
        }
    }

    static func icon(for phase: ServerPhase) -> NSImage {
        let up = phase.isUp || phase == .starting
        let name = up ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if phase != .stopped {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [phase.nsColor]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: phase.title)?
            .withSymbolConfiguration(config) ?? NSImage()
        // Stopped uses the normal black/white menu bar style; other states are coloured.
        image.isTemplate = phase == .stopped
        return image
    }
}
