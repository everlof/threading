import Darwin
import Foundation
import SystemPackage
@_spi(Fuzzing) import WasmKit
import WasmKitWASI

public enum SkalmanWasmRuntimeError: LocalizedError {
    case invalidHostCall
    case moduleTooLarge(maximum: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidHostCall:
            return "The WebAssembly extension made an invalid Skalman host call."
        case .moduleTooLarge(let maximum):
            return "The WebAssembly module is larger than \(maximum) bytes."
        }
    }
}

/// Runs one WASI command module with no filesystem preopens and one optional Skalman host call.
///
/// The guest receives stdin/stdout/stderr through WASI. It cannot open host files or sockets:
/// WasmKit only exposes capabilities explicitly linked here, and the sole non-WASI import is
/// `skalman.host_exchange`. Registration deliberately passes no broker descriptor, making the
/// import fail closed if extension code attempts a host call before it is authorised.
public enum SkalmanWasmRuntime {
    public static let hostModule = "skalman"
    public static let hostExchange = "host_exchange"
    public static let maximumModuleBytes: Int64 = 256 * 1024 * 1024
    public static let maximumRequestBytes = 8 * 1024 * 1024
    public static let maximumResponseBytes = 64 * 1024 + 8 * 1024 * 1024
    public static let maximumGuestMemoryBytes = 256 * 1024 * 1024
    public static let maximumTableElements = 1_000_000

    @discardableResult
    public static func run(
        moduleURL: URL,
        arguments: [String],
        environment: [String: String],
        hostDescriptor: Int32?
    ) throws -> UInt32 {
        let values = try moduleURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize,
           Int64(fileSize) > maximumModuleBytes {
            throw SkalmanWasmRuntimeError.moduleTooLarge(maximum: maximumModuleBytes)
        }

        let bytes = try Data(contentsOf: moduleURL)
        return try run(
            moduleBytes: bytes,
            moduleName: moduleURL.lastPathComponent,
            arguments: arguments,
            environment: environment,
            hostDescriptor: hostDescriptor
        )
    }

    /// Runs module bytes already opened by the trusted host.
    ///
    /// Production uses this overload so the sandboxed runner needs no package-directory
    /// entitlement: Skalman opens the validated module and installs that one descriptor.
    @discardableResult
    public static func run(
        moduleBytes: Data,
        moduleName: String,
        arguments: [String],
        environment: [String: String],
        hostDescriptor: Int32?
    ) throws -> UInt32 {
        guard Int64(moduleBytes.count) <= maximumModuleBytes else {
            throw SkalmanWasmRuntimeError.moduleTooLarge(maximum: maximumModuleBytes)
        }
        let module = try parseWasm(bytes: Array(moduleBytes))
        let wasi = try WASIBridgeToHost(
            args: [moduleName] + arguments,
            environment: environment,
            preopens: [:]
        )
        let engine = Engine(configuration: .init(
            compilationMode: .lazy,
            stackSize: 1024 * 1024
        ))
        let store = Store(engine: engine)
        store.resourceLimiter = SkalmanResourceLimiter()

        let broker = hostDescriptor.map {
            HostDescriptorExchange(descriptor: $0)
        }
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        imports.define(
            module: hostModule,
            name: hostExchange,
            Function(
                store: store,
                parameters: [.i32, .i32, .i32, .i32],
                results: [.i32]
            ) { caller, values in
                guard values.count == 4,
                      let memory = caller.instance?.exports[memory: "memory"] else {
                    throw SkalmanWasmRuntimeError.invalidHostCall
                }

                let requestOffset = Int(values[0].i32)
                let requestLength = Int(values[1].i32)
                let responseOffset = Int(values[2].i32)
                let responseCapacity = Int(values[3].i32)
                guard requestLength >= 0,
                      requestLength <= maximumRequestBytes,
                      responseCapacity >= 0,
                      responseCapacity <= maximumResponseBytes,
                      let requestRange = checkedRange(
                        offset: requestOffset,
                        count: requestLength,
                        limit: memory.data.count
                      ),
                      let responseRange = checkedRange(
                        offset: responseOffset,
                        count: responseCapacity,
                        limit: memory.data.count
                      ),
                      let broker else {
                    return [.i32(UInt32(bitPattern: -1))]
                }

                let request = Data(memory.data[requestRange])
                guard let response = try? broker.exchange(request),
                      response.count <= responseCapacity else {
                    return [.i32(UInt32(bitPattern: -1))]
                }

                _ = memory.withUnsafeMutableBufferPointer(
                    offset: UInt(responseRange.lowerBound),
                    count: response.count
                ) { destination in
                    response.copyBytes(to: destination)
                }
                return [.i32(UInt32(response.count))]
            }
        )

        let instance = try module.instantiate(store: store, imports: imports)
        return try wasi.start(instance)
    }

