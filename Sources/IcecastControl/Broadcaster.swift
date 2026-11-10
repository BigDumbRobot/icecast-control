import AppKit
import AVFoundation
import Foundation

enum BroadcastState: Equatable {
    case off
    case connecting
    case live(since: Date)
    /// Not connected right now, but will retry on its own.
    case waiting(String)
    /// Stopped trying; needs the user to fix something.
    case failed(String)

    var isLive: Bool { if case .live = self { return true } else { return false } }
}

/// Sends an audio input to the Icecast server (replacing LadioCast).
/// The app captures the audio itself; ffmpeg only encodes MP3 and uploads it.
/// Reconnects by itself after drops and server restarts.
@MainActor
final class Broadcaster: ObservableObject {
    @Published private(set) var state: BroadcastState = .off
    /// Peak level per channel in dBFS (-120 = silence).
    @Published private(set) var levels: [Float] = [-120, -120]
    @Published private(set) var inputs: [AudioInput] = [.systemAudio]
    /// True while the user wants to be on air (stays true across drops and restarts).
    @Published private(set) var wantsLive = false
    /// True while audio is being captured (when live, or when the panel shows the meter).
    @Published private(set) var capturing = false
    @Published private(set) var captureError: String?

    private let prefs: AppPreferences
    private let store: ConfigStore
    private let monitor: ServerMonitor

    private let processor = StereoProcessor()
    private lazy var capture = AudioCapture(processor: processor)
    private lazy var obs = OBSReceiver(processor: processor)
    private var previewing = false
    private var captureRate: Double = 48_000
    /// True while the OBS script is sending audio.
    @Published private(set) var obsConnected = false
    private var obsStopWork: DispatchWorkItem?

    private var process: Process?
    private var encoderRate: Double = 0
    private var reader: LineReader?
    private let writer = AudioWriter()
    private var recentLines: [String] = []
    private var retryAt: Date?
    private var failures = 0
    private var timer: Timer?

