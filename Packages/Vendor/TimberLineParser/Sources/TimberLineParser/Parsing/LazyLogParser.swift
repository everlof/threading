//
//  LazyLogParser.swift
//  TimberLineParser
//
//  High-performance lazy log parser using SIMD for line detection
//  and deferred parsing for timestamp/level extraction.
//

import Foundation
import os

// MARK: - Multiline Merge Options

/// Configuration for multiline log merging
public struct MultilineMergeOptions: Sendable {
    /// Whether to merge continuation lines into the parent log entry
    public let enabled: Bool

    /// Maximum number of continuation lines to merge (prevents runaway merging)
    public let maxContinuationLines: Int

    public static let disabled = MultilineMergeOptions(enabled: false, maxContinuationLines: 0)
    public static let `default` = MultilineMergeOptions(enabled: true, maxContinuationLines: 1000)

    public init(enabled: Bool, maxContinuationLines: Int = 1000) {
        self.enabled = enabled
        self.maxContinuationLines = maxContinuationLines
    }
}

// MARK: - Data Holder

/// Wrapper class to hold Data with a single reference point
public final class DataHolder {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

// MARK: - Lazy Log Line

/// A log line that lazily computes its content and metadata
/// Initially only stores byte range; parsing happens on-demand or via background task
public final class LazyLogLine: Identifiable {
    public let id: Int
    public let byteRange: Range<Int>
    public let byteOffset: UInt64

    // Reference to the shared data holder (single object for all lines)
    private let holder: DataHolder

    // Cached content - computed on first access
    private var _content: String?

    // Parsed metadata - set by background parser
    public private(set) var timestamp: Date?
    public private(set) var level: LogLevel = .unknown
    public private(set) var isParsed: Bool = false

    public init(id: Int, byteRange: Range<Int>, holder: DataHolder) {
        self.id = id
        self.byteRange = byteRange
        self.byteOffset = UInt64(byteRange.lowerBound)
        self.holder = holder
    }

    /// The line content as a String - lazily computed on first access
    public var content: String {
        if let cached = _content {
            return cached
        }

        let subdata = holder.data[byteRange]
        var str = String(decoding: subdata, as: UTF8.self)

        // Strip trailing \r if present
        if str.hasSuffix("\r") {
            str.removeLast()
        }

        _content = str
        return str
    }

    /// Called by background parser to set metadata and cache content string
    public func setMetadata(timestamp: Date?, level: LogLevel, contentString: String) {
        self.timestamp = timestamp
        self.level = level
        self._content = contentString  // Cache the content so it's ready for main thread
        self.isParsed = true
    }

    /// Get raw bytes for this line (for parsing)
    public func getBytes() -> [UInt8] {
        Array(holder.data[byteRange])
    }
}

// MARK: - Lazy Log Document

/// A document that holds raw Data and provides lazy access to lines
public final class LazyLogDocument {
    public let url: URL
    private var dataHolder: DataHolder?
    public private(set) var lines: [LazyLogLine] = []
    public private(set) var statistics: LogStatistics = LogStatistics()

    // Final converted LogLine array (built during parsing)
    private var convertedLines: [LogLine] = []
    private var convertedStatistics: LogStatistics = LogStatistics()

    // Parsing state
    private var parsingTask: Task<Void, Never>?

    // Multiline merging options
    private let multilineOptions: MultilineMergeOptions

    // Callback for when parsing updates occur
    public var onParsingProgress: ((Double) -> Void)?
    public var onParsingComplete: (() -> Void)?
    /// Called when line count is known (after LineScan phase)
    public var onLinesScanned: ((Int) -> Void)?

    /// Access to underlying data (for compatibility)
    public var data: Data { dataHolder?.data ?? Data() }

    /// Get the converted LogLine array and statistics (call after parsing complete)
    public func getLogLinesAndStatistics() -> ([LogLine], LogStatistics) {
        return (convertedLines, convertedStatistics)
    }

