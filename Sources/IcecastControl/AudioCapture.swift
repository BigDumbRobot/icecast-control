import AudioToolbox
import CoreAudio
import Foundation

/// An audio source the user can broadcast from.
struct AudioInput: Identifiable, Hashable {
    static let systemAudioID = "system"

    let id: String        // device UID, or "system"
    let name: String
    let channels: Int

    var isSystemAudio: Bool { id == Self.systemAudioID }
    var isOBS: Bool { id == Self.obsID }
    var isVirtual: Bool { isSystemAudio || isOBS }

    static let obsID = "obs"
    static let obs = AudioInput(id: obsID, name: "OBS (stream mix)", channels: 2)

    static let systemAudio = AudioInput(id: systemAudioID, name: "System Audio (everything this Mac plays)", channels: 2)
}

/// Lists Core Audio devices.
enum AudioDevices {
    static func inputs() -> [AudioInput] {
        var result: [AudioInput] = [.systemAudio, .obs]
        for id in allDeviceIDs() {
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { continue }
            // Hide our own temporary tap devices.
            if name.hasPrefix("Icecast Control") { continue }
            result.append(AudioInput(id: uid, name: name, channels: channels))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate > 0 ? rate : 48_000
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

enum CaptureError: LocalizedError {
    case deviceMissing(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceMissing(let name): return "The input \"\(name)\" isn't connected."
        case .coreAudio(let step, let status): return "Couldn't \(step) (Core Audio error \(status))."
        }
    }
}

/// Applies volume, measures peak levels and hands stereo audio to the encoder.
/// Shared by device capture and the OBS input.
final class StereoProcessor: @unchecked Sendable {
    /// Called on a background queue with interleaved Float32 stereo audio.
    var onAudio: ((Data) -> Void)?
    /// Called on a background queue roughly 15 times a second with peak levels in dBFS.
    var onLevels: ((Float, Float) -> Void)?

    private let lock = NSLock()
    private var _gain: Float = 1
    private var _sampleRate: Double = 48_000
    var gain: Float {
        get { lock.withLock { _gain } }
        set { lock.withLock { _gain = newValue } }
    }
    var sampleRate: Double {
        get { lock.withLock { _sampleRate } }
        set { lock.withLock { _sampleRate = newValue } }
    }

    private var peakL: Float = 0
    private var peakR: Float = 0
    private var framesSinceLevels = 0

    /// `left(i)` / `right(i)` return frame i of each channel.
    func process(frames: Int, left: (Int) -> Float, right: (Int) -> Float) {
        guard frames > 0 else { return }
        let gain = self.gain
        var output = [Float](repeating: 0, count: frames * 2)
        var pL = peakL, pR = peakR
        for frame in 0..<frames {
            let l = left(frame) * gain
            let r = right(frame) * gain
            output[frame * 2] = l
            output[frame * 2 + 1] = r
            pL = max(pL, abs(l))
            pR = max(pR, abs(r))
        }
        peakL = pL
        peakR = pR
        framesSinceLevels += frames
        if framesSinceLevels >= Int(sampleRate / 15) {
            framesSinceLevels = 0
            onLevels?(Self.decibels(peakL), Self.decibels(peakR))
            peakL = 0
            peakR = 0
        }
        onAudio?(output.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    func silence() { onLevels?(-120, -120) }

    private static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(-120, 20 * log10(amplitude)) : -120
    }
}

/// Captures two channels from a device or from the system output.
final class AudioCapture: @unchecked Sendable {
    private let processor: StereoProcessor
    private(set) var sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "IcecastControl.capture", qos: .userInteractive)
    private var deviceID: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var firstChannel = 0

    init(processor: StereoProcessor) {
        self.processor = processor
    }

    /// Starts capturing. `channelOffset` picks the channel pair (0 = channels 1–2).
    func start(input: AudioInput, channelOffset: Int) throws {
        stop()
        if input.isSystemAudio {
            try createSystemTap()
            deviceID = aggregateID
            // The tap's channels come last on the aggregate device.
            firstChannel = max(0, AudioDevices.inputChannelCount(aggregateID) - 2)
        } else {
            guard let id = AudioDevices.deviceID(forUID: input.id) else { throw CaptureError.deviceMissing(input.name) }
            deviceID = id
            firstChannel = channelOffset
        }
        sampleRate = AudioDevices.sampleRate(deviceID)
        processor.sampleRate = sampleRate

        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, deviceID, queue) { [weak self] _, inputData, _, _, _ in
            self?.process(inputData)
        }
        guard status == noErr, let newProc else {
            stop()
            throw CaptureError.coreAudio("open the audio input", status)
        }
        procID = newProc
        status = AudioDeviceStart(deviceID, newProc)
        guard status == noErr else {
            stop()
            throw CaptureError.coreAudio("start the audio input", status)
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = 0
        tapID = 0
        deviceID = 0
    }

    deinit { stop() }

    /// Mirrors the system output using a Core Audio process tap (macOS 14.2+).
    /// Audio keeps playing on the speakers as normal.
    private func createSystemTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Icecast Control System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw CaptureError.coreAudio("capture system audio", status) }
        tapID = newTap

        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Icecast Control Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        if let output = AudioDevices.defaultOutputUID() {
            settings[kAudioAggregateDeviceMainSubDeviceKey] = output
            settings[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var newAggregate = AudioDeviceID(0)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &newAggregate)
        guard status == noErr else { throw CaptureError.coreAudio("set up system audio capture", status) }
        aggregateID = newAggregate
    }

    private func process(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        // Map a flat channel number to (buffer, channel within buffer).
        var map: [(buffer: Int, channel: Int, stride: Int)] = []
        var frames = 0
        for (index, buffer) in buffers.enumerated() {
            let count = Int(buffer.mNumberChannels)
            guard count > 0 else { continue }
            if frames == 0 { frames = Int(buffer.mDataByteSize) / (4 * count) }
            for channel in 0..<count { map.append((index, channel, count)) }
        }
        guard frames > 0, !map.isEmpty else { return }

        let left = map[min(firstChannel, map.count - 1)]
        let right = map[min(firstChannel + 1, map.count - 1)]
        guard let leftData = buffers[left.buffer].mData?.assumingMemoryBound(to: Float.self),
              let rightData = buffers[right.buffer].mData?.assumingMemoryBound(to: Float.self) else { return }
        processor.process(frames: frames,
                          left: { leftData[$0 * left.stride + left.channel] },
                          right: { rightData[$0 * right.stride + right.channel] })
    }
}