    init(prefs: AppPreferences, store: ConfigStore, monitor: ServerMonitor) {
        self.prefs = prefs
        self.store = store
        self.monitor = monitor
        processor.gain = Float(prefs.gain)
        processor.onAudio = { [writer] data in writer.write(data) }
        processor.onLevels = { [weak self] left, right in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.levels = [left, right] } }
        }
        obs.onConnectionChange = { [weak self] connected, rate in
            MainActor.assumeIsolated { self?.obsChanged(connected: connected, rate: rate) }
        }
    }

    /// OBS started or stopped sending (it follows OBS streaming when the script is set to).
    private func obsChanged(connected: Bool, rate: Double) {
        obsConnected = connected
        guard selectedInput.isOBS else { return }
        obsStopWork?.cancel()
        if connected {
            captureRate = rate
            if process != nil, rate != encoderRate {
                stopEncoder()
                retryAt = nil
            }
            if prefs.followOBS && !wantsLive { goLive() }
            tick()
        } else {
            levels = [-120, -120]
            stopEncoder()
            // OBS stopped: end the broadcast too, unless it comes back within a few seconds.
            if prefs.followOBS && wantsLive {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.obsConnected, self.selectedInput.isOBS else { return }
                        self.stop()
                    }
                }
                obsStopWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }
        }
    }

    var selectedInput: AudioInput {
        inputs.first { $0.id == prefs.inputSource }
            ?? AudioInput(id: prefs.inputSource, name: prefs.inputSourceName, channels: 2)
    }

    /// True while the encoder is running (connected or connecting).
    var isRunning: Bool { process != nil }

    var selectedInputMissing: Bool { !inputs.contains { $0.id == prefs.inputSource } }

    func begin() {
        refreshInputs()
        Task {
            await killOrphans()
            if prefs.setupComplete && prefs.autoBroadcast { goLive() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writer.close()
                self?.process?.terminate()
                self?.capture.stop()
                self?.obs.stop()
            }
        }
        updateCapture()
    }

    // MARK: - Controls

    func goLive() {
        wantsLive = true
        failures = 0
        retryAt = nil
        if case .failed = state { state = .off }
        updateCapture()
        tick()
    }

    func stop() {
        wantsLive = false
        retryAt = nil
        state = .off
        stopEncoder()
        updateCapture()
    }

    /// Volume, applied instantly.
    func setGain(_ gain: Double) {
        prefs.gain = gain
        processor.gain = Float(gain)
    }

    /// Switches input; works while live (the stream continues).
    func selectInput(_ id: String, channelOffset: Int = 0) {
        prefs.inputSource = id
        prefs.inputChannelOffset = channelOffset
        if let input = inputs.first(where: { $0.id == id }) { prefs.inputSourceName = input.name }
        if capturing { restartCapture() } else { updateCapture() }
    }

    /// Shows the level meter while the panel is open, even when not live.
    func setPreview(_ on: Bool) {
        previewing = on
        if on { refreshInputs() }
        updateCapture()
    }

    func refreshInputs() {
        inputs = AudioDevices.inputs()
    }

    // MARK: - Capture

    private func updateCapture() {
        // The OBS input always listens, so OBS can start the broadcast by itself.
        let shouldCapture = wantsLive || previewing || selectedInput.isOBS
        if shouldCapture && !capturing {
            startCapture()
        } else if !shouldCapture && capturing {
            stopCapture()
        }
    }

    private func stopCapture() {
        capture.stop()
        obs.stop()
        obsConnected = false
        capturing = false
        levels = [-120, -120]
    }

    private func restartCapture() {
        stopCapture()
        startCapture()
        // A different sample rate needs a fresh encoder.
        if process != nil, captureRate != encoderRate {
            stopEncoder()
            retryAt = nil
        }
    }

    private func startCapture() {
        let input = selectedInput
        if input.isOBS {
            do {
                try obs.start()
                capturing = true
                captureError = nil
            } catch {
                captureError = "Couldn't listen for OBS on port \(OBSReceiver.port): \(error.localizedDescription)"
            }
            return
        }
        if !input.isSystemAudio {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.updateCapture() } }
                }
                return
            case .denied, .restricted:
                captureError = "Icecast Control needs permission to use audio inputs. Allow it in System Settings → Privacy & Security → Microphone."
                if wantsLive { fail(captureError!) }
                return
            default:
                break
            }
        }
        do {
            try capture.start(input: input, channelOffset: prefs.inputChannelOffset)
            captureRate = capture.sampleRate
            capturing = true
            captureError = nil
        } catch {
            capturing = false
            captureError = error.localizedDescription
            if wantsLive {
                state = .waiting("\(error.localizedDescription) Pick another input, or reconnect it.")
            }
        }
    }

    // MARK: - Encoder / connection loop

    private func tick() {
        guard wantsLive else { return }
        if !capturing {
            updateCapture()
            if !capturing { return }
        }
        guard process == nil else { return }
        if selectedInput.isOBS && !obsConnected {
            state = .waiting("Waiting for OBS. Start streaming in OBS, or press \"Start sending now\" in its Icecast Control script.")
            return
        }
        if !monitor.phase.isUp {
            state = .waiting(monitor.phase == .stopped || isFailed(monitor.phase)
                             ? "Server is off. Will go live as soon as it starts."
                             : "Waiting for the server…")
            return
        }
        if let retryAt, retryAt > Date() { return }
        retryAt = nil
        launchEncoder()
    }

    private func isFailed(_ phase: ServerPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func launchEncoder() {
        let ffmpeg = prefs.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            fail("ffmpeg wasn't found at \(ffmpeg). Install it with: brew install ffmpeg")
            return
        }
        let s = store.saved
        let password = s.sourcePassword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s.sourcePassword
        let url = "icecast://source:\(password)@127.0.0.1:\(s.port)\(s.mountName)"
        let rate = Int(captureRate)
        let arguments = [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "info",
            "-f", "f32le", "-ar", "\(rate)", "-ac", "2", "-i", "pipe:0",
            // Safety limiter at −1 dBFS: untouched below that, stops clipping in the MP3.
            "-af", "alimiter=limit=0.891:attack=5:release=50:level=0",
            "-c:a", "libmp3lame", "-b:a", "\(prefs.bitrate)k", "-ac", "2", "-ar", "44100",
            "-content_type", "audio/mpeg",
            "-ice_name", prefs.streamName,
            "-ice_genre", prefs.streamGenre,
            "-f", "mp3", url,
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let reader = LineReader { [weak self] lines in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(lines) } }
        }
        reader.attach(errors.fileHandleForReading)
        process.terminationHandler = { [weak self] ended in
            // Let the last log lines arrive before working out why it stopped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.encoderEnded(ended) }
            }
        }

        recentLines = []
        do {
            try process.run()
        } catch {
            fail("Couldn't run ffmpeg: \(error.localizedDescription)")
            return
        }
        self.process = process
        self.reader = reader
        encoderRate = captureRate
        writer.open(input.fileHandleForWriting)
        state = .connecting
    }

    private func stopEncoder() {
        writer.close()   // ffmpeg sees end of input and finishes
        guard let process else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    private func handle(_ lines: [String]) {
        for line in lines {
            recentLines.append(line)
            if recentLines.count > 40 { recentLines.removeFirst(recentLines.count - 40) }
            if line.hasPrefix("Output #0"), process != nil, state == .connecting {
                state = .live(since: Date())
                failures = 0
            }
        }
    }

    private func encoderEnded(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        reader = nil
        writer.close()
        guard wantsLive else {
            state = .off
            return
        }

        let log = recentLines.joined(separator: "\n")
        let mount = store.saved.mountName
        failures += 1
        let backoff = min(10.0, 2.0 * Double(failures))

        if log.contains("401") {
            fail("The server rejected the source password. Check Settings → Passwords, then Save & Restart.")
        } else if log.contains("403") {
            state = .waiting("Another source is already connected to \(mount), probably LadioCast. Disconnect it there and this will take over.")
            retryAt = Date().addingTimeInterval(10)
        } else if !monitor.phase.isUp || log.contains("Connection refused") || log.contains("Broken pipe")
                    || log.contains("Connection reset") {
            state = .waiting("Lost the connection to the server. Reconnecting…")
            retryAt = Date().addingTimeInterval(backoff)
        } else {
            let last = recentLines.last { $0.lowercased().contains("error") } ?? recentLines.last ?? ""
            state = .waiting("Broadcast stopped (\(Self.sanitize(last))). Reconnecting…")
            retryAt = Date().addingTimeInterval(backoff)
        }
    }

    private func fail(_ message: String) {
        wantsLive = false
        state = .failed(message)
        stopEncoder()
        updateCapture()
    }

    /// Removes the password-carrying URL from ffmpeg messages.
    private static func sanitize(_ line: String) -> String {
        let cleaned = line.replacingOccurrences(of: #"icecast://\S+"#, with: "server", options: .regularExpression)
            .replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "unknown reason" : String(cleaned.prefix(120))
    }

    /// Stops encoders left behind if the app quit unexpectedly.
    private func killOrphans() async {
        let s = store.saved
        let output = await Shell.run("/bin/ps", ["-axww", "-o", "pid=,args="])
        for line in output.text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("ffmpeg"), trimmed.contains("pipe:0"),
                  trimmed.contains("@127.0.0.1:\(s.port)\(s.mountName)"),
                  let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<space]) else { continue }
            kill(pid, SIGTERM)
        }
    }
}

