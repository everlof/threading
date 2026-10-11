import Foundation

/// One H.264 access unit (a picture) ready for VideoToolbox: its NAL units in AVCC form, each
/// behind a four-byte big-endian length, with the parameter sets in force when it began.
public struct H264AccessUnit: Equatable, Sendable {
    public let avcc: [UInt8]
    public let sequenceParameterSet: [UInt8]?
    public let pictureParameterSet: [UInt8]?
    public let isKeyFrame: Bool
    /// True when this unit carries parameter sets that differ from the previous unit's, so the
    /// decoder must be reconfigured before it.
    public let parameterSetsChanged: Bool
}

/// Splits `screenrecord --output-format=h264`'s Annex-B byte stream into access units.
///
/// A NAL's end is only known when the next start code arrives, and `screenrecord` writes a
/// frame only when the screen changes, so the last picture of a burst would otherwise wait for
/// the next change. `flush()` declares the buffered tail complete; the reader calls it when the
/// pipe goes quiet, which is how a still screen still shows its final frame.
public struct AnnexBStream: Sendable {
    public static let maximumAccessUnitBytes = 8 * 1024 * 1024

    public enum Failure: Error, Equatable, Sendable { case accessUnitTooLarge }

    private var buffer: [UInt8] = []
    private var currentNALs: [[UInt8]] = []
    private var currentHasPicture = false
    private var sequenceParameterSet: [UInt8]?
    private var pictureParameterSet: [UInt8]?
    private var deliveredSPS: [UInt8]?
    private var deliveredPPS: [UInt8]?

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [H264AccessUnit] {
        buffer.append(contentsOf: bytes)
        guard buffer.count <= Self.maximumAccessUnitBytes else { throw Failure.accessUnitTooLarge }
        var units: [H264AccessUnit] = []
        // Every NAL that has a following start code is complete.
        var starts = Self.startCodes(in: buffer)
        guard starts.count >= 2 else { return units }
        let tailStart = starts.removeLast()
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].offset : tailStart.offset
            let nal = Array(buffer[(start.offset + start.length)..<end])
            if let unit = accept(Self.trimmedTrailingZeros(nal)) { units.append(unit) }
        }
        buffer.removeFirst(tailStart.offset)
        return units
    }

    /// Treats everything buffered as complete and returns the access units that closes: the
    /// picture the tail NAL ended, then the tail's own picture.
    public mutating func flush() -> [H264AccessUnit] {
        var units: [H264AccessUnit] = []
        if let start = Self.startCodes(in: buffer).first {
            let nal = Self.trimmedTrailingZeros(Array(buffer[(start.offset + start.length)...]))
            buffer.removeAll()
            if let unit = accept(nal) { units.append(unit) }
        }
        if let unit = finishUnit() { units.append(unit) }
        return units
    }

    // MARK: - Private

    /// Adds one complete NAL; returns the unit it closed when it begins a new one.
    private mutating func accept(_ nal: [UInt8]) -> H264AccessUnit? {
        guard let header = nal.first else { return nil }
        let type = header & 0x1F
        var closed: H264AccessUnit?
        let isPicture = type == 1 || type == 5
        // A new picture starts with an AUD, SPS/PPS/SEI after a picture, or a slice whose
        // first_mb_in_slice is zero (its first Exp-Golomb bit is 1).
        let startsNewUnit = currentHasPicture && (
            type == 9 || type == 7 || type == 8 || type == 6
                || (isPicture && nal.count > 1 && nal[1] & 0x80 != 0)
        )
        if startsNewUnit { closed = finishUnit() }
        switch type {
        case 7: sequenceParameterSet = nal
        case 8: pictureParameterSet = nal
        case 9: break // Access unit delimiters carry nothing VideoToolbox needs.
        default:
            currentNALs.append(nal)
            if isPicture { currentHasPicture = true }
        }
        return closed
    }

    private mutating func finishUnit() -> H264AccessUnit? {
        defer {
            currentNALs.removeAll()
            currentHasPicture = false
        }
        guard currentHasPicture else { return nil }
        var avcc: [UInt8] = []
        var keyFrame = false
        for nal in currentNALs {
            avcc += BigEndian.bytes(UInt32(nal.count)) + nal
            if nal[0] & 0x1F == 5 { keyFrame = true }
        }
        let changed = sequenceParameterSet != deliveredSPS || pictureParameterSet != deliveredPPS
        deliveredSPS = sequenceParameterSet
        deliveredPPS = pictureParameterSet
        return H264AccessUnit(
            avcc: avcc, sequenceParameterSet: sequenceParameterSet, pictureParameterSet: pictureParameterSet,
            isKeyFrame: keyFrame, parameterSetsChanged: changed
        )
    }

    static func startCodes(in bytes: [UInt8]) -> [(offset: Int, length: Int)] {
        var result: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    if index > 0, bytes[index - 1] == 0 {
                        result.append((index - 1, 4))
                    } else {
                        result.append((index, 3))
                    }
                    index += 3
                    continue
                }
            }
            index += 1
        }
        return result
    }

    private static func trimmedTrailingZeros(_ nal: [UInt8]) -> [UInt8] {
        var end = nal.count
        while end > 1, nal[end - 1] == 0 { end -= 1 }
        return end == nal.count ? nal : Array(nal[..<end])
    }
}
