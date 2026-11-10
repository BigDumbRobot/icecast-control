import Foundation
import Network

/// Receives OBS's audio mix from the "Icecast Control" OBS script.
/// OBS sends uncompressed WAV over a local-only TCP connection (127.0.0.1:8046).
final class OBSReceiver: @unchecked Sendable {
    static let port: UInt16 = 8046

    /// Called on the main queue when OBS connects (true, sample rate) or disconnects (false, 0).
    var onConnectionChange: ((Bool, Double) -> Void)?

    private let processor: StereoProcessor
    private let queue = DispatchQueue(label: "IcecastControl.obs", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?

    // WAV parsing state
    private var header = Data()
    private var headerDone = false
    private var channels = 2
    private var bytesPerSample = 2
    private var isFloat = false
    private var remainder = Data()

    init(processor: StereoProcessor) {
        self.processor = processor
    }

    var isListening: Bool { queue.sync { listener != nil } }

    func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ new: NWConnection) {
        // One OBS at a time; a new connection replaces the old one.
        connection?.cancel()
        connection = new
        header = Data()
        headerDone = false
        remainder = Data()
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new else { return }
            switch state {
            case .failed, .cancelled:
                if self.connection === new {
                    self.connection = nil
                    self.processor.silence()
                    self.notify(false, 0)
                }
            default:
                break
            }
        }
        new.start(queue: queue)
        receive(on: new)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func consume(_ data: Data) {
        if headerDone {
            decode(data)
            return
        }
        header.append(data)
        guard let (payloadStart, rate) = parseHeader(header) else {
            if header.count > 65_536 { connection?.cancel() }   // not a WAV stream
            return
        }
        headerDone = true
        processor.sampleRate = rate
        notify(true, rate)
        let rest = header.subdata(in: payloadStart..<header.count)
        header = Data()
        decode(rest)
    }

    /// Returns where the audio starts and the sample rate, once the header is complete.
    private func parseHeader(_ data: Data) -> (Int, Double)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }
        guard String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            connection?.cancel()
            return nil
        }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        var offset = 12
        var rate: Double?
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "data" {
                guard let rate else { return nil }
                return (body, rate)
            }
            // Other chunks have a real size; wait until all of it has arrived.
            guard body + size <= bytes.count else { return nil }
            if id == "fmt " {
                let format = u16(body)
                channels = max(1, u16(body + 2))
                rate = Double(u32(body + 4))
                let bits = u16(body + 14)
                bytesPerSample = max(1, bits / 8)
                isFloat = format == 3 || (format == 0xFFFE && bits == 32 && size >= 26 && bytes[body + 24] == 3)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    private func decode(_ data: Data) {
        var data = data
        if !remainder.isEmpty {
            data = remainder + data
            remainder = Data()
        }
        let frameSize = channels * bytesPerSample
        let frames = data.count / frameSize
        let used = frames * frameSize
        if used < data.count { remainder = data.subdata(in: used..<data.count) }
        guard frames > 0 else { return }

        let rightChannel = channels > 1 ? 1 : 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if isFloat && bytesPerSample == 4 {
                let samples = raw.bindMemory(to: Float.self)
                let ch = channels
                processor.process(frames: frames,
                                  left: { samples[$0 * ch] },
                                  right: { samples[$0 * ch + rightChannel] })
            } else if bytesPerSample == 2 {
                let samples = raw.bindMemory(to: Int16.self)
                let ch = channels
                processor.process(frames: frames,
                                  left: { Float(Int16(littleEndian: samples[$0 * ch])) / 32_768 },
                                  right: { Float(Int16(littleEndian: samples[$0 * ch + rightChannel])) / 32_768 })
            } else if bytesPerSample == 4 {
                let samples = raw.bindMemory(to: Int32.self)
                let ch = channels
                processor.process(frames: frames,
                                  left: { Float(Int32(littleEndian: samples[$0 * ch])) / 2_147_483_648 },
                                  right: { Float(Int32(littleEndian: samples[$0 * ch + rightChannel])) / 2_147_483_648 })
            }
        }
    }

    private func notify(_ connected: Bool, _ rate: Double) {
        let callback = onConnectionChange
        DispatchQueue.main.async { callback?(connected, rate) }
    }
}
