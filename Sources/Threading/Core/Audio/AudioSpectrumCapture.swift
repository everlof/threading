import AppKit
import CoreAudio
import Foundation

struct AudioSpectrumSource: Equatable, Sendable {
    static let systemID = "system"
    let id: String
    let title: String
}

enum AudioSpectrumCaptureError: Error, Equatable {
    case sourceUnavailable
    case sourceChanged
    case unsupportedFormat
    case tooManyProcesses
    case coreAudio(OSStatus)
}

protocol AudioSpectrumCapturing: Sendable {
    func sources() async throws -> [AudioSpectrumSource]
    func start(sourceID: String) async throws
    func read(at now: TimeInterval) async throws -> AudioSpectrum?
    func stop() async
}

/// The audio callback only copies a bounded mono window into preallocated storage. A busy
/// reader drops a callback instead of blocking Core Audio. FFTs, allocation, HAL queries and
/// publication all happen outside the callback. The lock protects the pointer and counters.
final class AudioSpectrumMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: AudioSpectrumAnalyzer.sampleCount)
    private var cursor = 0
    private var count = 0
    private var revision: UInt64 = 0
    private var callbacks: UInt64 = 0

    init() { storage.initialize(repeating: 0, count: AudioSpectrumAnalyzer.sampleCount) }
    deinit { storage.deallocate() }

    func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        callbacks &+= 1
        guard input.pointee.mNumberBuffers > 0, input.pointee.mNumberBuffers <= 8 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var channelCount = 0
        var availableFrames = Int.max
        for buffer in buffers {
            guard buffer.mNumberChannels > 0, buffer.mNumberChannels <= 8,
                  buffer.mData != nil else { return }
            channelCount += Int(buffer.mNumberChannels)
            availableFrames = min(availableFrames, Int(buffer.mDataByteSize) / (4 * Int(buffer.mNumberChannels)))
        }
        guard channelCount <= 8, availableFrames > 0 else { return }
        let frameCount = min(availableFrames, 4_096)
        let firstFrame = availableFrames - frameCount
        for frame in firstFrame..<availableFrames {
            var sum: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                let channels = Int(buffer.mNumberChannels)
                for channel in 0..<channels {
                    let value = data[frame * channels + channel]
                    sum += value.isFinite ? value : 0
                }
            }
            storage[cursor] = sum / Float(channelCount)
            cursor = (cursor + 1) % AudioSpectrumAnalyzer.sampleCount
        }
        count = min(count + frameCount, AudioSpectrumAnalyzer.sampleCount)
        revision &+= 1
    }

    func latest(after previous: UInt64) -> (samples: [Float], revision: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard count == AudioSpectrumAnalyzer.sampleCount, revision != previous else { return nil }
        let samples = (0..<AudioSpectrumAnalyzer.sampleCount).map {
            storage[(cursor + $0) % AudioSpectrumAnalyzer.sampleCount]
        }
        return (samples, revision)
    }

    func diagnosticCounts() -> (callbacks: UInt64, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (callbacks, count)
    }
}

