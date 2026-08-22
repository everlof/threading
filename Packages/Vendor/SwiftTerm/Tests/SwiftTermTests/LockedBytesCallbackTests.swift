import Dispatch
import Testing
@testable import SwiftTerm

struct LockedBytesCallbackTests {
    @Test func repeatedCallsDoNotGrowTheCallbackStack() {
        let addresses = Locked<[UInt]>([])
        let deliveredCounts = Locked<[Int]>([])
        let callback = LockedBytesCallback { bytes in
            var marker = 0
            let address = withUnsafePointer(to: &marker) {
                UInt(bitPattern: $0)
            }
            addresses.withLock { $0.append(address) }
            deliveredCounts.withLock { $0.append(bytes.count) }
        }
        let payload: [UInt8] = [0x1b, 0x5b, 0x32, 0x4a]

        for _ in 0..<1_000 {
            callback.call(slice: payload[...])
        }

        let samples = addresses.withLock { $0 }
        let first = samples.first ?? 0
        let last = samples.last ?? 0
        let stackGrowth = first > last ? first - last : last - first

        #expect(samples.count == 1_000)
        #expect(deliveredCounts.withLock { $0 } == Array(repeating: payload.count, count: 1_000))
        #expect(
            stackGrowth < 4_096,
            "callback stack grew by \(stackGrowth) bytes")
    }

    @Test func callbackCanReplaceItself() {
        let callback = LockedBytesCallback()
        let deliveries = Locked<[[UInt8]]>([])
        callback.replace { bytes in
            deliveries.withLock { $0.append(bytes) }
            callback.replace(with: nil)
        }

        let payload: [UInt8] = [1, 2, 3]
        callback.call(slice: payload[...])
        callback.call(slice: payload[...])

        #expect(deliveries.withLock { $0 } == [payload])
    }

    @Test func concurrentCallsAndReplacementsRemainSafe() {
        let callback = LockedBytesCallback()
        let deliveries = Locked(0)
        let body: @Sendable ([UInt8]) -> Void = { bytes in
            deliveries.withLock { $0 += bytes.count }
        }
        let payload: [UInt8] = [1, 2, 3, 4]

        DispatchQueue.concurrentPerform(iterations: 10_000) { iteration in
            if iteration.isMultiple(of: 8) {
                callback.replace(with: iteration.isMultiple(of: 16) ? nil : body)
            } else {
                callback.call(slice: payload[...])
            }
        }

        callback.replace(with: body)
        callback.call(slice: payload[...])
        #expect(deliveries.withLock { $0 } >= payload.count)
    }
}
