//
//  Locked.swift
//  SwiftTerm
//
//  A small synchronized state container for state that does not require the
//  FIFO fairness guarantee of TerminalLock.
//

import Foundation
#if canImport(Synchronization)
import Synchronization
#endif

/// Owns one value behind a non-recursive lock.
///
/// The unchecked conformance is limited to this synchronization primitive.
/// Callers must not expose mutable value storage from `withLock`. They can copy
/// a stable reference when that reference has separate synchronization and
/// does not escape the owning API.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init (_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result> (_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private protocol VoidCallbackStorage: Sendable {
    func replace(with body: (@Sendable () -> Void)?)
    var current: (@Sendable () -> Void)? { get }
    func call()
}

private final class NSLockedVoidCallbackStorage: VoidCallbackStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    init(_ body: (@Sendable () -> Void)? = nil) {
        callback = body
    }

    func replace(with body: (@Sendable () -> Void)?) {
        lock.lock()
        callback = body
        lock.unlock()
    }

    /// Returns the callback for APIs that must expose a stored function.
    var current: (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return callback
    }

    func call() {
        lock.lock()
        let current = callback
        lock.unlock()
        current?()
    }
}

#if canImport(Synchronization)
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private final class MutexVoidCallbackStorage: VoidCallbackStorage, Sendable {
    private final class Callback: Sendable {
        let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        func call() {
            body()
        }
    }

    private let callback: Mutex<Callback?>

    init(_ body: (@Sendable () -> Void)? = nil) {
        callback = Mutex(body.map(Callback.init))
    }

    func replace(with body: (@Sendable () -> Void)?) {
        let next = body.map(Callback.init)
        callback.withLock { $0 = next }
    }

    var current: (@Sendable () -> Void)? {
        callback.withLock { $0 }?.body
    }

    func call() {
        let current = callback.withLock { $0 }
        current?.call()
    }
}
#endif

/// Stores a replaceable callback without passing the function value through a
/// generic container. Uses `Mutex` when the build and runtime support it, and
/// falls back to `NSLock` on older systems.
final class LockedVoidCallback: Sendable {
    private let storage: any VoidCallbackStorage

    init(_ body: (@Sendable () -> Void)? = nil) {
#if canImport(Synchronization)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            storage = MutexVoidCallbackStorage(body)
        } else {
            storage = NSLockedVoidCallbackStorage(body)
        }
#else
        storage = NSLockedVoidCallbackStorage(body)
#endif
    }

    func replace(with body: (@Sendable () -> Void)?) {
        storage.replace(with: body)
    }

    /// Returns the callback for APIs that must expose a stored function.
    var current: (@Sendable () -> Void)? {
        storage.current
    }

    func call() {
        storage.call()
    }
}

private final class BytesCallback: Sendable {
    let body: @Sendable ([UInt8]) -> Void

    init(_ body: @escaping @Sendable ([UInt8]) -> Void) {
        self.body = body
    }

    func call(slice bytes: ArraySlice<UInt8>) {
        body(Array(bytes))
    }

    func call(borrowed bytes: Span<UInt8>) {
        body(bytes.copiedBytes())
    }
}

private protocol BytesCallbackStorage: Sendable {
    func replace(with callback: BytesCallback?)
    func call(slice bytes: ArraySlice<UInt8>)
    func call(borrowed bytes: Span<UInt8>)
}

private final class NSLockedBytesCallbackStorage: BytesCallbackStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: BytesCallback?

    init(_ callback: BytesCallback? = nil) {
        self.callback = callback
    }

    func replace(with callback: BytesCallback?) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func call(slice bytes: ArraySlice<UInt8>) {
        current()?.call(slice: bytes)
    }

    func call(borrowed bytes: Span<UInt8>) {
        current()?.call(borrowed: bytes)
    }

    private func current() -> BytesCallback? {
        lock.lock()
        defer { lock.unlock() }
        return callback
    }
}

#if canImport(Synchronization)
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private final class MutexBytesCallbackStorage: BytesCallbackStorage, Sendable {
    private let callback: Mutex<BytesCallback?>

    init(_ callback: BytesCallback? = nil) {
        self.callback = Mutex(callback)
    }

    func replace(with callback: BytesCallback?) {
        self.callback.withLock { $0 = callback }
    }

    func call(slice bytes: ArraySlice<UInt8>) {
        callback.withLock { $0 }?.call(slice: bytes)
    }

    func call(borrowed bytes: Span<UInt8>) {
        callback.withLock { $0 }?.call(borrowed: bytes)
    }
}
#endif

/// Stores a replaceable owned-byte callback without ever returning its function value through
/// ``Locked.withLock(_:)``.
///
/// The stable `BytesCallback` reference is load-bearing. Repeatedly returning a raw function from
/// a generic synchronized container can wrap its stored representation in another reabstraction
/// thunk on each read in Swift 6.2 builds, eventually overflowing the reader thread's
/// stack. Both storage implementations copy a stable reference under their lock, release the lock,
/// and only then copy and deliver the bytes. A nil callback therefore still makes no byte copy.
final class LockedBytesCallback: Sendable {
    private let storage: any BytesCallbackStorage

    init(_ body: (@Sendable ([UInt8]) -> Void)? = nil) {
        let callback = body.map(BytesCallback.init)
#if canImport(Synchronization)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            storage = MutexBytesCallbackStorage(callback)
        } else {
            storage = NSLockedBytesCallbackStorage(callback)
        }
#else
        storage = NSLockedBytesCallbackStorage(callback)
#endif
    }

    func replace(with body: (@Sendable ([UInt8]) -> Void)?) {
        storage.replace(with: body.map(BytesCallback.init))
    }

    func call(slice bytes: ArraySlice<UInt8>) {
        storage.call(slice: bytes)
    }

    func call(borrowed bytes: Span<UInt8>) {
        storage.call(borrowed: bytes)
    }
}