    /// Lightweight initializer - does NOT load the file yet
    /// Call `startFullBackgroundLoad()` to begin loading
    public init(url: URL, multilineOptions: MultilineMergeOptions = .default) {
        self.url = url
        self.multilineOptions = multilineOptions
    }

    deinit {
        parsingTask?.cancel()
    }

    /// Load the document synchronously - finds line boundaries using SIMD
    /// - Warning: This runs on the calling thread. For large files, use `startFullBackgroundLoad()` instead.
    public func load() {
        guard let dataHolder = dataHolder else {
            // If data not loaded yet, load it now (backwards compatibility)
            do {
                let signpostID = ParserSignpost.signposter.makeSignpostID()
                let state = ParserSignpost.signposter.beginInterval("FileLoading", id: signpostID)
                let data = try Data(contentsOf: url)
                ParserSignpost.signposter.endInterval("FileLoading", state)
                self.dataHolder = DataHolder(data: data)
                performLineScan()
            } catch {
                print("[LazyLogDocument] Failed to load file: \(error)")
            }
            return
        }
        performLineScan()
    }

    /// Perform line scanning on already-loaded data
    private func performLineScan() {
        guard let dataHolder = dataHolder else { return }

        let signpostID = ParserSignpost.signposter.makeSignpostID()
        let state = ParserSignpost.signposter.beginInterval("LineScan", id: signpostID)

        // SIMD scan for newlines
        let newlinePositions = SIMDLineScanner.findNewlines(in: dataHolder.data)
        let ranges = SIMDLineScanner.newlinesToRanges(newlinePositions, totalLength: dataHolder.data.count)

        // Create lazy line objects - all lines share the same DataHolder
        lines.reserveCapacity(ranges.count)
        for (index, range) in ranges.enumerated() {
            let line = LazyLogLine(
                id: index,
                byteRange: range.start..<range.end,
                holder: dataHolder
            )
            lines.append(line)
        }

        // Update basic statistics
        statistics.totalLines = lines.count
        statistics.filteredLines = lines.count

        ParserSignpost.signposter.endInterval("LineScan", state)
    }

    /// Start full background loading: file read → line scan → parse
    /// ALL heavy work happens off the main thread
    public func startFullBackgroundLoad() {
        // Keep strong reference to self to ensure we stay alive until completion
        // The caller is responsible for keeping a reference if they need the results
        let strongSelf = self
        let fileURL = url
        let multilineOpts = multilineOptions

        DispatchQueue.global(qos: .userInitiated).async {
            ThreadAssertions.assertNotMainThread()

            // Capture callbacks at start of async block
            let onLinesScanned = strongSelf.onLinesScanned
            let onProgress = strongSelf.onParsingProgress
            let onComplete = strongSelf.onParsingComplete

            // Phase 1: Load file
            let fileSignpostID = ParserSignpost.signposter.makeSignpostID()
            let fileState = ParserSignpost.signposter.beginInterval("FileLoading", id: fileSignpostID)

            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                print("[LazyLogDocument] Failed to load file: \(fileURL.path)")
                print("[LazyLogDocument] Error: \(error)")
                DispatchQueue.main.async {
                    onComplete?()
                }
                return
            }
            ParserSignpost.signposter.endInterval("FileLoading", fileState)

            let holder = DataHolder(data: data)

            // Phase 2: SIMD line scan
            let scanSignpostID = ParserSignpost.signposter.makeSignpostID()
            let scanState = ParserSignpost.signposter.beginInterval("LineScan", id: scanSignpostID)

            let newlinePositions = SIMDLineScanner.findNewlines(in: data)
            let ranges = SIMDLineScanner.newlinesToRanges(newlinePositions, totalLength: data.count)

            let lineCount = ranges.count

            ParserSignpost.signposter.endInterval("LineScan", scanState)

            // Report line count to main thread
            DispatchQueue.main.async {
                strongSelf.statistics.totalLines = lineCount
                strongSelf.statistics.filteredLines = lineCount
                onLinesScanned?(lineCount)
            }

            // Phase 3: Full parse - build LogLine array directly
            let (logLines, stats) = Self.parseRangesDirectly(
                data: data,
                ranges: ranges,
                lineCount: lineCount,
                multilineOptions: multilineOpts,
                onProgress: onProgress
            )

            // Deliver results and completion on main thread
            DispatchQueue.main.async {
                strongSelf.dataHolder = holder
                strongSelf.convertedLines = logLines
                strongSelf.convertedStatistics = stats
                onComplete?()
            }
        }
    }

