import Darwin
import Foundation

/// One explicitly selected phone's HCI traffic. The optional GPL/LGPL developer tool is an
/// external process, never bundled or linked. Its PCAP mode flushes every packet; PKLG does not.
public final class BluetoothLogRowSource: BufferedDeviceLogSource, @unchecked Sendable {
    private let worker = BluetoothCaptureWorker()
    private let udid: String
    private let overNetwork: Bool
    private let toolPath: String?

    /// The session's checkout, whose `.threading/bluetooth.yaml` gives ATT values app meaning.
    /// Set before `start()`.
    var definitionsCheckout: String?
    /// Every load of the definitions file, from the worker's queue.
    var onDefinitionsChanged: (@Sendable (BluetoothDefinitionReport) -> Void)?

    public init(udid: String, overNetwork: Bool, toolPath: String?) {
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = toolPath
    }

    static func arguments(udid: String, overNetwork: Bool) -> [String] {
        var arguments = ["-u", udid, "-x", "-f", "pcap"]
        if overNetwork { arguments.append("-n") }
        return arguments + ["-"]
    }

    public override func start() {
        worker.start(
            toolPath: toolPath,
            arguments: Self.arguments(udid: udid, overNetwork: overNetwork),
            definitionsCheckout: definitionsCheckout,
            phoneIdentity: udid,
            onDefinitions: onDefinitionsChanged,
            onRows: { [weak self] in self?.enqueue($0) },
            onEnd: { [weak self] in self?.onStreamEnded?($0) }
        )
    }

    public override func stop() { worker.stop() }

    /// Drops every remembered GATT table, in memory and on disk.
    func forgetRememberedGATTTables() { worker.forgetRememberedGATTTables() }
    deinit { worker.stop() }
}

/// All process, pipe and codec work belongs to this serial worker, including launch and teardown.
/// Nonblocking reads cap each tick at 128 KiB per pipe, so cancellation never waits behind a
/// firehose or a silent child. The existing 20k handoff / 50k visible ring bound retained rows.
private final class BluetoothCaptureWorker: @unchecked Sendable {
    private enum Limits {
        static let pollMilliseconds = 50
        static let readsPerTick = 4
        static let diagnosticsBytes = 4_096
        static let terminationSeconds: TimeInterval = 1
        /// Ticks between definition-file stats: once a second at the 50 ms poll.
        static let definitionCheckTicks = 20
    }

    private let queue = DispatchQueue(label: "codes.threading.devicelog.bluetooth")
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var timer: DispatchSourceTimer?
    private var decoder = BluetoothPacketDecoder()
    private var diagnostics = Data()
    private var diagnosticFailure: String?
    private var onRows: (@Sendable ([DeviceLogRow]) -> Void)?
    private var onEnd: (@Sendable (String) -> Void)?
    private var definitionsCheckout: String?
    private var definitionsStamp: BluetoothDefinitionsFile.Stamp?
    /// Where learned enums are kept; tests point it elsewhere.
    var learnedStoreURL = BluetoothLearnedEnums.defaultURL
    private var savedLearnedRevision = 0
    var gattStoreURL = BluetoothGATTTables.defaultURL
    private var savedGATTRevision = 0
    private var report = BluetoothDefinitionReport(status: .noCheckout)
    private var onDefinitions: (@Sendable (BluetoothDefinitionReport) -> Void)?
    private var ticksUntilDefinitionCheck = 0

