import AppKit
import SwiftUI

/// Opens the first-run guide in its own window.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = WelcomeGuide(close: { close() })
            .environmentObject(model.prefs)
            .environmentObject(model.store)
            .environmentObject(model.monitor)
            .environmentObject(model.broadcaster)
            .environmentObject(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Icecast Control"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    static func close() {
        window?.close()
        window = nil
    }
}

private enum Step: Int, CaseIterable {
    case welcome, server, internet, audio, finish

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .server: return "Server"
        case .internet: return "Internet"
        case .audio: return "Audio"
        case .finish: return "Finish"
        }
    }
}

struct WelcomeGuide: View {
    let close: () -> Void

    @EnvironmentObject private var prefs: AppPreferences
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var broadcaster: Broadcaster

    @State private var step: Step = .welcome
    @State private var existing: [ExistingIcecast] = []
    @State private var scanning = true
    /// nil = create a new server; otherwise the config path of an existing one.
    @State private var useExisting: String?
    @State private var server = ServerSetup.NewServer()
    @State private var showPasswords = false
    @State private var lookingUpIP = false
    @State private var problem: String?
    @State private var openAtLogin = true
    @State private var startServerAtLaunch = true
    /// Ignores repeated presses (e.g. holding Return) so each press moves exactly one step.
    @State private var lastStepChange = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 34)
                .padding(.bottom, 18)
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .server: serverStep
                    case .internet: internetStep
                    case .audio: audioStep
                    case .finish: finishStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            navigation
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(width: 600, height: 560)
        .task { await scan() }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        if s.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(s.rawValue + 1)").font(.caption2.bold())
                                .foregroundStyle(s.rawValue <= step.rawValue ? .white : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(s == step ? .primary : .secondary)
                }
                if s != Step.allCases.last {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 18, height: 1)
                }
            }
        }
    }

    private var navigation: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if step != .welcome {
                Button("Back") {
                    guard Date().timeIntervalSince(lastStepChange) > 0.3 else { return }
                    move(-1)
                }
            }
            Button(step == .finish ? "Start Using Icecast Control" : "Continue") { next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .server && scanning)
        }
    }

    private func move(_ delta: Int) {
        problem = nil
        if let s = Step(rawValue: step.rawValue + delta) {
            lastStepChange = Date()
            step = s
        }
    }

    private func next() {
        guard Date().timeIntervalSince(lastStepChange) > 0.6 else { return }
        problem = nil
        switch step {
        case .server:
            guard applyServerChoice() else { return }
        case .finish:
            finish()
            return
        default:
            break
        }
        move(1)
    }

    // MARK: 1. Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your own internet radio stream").font(.title2.bold())
                    Text("Icecast Control runs a stream server on this Mac and sends your audio to it.")
                        .foregroundStyle(.secondary)
                }
            }
            feature("server.rack", "Built-in server", "Icecast is included. Nothing else to install.")
            feature("waveform", "Any audio", "Stream everything this Mac plays, an audio interface or microphone, or OBS.")
            feature("arrow.triangle.2.circlepath", "Stays on air", "Reconnects by itself after hiccups and restarts.")
            feature("menubar.rectangle", "Lives in the menu bar", "Status at a glance: green is on air, orange is ready, red needs attention.")
            Text("This takes about two minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2. Server

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up your stream server").font(.title2.bold())
            if scanning {
                HStack { ProgressView().controlSize(.small); Text("Looking for an existing Icecast server…") }
            } else if !existing.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Icecast is already set up on this Mac. Do you want to use it, or make a new one?")
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(existing) { item in
                        choiceRow(selected: useExisting == item.configPath,
                                  title: "Use the existing server" + (item.isRunning ? " (running now)" : ""),
                                  detail: "\(item.summary)\n\(item.configPath)") {
                            useExisting = item.configPath
                        }
                    }
                    choiceRow(selected: useExisting == nil,
                              title: "Make a new server",
                              detail: "Separate from the existing one, managed by this app.") {
                        useExisting = nil
                    }
                }
            }
            if !scanning && useExisting == nil {
                newServerForm
            }
        }
    }

    private func choiceRow(selected: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newServerForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("Stream name", hint: "Shown in listeners' players.") {
                TextField("My Stream", text: $server.streamName)
            }
            labeled("Public address", hint: "How listeners reach you: a free domain from DuckDNS or No-IP is best (your home IP can change). You can change this later.") {
                HStack {
                    TextField("radio.example.com", text: $server.hostname)
                    Button(lookingUpIP ? "Looking up…" : "Use My Public IP") {
                        lookingUpIP = true
                        Task {
                            if let ip = await ServerSetup.publicIPAddress() { server.hostname = ip }
                            else { problem = "Couldn't look up your public IP. Check the internet connection." }
                            lookingUpIP = false
                        }
                    }
                    .disabled(lookingUpIP)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                labeled("Port", hint: nil) {
                    TextField("8000", text: $server.port).frame(width: 90)
                }
                labeled("Stream path", hint: nil) {
                    TextField("/stream.mp3", text: $server.mount).frame(width: 160)
                }
            }
            DisclosureGroup("Passwords (created for you)", isExpanded: $showPasswords) {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Source", value: server.sourcePassword, copyable: true)
                    InfoRow(label: "Admin (user: admin)", value: server.adminPassword, copyable: true)
                    Text("You don't need to remember these; they're in the Settings tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private func labeled<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            content().textFieldStyle(.roundedBorder)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scan() async {
        scanning = true
        existing = await ServerSetup.findExisting()
        // Default to the existing server if there is one; otherwise a new one.
        useExisting = existing.first?.configPath
        // Avoid a port that an existing server already uses.
        let usedPorts = existing.compactMap { item in
            item.summary.split(separator: "·").first.flatMap { Int($0.replacingOccurrences(of: "Port", with: "").trimmingCharacters(in: .whitespaces)) }
        }
        if usedPorts.contains(8000) { server.port = "8010" }
        scanning = false
    }

    private func applyServerChoice() -> Bool {
        if let path = useExisting {
            let item = existing.first { $0.configPath == path }
            prefs.configPath = path
            if let program = item?.programPath ?? ServerSetup.bundledIcecast { prefs.icecastPath = program }
            store.load(path: path)
            if let error = store.loadError { problem = error; return false }
            return true
        }
        var s = server
        s.hostname = s.hostname.trimmingCharacters(in: .whitespaces)
        s.mount = s.mount.trimmingCharacters(in: .whitespaces)
        if s.streamName.trimmingCharacters(in: .whitespaces).isEmpty { problem = "Give your stream a name."; return false }
        guard let port = Int(s.port), (1024...65535).contains(port) else { problem = "Port must be a number from 1024 to 65535."; return false }
        if !s.mount.hasPrefix("/") { s.mount = "/" + s.mount }
        if s.mount.count < 2 || s.mount.contains(" ") { problem = "Stream path should look like /stream.mp3."; return false }
        if s.hostname.contains("/") || s.hostname.contains(" ") { problem = "Public address should be just a name or IP, like radio.example.com."; return false }
        server = s
        do {
            try ServerSetup.createManagedConfig(s)
        } catch {
            problem = "Couldn't create the server settings: \(error.localizedDescription)"
            return false
        }
        prefs.configPath = ServerSetup.managedConfigURL.path
        if let bundled = ServerSetup.bundledIcecast { prefs.icecastPath = bundled }
        prefs.streamName = s.streamName
        store.load(path: prefs.configPath)
        return store.loadError == nil
    }

    // MARK: 3. Internet

    private var internetStep: some View {
        let s = store.saved
        let local = ServerSetup.localIPAddress() ?? "this Mac's IP"
        return VStack(alignment: .leading, spacing: 16) {
            Text("Let listeners reach you").font(.title2.bold())

            HStack(spacing: 12) {
                StatusLight(phase: monitor.phase).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.phase.title).font(.headline)
                    Text(monitor.phase.isUp ? "Your server is running." : "Start the server to test it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !monitor.phase.isUp {
                    Button("Start Server") { Task { await monitor.start() } }
                        .disabled(monitor.phase.isBusy)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 8) {
                Text("On your home network").font(.headline)
                InfoRow(label: "Listen link", value: "http://\(local):\(s.port)\(s.mountName)", copyable: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("From the internet").font(.headline)
                Text("Your router needs to pass listeners through to this Mac (\"port forwarding\"). Open your router's settings page, find Port Forwarding (sometimes called Virtual Server or NAT), and add:")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    InfoRow(label: "Port (TCP)", value: s.port, copyable: true)
                    InfoRow(label: "Forward to", value: local, copyable: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                HStack(spacing: 8) {
                    Button("Test From the Internet") { Task { await monitor.checkPublicAddress() } }
                        .disabled(!monitor.phase.isUp || s.hostname == "localhost" || monitor.publicCheck == .checking)
                    switch monitor.publicCheck {
                    case .checking: ProgressView().controlSize(.small)
                    case .reachable: Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unreachable: Label("Not reachable yet", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                    case .idle: EmptyView()
                    }
                }
                Text(s.hostname == "localhost"
                     ? "Add a public address in Settings later to test this."
                     : "Some routers can't test their own public address from inside. If it says not reachable but you've set up forwarding, try the listen link from a phone using mobile data. If macOS asks whether \"icecast\" may accept incoming connections, choose Allow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can skip this and do it later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 4. Audio

    private var audioStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you want to stream?").font(.title2.bold())
            VStack(spacing: 8) {
                choiceRow(selected: prefs.inputSource == AudioInput.systemAudioID,
                          title: "Everything this Mac plays",
                          detail: "Music apps, browsers, DAWs… Sound keeps playing normally. macOS will ask permission the first time.") {
                    broadcaster.selectInput(AudioInput.systemAudioID)
                }
                choiceRow(selected: prefs.inputSource == AudioInput.obsID,
                          title: "OBS",
                          detail: "Sends OBS's stream audio, so this matches your video stream. Needs the free OBS plugin (separate download).") {
                    broadcaster.selectInput(AudioInput.obsID)
                }
                choiceRow(selected: !AudioInput(id: prefs.inputSource, name: "", channels: 2).isVirtual,
                          title: "An audio interface or microphone",
                          detail: "Pick the device below.") {
                    if let first = broadcaster.inputs.first(where: { !$0.isVirtual }) { broadcaster.selectInput(first.id) }
                }
            }
            if !AudioInput(id: prefs.inputSource, name: "", channels: 2).isVirtual {
                Picker("Device", selection: Binding(get: { prefs.inputSource }, set: { broadcaster.selectInput($0) })) {
                    ForEach(broadcaster.inputs.filter { !$0.isVirtual }) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 360)
            }
            if prefs.inputSource == AudioInput.obsID {
                Link("Get the OBS plugin →", destination: Links.downloads)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Play something to check the level:").font(.caption).foregroundStyle(.secondary)
                    LevelMeter(levels: broadcaster.levels, active: broadcaster.capturing)
                        .frame(maxWidth: 360)
                    if let error = broadcaster.captureError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .onAppear { broadcaster.setPreview(true) }
        .onDisappear { broadcaster.setPreview(false) }
    }

    // MARK: 5. Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're all set").font(.title2.bold())
            Toggle("Open Icecast Control when I log in", isOn: $openAtLogin)
            Toggle("Start the server when the app opens", isOn: $startServerAtLaunch)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(.green).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find it in the menu bar").font(.headline)
                    Text("Click the antenna icon at the top of the screen, then press **Go Live**.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Can't see it? A full menu bar can hide icons behind the camera notch. Hold ⌘ and drag other icons out of the menu bar to make room.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.title2).foregroundStyle(Color.accentColor).frame(width: 28)
                Text("You can open this guide again from the panel's footer.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        prefs.setupComplete = true
        prefs.autoStartServer = startServerAtLaunch
        if prefs.launchAtLogin != openAtLogin { prefs.launchAtLogin = openAtLogin }
        if !monitor.phase.isUp { Task { await monitor.start() } }
        close()
    }
}
