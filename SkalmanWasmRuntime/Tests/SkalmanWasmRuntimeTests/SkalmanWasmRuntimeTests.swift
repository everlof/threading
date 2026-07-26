import Darwin
import Foundation
import SkalmanWasmRuntime
import Testing
import WAT

@Suite("Skalman WebAssembly runtime")
struct SkalmanWasmRuntimeTests {
    @Test("Runs a WASI module without host authority")
    func registrationModule() throws {
        let module = try temporaryModule(
            #"""
            (module
              (func (export "_start")))
            """#
        )
        defer { try? FileManager.default.removeItem(at: module.deletingLastPathComponent()) }

        #expect(try SkalmanWasmRuntime.run(
            moduleURL: module,
            arguments: ["--skalman-register"],
            environment: [:],
            hostDescriptor: nil
        ) == 0)
    }

    @Test("Forwards the sole host import over the broker descriptor")
    func hostExchange() async throws {
        let request = "GET /v1/storage/kv HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
        let module = try temporaryModule(
            """
            (module
              (import "skalman" "host_exchange"
                (func $exchange (param i32 i32 i32 i32) (result i32)))
              (memory (export "memory") 1)
              (data (i32.const 0) "\(watEscaped(request))")
              (func (export "_start")
                (if
                  (i32.ne
                    (call $exchange
                      (i32.const 0)
                      (i32.const \(request.utf8.count))
                      (i32.const 4096)
                      (i32.const 4096))
                    (i32.const \(response.utf8.count)))
                  (then unreachable))))
            """
        )
        defer { try? FileManager.default.removeItem(at: module.deletingLastPathComponent()) }

        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let serverDescriptor = descriptors[0]
        let guestDescriptor = descriptors[1]
        defer {
            close(serverDescriptor)
            close(guestDescriptor)
        }

        let server = Task.detached { @Sendable () -> Bool in
            var bytes = [UInt8](repeating: 0, count: request.utf8.count)
            var offset = 0
            while offset < bytes.count {
                let readCount = bytes.withUnsafeMutableBytes { raw in
                    Darwin.read(
                        serverDescriptor,
                        raw.baseAddress.map { $0 + offset },
                        raw.count - offset
                    )
                }
                guard readCount > 0 else { return false }
                offset += readCount
            }
            guard String(decoding: bytes, as: UTF8.self) == request else { return false }
            return response.withCString { pointer in
                Darwin.write(serverDescriptor, pointer, response.utf8.count)
                    == response.utf8.count
            }
        }

        #expect(try SkalmanWasmRuntime.run(
            moduleURL: module,
            arguments: ["--skalman-serve"],
            environment: [:],
            hostDescriptor: guestDescriptor
        ) == 0)
        #expect(await server.value)
    }

    @Test("A registration guest cannot call the host")
    func registrationHostCallFailsClosed() throws {
        let module = try temporaryModule(
            #"""
            (module
              (import "skalman" "host_exchange"
                (func $exchange (param i32 i32 i32 i32) (result i32)))
              (memory (export "memory") 1)
              (func (export "_start")
                (if
                  (i32.ne
                    (call $exchange
                      (i32.const 0) (i32.const 0)
                      (i32.const 16) (i32.const 16))
                    (i32.const -1))
                  (then unreachable))))
            """#
        )
        defer { try? FileManager.default.removeItem(at: module.deletingLastPathComponent()) }

        #expect(try SkalmanWasmRuntime.run(
            moduleURL: module,
            arguments: ["--skalman-register"],
            environment: [:],
            hostDescriptor: nil
        ) == 0)
    }

    private func temporaryModule(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("fixture.wasm")
        try Data(wat2wasm(source)).write(to: url)
        return url
    }

    private func watEscaped(_ value: String) -> String {
        value.utf8.map { String(format: "\\%02x", $0) }.joined()
    }
}