/// All HAL lifecycle and process discovery stay on this worker actor, never the main actor.
/// One private, unmuted tap and aggregate device; no microphone, disk recording or playback.
@available(macOS 14.2, *)
actor AudioSpectrumCapture: AudioSpectrumCapturing {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var mailbox: AudioSpectrumMailbox?
    private var analyzer: AudioSpectrumAnalyzer?
    private var sampleRate: Double = 48_000
    private var revision: UInt64 = 0
    private var sourceID = ""
    private var processIDs: [AudioObjectID] = []
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var checkedAt: TimeInterval = 0
    private var receivedAt: TimeInterval?
    private let silence = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)

    func sources() throws -> [AudioSpectrumSource] {
        var byID: [String: String] = [:]
        for process in try Self.processes() {
            guard let bundleID = try? Self.string(process, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty,
                  let pid: pid_t = try? Self.scalar(process, kAudioProcessPropertyPID, initial: 0),
                  pid != getpid() else { continue }
            // Resolving the local display name can touch bundle metadata, so it stays here.
            byID[bundleID] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
        }
        return byID.map { AudioSpectrumSource(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(32).map { $0 }
    }

    func start(sourceID: String) throws {
        stop()
        do {
            let processes = try Self.selectedProcesses(sourceID)
            let description = sourceID == AudioSpectrumSource.systemID
                ? CATapDescription(monoGlobalTapButExcludeProcesses: processes)
                : CATapDescription(monoMixdownOfProcesses: processes)
            description.name = "Threading theme audio spectrum"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID))
            let format = try Self.format(tapID)
            sampleRate = format.mSampleRate
            outputDevice = try Self.scalar(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: 0
            )
            let tapUID = try Self.string(tapID, kAudioTapPropertyUID)
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Threading theme spectrum",
                kAudioAggregateDeviceUIDKey: "codes.threading.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                // Tap-only: adding a duplex output device here also adds its microphone
                // input streams to the aggregate. The tap supplies the capture clock.
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &deviceID))
            let mailbox = AudioSpectrumMailbox()
            guard let analyzer = AudioSpectrumAnalyzer() else {
                throw AudioSpectrumCaptureError.unsupportedFormat
            }
            self.mailbox = mailbox
            self.analyzer = analyzer
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) {
                _, input, _, _, _ in mailbox.receive(input)
            })
            try Self.check(AudioDeviceStart(deviceID, ioProc))
            self.sourceID = sourceID
            processIDs = processes
            revision = 0
            checkedAt = 0
            receivedAt = nil
        } catch {
            stop()
            throw error
        }
    }

    func read(at now: TimeInterval) throws -> AudioSpectrum? {
        guard let mailbox, let analyzer else { return nil }
        if now - checkedAt >= 2 {
            checkedAt = now
            let output: AudioObjectID = try Self.scalar(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: 0
            )
            guard output == outputDevice,
                  try Self.selectedProcesses(sourceID) == processIDs,
                  try Self.format(tapID).mSampleRate == sampleRate else {
                throw AudioSpectrumCaptureError.sourceChanged
            }
        }
        if let latest = mailbox.latest(after: revision) {
            revision = latest.revision
            receivedAt = now
            return analyzer.analyze(samples: latest.samples, sampleRate: sampleRate, at: now)
        }
        // Successful device creation is not evidence of delivered audio. In particular a
        // refused/protected/stalled stream must not be advertised as available silence.
        guard let receivedAt, now - receivedAt < 0.25 else { return nil }
        return analyzer.analyze(samples: silence, sampleRate: sampleRate, at: now)
    }

    func stop() {
        if deviceID != kAudioObjectUnknown, let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        mailbox = nil
        analyzer = nil
        receivedAt = nil
    }

    func diagnosticCountsForTesting() -> (callbacks: UInt64, frames: Int, processes: Int) {
        let counts = mailbox?.diagnosticCounts() ?? (callbacks: 0, frames: 0)
        return (counts.callbacks, counts.frames, processIDs.count)
    }

    private static func selectedProcesses(_ sourceID: String) throws -> [AudioObjectID] {
        let selected = try processes().filter { process in
            if sourceID == AudioSpectrumSource.systemID {
                let pid: pid_t = (try? scalar(process, kAudioProcessPropertyPID, initial: 0)) ?? 0
                return pid == getpid()
            }
            return (try? string(process, kAudioProcessPropertyBundleID)) == sourceID
        }
        guard sourceID == AudioSpectrumSource.systemID || !selected.isEmpty else {
            throw AudioSpectrumCaptureError.sourceUnavailable
        }
        return selected.sorted()
    }

    private static func processes() throws -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        guard size <= 256 * MemoryLayout<AudioObjectID>.stride else {
            throw AudioSpectrumCaptureError.tooManyProcesses
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard !objects.isEmpty else { return [] }
        try objects.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!))
        }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    private static func format(_ object: AudioObjectID) throws -> AudioStreamBasicDescription {
        let format = try scalar(object, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              (1...8).contains(format.mChannelsPerFrame),
              format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw AudioSpectrumCaptureError.unsupportedFormat
        }
        return format
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                      initial: Value) throws -> Value {
        var property = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        try withUnsafeMutablePointer(to: &value) {
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0))
        }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        // Core Audio transfers ownership of these CFString properties to the caller.
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
        guard let value else { throw AudioSpectrumCaptureError.sourceUnavailable }
        return value.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioSpectrumCaptureError.coreAudio(status) }
    }
}