    /// Parse line ranges directly into LogLine array without intermediate LazyLogLine objects
    /// This is more memory efficient and avoids thread-safety issues
    private static func parseRangesDirectly(
        data: Data,
        ranges: [(start: Int, end: Int)],
        lineCount: Int,
        multilineOptions: MultilineMergeOptions = .default,
        onProgress: ((Double) -> Void)?
    ) -> ([LogLine], LogStatistics) {
        ThreadAssertions.assertNotMainThread()

        let signpostID = ParserSignpost.signposter.makeSignpostID()
        let state = ParserSignpost.signposter.beginInterval("FullParse", id: signpostID)

        let batchSize = max(50000, min(lineCount / 8, 100000))

        var lastTimestamp: Date? = nil
        var detectedFormat: TimestampFormat = .unknown
        var formatConfidence: Int = 0
        let formatLockThreshold = 5

        var result: [LogLine] = []
        result.reserveCapacity(lineCount)

        var counts: [LogLevel: Int] = [:]
        for level in LogLevel.allCases {
            counts[level] = 0
        }
        var firstTimestamp: Date?
        var lastStatTimestamp: Date?

        var parsedCount = 0
        var batchNumber = 0
        var batchByteExtractionTime: UInt64 = 0
        var batchTimestampParseTime: UInt64 = 0
        var batchLevelDetectTime: UInt64 = 0
        var batchStringConvertTime: UInt64 = 0
        var batchLogLineCreateTime: UInt64 = 0

        // Multiline merging state
        var pendingLine: LogLine? = nil
        var pendingContent: String = ""
        var continuationCount = 0
        var outputLineIndex = 0

        for (index, range) in ranges.enumerated() {
            // Extract bytes directly from data
            var start = DispatchTime.now().uptimeNanoseconds
            let bytes = Array(data[range.start..<range.end])
            batchByteExtractionTime += DispatchTime.now().uptimeNanoseconds - start

            // Parse timestamp
            start = DispatchTime.now().uptimeNanoseconds
            let timestamp: Date?
            if detectedFormat != .unknown && formatConfidence >= formatLockThreshold {
                if let ts = TimestampParser.parseTimestamp(bytes: bytes, format: detectedFormat) {
                    timestamp = ts
                } else {
                    let (ts, fmt) = TimestampParser.tryAllTimestampFormats(bytes: bytes)
                    timestamp = ts
                    if let fmt = fmt, fmt != detectedFormat {
                        detectedFormat = fmt
                        formatConfidence = 1
                    }
                }
            } else {
                let (ts, fmt) = TimestampParser.tryAllTimestampFormats(bytes: bytes)
                timestamp = ts
                if let fmt = fmt {
                    if fmt == detectedFormat {
                        formatConfidence += 1
                    } else {
                        detectedFormat = fmt
                        formatConfidence = 1
                    }
                }
            }
            batchTimestampParseTime += DispatchTime.now().uptimeNanoseconds - start

            let effectiveTimestamp = timestamp ?? lastTimestamp
            if timestamp != nil {
                lastTimestamp = timestamp
            }

            // Parse level
            start = DispatchTime.now().uptimeNanoseconds
            let level = LevelDetector.detectLevel(bytes: bytes)
            batchLevelDetectTime += DispatchTime.now().uptimeNanoseconds - start

            // Convert bytes to string
            start = DispatchTime.now().uptimeNanoseconds
            var contentString = String(decoding: bytes, as: UTF8.self)
            if contentString.hasSuffix("\r") {
                contentString.removeLast()
            }
            batchStringConvertTime += DispatchTime.now().uptimeNanoseconds - start

            // Create LogLine with multiline merging
            start = DispatchTime.now().uptimeNanoseconds

            if multilineOptions.enabled {
                // Check if this is a continuation line
                let hasTimestamp = TimestampParser.hasTimestamp(bytes: bytes)
                let isContinuation = !hasTimestamp && isContinuationLine(bytes: bytes)

                if isContinuation && pendingLine != nil && continuationCount < multilineOptions.maxContinuationLines {
                    // Append to pending line
                    pendingContent += "\n" + contentString
                    continuationCount += 1
                } else {
                    // Yield any pending line first
                    if let pending = pendingLine {
                        let mergedLine = LogLine(
                            id: pending.id,
                            content: pendingContent,
                            byteOffset: pending.byteOffset,
                            level: pending.level,
                            timestamp: pending.timestamp
                        )
                        result.append(mergedLine)
                        counts[mergedLine.level, default: 0] += 1
                        if let ts = mergedLine.timestamp {
                            if firstTimestamp == nil || ts < firstTimestamp! {
                                firstTimestamp = ts
                            }
                            if lastStatTimestamp == nil || ts > lastStatTimestamp! {
                                lastStatTimestamp = ts
                            }
                        }
                        outputLineIndex += 1
                    }

                    // Start new pending line
                    let logLine = LogLine(
                        id: outputLineIndex,
                        content: contentString,
                        byteOffset: UInt64(range.start),
                        level: level,
                        timestamp: effectiveTimestamp
                    )
                    pendingLine = logLine
                    pendingContent = contentString
                    continuationCount = 0
                }
            } else {
                // No multiline merging - append directly
                let logLine = LogLine(
                    id: index,
                    content: contentString,
                    byteOffset: UInt64(range.start),
                    level: level,
                    timestamp: effectiveTimestamp
                )
                result.append(logLine)

                counts[level, default: 0] += 1
                if let ts = effectiveTimestamp {
                    if firstTimestamp == nil || ts < firstTimestamp! {
                        firstTimestamp = ts
                    }
                    if lastStatTimestamp == nil || ts > lastStatTimestamp! {
                        lastStatTimestamp = ts
                    }
                }
            }
            batchLogLineCreateTime += DispatchTime.now().uptimeNanoseconds - start

            parsedCount += 1

            if parsedCount % batchSize == 0 {
                batchNumber += 1
                ParserSignpost.signposter.emitEvent("BatchComplete", "Batch \(batchNumber): bytes=\(batchByteExtractionTime/1_000_000)ms ts=\(batchTimestampParseTime/1_000_000)ms lvl=\(batchLevelDetectTime/1_000_000)ms str=\(batchStringConvertTime/1_000_000)ms create=\(batchLogLineCreateTime/1_000_000)ms")

                batchByteExtractionTime = 0
                batchTimestampParseTime = 0
                batchLevelDetectTime = 0
                batchStringConvertTime = 0
                batchLogLineCreateTime = 0

                // Report progress synchronously - caller handles main thread dispatch
                let progress = Double(parsedCount) / Double(lineCount)
                onProgress?(progress)
            }
        }

        // Yield final pending line if multiline merging
        if multilineOptions.enabled, let pending = pendingLine {
            let mergedLine = LogLine(
                id: pending.id,
                content: pendingContent,
                byteOffset: pending.byteOffset,
                level: pending.level,
                timestamp: pending.timestamp
            )
            result.append(mergedLine)
            counts[mergedLine.level, default: 0] += 1
            if let ts = mergedLine.timestamp {
                if firstTimestamp == nil || ts < firstTimestamp! {
                    firstTimestamp = ts
                }
                if lastStatTimestamp == nil || ts > lastStatTimestamp! {
                    lastStatTimestamp = ts
                }
            }
        }

        let stats = LogStatistics(
            totalLines: result.count,
            countsByLevel: counts,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastStatTimestamp
        )

        ParserSignpost.signposter.endInterval("FullParse", state)

        return (result, stats)
    }

