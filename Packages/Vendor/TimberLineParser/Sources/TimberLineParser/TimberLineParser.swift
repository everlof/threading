//
//  TimberLineParser.swift
//  TimberLineParser
//
//  High-performance log line parsing library for macOS.
//  Provides fast timestamp parsing, log level detection, and SIMD-accelerated newline scanning.
//

import Foundation

// This file serves as the module entry point.
// All public types are automatically exported from the package.
//
// Public API:
//
// Models:
//   - LogLine: Core log line model with parsed metadata
//   - LogLevel: Log severity enum (error, warning, info, debug, verbose, trace, unknown)
//   - ParserProgress: Progress information during parsing
//   - ParseResult: Container for parsed lines and statistics
//   - LogStatistics: Statistics about parsed log data
//
// Parsing:
//   - SinglePassLogParser: Main parser class for processing log data
//   - TimestampParser: High-performance byte-level timestamp parsing
//   - TimestampFormat: Detected timestamp format enum
//   - LevelDetector: Log level detection using byte pattern matching
//   - LazyLogDocument: Lazy document parser with background processing
//   - LazyLogLine: Lazy log line with on-demand content parsing
//   - DataHolder: Shared data wrapper for lazy lines
//
// SIMD:
//   - SIMDLineScanner: SIMD-accelerated newline detection
//
// Instrumentation:
//   - ParserSignpost: os_signpost configuration for profiling
//   - ThreadAssertions: Debug assertions for thread safety
