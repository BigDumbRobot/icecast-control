import Foundation
import ServiceManagement
import UserNotifications

/// Settings for the app itself (not Icecast), stored in UserDefaults.
@MainActor
final class AppPreferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var configPath: String { didSet { defaults.set(configPath, forKey: "configPath") } }
    @Published var icecastPath: String { didSet { defaults.set(icecastPath, forKey: "icecastPath") } }
    @Published var autoStartServer: Bool { didSet { defaults.set(autoStartServer, forKey: "autoStartServer") } }
    @Published var notifyOnChanges: Bool {
        didSet {
            defaults.set(notifyOnChanges, forKey: "notifyOnChanges")
            if notifyOnChanges { Notifier.requestPermission() }
        }
    }
    @Published var showTextInMenuBar: Bool { didSet { defaults.set(showTextInMenuBar, forKey: "showTextInMenuBar") } }
    @Published private(set) var loginItemError: String?

    // Broadcasting
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    /// "system" for system audio, otherwise a Core Audio device UID.
    @Published var inputSource: String { didSet { defaults.set(inputSource, forKey: "inputSource") } }
    @Published var inputSourceName: String { didSet { defaults.set(inputSourceName, forKey: "inputSourceName") } }
    /// 0 = channels 1–2, 2 = channels 3–4, …
    @Published var inputChannelOffset: Int { didSet { defaults.set(inputChannelOffset, forKey: "inputChannelOffset") } }
    @Published var gain: Double { didSet { defaults.set(gain, forKey: "gain") } }
    @Published var bitrate: Int { didSet { defaults.set(bitrate, forKey: "bitrate") } }
    @Published var streamName: String { didSet { defaults.set(streamName, forKey: "streamName") } }
    @Published var streamGenre: String { didSet { defaults.set(streamGenre, forKey: "streamGenre") } }
    @Published var autoBroadcast: Bool { didSet { defaults.set(autoBroadcast, forKey: "autoBroadcast") } }
    /// The welcome guide has been completed.
    @Published var setupComplete: Bool { didSet { defaults.set(setupComplete, forKey: "setupComplete") } }

    static let bitrates = [32, 48, 64, 96, 128, 160, 192, 256, 320]

    init() {
        ffmpegPath = Self.program(stored: defaults.string(forKey: "ffmpegPath"), bundled: ServerSetup.bundledFFmpeg,
                                  fallbacks: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        inputSource = defaults.string(forKey: "inputSource") ?? AudioInput.systemAudioID
        inputSourceName = defaults.string(forKey: "inputSourceName") ?? AudioInput.systemAudio.name
        inputChannelOffset = defaults.integer(forKey: "inputChannelOffset")
        gain = defaults.object(forKey: "gain") as? Double ?? 1.0
        // 128 kbps: close to YouTube's audio quality.
        bitrate = defaults.object(forKey: "bitrate") as? Int ?? 128
        streamName = defaults.string(forKey: "streamName") ?? "My Stream"
        streamGenre = defaults.string(forKey: "streamGenre") ?? "Various"
        autoBroadcast = defaults.object(forKey: "autoBroadcast") as? Bool ?? false
        setupComplete = defaults.bool(forKey: "setupComplete")

        configPath = defaults.string(forKey: "configPath") ?? ServerSetup.managedConfigURL.path
        icecastPath = Self.program(stored: defaults.string(forKey: "icecastPath"), bundled: ServerSetup.bundledIcecast,
                                   fallbacks: ["/opt/homebrew/bin/icecast", "/usr/local/bin/icecast", "/opt/local/bin/icecast"])
        autoStartServer = defaults.object(forKey: "autoStartServer") as? Bool ?? false
        notifyOnChanges = defaults.object(forKey: "notifyOnChanges") as? Bool ?? true
        showTextInMenuBar = defaults.object(forKey: "showTextInMenuBar") as? Bool ?? false
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = "Couldn't change login item: \(error.localizedDescription)"
            }
        }
    }

    /// Picks a program path: the user's choice if it still exists, otherwise the copy inside the app
    /// (which also follows the app if it's moved), otherwise a Homebrew install.
    private static func program(stored: String?, bundled: String?, fallbacks: [String]) -> String {
        let fm = FileManager.default
        if let stored, fm.isExecutableFile(atPath: stored), !stored.contains(".app/Contents/MacOS/") { return stored }
        if let bundled { return bundled }
        return fallbacks.first { fm.isExecutableFile(atPath: $0) } ?? fallbacks[0]
    }
}

enum Notifier {
    /// Notifications only work when running as a real .app bundle.
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
