import Darwin
import Foundation
import SkalmanWasmRuntime

enum WasmRunnerError: LocalizedError {
    case usage
    case unsupportedMode(String)
    case moduleDescriptorUnreadable

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: skalman-wasm-extension-runner "
                + "(--skalman-register|--skalman-serve)"
        case .unsupportedMode(let mode):
            return "Unsupported extension entry mode: \(mode)"
        case .moduleDescriptorUnreadable:
            return "The inherited WebAssembly module descriptor could not be read."
        }
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw WasmRunnerError.usage
    }
    let guestArguments = Array(CommandLine.arguments.dropFirst())
    guard guestArguments.count == 1,
          guestArguments[0] == "--skalman-register"
            || guestArguments[0] == "--skalman-serve" else {
        throw WasmRunnerError.unsupportedMode(guestArguments.joined(separator: " "))
    }

    let moduleHandle = FileHandle(fileDescriptor: 4, closeOnDealloc: false)
    guard let moduleBytes = try moduleHandle.readToEnd() else {
        throw WasmRunnerError.moduleDescriptorUnreadable
    }
    let descriptor: Int32? = guestArguments[0] == "--skalman-serve" ? 3 : nil
    let status = try SkalmanWasmRuntime.run(
        moduleBytes: moduleBytes,
        moduleName: "extension.wasm",
        arguments: guestArguments,
        environment: ProcessInfo.processInfo.environment,
        hostDescriptor: descriptor
    )
    exit(Int32(status))
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("Skalman WebAssembly runner: \(message)\n".utf8))
    exit(1)
}
