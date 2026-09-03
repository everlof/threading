//
//  TimestampParser.swift
//  TimberLineParser
//
//  High-performance byte-level timestamp parsing without regex or DateFormatter.
//
//  Performance notes (benchmarked Dec 2025):
//  - Quick format detection: check char at position 10 ('T' for ISO8601, ' ' for simple)
//    to skip directly to the right parser instead of trying all 7 formats
//  - UnsafePointer eliminates array bounds checking in hot paths
//  - Cached timezone offset and current year (computed once at load time)
//  - Result: 92% faster (1.1s → 0.087s for 1M parses)
//
//  Format detection order optimized for common log formats:
//  1. YYYY-MM-DDT... (ISO8601) - position 10 = 'T'
//  2. YYYY-MM-DD ... (simple)  - position 10 = ' '
//  3. [YYYY-...      (bracketed) - position 0 = '['
//  4. Other formats fall back to sequential checking
//

import Foundation

/// High-performance timestamp parser using direct byte operations
public enum TimestampParser {

    /// Quick check if a line likely has a timestamp (fast, may have false negatives)
    /// This is used for multiline detection - we want to know if a line starts with a timestamp
    public static func hasTimestamp(bytes: [UInt8]) -> Bool {
        guard bytes.count >= 10 else { return false }

        return bytes.withUnsafeBufferPointer { buffer in
            let ptr = buffer.baseAddress!
            let count = buffer.count

            // Check for YYYY-MM-DD pattern at start (most common formats)
            if count >= 10 &&
               isDigit(ptr[0]) && isDigit(ptr[1]) && isDigit(ptr[2]) && isDigit(ptr[3]) &&
               ptr[4] == 0x2D && // '-'
               isDigit(ptr[5]) && isDigit(ptr[6]) &&
               ptr[7] == 0x2D && // '-'
               isDigit(ptr[8]) && isDigit(ptr[9]) {
                return true
            }

            // Check for bracketed: [YYYY-...
            if ptr[0] == 0x5B && count >= 11 && // '['
               isDigit(ptr[1]) && isDigit(ptr[2]) && isDigit(ptr[3]) && isDigit(ptr[4]) &&
               (ptr[5] == 0x2D || ptr[5] == 0x2F) { // '-' or '/'
                return true
            }

            // Check for syslog style: Nov 21 or Jan  5
            if count >= 6 &&
               isAlpha(ptr[0]) && isLowerAlpha(ptr[1]) && isLowerAlpha(ptr[2]) &&
               ptr[3] == 0x20 { // space
                return true
            }

            // Check for year prefix syslog: 2024 Nov 21
            if count >= 9 &&
               isDigit(ptr[0]) && isDigit(ptr[1]) && isDigit(ptr[2]) && isDigit(ptr[3]) &&
               ptr[4] == 0x20 && // space
               isAlpha(ptr[5]) && isLowerAlpha(ptr[6]) && isLowerAlpha(ptr[7]) {
                return true
            }

            // Check for Android logcat: MM-DD HH:MM:SS
            if count >= 14 &&
               isDigit(ptr[0]) && isDigit(ptr[1]) &&
               ptr[2] == 0x2D && // '-'
               isDigit(ptr[3]) && isDigit(ptr[4]) &&
               ptr[5] == 0x20 && // space
               isDigit(ptr[6]) && isDigit(ptr[7]) &&
               ptr[8] == 0x3A { // ':'
                return true
            }

            // Check for US datetime: MM/DD/YYYY
            if count >= 10 &&
               isDigit(ptr[0]) &&
               (ptr[1] == 0x2F || (isDigit(ptr[1]) && ptr[2] == 0x2F)) { // 'M/' or 'MM/'
                return true
            }

            // Check for Apache CLF: DD/Mon/YYYY
            if count >= 11 &&
               isDigit(ptr[0]) &&
               (ptr[1] == 0x2F || (isDigit(ptr[1]) && ptr[2] == 0x2F)) && // 'D/' or 'DD/'
               isAlpha(ptr[3]) || (isDigit(ptr[1]) && isAlpha(ptr[3])) {
                return true
            }

            return false
        }
    }

    /// Try all timestamp formats and return (date, format) if found
    public static func tryAllTimestampFormats(bytes: [UInt8]) -> (Date?, TimestampFormat?) {
        guard bytes.count >= 10 else { return (nil, nil) }

        return bytes.withUnsafeBufferPointer { buffer in
            tryAllTimestampFormatsUnsafe(buffer: buffer)
        }
    }