    private static func checkedRange(
        offset: Int,
        count: Int,
        limit: Int
    ) -> Range<Int>? {
        guard offset >= 0, count >= 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow, end <= limit else { return nil }
        return offset..<end
    }
}

private struct SkalmanResourceLimiter: ResourceLimiter {
    func limitMemoryGrowth(to desired: Int) throws -> Bool {
        desired <= SkalmanWasmRuntime.maximumGuestMemoryBytes
    }

    func limitTableGrowth(to desired: Int) throws -> Bool {
        desired <= SkalmanWasmRuntime.maximumTableElements
    }
}

/// One serialized HTTP-framed request-response exchange over an inherited socket.
///
/// The extension SDK already speaks this framing. Keeping it intact means the native runner
/// is a byte bridge, not a second authentication or capability implementation.
final class HostDescriptorExchange {
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private let descriptor: Int32
    private var responseBuffer = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func exchange(_ request: Data) throws -> Data {
        try writeAll(request)

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let length = try completeResponseLength(in: responseBuffer) {
                let response = Data(responseBuffer.prefix(length))
                responseBuffer.removeFirst(length)
                return response
            }
            guard responseBuffer.count <= SkalmanWasmRuntime.maximumResponseBytes else {
                throw SkalmanWasmRuntimeError.invalidHostCall
            }

            let count = chunk.withUnsafeMutableBytes { bytes -> Int in
                var result: Int
                repeat {
                    result = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                } while result < 0 && errno == EINTR
                return result
            }
            guard count > 0 else {
                throw SkalmanWasmRuntimeError.invalidHostCall
            }
            responseBuffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                var count: Int
                repeat {
                    count = Darwin.write(
                        descriptor,
                        bytes.baseAddress.map { $0 + offset },
                        bytes.count - offset
                    )
                } while count < 0 && errno == EINTR
                guard count > 0 else {
                    throw SkalmanWasmRuntimeError.invalidHostCall
                }
                offset += count
            }
        }
    }

    private func completeResponseLength(in data: Data) throws -> Int? {
        guard let terminator = data.range(of: Self.headerTerminator) else {
            guard data.count <= 64 * 1024 else {
                throw SkalmanWasmRuntimeError.invalidHostCall
            }
            return nil
        }
        guard let head = String(
            data: data[data.startIndex..<terminator.lowerBound],
            encoding: .utf8
        ) else {
            throw SkalmanWasmRuntimeError.invalidHostCall
        }
        let contentLength = head
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare("Content-Length") == .orderedSame else {
                    return nil
                }
                return Int(pieces[1].trimmingCharacters(in: .whitespaces))
            }
            .first
        guard let contentLength,
              contentLength >= 0,
              contentLength <= 8 * 1024 * 1024 else {
            throw SkalmanWasmRuntimeError.invalidHostCall
        }

        let headerLength = terminator.upperBound - data.startIndex
        let (total, overflow) = headerLength.addingReportingOverflow(contentLength)
        guard !overflow, total <= SkalmanWasmRuntime.maximumResponseBytes else {
            throw SkalmanWasmRuntimeError.invalidHostCall
        }
        return data.count >= total ? total : nil
    }
}