    func start(
        toolPath: String?, arguments: [String],
        definitionsCheckout: String?,
        phoneIdentity: String? = nil,
        onDefinitions: (@Sendable (BluetoothDefinitionReport) -> Void)?,
        onRows: @escaping @Sendable ([DeviceLogRow]) -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [self] in
            stopOnQueue()
            self.onRows = onRows
            self.onEnd = onEnd
            guard let toolPath, FileManager.default.isExecutableFile(atPath: toolPath) else {
                end("Install libimobiledevice (brew install libimobiledevice), then Rescan to enable Bluetooth capture.")
                return
            }
            decoder = BluetoothPacketDecoder()
            decoder.learned = BluetoothLearnedEnums.load(from: learnedStoreURL)
            savedLearnedRevision = decoder.learnedRevision
            decoder.gatt = BluetoothGATTTables.load(from: gattStoreURL)
            decoder.phoneIdentity = phoneIdentity
            savedGATTRevision = decoder.gattRevision
            self.definitionsCheckout = definitionsCheckout
            self.onDefinitions = onDefinitions
            reloadDefinitions()
            diagnostics = Data()
            diagnosticFailure = nil
            let task = Process()
            let output = Pipe()
            let errors = Pipe()
            self.output = output
            self.errors = errors
            process = task
            task.executableURL = URL(fileURLWithPath: toolPath)
            task.arguments = arguments
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = output
            task.standardError = errors
            do {
                for pipe in [output, errors] {
                    let fd = pipe.fileHandleForReading.fileDescriptor
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                        throw POSIXError(.EIO)
                    }
                }
                try task.run()
                try output.fileHandleForWriting.close()
                try errors.fileHandleForWriting.close()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(Limits.pollMilliseconds))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            } catch {
                end("Could not start Bluetooth capture: \(error.localizedDescription)")
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    /// Loads the file when it changed since the last load, so an author's save shows on the next
    /// packet. A stat a second is the whole steady-state cost.
    private func reloadDefinitions(force: Bool = true) {
        let stamp = BluetoothDefinitionsFile.stamp(checkout: definitionsCheckout)
        guard force || stamp != definitionsStamp else { return }
        definitionsStamp = stamp
        let (definitions, status) = BluetoothDefinitionsFile.load(checkout: definitionsCheckout)
        decoder.definitions = definitions
        report.status = status
        report.highlights = definitions?.highlights ?? [:]
        report.logLinks = definitions?.logLinks ?? []
        report.learned = decoder.learned.summary(enums: definitions?.learnedEnumNames ?? [])
        report.names = decoder.learned.names(definitions: definitions)
        onDefinitions?(report)
    }

    /// Saves what devices taught since the last save and tells the pane. On the worker, at most
    /// once per definition check, so a map exchange of hundreds of pages is one write.
    private func persistLearned() {
        if decoder.gattRevision != savedGATTRevision {
            savedGATTRevision = decoder.gattRevision
            try? decoder.gatt.save(to: gattStoreURL)
        }
        if decoder.learnedRevision != savedLearnedRevision {
            savedLearnedRevision = decoder.learnedRevision
            try? decoder.learned.save(to: learnedStoreURL)
        }
        var next = report
        let current = decoder.learnedFirmware
        next.learned = decoder.learned.summary(
            enums: decoder.definitions?.learnedEnumNames ?? [], identity: current.identity, firmware: current.firmware
        )
        next.names = decoder.learned.names(definitions: decoder.definitions)
        next.gatt = decoder.gattSummary
        guard next != report else { return }
        report = next
        onDefinitions?(report)
    }

    func forgetRememberedGATTTables() {
        queue.async { [self] in
            decoder.gatt = BluetoothGATTTables()
            savedGATTRevision = decoder.gattRevision
            try? FileManager.default.removeItem(at: gattStoreURL)
            report.gatt = nil
            onDefinitions?(report)
        }
    }

    private func tick() {
        guard process != nil, let output, let errors else { return }
        ticksUntilDefinitionCheck -= 1
        if ticksUntilDefinitionCheck <= 0 {
            ticksUntilDefinitionCheck = Limits.definitionCheckTicks
            reloadDefinitions(force: false)
            persistLearned()
        }
        do {
            _ = try drain(errors.fileHandleForReading) { [self] data in
                diagnostics.append(data)
                if diagnostics.count > Limits.diagnosticsBytes {
                    diagnostics = Data(diagnostics.suffix(Limits.diagnosticsBytes))
                }
                // idevicebtlogger can report a failed service start and keep waiting for the
                // next device event. Surface that failure even though the child has not exited.
                let text = String(decoding: diagnostics, as: UTF8.self)
                if text.contains("ERROR:") || text.contains("Could not start logger") {
                    diagnosticFailure = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let diagnosticFailure {
                end(diagnosticFailure)
                return
            }
            let ended = try drain(output.fileHandleForReading) { [self] data in
                let rows = try decoder.append(data)
                if !rows.isEmpty {
                    onRows?(rows)
                }
            }
            if ended {
                try decoder.finish()
                let detail = String(decoding: diagnostics, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                end(detail.isEmpty ? "Bluetooth capture ended." : detail)
            }
        } catch {
            end(error.localizedDescription)
        }
    }

    private func drain(_ handle: FileHandle, consume: (Data) throws -> Void) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: BluetoothPacketDecoder.Limits.chunkBytes)
        for _ in 0..<Limits.readsPerTick {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                try consume(Data(bytes.prefix(count)))
            } else if count == 0 {
                return true
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return false
    }

    private func end(_ reason: String) {
        let callback = onEnd
        stopOnQueue()
        callback?(reason)
    }

    private func stopOnQueue() {
        persistLearned()
        timer?.cancel()
        timer = nil
        onRows = nil
        onEnd = nil
        onDefinitions = nil
        if let task = process, task.isRunning {
            task.terminate()
            // A wedged child must not retain the device service after the pane has stopped.
            queue.asyncAfter(deadline: .now() + Limits.terminationSeconds) {
                if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        for pipe in [output, errors].compactMap({ $0 }) {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        output = nil
        errors = nil
    }
}