    /// Fast path using UnsafeBufferPointer
    @inline(__always)
    private static func tryAllTimestampFormatsUnsafe(buffer: UnsafeBufferPointer<UInt8>) -> (Date?, TimestampFormat?) {
        let ptr = buffer.baseAddress!
        let count = buffer.count

        // Quick format detection based on character at position 10
        // Most common formats: YYYY-MM-DD followed by 'T' (ISO8601) or ' ' (simple)
        if count >= 19 {
            // Check for YYYY-MM-DD pattern at start
            if isDigit(ptr[0]) && isDigit(ptr[1]) && isDigit(ptr[2]) && isDigit(ptr[3]) &&
               ptr[4] == 0x2D && isDigit(ptr[5]) && isDigit(ptr[6]) &&
               ptr[7] == 0x2D && isDigit(ptr[8]) && isDigit(ptr[9]) {

                let separator = ptr[10]
                if separator == 0x54 { // 'T' - ISO8601
                    if let date = parseISO8601Unsafe(ptr: ptr, count: count, startIdx: 0) {
                        return (date, .iso8601)
                    }
                } else if separator == 0x20 { // ' ' - Simple datetime
                    if let date = parseSimpleDatetimeUnsafe(ptr: ptr, count: count, startIdx: 0) {
                        return (date, .simple)
                    }
                }
            }

            // Check for bracketed: [YYYY-...
            if ptr[0] == 0x5B && isDigit(ptr[1]) {
                if let date = parseBracketedDatetimeUnsafe(ptr: ptr, count: count) {
                    return (date, .bracketed)
                }
            }
        }

        // Fall back to trying each format (for less common formats or offset starts)
        if let date = parseISO8601Unsafe(ptr: ptr, count: count, startIdx: nil) {
            return (date, .iso8601)
        }
        if let date = parseSimpleDatetimeUnsafe(ptr: ptr, count: count, startIdx: nil) {
            return (date, .simple)
        }
        if let date = parseBracketedDatetimeUnsafe(ptr: ptr, count: count) {
            return (date, .bracketed)
        }
        if let date = parseSyslogTimestampUnsafe(ptr: ptr, count: count) {
            return (date, .syslog)
        }
        if let date = parseAndroidLogcatUnsafe(ptr: ptr, count: count) {
            return (date, .androidLogcat)
        }
        if let date = parseUSDatetimeUnsafe(ptr: ptr, count: count) {
            return (date, .usDatetime)
        }
        if let date = parseApacheCLFUnsafe(ptr: ptr, count: count) {
            return (date, .apacheCLF)
        }
        return (nil, nil)
    }

    /// Parse timestamp using a specific known format
    public static func parseTimestamp(bytes: [UInt8], format: TimestampFormat) -> Date? {
        switch format {
        case .iso8601: return parseISO8601(bytes: bytes)
        case .simple: return parseSimpleDatetime(bytes: bytes)
        case .bracketed: return parseBracketedDatetime(bytes: bytes)
        case .apacheCLF: return parseApacheCLF(bytes: bytes)
        case .androidLogcat: return parseAndroidLogcat(bytes: bytes)
        case .usDatetime: return parseUSDatetime(bytes: bytes)
        case .syslog: return parseSyslogTimestamp(bytes: bytes)
        case .unknown: return nil
        }
    }

    // MARK: - ISO8601: 2024-01-15T10:30:45Z or 2024-01-15T10:30:45.123+02:00

    private static func parseISO8601(bytes: [UInt8]) -> Date? {
        guard let startIdx = findISO8601Start(bytes: bytes) else { return nil }
        let slice = bytes[startIdx...]
        guard slice.count >= 19 else { return nil }
        guard slice[slice.startIndex + 10] == 0x54 else { return nil }
        return parseISO8601Components(slice: slice)
    }

    private static func findISO8601Start(bytes: [UInt8]) -> Int? {
        let count = bytes.count
        guard count >= 19 else { return nil }

        for i in 0..<min(count - 18, 50) {
            if isDigit(bytes[i]) && isDigit(bytes[i+1]) && isDigit(bytes[i+2]) && isDigit(bytes[i+3]) &&
               bytes[i+4] == 0x2D &&
               isDigit(bytes[i+5]) && isDigit(bytes[i+6]) &&
               bytes[i+7] == 0x2D &&
               isDigit(bytes[i+8]) && isDigit(bytes[i+9]) &&
               bytes[i+10] == 0x54 {
                return i
            }
        }
        return nil
    }

