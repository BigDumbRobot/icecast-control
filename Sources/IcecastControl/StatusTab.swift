import AppKit
import SwiftUI

struct StatusTab: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var broadcaster: Broadcaster
    @State private var confirmingStop: PendingStop?
    @State private var showExternalSource = false

    enum PendingStop { case stop, restart }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls

                if let pending = confirmingStop {
                    confirmation(for: pending)
                }
                if monitor.externalInstance {
                    Banner(text: "Icecast is running, but it was started with a different settings file, so it can't be stopped from here.")
                }

                BroadcastCard()
                streamCard
                serverCard
                ladioCastCard
            }
            .padding(16)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if monitor.phase.isUp || monitor.phase == .stopping {
                Button {
                    request(.stop)
                } label: {
                    Label("Stop Server", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(!monitor.canStop)

                Button {
                    request(.restart)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .disabled(!monitor.canStop)
            } else {
                Button {
                    Task { await monitor.start() }
                } label: {
                    Label(monitor.phase == .starting ? "Starting…" : "Start Server", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .controlSize(.large)
        .disabled(monitor.phase.isBusy)
    }

    private func request(_ action: PendingStop) {
        // Ask first if this would cut off a live broadcast.
        if monitor.phase == .live {
            confirmingStop = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingStop) {
        confirmingStop = nil
        Task {
            switch action {
            case .stop: await monitor.stop()
            case .restart: await monitor.restart()
            }
        }
    }

    private func confirmation(for action: PendingStop) -> some View {
        let listeners = monitor.snapshot?.source?.listeners ?? 0
        let verb = action == .stop ? "Stopping" : "Restarting"
        let after = broadcaster.wantsLive
            ? "The broadcast will reconnect by itself once the server is back."
            : "An external source like LadioCast will need to reconnect."
        return VStack(alignment: .leading, spacing: 10) {
            Banner(text: "You're on air with \(listeners) listener\(listeners == 1 ? "" : "s"). \(verb) the server will cut off the broadcast. \(after)")
            HStack {
                Spacer()
                Button("Cancel") { confirmingStop = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action == .stop ? "Stop Anyway" : "Restart Anyway") { perform(action) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    // MARK: Cards

    private var streamCard: some View {
        Card(title: "Stream") {
            if let source = monitor.snapshot?.source {
                InfoRow(label: "Listeners", value: source.peakListeners.map { "\(source.listeners)  (peak \($0))" } ?? "\(source.listeners)")
                if let started = source.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        InfoRow(label: "On air for", value: Format.duration(since: started, now: context.date))
                    }
                }
                if let bitrate = source.bitrate {
                    InfoRow(label: "Bitrate", value: "\(bitrate) kbps")
                }
                if let title = source.title {
                    InfoRow(label: "Now playing", value: title)
                }
            } else {
                Text(monitor.phase.isUp
                     ? "No audio coming in yet. Press Go Live above, or connect an external source like LadioCast (details at the bottom)."
                     : "The stream is offline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 6) {
                Text("Listen link").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(monitor.settings.streamURL)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                CopyButton(text: monitor.settings.streamURL)
                Button {
                    if let url = URL(string: monitor.settings.streamURL) { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help("Open the stream in your browser")
            }
            .font(.callout)
        }
    }

    private var ladioCastCard: some View {
        let s = monitor.settings
        return DisclosureGroup(isExpanded: $showExternalSource) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Only needed if you send audio from another app such as LadioCast instead of Go Live. After a server restart, reconnect it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InfoRow(label: "Host", value: "127.0.0.1 (or \(s.hostname))", copyable: false)
                InfoRow(label: "Port", value: s.port, copyable: true)
                InfoRow(label: "Mount", value: s.mountName, copyable: true)
                InfoRow(label: "User", value: "source", copyable: true)
                InfoRow(label: "Password", value: s.sourcePassword, copyable: true, secret: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.top, 6)
        } label: {
            Text("EXTERNAL SOURCE (LADIOCAST)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var serverCard: some View {
        Card(title: "Server") {
            if let start = monitor.snapshot?.serverStart, monitor.phase.isUp {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    InfoRow(label: "Running for", value: Format.duration(since: start, now: context.date))
                }
            }
            if let version = monitor.snapshot?.serverID {
                InfoRow(label: "Version", value: version)
            }
            HStack(spacing: 6) {
                Text("Reachable online").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                publicCheckResult
                if monitor.settings.hasPublicAddress {
                    Button("Test") { Task { await monitor.checkPublicAddress() } }
                        .controlSize(.small)
                        .disabled(!monitor.phase.isUp || monitor.publicCheck == .checking)
                        .help("Checks \(monitor.settings.hostname):\(monitor.settings.port) from this Mac. Some routers can't loop back to their own public address, so a failure here doesn't always mean listeners can't connect.")
                }
            }
            .font(.callout)
            switch monitor.publicCheck {
            case .unreachable(let reason):
                Text("\(monitor.settings.hostname):\(monitor.settings.port) didn't answer: \(reason) Check that the router forwards port \(monitor.settings.port) to this Mac. Some routers can't reach their own public address from inside, so it may still work for listeners.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .reachable(let date):
                Text("Checked \(date.formatted(date: .omitted, time: .shortened)) at \(monitor.settings.hostname):\(monitor.settings.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .onAppear { if monitor.settings.hasPublicAddress { monitor.checkPublicAddressIfStale() } }
    }

    @ViewBuilder
    private var publicCheckResult: some View {
        if !monitor.settings.hasPublicAddress {
            Text("Add a public address in Settings").foregroundStyle(.secondary)
        } else {
            publicCheckState
        }
    }

    @ViewBuilder
    private var publicCheckState: some View {
        switch monitor.publicCheck {
        case .idle:
            Text("Not tested").foregroundStyle(.tertiary)
        case .checking:
            ProgressView().controlSize(.small)
        case .reachable:
            Label("Yes", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unreachable(let reason):
            Label("No", systemImage: "xmark.circle.fill").foregroundStyle(.red).help(reason)
        }
    }
}
