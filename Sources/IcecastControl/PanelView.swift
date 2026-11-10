import AppKit
import SwiftUI

enum PanelTab: Hashable {
    case status, settings
}

/// The panel that drops down from the menu bar icon.
struct PanelView: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var broadcaster: Broadcaster
    @State private var tab: PanelTab = .status

    private var subtitle: String {
        if monitor.phase == .live, broadcaster.state.isLive {
            let n = monitor.snapshot?.source?.listeners ?? 0
            return "Broadcasting \(broadcaster.selectedInput.isSystemAudio ? "system audio" : broadcaster.selectedInput.name) · \(n) listener\(n == 1 ? "" : "s")"
        }
        return monitor.statusDetail
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                StatusLight(phase: monitor.phase)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.phase.title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            Picker("", selection: $tab) {
                Text("Status").tag(PanelTab.status)
                Text(store.isDirty ? "Settings •" : "Settings").tag(PanelTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .status: StatusTab()
                case .settings: SettingsTab()
                }
            }
            .frame(height: 500)

            Divider()
            FooterBar()
        }
        .frame(width: 370)
        .onAppear { Task { await monitor.refresh() } }
    }
}

struct FooterBar: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if let url = URL(string: "http://127.0.0.1:\(monitor.settings.port)/admin/") {
                    NSWorkspace.shared.open(url)
                }
            } label: { Label("Admin", systemImage: "globe") }
                .disabled(!monitor.phase.isUp)
                .help("Open Icecast's own admin page in your browser")

            Button {
                if let url = monitor.settings.errorLogURL { NSWorkspace.shared.open(url) }
            } label: { Label("Error Log", systemImage: "doc.text.magnifyingglass") }
                .disabled(monitor.settings.errorLogURL == nil)
                .help("Open Icecast's error log")

            Button { WelcomeWindow.show(model: model) } label: { Label("Guide", systemImage: "questionmark.circle") }
                .help("Open the setup guide")

            Spacer()

            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                .help("Quit Icecast Control (the server keeps running)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
