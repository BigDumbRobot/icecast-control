import AppKit
import SwiftUI

/// Input picker, level meter, volume and Go Live button.
struct BroadcastCard: View {
    @EnvironmentObject private var broadcaster: Broadcaster
    @EnvironmentObject private var prefs: AppPreferences
    @EnvironmentObject private var monitor: ServerMonitor

    var body: some View {
        Card(title: "Broadcast") {
            inputPicker
            if broadcaster.selectedInput.channels > 2 && !broadcaster.selectedInput.isVirtual {
                channelPicker
            }
            if broadcaster.selectedInput.isOBS {
                obsSection
            }
            LevelMeter(levels: broadcaster.levels, active: broadcaster.capturing)
            volumeSlider
            statusLine
            goLiveButton
        }
        .onAppear { broadcaster.setPreview(true) }
        .onDisappear { broadcaster.setPreview(false) }
    }

    private var inputPicker: some View {
        HStack(spacing: 6) {
            Text("Input").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker("Input", selection: Binding(
                get: { prefs.inputSource },
                set: { broadcaster.selectInput($0) }
            )) {
                Text(AudioInput.systemAudio.name).tag(AudioInput.systemAudioID)
                Text(AudioInput.obs.name).tag(AudioInput.obsID)
                Divider()
                ForEach(broadcaster.inputs.filter { !$0.isVirtual }) { input in
                    Text(input.name).tag(input.id)
                }
                if broadcaster.selectedInputMissing {
                    Text("\(prefs.inputSourceName) (not connected)").tag(prefs.inputSource)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 230)
            Button { broadcaster.refreshInputs() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh the list of inputs")
        }
        .font(.callout)
    }

    private var obsPluginInstalled: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/scripts/icecast-control-obs.lua").path)
    }

    private var obsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(broadcaster.obsConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(broadcaster.obsConnected ? "Receiving audio from OBS"
                     : obsPluginInstalled ? "Ready. Start streaming in OBS to go live."
                     : "Waiting for OBS")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !obsPluginInstalled && !broadcaster.obsConnected {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OBS needs the Icecast Control OBS plugin (a separate, one-time install).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Get the OBS plugin", destination: Links.downloads)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            Toggle("Go live and stop together with OBS", isOn: $prefs.followOBS)
                .font(.callout)
                .toggleStyle(.checkbox)
        }
    }

    private var channelPicker: some View {
        let count = broadcaster.selectedInput.channels
        return HStack {
            Text("Channels").foregroundStyle(.secondary)
            Spacer()
            Picker("Channels", selection: Binding(
                get: { prefs.inputChannelOffset },
                set: { broadcaster.selectInput(prefs.inputSource, channelOffset: $0) }
            )) {
                ForEach(Array(stride(from: 0, to: count - 1, by: 2)), id: \.self) { offset in
                    Text("\(offset + 1)–\(offset + 2)").tag(offset)
                }
            }
            .labelsHidden()
            .frame(width: 90)
        }
        .font(.callout)
    }

    private var volumeSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
            Slider(value: Binding(get: { prefs.gain }, set: { broadcaster.setGain($0) }), in: 0...2)
                .controlSize(.small)
            Text(gainText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .onTapGesture(count: 2) { broadcaster.setGain(1) }
                .help("Double-click to reset to 0 dB")
        }
    }

    private var gainText: String {
        prefs.gain <= 0.001 ? "Muted" : String(format: "%+.1f dB", 20 * log10(prefs.gain))
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = broadcaster.captureError, !broadcaster.capturing {
            note(error, color: .red)
        } else {
            switch broadcaster.state {
            case .off:
                if monitor.phase == .live && !broadcaster.isRunning {
                    note("Another source (e.g. LadioCast) is on air right now.", color: .secondary)
                } else if broadcaster.selectedInput.isSystemAudio && broadcaster.levels.allSatisfy({ $0 <= -119 }) {
                    note("Meter flat while sound is playing? Allow Icecast Control under System Settings → Privacy & Security → Screen & System Audio Recording.", color: .secondary)
                }
            case .connecting:
                note("Connecting to the server…", color: .secondary)
            case .live(let since):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    note("Live for \(Format.duration(since: since, now: context.date))", color: .green)
                }
            case .waiting(let message):
                note(message, color: .orange)
            case .failed(let message):
                note(message, color: .red)
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var goLiveButton: some View {
        Group {
            if broadcaster.wantsLive {
                Button { broadcaster.stop() } label: {
                    Label("Stop Broadcast", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                Button { broadcaster.goLive() } label: {
                    Label("Go Live", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .controlSize(.large)
    }
}

/// Two horizontal peak meters, −60 dB to 0 dB.
struct LevelMeter: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { channel in
                HStack(spacing: 6) {
                    Text(channel == 0 ? "L" : "R")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 8)
                    bar(level: channel < levels.count ? levels[channel] : -120)
                }
            }
        }
        .opacity(active ? 1 : 0.4)
        .accessibilityLabel("Input level")
    }

    private func bar(level: Float) -> some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, (level + 60) / 60)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                LinearGradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: 0.7),
                    .init(color: .yellow, location: 0.85),
                    .init(color: .red, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: geometry.size.width * fraction)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .animation(.linear(duration: 0.08), value: fraction)
        }
        .frame(height: 6)
    }
}
