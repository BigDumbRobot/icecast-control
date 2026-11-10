import AppKit
import SwiftUI

enum ServerPhase: Equatable {
    case checking
    case stopped
    case starting
    case stopping
    /// Server is up but LadioCast isn't sending audio to the mount yet.
    case online
    /// Server is up and LadioCast is connected: on air.
    case live
    /// The Icecast process exists but doesn't answer on its port.
    case unresponsive
    case failed(String)

    var isUp: Bool { self == .online || self == .live || self == .unresponsive }
    var isBusy: Bool { self == .starting || self == .stopping || self == .checking }

    var title: String {
        switch self {
        case .checking: return "Checking…"
        case .stopped: return "Server Stopped"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .online: return "Server Ready"
        case .live: return "On Air"
        case .unresponsive: return "Not Responding"
        case .failed: return "Couldn't Start"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .live: return .systemGreen
        case .online: return .systemOrange
        case .unresponsive, .failed: return .systemRed
        case .starting, .stopping, .checking: return .systemBlue
        case .stopped: return .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum PublicCheck: Equatable {
    case idle
    case checking
    case reachable(Date)
    case unreachable(String)
}

/// Watches the Icecast server and starts/stops it.
@MainActor
final class ServerMonitor: ObservableObject {
    @Published private(set) var phase: ServerPhase = .checking
    @Published private(set) var pids: [Int32] = []
    @Published private(set) var snapshot: StatusSnapshot?
    /// Something answers on the port, but it wasn't started with our settings file.
    @Published private(set) var externalInstance = false
    @Published private(set) var publicCheck: PublicCheck = .idle

    private let prefs: AppPreferences
    private let store: ConfigStore
    private var timer: Timer?
    private var refreshing = false
    private var operationInProgress = false
    private var httpFailures = 0

    init(prefs: AppPreferences, store: ConfigStore) {
        self.prefs = prefs
        self.store = store
    }

    var settings: IcecastSettings { store.saved }
    var canStop: Bool { !pids.isEmpty }

    var statusDetail: String {
        switch phase {
        case .checking: return "Looking for the Icecast server"
        case .stopped: return "Press Start to put the server online"
        case .starting: return "Launching Icecast"
        case .stopping: return "Shutting down"
        case .online: return "Server running · no audio on \(settings.mountName) yet"
        case .live:
            let n = snapshot?.source?.listeners ?? 0
            return "Audio connected · \(n) listener\(n == 1 ? "" : "s")"
        case .unresponsive: return "Icecast is running but not answering on port \(settings.port)"
        case .failed(let message): return message
        }
    }

    var menuBarText: String? {
        switch phase {
        case .live: return "LIVE \(snapshot?.source?.listeners ?? 0)"
        case .online: return "READY"
        case .stopped: return "OFF"
        case .unresponsive, .failed: return "ERROR"
        case .starting, .stopping, .checking: return "…"
        }
    }

    func begin() {
        if prefs.notifyOnChanges { Notifier.requestPermission() }
        Task {
            await refresh()
            if prefs.setupComplete, prefs.autoStartServer, phase == .stopped { await start() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: - Monitoring

    func refresh() async {
        guard !refreshing, !operationInProgress else { return }
        refreshing = true
        defer { refreshing = false }

        store.reloadIfChangedOnDisk()
        let s = settings
        let found = await ProcessFinder.icecastPIDs(configPath: prefs.configPath)
        let snap = await StatusClient.fetch(port: s.portNumber, mount: s.mountName)
        guard !operationInProgress else { return }

        pids = found
        snapshot = snap
        externalInstance = found.isEmpty && snap != nil

        let next: ServerPhase
        if let snap {
            httpFailures = 0
            next = snap.source != nil ? .live : .online
        } else if found.isEmpty {
            httpFailures = 0
            if case .failed = phase { next = phase } else { next = .stopped }
        } else {
            // Allow one missed check before calling it unresponsive.
            httpFailures += 1
            next = httpFailures >= 2 ? .unresponsive : (phase.isUp ? phase : .online)
        }
        transition(to: next)
    }

    private func transition(to next: ServerPhase, userInitiated: Bool = false) {
        let old = phase
        guard old != next else { return }
        phase = next
        guard prefs.notifyOnChanges, !userInitiated, old != .checking else { return }
        let mount = settings.mountName
        switch (old, next) {
        case (_, .live):
            Notifier.post("On Air", "Audio is streaming to \(mount).")
        case (.live, .online):
            Notifier.post("Stream Went Off Air", "Audio stopped arriving at \(mount). The server is still running.")
        case (let previous, .stopped) where previous.isUp:
            Notifier.post("Icecast Stopped", "The Icecast server stopped unexpectedly.")
        case (_, .unresponsive):
            Notifier.post("Icecast Not Responding", "The server is running but not answering on port \(settings.port).")
        default:
            break
        }
    }

    // MARK: - Start / stop

    func start() async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        phase = .starting
        publicCheck = .idle

        let fm = FileManager.default
        let configPath = prefs.configPath
        let icecast = prefs.icecastPath
        guard fm.isExecutableFile(atPath: icecast) else {
            phase = .failed("Icecast program not found at \(icecast). Check Settings → This App.")
            return
        }
        guard fm.fileExists(atPath: configPath) else {
            phase = .failed("Settings file not found at \(configPath).")
            return
        }
        let s = settings
        if let snap = await StatusClient.fetch(port: s.portNumber, mount: s.mountName) {
            // Already answering: nothing to start.
            snapshot = snap
            operationInProgress = false
            await refresh()
            return
        }
        // Icecast refuses to start if its log folder is missing.
        if !s.logDir.isEmpty {
            try? fm.createDirectory(atPath: s.logDir, withIntermediateDirectories: true)
        }

        let launchLog = Self.appLogDirectory.appendingPathComponent("icecast-launch.log")
        let errorLogSizeBefore = Self.fileSize(s.errorLogURL)
        do {
            try Shell.launch(icecast, ["-b", "-c", configPath],
                             workingDirectory: URL(fileURLWithPath: configPath).deletingLastPathComponent(),
                             logFile: launchLog)
        } catch {
            phase = .failed("Couldn't launch Icecast: \(error.localizedDescription)")
            return
        }

        // Wait up to ~10 seconds for it to come up.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let found = await ProcessFinder.icecastPIDs(configPath: configPath)
            if !found.isEmpty, let snap = await StatusClient.fetch(port: s.portNumber, mount: s.mountName) {
                pids = found
                snapshot = snap
                externalInstance = false
                httpFailures = 0
                transition(to: snap.source != nil ? .live : .online, userInitiated: true)
                return
            }
        }
        phase = .failed(Self.diagnoseStartFailure(launchLog: launchLog,
                                                  errorLog: s.errorLogURL,
                                                  errorLogOffset: errorLogSizeBefore,
                                                  port: s.port))
    }

    func stop() async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        phase = .stopping

        let targets = await ProcessFinder.icecastPIDs(configPath: prefs.configPath)
        if targets.isEmpty {
            operationInProgress = false
            await refresh()
            return
        }
        for pid in targets where kill(pid, SIGTERM) != 0 && errno == EPERM {
            phase = .failed("No permission to stop Icecast (it was started by another user or with sudo). Stop it from Terminal.")
            return
        }
        // Give it up to 6 seconds to shut down cleanly, then force it.
        for _ in 0..<30 {
            if !targets.contains(where: ProcessFinder.isAlive) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        for pid in targets where ProcessFinder.isAlive(pid) { kill(pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 300_000_000)

        pids = []
        snapshot = nil
        httpFailures = 0
        transition(to: .stopped, userInitiated: true)
    }

    func restart() async {
        await stop()
        if phase == .stopped { await start() }
    }

    private var lastPublicCheck: Date?

    /// Re-checks the public address when the panel opens, at most once a minute.
    func checkPublicAddressIfStale() {
        guard phase.isUp, publicCheck != .checking else { return }
        if let last = lastPublicCheck, Date().timeIntervalSince(last) < 60 { return }
        Task { await checkPublicAddress() }
    }

    func checkPublicAddress() async {
        lastPublicCheck = Date()
        publicCheck = .checking
        switch await StatusClient.checkPublic(host: settings.hostname, port: settings.portNumber) {
        case .success: publicCheck = .reachable(Date())
        case .failure(let error): publicCheck = .unreachable(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    static var appLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Icecast Control")
    }

    private static func fileSize(_ url: URL?) -> UInt64 {
        guard let url else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
    }

    /// Turns Icecast's output into a short, readable reason.
    private static func diagnoseStartFailure(launchLog: URL, errorLog: URL?, errorLogOffset: UInt64, port: String) -> String {
        var text = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
        if let errorLog, let handle = try? FileHandle(forReadingFrom: errorLog) {
            try? handle.seek(toOffset: errorLogOffset)
            text += "\n" + String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            try? handle.close()
        }
        let lower = text.lowercased()
        if lower.contains("could not create listener socket") || lower.contains("address already in use") {
            return "Port \(port) is already in use by another program."
        }
        if lower.contains("xml config parsing error") || lower.contains("parse error") {
            return "The settings file has an error. Check it, or restore icecast.xml.bak."
        }
        if lower.contains("permission denied") {
            return "Icecast doesn't have permission to open a file it needs (check the log folder)."
        }
        let errorLine = text.split(separator: "\n").last { $0.contains("EROR") || $0.lowercased().contains("error") }
        if let errorLine {
            return "Icecast didn't start: " + errorLine.trimmingCharacters(in: .whitespaces)
        }
        return "Icecast didn't start within 10 seconds. Open the error log for details."
    }
}
