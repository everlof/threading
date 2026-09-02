//
//  Signposts.swift
//  TimberLineParser
//
//  os_signpost configuration for debugging and performance profiling.
//

import os

/// Signpost configuration for parser debugging and performance profiling
public enum ParserSignpost {
    /// Log handle for parser operations
    public static let log = OSLog(subsystem: "com.timber.lineparser", category: "Parsing")

    /// Signposter for creating signpost intervals
    public static let signposter = OSSignposter(logHandle: log)

    /// Category names for different parsing phases
    public enum Category {
        public static let fileLoading = "FileLoading"
        public static let lineScan = "LineScan"
        public static let timestampParsing = "TimestampParsing"
        public static let levelDetection = "LevelDetection"
        public static let fullParse = "FullParse"
        public static let batchParse = "BatchParse"
        public static let byteExtraction = "ByteExtraction"
        public static let stringConversion = "StringConversion"
        public static let logLineCreation = "LogLineCreation"
    }
}
