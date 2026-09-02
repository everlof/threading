//
//  SIMDLineScanner.swift
//  TimberLineParser
//
//  Ultra-fast newline detection using SIMD operations.
//  Processes 32 bytes at a time instead of byte-by-byte.
//
//  Performance notes (benchmarked Dec 2025):
//  - Release mode: ~2ms for 5MB (~2.5 GB/s throughput)
//  - Debug mode is ~100x slower due to no optimization
//
//  Key optimizations:
//  - withUnsafeBytes: avoids copying Data to [UInt8] (was 56% of time!)
//  - loadUnaligned: single instruction to load 32 bytes into SIMD vector
//  - UnsafeMutableBufferPointer: direct memory writes, no append overhead
//  - Unrolled mask extraction: compiler can optimize 32 conditionals
//
//  Approaches tried but didn't help further:
//  - ContiguousArray: no benefit over Array with reserveCapacity
//  - Separate extractPositions function: inlining was same speed
//  - The 32 conditional checks are unavoidable without platform-specific intrinsics
//

import Foundation

/// Ultra-fast newline detection using SIMD operations
public struct SIMDLineScanner {

    /// Find all newline positions in data using SIMD
    /// Returns array of byte offsets where newlines occur
    public static func findNewlines(in data: Data) -> [Int] {
        let count = data.count
        guard count > 0 else { return [] }

        // Allocate buffer with generous capacity - direct pointer access, no append overhead
        let capacity = count / 40 + 32  // Overestimate to avoid reallocation
        let buffer = UnsafeMutableBufferPointer<Int>.allocate(capacity: capacity)
        var writeIndex = 0

        data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return }
            let ptr = basePtr.assumingMemoryBound(to: UInt8.self)

            var i = 0
            let newlineVector = SIMD32<UInt8>(repeating: 0x0A)

            // Process 32 bytes at a time
            while i + 32 <= count {
                let chunk = loadSIMD32(from: ptr, at: i)
                let mask = chunk .== newlineVector

                if anyTrue(mask) {
                    // Write directly to buffer - no bounds checking, no append overhead
                    if mask[0] { buffer[writeIndex] = i; writeIndex += 1 }
                    if mask[1] { buffer[writeIndex] = i + 1; writeIndex += 1 }
                    if mask[2] { buffer[writeIndex] = i + 2; writeIndex += 1 }
                    if mask[3] { buffer[writeIndex] = i + 3; writeIndex += 1 }
                    if mask[4] { buffer[writeIndex] = i + 4; writeIndex += 1 }
                    if mask[5] { buffer[writeIndex] = i + 5; writeIndex += 1 }
                    if mask[6] { buffer[writeIndex] = i + 6; writeIndex += 1 }
                    if mask[7] { buffer[writeIndex] = i + 7; writeIndex += 1 }
                    if mask[8] { buffer[writeIndex] = i + 8; writeIndex += 1 }
                    if mask[9] { buffer[writeIndex] = i + 9; writeIndex += 1 }
                    if mask[10] { buffer[writeIndex] = i + 10; writeIndex += 1 }
                    if mask[11] { buffer[writeIndex] = i + 11; writeIndex += 1 }
                    if mask[12] { buffer[writeIndex] = i + 12; writeIndex += 1 }
                    if mask[13] { buffer[writeIndex] = i + 13; writeIndex += 1 }
                    if mask[14] { buffer[writeIndex] = i + 14; writeIndex += 1 }
                    if mask[15] { buffer[writeIndex] = i + 15; writeIndex += 1 }
                    if mask[16] { buffer[writeIndex] = i + 16; writeIndex += 1 }
                    if mask[17] { buffer[writeIndex] = i + 17; writeIndex += 1 }
                    if mask[18] { buffer[writeIndex] = i + 18; writeIndex += 1 }
                    if mask[19] { buffer[writeIndex] = i + 19; writeIndex += 1 }
                    if mask[20] { buffer[writeIndex] = i + 20; writeIndex += 1 }
                    if mask[21] { buffer[writeIndex] = i + 21; writeIndex += 1 }
                    if mask[22] { buffer[writeIndex] = i + 22; writeIndex += 1 }
                    if mask[23] { buffer[writeIndex] = i + 23; writeIndex += 1 }
                    if mask[24] { buffer[writeIndex] = i + 24; writeIndex += 1 }
                    if mask[25] { buffer[writeIndex] = i + 25; writeIndex += 1 }
                    if mask[26] { buffer[writeIndex] = i + 26; writeIndex += 1 }
                    if mask[27] { buffer[writeIndex] = i + 27; writeIndex += 1 }
                    if mask[28] { buffer[writeIndex] = i + 28; writeIndex += 1 }
                    if mask[29] { buffer[writeIndex] = i + 29; writeIndex += 1 }
                    if mask[30] { buffer[writeIndex] = i + 30; writeIndex += 1 }
                    if mask[31] { buffer[writeIndex] = i + 31; writeIndex += 1 }
                }

                i += 32
            }

            // Handle remaining bytes
            while i < count {
                if ptr[i] == 0x0A {
                    buffer[writeIndex] = i
                    writeIndex += 1
                }
                i += 1
            }
        }

        // Create array from buffer and deallocate
        let result = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: writeIndex))
        buffer.deallocate()
        return result
    }

    /// Load 32 bytes into a SIMD vector directly from memory
    @inline(__always)
    private static func loadSIMD32(from ptr: UnsafePointer<UInt8>, at offset: Int) -> SIMD32<UInt8> {
        // Load directly from memory - this compiles to a single vector load instruction
        let loadPtr = UnsafeRawPointer(ptr + offset)
        return loadPtr.loadUnaligned(as: SIMD32<UInt8>.self)
    }

    /// Check if any lane in the mask is true
    @inline(__always)
    private static func anyTrue(_ mask: SIMDMask<SIMD32<UInt8>.MaskStorage>) -> Bool {
        // Select 1s where mask is true, then sum - non-zero means at least one match
        let ones = SIMD32<UInt8>(repeating: 1)
        let zeros = SIMD32<UInt8>(repeating: 0)
        let selected = ones.replacing(with: zeros, where: .!mask)
        return selected.wrappedSum() != 0
    }

    /// Convert newline positions to line ranges
    /// Each range is (start, end) where end excludes the newline
    public static func newlinesToRanges(_ newlinePositions: [Int], totalLength: Int) -> [(start: Int, end: Int)] {
        guard !newlinePositions.isEmpty else {
            if totalLength > 0 {
                return [(0, totalLength)]
            }
            return []
        }

        var ranges: [(start: Int, end: Int)] = []
        ranges.reserveCapacity(newlinePositions.count + 1)

        var lineStart = 0

        for nlPos in newlinePositions {
            ranges.append((lineStart, nlPos))
            lineStart = nlPos + 1
        }

        if lineStart < totalLength {
            ranges.append((lineStart, totalLength))
        }

        return ranges
    }
}