    /// Check if a line is a continuation line (no timestamp + starts with whitespace or numbered pattern)
    private static func isContinuationLine(bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }

        let firstByte = bytes[0]

        // Line starts with whitespace (space or tab)
        if firstByte == 0x20 || firstByte == 0x09 {
            return true
        }

        // Line starts with digit followed by colon (like "1:", "42:")
        if firstByte >= 0x30 && firstByte <= 0x39 { // 0-9
            for i in 1..<min(bytes.count, 6) {
                let b = bytes[i]
                if b == 0x3A { // colon
                    return true
                } else if b < 0x30 || b > 0x39 { // not a digit
                    break
                }
            }
        }

        return false
    }

    /// Start background parsing of timestamps and levels (legacy method)
    /// Assumes load() was already called
    public func startBackgroundParsing() {
        parsingTask?.cancel()

        // Capture values to avoid self reference issues
        let linesToParse = lines
        let lineCount = lines.count
        let onProgress = onParsingProgress
        let onComplete = onParsingComplete

        // Use GCD for guaranteed background execution
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ThreadAssertions.assertNotMainThread()

            let (logLines, stats) = Self.parseAllLinesAndConvertSync(
                lines: linesToParse,
                lineCount: lineCount,
                onProgress: onProgress
            )

            DispatchQueue.main.async {
                self?.convertedLines = logLines
                self?.convertedStatistics = stats
                onComplete?()
            }
        }
    }

    /// Cancel background parsing
    public func cancelBackgroundParsing() {
        parsingTask?.cancel()
        parsingTask = nil
    }

    // MARK: - Background Parsing

    /// Parse all lines and convert to LogLine array in a single pass (synchronous version for GCD)
    /// Returns the LogLine array and computed statistics
    private static func parseAllLinesAndConvertSync(
        lines: [LazyLogLine],
        lineCount: Int,
        onProgress: ((Double) -> Void)?
    ) -> ([LogLine], LogStatistics) {
        // Assert we're not on main thread - this is heavy work
        ThreadAssertions.assertNotMainThread()

        let signpostID = ParserSignpost.signposter.makeSignpostID()
        let state = ParserSignpost.signposter.beginInterval("FullParse", id: signpostID)

        // Larger batch size = fewer main thread updates
        // For 800k lines: 100k batch = 8 updates
        let batchSize = max(50000, min(lineCount / 8, 100000))

        var lastTimestamp: Date? = nil
        var detectedFormat: TimestampFormat = .unknown
        var formatConfidence: Int = 0
        let formatLockThreshold = 5

        // Pre-allocate result array
        var result: [LogLine] = []
        result.reserveCapacity(lineCount)

        // Statistics tracking
        var counts: [LogLevel: Int] = [:]
        for level in LogLevel.allCases {
            counts[level] = 0
        }
        var firstTimestamp: Date?
        var lastStatTimestamp: Date?

        var parsedCount = 0
        var batchNumber = 0

        // Accumulators for per-batch timing
        var batchByteExtractionTime: UInt64 = 0
        var batchTimestampParseTime: UInt64 = 0
        var batchLevelDetectTime: UInt64 = 0
        var batchStringConvertTime: UInt64 = 0
        var batchLogLineCreateTime: UInt64 = 0

        for lazyLine in lines {
            // Check for cancellation
            if Task.isCancelled { break }

            // Byte extraction
            var start = DispatchTime.now().uptimeNanoseconds
            let bytes = lazyLine.getBytes()
            batchByteExtractionTime += DispatchTime.now().uptimeNanoseconds - start

            // Parse timestamp
            start = DispatchTime.now().uptimeNanoseconds
            let timestamp: Date?
            if detectedFormat != .unknown && formatConfidence >= formatLockThreshold {
                if let ts = TimestampParser.parseTimestamp(bytes: bytes, format: detectedFormat) {
                    timestamp = ts
                } else {
                    let (ts, fmt) = TimestampParser.tryAllTimestampFormats(bytes: bytes)
                    timestamp = ts
                    if let fmt = fmt, fmt != detectedFormat {
                        detectedFormat = fmt
                        formatConfidence = 1
                    }
                }
            } else {
                let (ts, fmt) = TimestampParser.tryAllTimestampFormats(bytes: bytes)
                timestamp = ts
                if let fmt = fmt {
                    if fmt == detectedFormat {
                        formatConfidence += 1
                    } else {
                        detectedFormat = fmt
                        formatConfidence = 1
                    }
                }
            }
            batchTimestampParseTime += DispatchTime.now().uptimeNanoseconds - start

            // Timestamp inheritance
            let effectiveTimestamp = timestamp ?? lastTimestamp
            if timestamp != nil {
                lastTimestamp = timestamp
            }

            // Parse level
            start = DispatchTime.now().uptimeNanoseconds
            let level = LevelDetector.detectLevel(bytes: bytes)
            batchLevelDetectTime += DispatchTime.now().uptimeNanoseconds - start

            // Convert bytes to string
            start = DispatchTime.now().uptimeNanoseconds
            var contentString = String(decoding: bytes, as: UTF8.self)
            if contentString.hasSuffix("\r") {
                contentString.removeLast()
            }
            batchStringConvertTime += DispatchTime.now().uptimeNanoseconds - start

            // Create LogLine directly (no intermediate LazyLogLine metadata update needed)
            start = DispatchTime.now().uptimeNanoseconds
            let logLine = LogLine(
                id: lazyLine.id,
                content: contentString,
                byteOffset: lazyLine.byteOffset,
                level: level,
                timestamp: effectiveTimestamp
            )
            result.append(logLine)
            batchLogLineCreateTime += DispatchTime.now().uptimeNanoseconds - start

            // Update statistics inline
            counts[level, default: 0] += 1
            if let ts = effectiveTimestamp {
                if firstTimestamp == nil || ts < firstTimestamp! {
                    firstTimestamp = ts
                }
                if lastStatTimestamp == nil || ts > lastStatTimestamp! {
                    lastStatTimestamp = ts
                }
            }

            parsedCount += 1

            // Report progress and emit signposts in batches
            if parsedCount % batchSize == 0 {
                batchNumber += 1

                // Emit signposts for this batch's breakdown
                ParserSignpost.signposter.emitEvent("BatchComplete", "Batch \(batchNumber): bytes=\(batchByteExtractionTime/1_000_000)ms ts=\(batchTimestampParseTime/1_000_000)ms lvl=\(batchLevelDetectTime/1_000_000)ms str=\(batchStringConvertTime/1_000_000)ms create=\(batchLogLineCreateTime/1_000_000)ms")

                // Reset accumulators
                batchByteExtractionTime = 0
                batchTimestampParseTime = 0
                batchLevelDetectTime = 0
                batchStringConvertTime = 0
                batchLogLineCreateTime = 0

                let progress = Double(parsedCount) / Double(lineCount)
                DispatchQueue.main.async {
                    onProgress?(progress)
                }
            }
        }

        // Final progress update
        DispatchQueue.main.async {
            onProgress?(1.0)
        }

        let stats = LogStatistics(
            totalLines: result.count,
            countsByLevel: counts,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastStatTimestamp
        )

        ParserSignpost.signposter.endInterval("FullParse", state)

        return (result, stats)
    }
}
