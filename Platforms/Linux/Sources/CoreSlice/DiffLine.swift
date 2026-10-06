import Foundation
import NativeDiffCore

// MARK: - Shared Diff Model

/// Compatibility names for the app's existing git/staging code. The value types themselves
/// live in NativeDiffCore and are the same ones rendered by AppKit and UIKit.
typealias DiffLine = NativeDiffCore.DiffLine
typealias GitFileDiff = NativeDiffCore.DiffFile
typealias GitHunk = NativeDiffCore.DiffHunk
typealias GitDiffLine = NativeDiffCore.DiffLine