/// Writes audio to ffmpeg on a background queue, dropping audio rather than
/// building up delay if ffmpeg falls behind.
final class AudioWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IcecastControl.writer")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pending = 0

    func open(_ handle: FileHandle) {
        lock.withLock {
            self.handle = handle
            pending = 0
        }
    }

    func close() {
        let old: FileHandle? = lock.withLock {
            let h = handle
            handle = nil
            return h
        }
        queue.async { try? old?.close() }
    }

    func write(_ data: Data) {
        let target: FileHandle? = lock.withLock {
            guard let handle, pending < 64 else { return nil }
            pending += 1
            return handle
        }
        guard let target else { return }
        queue.async { [weak self] in
            try? target.write(contentsOf: data)
            self?.lock.withLock { self?.pending -= 1 }
        }
    }
}

/// Collects output from a pipe and hands it over line by line.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let onLines: ([String]) -> Void

    init(onLines: @escaping ([String]) -> Void) {
        self.onLines = onLines
    }

    func attach(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.buffer.append(data)
            var lines: [String] = []
            while let index = self.buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let lineData = self.buffer[self.buffer.startIndex..<index]
                self.buffer.removeSubrange(self.buffer.startIndex...index)
                if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
            }
            if !lines.isEmpty { self.onLines(lines) }
        }
    }
}
