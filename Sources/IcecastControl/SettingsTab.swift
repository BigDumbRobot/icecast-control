import AppKit
import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var prefs: AppPreferences

    @State private var problems: [String] = []
    @State private var needsRestart = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let error = store.loadError {
                    Section {
                        Banner(text: error, tint: .red)
                    }
                }

                Section {
                    TextField("Host name", text: $store.draft.hostname)
                    TextField("Port", text: $store.draft.port)
                    TextField("Mount point", text: $store.draft.mountName)
                } header: {
                    Text("Stream address")
                } footer: {
                    Text("Listeners connect to http://host:port/mount. Your router must forward this port to this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    PasswordField(title: "Source password", text: $store.draft.sourcePassword)
                    TextField("Admin user", text: $store.draft.adminUser)
                    PasswordField(title: "Admin password", text: $store.draft.adminPassword)
                    PasswordField(title: "Relay password", text: $store.draft.relayPassword)
                } header: {
                    Text("Passwords")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The source password is what audio sources log in with. Go Live picks up changes automatically; an external app like LadioCast must be updated to match. Admin and relay passwords don't affect sources.")
                        if store.draft.hasPlaceholderPasswords {
                            Label("The admin or relay password is still a placeholder. Set your own before going public.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("MP3 quality", selection: $prefs.bitrate) {
                        ForEach(AppPreferences.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                    TextField("Stream name", text: $prefs.streamName)
                    TextField("Genre", text: $prefs.streamGenre)
                    Toggle("Go live automatically when app opens", isOn: $prefs.autoBroadcast)
                } header: {
                    Text("Broadcast")
                } footer: {
                    Text("128 kbps or more matches YouTube's audio quality. Each listener uses that much of your internet upload (e.g. 20 listeners at 128 kbps ≈ 2.6 Mbps). Audio is sent at its original level with a safety limiter at −1 dBFS. Changes apply the next time you go live.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Limits") {
                    TextField("Max listeners", text: $store.draft.maxListeners)
                    TextField("Max connections", text: $store.draft.maxClients)
                }

                Section("Server info") {
                    TextField("Location", text: $store.draft.location)
                    TextField("Admin contact", text: $store.draft.adminContact)
                }

                appSection
            }
            .formStyle(.grouped)

            if store.isDirty || !problems.isEmpty || needsRestart {
                Divider()
                saveBar
            }
        }
        .onChange(of: store.draft) { problems = [] }
    }

    // MARK: Save bar

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if store.isDirty {
                    Button("Revert") { store.revert() }
                    Spacer()
                    if monitor.phase.isUp && monitor.canStop {
                        Button("Save") { save(restart: false) }
                        Button("Save & Restart") { save(restart: true) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Save") { save(restart: false) }
                            .buttonStyle(.borderedProminent)
                    }
                } else if needsRestart {
                    Text("Saved. Restart the server to use the new settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") {
                        needsRestart = false
                        Task { await monitor.restart() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func save(restart: Bool) {
        do {
            try store.save()
            problems = []
            if restart {
                needsRestart = false
                Task { await monitor.restart() }
            } else {
                needsRestart = monitor.phase.isUp && monitor.canStop
            }
        } catch ConfigError.invalid(let list) {
            problems = list
        } catch {
            problems = [error.localizedDescription]
        }
    }

    // MARK: App preferences

    private var appSection: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            Toggle("Start server when app opens", isOn: $prefs.autoStartServer)
            Toggle("Notify when going on/off air", isOn: $prefs.notifyOnChanges)
            Toggle("Show status text in menu bar", isOn: $prefs.showTextInMenuBar)
            pathRow(title: "Settings file", path: prefs.configPath) {
                if let path = chooseFile(title: "Choose icecast.xml", startingAt: prefs.configPath) {
                    prefs.configPath = path
                    store.load(path: path)
                    Task { await monitor.refresh() }
                }
            }
            pathRow(title: "Icecast program", path: prefs.icecastPath) {
                if let path = chooseFile(title: "Choose the icecast program", startingAt: prefs.icecastPath) {
                    prefs.icecastPath = path
                }
            }
            pathRow(title: "ffmpeg program", path: prefs.ffmpegPath) {
                if let path = chooseFile(title: "Choose the ffmpeg program", startingAt: prefs.ffmpegPath) {
                    prefs.ffmpegPath = path
                }
            }
            if let error = prefs.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("This app")
        } footer: {
            Text("Settings are saved to the Icecast settings file. A backup of the previous version is kept next to it as .bak.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pathRow(title: String, path: String, choose: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? Color.secondary : Color.red)
                    .help(path)
                Button("Change…", action: choose).controlSize(.small)
            }
        }
    }
}
