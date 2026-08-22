//
//  TerminalColorCustomization.swift
//  SwiftTerm
//

import Foundation

/// The spelling a program used for a colour after terminal rendering semantics
/// such as inverse video and bold-as-bright have been applied.
public enum TerminalRenderedColorSource: Hashable, Sendable {
    case ansi256(index: UInt8)
    case trueColor(red: UInt8, green: UInt8, blue: UInt8)
    case defaultForeground
    case defaultBackground
    case invertedDefaultForeground
    case invertedDefaultBackground
}

/// A rendered colour reduced to stable sRGB bytes.
public struct TerminalRenderedColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A meaningful visible run whose final foreground and background have
/// effectively no contrast. Observation only; SwiftTerm never rewrites it.
public struct TerminalTextColorConflict: Hashable, Sendable {
    public let foregroundSource: TerminalRenderedColorSource
    public let backgroundSource: TerminalRenderedColorSource
    public let foreground: TerminalRenderedColor
    public let background: TerminalRenderedColor
    public let contrastRatio: Double
    public let sample: String

    public init(foregroundSource: TerminalRenderedColorSource,
                backgroundSource: TerminalRenderedColorSource,
                foreground: TerminalRenderedColor,
                background: TerminalRenderedColor,
                contrastRatio: Double,
                sample: String = "") {
        self.foregroundSource = foregroundSource
        self.backgroundSource = backgroundSource
        self.foreground = foreground
        self.background = background
        self.contrastRatio = contrastRatio
        self.sample = sample
    }
}

public enum TerminalContrastSample {
    public static let scanLimit = 64
    public static let characterLimit = 24
    public static let ellipsis: Character = "…"
}

struct TerminalTextContrastPair: Hashable {
    let foregroundSource: TerminalRenderedColorSource
    let backgroundSource: TerminalRenderedColorSource
    let foreground: TerminalRenderedColor
    let background: TerminalRenderedColor
}

/// A value-only true-colour background transform that can run on SwiftTerm's
/// renderer thread.
public protocol TerminalTrueColorBackgroundTransform: Sendable {
    /// Changes whenever the transform's output can change. SwiftTerm uses the
    /// value to invalidate its rendered-attribute cache.
    var cacheIdentity: UInt64 { get }

    func transform(_ color: TerminalRenderedColor) -> TerminalRenderedColor
}