    private static func parseISO8601Components(slice: ArraySlice<UInt8>) -> Date? {
        let base = slice.startIndex

        let year = parseDigits4(slice, at: base)
        let month = parseDigits2(slice, at: base + 5)
        let day = parseDigits2(slice, at: base + 8)
        let hour = parseDigits2(slice, at: base + 11)
        let minute = parseDigits2(slice, at: base + 14)
        let second = parseDigits2(slice, at: base + 17)

        guard year > 0, month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        var nanoseconds: Int = 0
        var offset = 19
        if base + offset < slice.endIndex && slice[base + offset] == 0x2E {
            offset += 1
            var frac = 0
            var digits = 0
            while base + offset < slice.endIndex && isDigit(slice[base + offset]) {
                frac = frac * 10 + Int(slice[base + offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        var tzOffset: Int = 0
        if base + offset < slice.endIndex {
            let tzByte = slice[base + offset]
            if tzByte == 0x5A {
                tzOffset = 0
            } else if tzByte == 0x2B || tzByte == 0x2D {
                let sign = tzByte == 0x2B ? 1 : -1
                if base + offset + 3 <= slice.endIndex {
                    let tzHour = parseDigits2(slice, at: base + offset + 1)
                    var tzMinute = 0
                    if base + offset + 6 <= slice.endIndex && slice[base + offset + 3] == 0x3A {
                        tzMinute = parseDigits2(slice, at: base + offset + 4)
                    } else if base + offset + 5 <= slice.endIndex {
                        tzMinute = parseDigits2(slice, at: base + offset + 3)
                    }
                    tzOffset = sign * (tzHour * 3600 + tzMinute * 60)
                }
            }
        }

        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: tzOffset)
    }

    // Unsafe wrapper for ISO8601 - delegates to array-based for now
    @inline(__always)
    private static func parseISO8601Unsafe(ptr: UnsafePointer<UInt8>, count: Int, startIdx: Int?) -> Date? {
        // For fast path (startIdx provided), parse directly
        if let start = startIdx {
            guard start + 19 <= count else { return nil }
            guard ptr[start + 10] == 0x54 else { return nil }
            return parseISO8601ComponentsUnsafe(ptr: ptr, count: count, base: start)
        }
        // Fall back to scanning
        guard let start = findISO8601StartUnsafe(ptr: ptr, count: count) else { return nil }
        return parseISO8601ComponentsUnsafe(ptr: ptr, count: count, base: start)
    }

    @inline(__always)
    private static func findISO8601StartUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Int? {
        guard count >= 19 else { return nil }
        for i in 0..<min(count - 18, 50) {
            if isDigit(ptr[i]) && isDigit(ptr[i+1]) && isDigit(ptr[i+2]) && isDigit(ptr[i+3]) &&
               ptr[i+4] == 0x2D &&
               isDigit(ptr[i+5]) && isDigit(ptr[i+6]) &&
               ptr[i+7] == 0x2D &&
               isDigit(ptr[i+8]) && isDigit(ptr[i+9]) &&
               ptr[i+10] == 0x54 {
                return i
            }
        }
        return nil
    }

    @inline(__always)
    private static func parseISO8601ComponentsUnsafe(ptr: UnsafePointer<UInt8>, count: Int, base: Int) -> Date? {
        let year = parseDigits4Unsafe(ptr: ptr, at: base)
        let month = parseDigits2Unsafe(ptr: ptr, at: base + 5)
        let day = parseDigits2Unsafe(ptr: ptr, at: base + 8)
        let hour = parseDigits2Unsafe(ptr: ptr, at: base + 11)
        let minute = parseDigits2Unsafe(ptr: ptr, at: base + 14)
        let second = parseDigits2Unsafe(ptr: ptr, at: base + 17)

        guard year > 0, month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        var nanoseconds: Int = 0
        var offset = base + 19
        if offset < count && ptr[offset] == 0x2E {
            offset += 1
            var frac = 0
            var digits = 0
            while offset < count && isDigit(ptr[offset]) {
                frac = frac * 10 + Int(ptr[offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        var tzOffset: Int = 0
        if offset < count {
            let tzByte = ptr[offset]
            if tzByte == 0x5A {
                tzOffset = 0
            } else if tzByte == 0x2B || tzByte == 0x2D {
                let sign = tzByte == 0x2B ? 1 : -1
                if offset + 3 <= count {
                    let tzHour = parseDigits2Unsafe(ptr: ptr, at: offset + 1)
                    var tzMinute = 0
                    if offset + 6 <= count && ptr[offset + 3] == 0x3A {
                        tzMinute = parseDigits2Unsafe(ptr: ptr, at: offset + 4)
                    } else if offset + 5 <= count {
                        tzMinute = parseDigits2Unsafe(ptr: ptr, at: offset + 3)
                    }
                    tzOffset = sign * (tzHour * 3600 + tzMinute * 60)
                }
            }
        }

        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: tzOffset)
    }

    // MARK: - Simple Datetime: 2024-01-15 10:30:45.123

    private static func parseSimpleDatetime(bytes: [UInt8]) -> Date? {
        guard let startIdx = findSimpleDatetimeStart(bytes: bytes) else { return nil }
        let slice = bytes[startIdx...]
        guard slice.count >= 19 else { return nil }
        guard slice[slice.startIndex + 10] == 0x20 else { return nil }
        return parseSimpleDatetimeComponents(slice: slice)
    }

    @inline(__always)
    private static func parseSimpleDatetimeUnsafe(ptr: UnsafePointer<UInt8>, count: Int, startIdx: Int?) -> Date? {
        let start: Int
        if let idx = startIdx {
            start = idx
        } else {
            guard let idx = findSimpleDatetimeStartUnsafe(ptr: ptr, count: count) else { return nil }
            start = idx
        }

        guard start + 19 <= count else { return nil }
        guard ptr[start + 10] == 0x20 else { return nil }

        return parseSimpleDatetimeComponentsUnsafe(ptr: ptr, count: count, base: start)
    }

    private static func findSimpleDatetimeStart(bytes: [UInt8]) -> Int? {
        let count = bytes.count
        guard count >= 19 else { return nil }

        for i in 0..<min(count - 18, 50) {
            if isDigit(bytes[i]) && isDigit(bytes[i+1]) && isDigit(bytes[i+2]) && isDigit(bytes[i+3]) &&
               bytes[i+4] == 0x2D &&
               isDigit(bytes[i+5]) && isDigit(bytes[i+6]) &&
               bytes[i+7] == 0x2D &&
               isDigit(bytes[i+8]) && isDigit(bytes[i+9]) &&
               bytes[i+10] == 0x20 {
                return i
            }
        }
        return nil
    }

    @inline(__always)
    private static func findSimpleDatetimeStartUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Int? {
        guard count >= 19 else { return nil }

        for i in 0..<min(count - 18, 50) {
            if isDigit(ptr[i]) && isDigit(ptr[i+1]) && isDigit(ptr[i+2]) && isDigit(ptr[i+3]) &&
               ptr[i+4] == 0x2D &&
               isDigit(ptr[i+5]) && isDigit(ptr[i+6]) &&
               ptr[i+7] == 0x2D &&
               isDigit(ptr[i+8]) && isDigit(ptr[i+9]) &&
               ptr[i+10] == 0x20 {
                return i
            }
        }
        return nil
    }

    private static func parseSimpleDatetimeComponents(slice: ArraySlice<UInt8>) -> Date? {
        let base = slice.startIndex

        let year = parseDigits4(slice, at: base)
        let month = parseDigits2(slice, at: base + 5)
        let day = parseDigits2(slice, at: base + 8)

        // Skip spaces between date and time (handle multiple spaces)
        var timeStart = base + 10
        while timeStart < slice.endIndex && slice[timeStart] == 0x20 {
            timeStart += 1
        }

        // Need at least 8 more chars for HH:MM:SS
        guard timeStart + 8 <= slice.endIndex else { return nil }

        let hour = parseDigits2(slice, at: timeStart)
        let minute = parseDigits2(slice, at: timeStart + 3)
        let second = parseDigits2(slice, at: timeStart + 6)

        guard year > 0, month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        var nanoseconds: Int = 0
        var offset = timeStart + 8 - base
        if base + offset < slice.endIndex &&
           (slice[base + offset] == 0x2E || slice[base + offset] == 0x2C) {
            offset += 1
            var frac = 0
            var digits = 0
            while base + offset < slice.endIndex && isDigit(slice[base + offset]) {
                frac = frac * 10 + Int(slice[base + offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        // Simple datetime without timezone - interpret in local timezone
        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: naiveStampOffsetSeconds)
    }

    @inline(__always)
    private static func parseSimpleDatetimeComponentsUnsafe(ptr: UnsafePointer<UInt8>, count: Int, base: Int) -> Date? {
        let year = parseDigits4Unsafe(ptr: ptr, at: base)
        let month = parseDigits2Unsafe(ptr: ptr, at: base + 5)
        let day = parseDigits2Unsafe(ptr: ptr, at: base + 8)

        // Skip spaces between date and time
        var timeStart = base + 11
        while timeStart < count && ptr[timeStart] == 0x20 {
            timeStart += 1
        }

        guard timeStart + 8 <= count else { return nil }

        let hour = parseDigits2Unsafe(ptr: ptr, at: timeStart)
        let minute = parseDigits2Unsafe(ptr: ptr, at: timeStart + 3)
        let second = parseDigits2Unsafe(ptr: ptr, at: timeStart + 6)

        guard year > 0, month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        var nanoseconds: Int = 0
        var offset = timeStart + 8
        if offset < count && (ptr[offset] == 0x2E || ptr[offset] == 0x2C) {
            offset += 1
            var frac = 0
            var digits = 0
            while offset < count && isDigit(ptr[offset]) {
                frac = frac * 10 + Int(ptr[offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds,
                       tzOffsetSeconds: trailingOffsetUnsafe(ptr: ptr, count: count, at: offset)
                           ?? naiveStampOffsetSeconds)
    }

    // MARK: - Bracketed Datetime: [2024-01-15 10:30:45]

    // Unsafe wrapper for Bracketed - quick check then delegate
    @inline(__always)
    private static func parseBracketedDatetimeUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Date? {
        guard count >= 21 else { return nil }
        // Quick check for [YYYY pattern
        guard ptr[0] == 0x5B && isDigit(ptr[1]) else {
            // Scan for bracket
            for i in 1..<min(count - 20, 20) {
                if ptr[i] == 0x5B && isDigit(ptr[i+1]) {
                    let dateStart = i + 1
                    guard dateStart + 19 <= count else { return nil }
                    return parseBracketedComponentsUnsafe(ptr: ptr, count: count, base: dateStart)
                }
            }
            return nil
        }
        return parseBracketedComponentsUnsafe(ptr: ptr, count: count, base: 1)
    }

    @inline(__always)
    private static func parseBracketedComponentsUnsafe(ptr: UnsafePointer<UInt8>, count: Int, base: Int) -> Date? {
        guard base + 19 <= count else { return nil }

        let year = parseDigits4Unsafe(ptr: ptr, at: base)
        let month = parseDigits2Unsafe(ptr: ptr, at: base + 5)
        let day = parseDigits2Unsafe(ptr: ptr, at: base + 8)
        let hour = parseDigits2Unsafe(ptr: ptr, at: base + 11)
        let minute = parseDigits2Unsafe(ptr: ptr, at: base + 14)
        let second = parseDigits2Unsafe(ptr: ptr, at: base + 17)

        guard year > 0, month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        var nanoseconds: Int = 0
        var offset = base + 19
        if offset < count && (ptr[offset] == 0x2E || ptr[offset] == 0x2C) {
            offset += 1
            var frac = 0
            var digits = 0
            while offset < count && isDigit(ptr[offset]) {
                frac = frac * 10 + Int(ptr[offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: naiveStampOffsetSeconds)
    }

    private static func parseBracketedDatetime(bytes: [UInt8]) -> Date? {
        guard let startIdx = findBracketedStart(bytes: bytes) else { return nil }
        let dateStart = startIdx + 1
        guard dateStart + 19 <= bytes.count else { return nil }
        let slice = bytes[dateStart...]
        return parseBracketedComponents(slice: slice)
    }

    private static func findBracketedStart(bytes: [UInt8]) -> Int? {
        let count = bytes.count
        guard count >= 21 else { return nil }

        for i in 0..<min(count - 20, 20) {
            if bytes[i] == 0x5B &&
               isDigit(bytes[i+1]) && isDigit(bytes[i+2]) && isDigit(bytes[i+3]) && isDigit(bytes[i+4]) {
                if bytes[i+5] == 0x2D || bytes[i+5] == 0x2F {
                    return i
                }
            }
        }
        return nil
    }

    private static func parseBracketedComponents(slice: ArraySlice<UInt8>) -> Date? {
        let base = slice.startIndex
        guard base + 19 <= slice.endIndex else { return nil }

        let year = parseDigits4(slice, at: base)
        let month = parseDigits2(slice, at: base + 5)
        let day = parseDigits2(slice, at: base + 8)
        let hour = parseDigits2(slice, at: base + 11)
        let minute = parseDigits2(slice, at: base + 14)
        let second = parseDigits2(slice, at: base + 17)

        guard year > 0, month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        var nanoseconds: Int = 0
        var offset = 19
        if base + offset < slice.endIndex &&
           (slice[base + offset] == 0x2E || slice[base + offset] == 0x2C) {
            offset += 1
            var frac = 0
            var digits = 0
            while base + offset < slice.endIndex && isDigit(slice[base + offset]) {
                frac = frac * 10 + Int(slice[base + offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        // Bracketed datetime without timezone - interpret in local timezone
        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: naiveStampOffsetSeconds)
    }

    // MARK: - Syslog: Nov 21 10:30:45 or 2024 Nov 21 10:30:45

    // Unsafe stubs - delegate to array-based implementations for less common formats
    @inline(__always)
    private static func parseSyslogTimestampUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Date? {
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: count))
        return parseSyslogTimestamp(bytes: bytes)
    }

    @inline(__always)
    private static func parseAndroidLogcatUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Date? {
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: count))
        return parseAndroidLogcat(bytes: bytes)
    }

    @inline(__always)
    private static func parseUSDatetimeUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Date? {
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: count))
        return parseUSDatetime(bytes: bytes)
    }

    @inline(__always)
    private static func parseApacheCLFUnsafe(ptr: UnsafePointer<UInt8>, count: Int) -> Date? {
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: count))
        return parseApacheCLF(bytes: bytes)
    }

    private static func parseSyslogTimestamp(bytes: [UInt8]) -> Date? {
        guard let (startIdx, hasYear) = findSyslogStart(bytes: bytes) else { return nil }
        let slice = bytes[startIdx...]
        return parseSyslogComponents(slice: slice, hasYear: hasYear)
    }

    private static func findSyslogStart(bytes: [UInt8]) -> (Int, Bool)? {
        let count = bytes.count
        guard count >= 15 else { return nil }

        for i in 0..<min(count - 14, 20) {
            var monthStart = i
            var hasYear = false

            if i + 5 < count &&
               isDigit(bytes[i]) && isDigit(bytes[i+1]) && isDigit(bytes[i+2]) && isDigit(bytes[i+3]) &&
               bytes[i+4] == 0x20 {
                monthStart = i + 5
                hasYear = true
            }

            if monthStart + 3 < count &&
               isAlpha(bytes[monthStart]) &&
               isLowerAlpha(bytes[monthStart + 1]) &&
               isLowerAlpha(bytes[monthStart + 2]) &&
               bytes[monthStart + 3] == 0x20 {
                let monthBytes = (bytes[monthStart], bytes[monthStart + 1], bytes[monthStart + 2])
                if parseMonthAbbrev(monthBytes) != nil {
                    return (i, hasYear)
                }
            }
        }
        return nil
    }

    private static func parseSyslogComponents(slice: ArraySlice<UInt8>, hasYear: Bool) -> Date? {
        var base = slice.startIndex

        var year: Int
        if hasYear {
            year = parseDigits4(slice, at: base)
            base += 5
        } else {
            year = cachedCurrentYear
        }

        guard base + 15 <= slice.endIndex else { return nil }

        let monthBytes = (slice[base], slice[base + 1], slice[base + 2])
        guard let month = parseMonthAbbrev(monthBytes) else { return nil }

        base += 4

        var day: Int
        var timeStart: Int
        if slice[base] == 0x20 {
            day = Int(slice[base + 1] - 0x30)
            timeStart = base + 3
        } else if isDigit(slice[base]) && slice[base + 1] == 0x20 {
            day = Int(slice[base] - 0x30)
            timeStart = base + 2
        } else {
            day = parseDigits2(slice, at: base)
            timeStart = base + 3
        }

        guard day >= 1, day <= 31 else { return nil }
        guard timeStart + 8 <= slice.endIndex else { return nil }

        let hour = parseDigits2(slice, at: timeStart)
        let minute = parseDigits2(slice, at: timeStart + 3)
        let second = parseDigits2(slice, at: timeStart + 6)

        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59, second >= 0, second <= 59 else {
            return nil
        }

        // `idevicesyslog` writes `Sep  1 16:21:01.549408` — six fractional digits that were being
        // dropped, so every row in a busy second collapsed onto the same instant and stopped
        // ordering. The clock column showed them all along; only the instant lost them.
        var nanoseconds = 0
        var after = timeStart + 8
        if after < slice.endIndex, slice[base + (after - base)] == 0x2E {
            after += 1
            var frac = 0
            var digits = 0
            while after < slice.endIndex, isDigit(slice[after]) {
                frac = frac * 10 + Int(slice[after] - 0x30)
                digits += 1
                after += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        // Syslog names no zone, so it takes the convention.
        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: naiveStampOffsetSeconds)
    }

    // MARK: - Android Logcat: 01-15 10:30:45.123

    private static func parseAndroidLogcat(bytes: [UInt8]) -> Date? {
        guard let startIdx = findAndroidLogcatStart(bytes: bytes) else { return nil }
        let slice = bytes[startIdx...]
        return parseAndroidLogcatComponents(slice: slice)
    }

    private static func findAndroidLogcatStart(bytes: [UInt8]) -> Int? {
        let count = bytes.count
        guard count >= 18 else { return nil }

        for i in 0..<min(count - 17, 20) {
            if isDigit(bytes[i]) && isDigit(bytes[i+1]) &&
               bytes[i+2] == 0x2D &&
               isDigit(bytes[i+3]) && isDigit(bytes[i+4]) &&
               bytes[i+5] == 0x20 &&
               isDigit(bytes[i+6]) && isDigit(bytes[i+7]) &&
               bytes[i+8] == 0x3A {
                return i
            }
        }
        return nil
    }

    private static func parseAndroidLogcatComponents(slice: ArraySlice<UInt8>) -> Date? {
        let base = slice.startIndex
        guard base + 18 <= slice.endIndex else { return nil }

        let month = parseDigits2(slice, at: base)
        let day = parseDigits2(slice, at: base + 3)
        let hour = parseDigits2(slice, at: base + 6)
        let minute = parseDigits2(slice, at: base + 9)
        let second = parseDigits2(slice, at: base + 12)

        guard month >= 1, month <= 12, day >= 1, day <= 31,
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        let year = cachedCurrentYear

        var nanoseconds: Int = 0
        if base + 15 <= slice.endIndex && slice[base + 14] == 0x2E {
            var frac = 0
            var digits = 0
            var offset = base + 15
            while offset < slice.endIndex && isDigit(slice[offset]) {
                frac = frac * 10 + Int(slice[offset] - 0x30)
                digits += 1
                offset += 1
            }
            while digits < 9 { frac *= 10; digits += 1 }
            while digits > 9 { frac /= 10; digits -= 1 }
            nanoseconds = frac
        }

        // Android logcat without timezone - interpret in local timezone
        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: nanoseconds, tzOffsetSeconds: naiveStampOffsetSeconds)
    }

    // MARK: - US Datetime: 01/15/2024 10:30:45

    private static func parseUSDatetime(bytes: [UInt8]) -> Date? {
        guard let startIdx = findUSDatetimeStart(bytes: bytes) else { return nil }
        let slice = bytes[startIdx...]
        return parseUSDatetimeComponents(slice: slice)
    }

    private static func findUSDatetimeStart(bytes: [UInt8]) -> Int? {
        let count = bytes.count
        guard count >= 17 else { return nil }

        for i in 0..<min(count - 16, 50) {
            if isDigit(bytes[i]) {
                var monthEnd = i + 1
                if i + 1 < count && isDigit(bytes[i + 1]) { monthEnd = i + 2 }

                if monthEnd < count && bytes[monthEnd] == 0x2F {
                    var dayEnd = monthEnd + 2
                    if monthEnd + 2 < count && isDigit(bytes[monthEnd + 2]) { dayEnd = monthEnd + 3 }

                    if dayEnd < count && bytes[dayEnd] == 0x2F {
                        if dayEnd + 5 < count &&
                           isDigit(bytes[dayEnd + 1]) && isDigit(bytes[dayEnd + 2]) &&
                           isDigit(bytes[dayEnd + 3]) && isDigit(bytes[dayEnd + 4]) &&
                           bytes[dayEnd + 5] == 0x20 {
                            return i
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func parseUSDatetimeComponents(slice: ArraySlice<UInt8>) -> Date? {
        let base = slice.startIndex

        var month: Int
        var dayStart: Int
        if slice[base + 1] == 0x2F {
            month = Int(slice[base] - 0x30)
            dayStart = base + 2
        } else {
            month = parseDigits2(slice, at: base)
            dayStart = base + 3
        }

        guard month >= 1, month <= 12 else { return nil }

        var day: Int
        var yearStart: Int
        if dayStart + 1 < slice.endIndex && slice[dayStart + 1] == 0x2F {
            day = Int(slice[dayStart] - 0x30)
            yearStart = dayStart + 2
        } else {
            guard dayStart + 2 < slice.endIndex else { return nil }
            day = parseDigits2(slice, at: dayStart)
            yearStart = dayStart + 3
        }

        guard day >= 1, day <= 31 else { return nil }
        guard yearStart + 4 < slice.endIndex else { return nil }

        let year = parseDigits4(slice, at: yearStart)
        guard year > 0 else { return nil }

        let timeStart = yearStart + 5
        guard timeStart + 8 <= slice.endIndex else { return nil }

        let hour = parseDigits2(slice, at: timeStart)
        let minute = parseDigits2(slice, at: timeStart + 3)
        let second = parseDigits2(slice, at: timeStart + 6)

        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59, second >= 0, second <= 59 else {
            return nil
        }

        // US datetime without timezone - interpret in local timezone
        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: 0, tzOffsetSeconds: naiveStampOffsetSeconds)
    }

    // MARK: - Apache CLF: 21/Nov/2024:10:30:45 +0000

    private static func parseApacheCLF(bytes: [UInt8]) -> Date? {
        guard let startIdx = findApacheCLFStart(bytes: bytes) else { return nil }
        let slice = bytes[startIdx...]
        return parseApacheCLFComponents(slice: slice)
    }

    private static func findApacheCLFStart(bytes: [UInt8]) -> Int? {
        let count = bytes.count
        guard count >= 20 else { return nil }

        for i in 0..<min(count - 19, 50) {
            if isDigit(bytes[i]) && (isDigit(bytes[i+1]) || bytes[i+1] == 0x2F) {
                var dayEnd = i + 1
                if isDigit(bytes[i+1]) { dayEnd = i + 2 }

                if dayEnd < count && bytes[dayEnd] == 0x2F {
                    if dayEnd + 4 < count &&
                       isAlpha(bytes[dayEnd + 1]) &&
                       isLowerAlpha(bytes[dayEnd + 2]) &&
                       isLowerAlpha(bytes[dayEnd + 3]) &&
                       bytes[dayEnd + 4] == 0x2F {
                        return i
                    }
                }
            }
        }
        return nil
    }

    private static func parseApacheCLFComponents(slice: ArraySlice<UInt8>) -> Date? {
        let base = slice.startIndex

        var day: Int
        var monthStart: Int
        if slice[base + 1] == 0x2F {
            day = Int(slice[base] - 0x30)
            monthStart = base + 2
        } else {
            day = parseDigits2(slice, at: base)
            monthStart = base + 3
        }

        guard day >= 1, day <= 31, monthStart + 3 < slice.endIndex else { return nil }

        let monthBytes = (slice[monthStart], slice[monthStart + 1], slice[monthStart + 2])
        guard let month = parseMonthAbbrev(monthBytes) else { return nil }

        let yearStart = monthStart + 4
        guard yearStart + 4 < slice.endIndex else { return nil }

        let year = parseDigits4(slice, at: yearStart)
        guard year > 0 else { return nil }

        let colonPos = yearStart + 4
        guard colonPos < slice.endIndex && slice[colonPos] == 0x3A else { return nil }

        let hourStart = colonPos + 1
        guard hourStart + 8 <= slice.endIndex else { return nil }

        let hour = parseDigits2(slice, at: hourStart)
        let minute = parseDigits2(slice, at: hourStart + 3)
        let second = parseDigits2(slice, at: hourStart + 6)

        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59, second >= 0, second <= 59 else {
            return nil
        }

        var tzOffset: Int = 0
        let tzStart = hourStart + 8
        if tzStart + 1 < slice.endIndex && slice[tzStart] == 0x20 {
            let tzSignPos = tzStart + 1
            if tzSignPos < slice.endIndex {
                let tzSign = slice[tzSignPos]
                if (tzSign == 0x2B || tzSign == 0x2D) && tzSignPos + 5 <= slice.endIndex {
                    let sign = tzSign == 0x2B ? 1 : -1
                    let tzHour = parseDigits2(slice, at: tzSignPos + 1)
                    let tzMinute = parseDigits2(slice, at: tzSignPos + 3)
                    tzOffset = sign * (tzHour * 3600 + tzMinute * 60)
                }
            }
        }

        return makeDate(year: year, month: month, day: day,
                       hour: hour, minute: minute, second: second,
                       nanoseconds: 0, tzOffsetSeconds: tzOffset)
    }

    // MARK: - Helper Functions

    @inline(__always)
    private static func isDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always)
    private static func isAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    @inline(__always)
    private static func isLowerAlpha(_ b: UInt8) -> Bool {
        b >= 0x61 && b <= 0x7A
    }

    @inline(__always)
    private static func parseDigits2(_ bytes: ArraySlice<UInt8>, at index: Int) -> Int {
        guard index + 1 < bytes.endIndex else { return -1 }
        let d0 = bytes[index]
        let d1 = bytes[index + 1]
        guard isDigit(d0) && isDigit(d1) else { return -1 }
        return Int(d0 - 0x30) * 10 + Int(d1 - 0x30)
    }

    @inline(__always)
    private static func parseDigits4(_ bytes: ArraySlice<UInt8>, at index: Int) -> Int {
        guard index + 3 < bytes.endIndex else { return -1 }
        let d0 = bytes[index]
        let d1 = bytes[index + 1]
        let d2 = bytes[index + 2]
        let d3 = bytes[index + 3]
        guard isDigit(d0) && isDigit(d1) && isDigit(d2) && isDigit(d3) else { return -1 }
        return Int(d0 - 0x30) * 1000 + Int(d1 - 0x30) * 100 + Int(d2 - 0x30) * 10 + Int(d3 - 0x30)
    }

    /// A zone suffix at `index`, or nil when the stamp names none.
    ///
    /// `2026-09-01 21:13:45.282914+0200` is the shape `log stream --style=ndjson` writes, and the
    /// simple-datetime reader used to stop at the fraction and discard the `+0200` — so every row
    /// off a simulator or a device landed an offset away from the instant it names. A stamp that
    /// says its zone must be believed; only silence gets the UTC convention.
    @inline(__always)
    private static func trailingOffsetUnsafe(ptr: UnsafePointer<UInt8>, count: Int, at index: Int) -> Int? {
        guard index < count else { return nil }
        let byte = ptr[index]
        if byte == 0x5A { return 0 }                       // Z
        guard byte == 0x2B || byte == 0x2D else { return nil }   // + or -
        guard index + 3 <= count else { return nil }
        let sign = byte == 0x2B ? 1 : -1
        let hour = parseDigits2Unsafe(ptr: ptr, at: index + 1)
        var minute = 0
        if index + 6 <= count, ptr[index + 3] == 0x3A {    // +HH:MM
            minute = parseDigits2Unsafe(ptr: ptr, at: index + 4)
        } else if index + 5 <= count {                     // +HHMM
            minute = parseDigits2Unsafe(ptr: ptr, at: index + 3)
        }
        guard hour <= 14, minute <= 59 else { return nil }
        return sign * (hour * 3600 + minute * 60)
    }

    @inline(__always)
    private static func parseDigits2Unsafe(ptr: UnsafePointer<UInt8>, at index: Int) -> Int {
        let d0 = ptr[index]
        let d1 = ptr[index + 1]
        guard isDigit(d0) && isDigit(d1) else { return -1 }
        return Int(d0 - 0x30) * 10 + Int(d1 - 0x30)
    }

    @inline(__always)
    private static func parseDigits4Unsafe(ptr: UnsafePointer<UInt8>, at index: Int) -> Int {
        let d0 = ptr[index]
        let d1 = ptr[index + 1]
        let d2 = ptr[index + 2]
        let d3 = ptr[index + 3]
        guard isDigit(d0) && isDigit(d1) && isDigit(d2) && isDigit(d3) else { return -1 }
        return Int(d0 - 0x30) * 1000 + Int(d1 - 0x30) * 100 + Int(d2 - 0x30) * 10 + Int(d3 - 0x30)
    }

    private static func parseMonthAbbrev(_ bytes: (UInt8, UInt8, UInt8)) -> Int? {
        let b0 = bytes.0 | 0x20
        let b1 = bytes.1 | 0x20
        let b2 = bytes.2 | 0x20

        switch (b0, b1, b2) {
        case (0x6A, 0x61, 0x6E): return 1
        case (0x66, 0x65, 0x62): return 2
        case (0x6D, 0x61, 0x72): return 3
        case (0x61, 0x70, 0x72): return 4
        case (0x6D, 0x61, 0x79): return 5
        case (0x6A, 0x75, 0x6E): return 6
        case (0x6A, 0x75, 0x6C): return 7
        case (0x61, 0x75, 0x67): return 8
        case (0x73, 0x65, 0x70): return 9
        case (0x6F, 0x63, 0x74): return 10
        case (0x6E, 0x6F, 0x76): return 11
        case (0x64, 0x65, 0x63): return 12
        default: return nil
        }
    }

    // MARK: - Date Creation

    /// The zone a stamp that names none is read in: **UTC**.
    ///
    /// This was `TimeZone.current.secondsFromGMT()`, cached at load. That is the offset *now*, not
    /// the offset at the stamp's own instant, so it was wrong twice over. A January stamp parsed in
    /// September got summer time — measured here, `2024-01-15 10:30:45.123` came out as
    /// `08:30:45Z` when the correct local reading is `09:30:45Z`, an hour adrift purely because of
    /// when the parser happened to run. And the same file parsed in two places, or side of a DST
    /// change, produced two different instants for the same line.
    ///
    /// UTC is a *convention*, not a guess at the truth: a naive stamp genuinely does not say what
    /// zone it was written in, and no amount of cleverness recovers it. What a convention buys is
    /// everything that actually matters here — the same line always parses to the same instant, two
    /// lines in one log order and subtract correctly, and formatting the result back in UTC returns
    /// the characters the file wrote. A caller that knows the log's zone can shift by that offset;
    /// a caller that guesses cannot be corrected.
    ///
    /// Formats that *do* carry an offset — ISO 8601 and Apache CLF — pass their own and are
    /// unaffected.
    private static let naiveStampOffsetSeconds: Int = 0

    /// Cached current year for formats that don't include year
    private static let cachedCurrentYear: Int = Calendar.current.component(.year, from: Date())

    private static let daysPerMonth: [Int] = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    private static let daysToYear: [Int] = {
        var days = [Int]()
        var total = 0
        for year in 1970...2100 {
            days.append(total)
            let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            total += isLeap ? 366 : 365
        }
        return days
    }()

    @inline(__always)
    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    }

    private static func makeDate(
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int, second: Int,
        nanoseconds: Int, tzOffsetSeconds: Int
    ) -> Date? {
        guard year >= 1970, year <= 2100,
              month >= 1, month <= 12,
              day >= 1, day <= 31,
              hour >= 0, hour <= 23,
              minute >= 0, minute <= 59,
              second >= 0, second <= 59 else {
            return nil
        }

        let yearIndex = year - 1970
        guard yearIndex >= 0, yearIndex < Self.daysToYear.count else { return nil }

        var daysSinceEpoch = Self.daysToYear[yearIndex]

        for m in 1..<month {
            daysSinceEpoch += Self.daysPerMonth[m]
            if m == 2 && Self.isLeapYear(year) {
                daysSinceEpoch += 1
            }
        }

        daysSinceEpoch += day - 1

        let totalSeconds = daysSinceEpoch * 86400 + hour * 3600 + minute * 60 + second
        let timestamp = TimeInterval(totalSeconds - tzOffsetSeconds) + TimeInterval(nanoseconds) / 1_000_000_000

        return Date(timeIntervalSince1970: timestamp)
    }
}
