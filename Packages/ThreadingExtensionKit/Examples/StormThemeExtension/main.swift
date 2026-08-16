#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

// Storm: an app theme, and the app icon that goes with it.
//
// **Nothing in this file runs for the theme to work.** Themes, fonts and their icon marks are
// *data the host reads at inspection* — before the package is enabled, before this executable is
// launched, and even if it could never launch at all. That is what lets Threading resolve a
// contributed theme at startup, before the first window exists, rather than repainting it in
// once an extension host has spun up. The declaration below simply mirrors
// `threading-extension.json` so the manifest and the code cannot disagree.
//
// The interesting part of this example is therefore the two resources, not the Swift:
//
//   Resources/storm.json       the theme document — roles, material, terminal palette
//   Resources/storm-mark.png   the app-icon mark, drawn by Scripts/make-mark.swift
//
// About the mark, because it is the part with a rule you can fail:
//
//   Threading draws the icon's *plate* from this theme's own `ground` role and composites the mark
//   on top. So you ship a **glyph on transparency**, not a finished icon — one asset, and it
//   works against either appearance because the plate follows the theme rather than the artwork.
//   A PNG whose edges are opaque is a tile, and the host refuses the whole package at inspection
//   with an error naming the file. That refusal is not a style preference: it is what makes it
//   impossible for an extension to turn Threading's Dock icon into some other application's.
//
//   A mark is optional. Without one, a contributed theme's icon is Threading's own chevron drawn in
//   your `accent` on your `ground`, with your `material.glow` behind it — the same treatment every
//   built-in style gets, and usually the right answer. Declare a mark when your theme's identity
//   is genuinely a different glyph, not merely different colours.

let manifest = ExtensionManifest(
    identifier: "codes.threading.storm",
    name: "Storm",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/storm.wasm",
    capabilities: [
        .themeProvider
    ],
    themes: [
        ExtensionThemeContribution(
            id: "storm",
            resource: "Resources/storm.json",
            iconMark: "Resources/storm-mark.png"
        )
    ]
)

// A theme-only extension contributes no commands, panels or tools, so its registration is empty
// and it makes no host calls at all.
let registration = ExtensionRegistration()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func writeProtocolValue<Value: Encodable>(_ value: Value) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try writeProtocolValue(registration)

case ["--threading-serve"]:
    try writeProtocolValue(registration)

    // Nothing to serve, but the process still holds stdin open so its lifetime tracks the
    // generation the host supervises — EOF means disabled, reloaded, or removed. The theme
    // itself is already in force either way; see the note above.
    while readLine(strippingNewline: true) != nil {}

default:
    FileHandle.standardError.write(
        Data("Use --threading-register or --threading-serve.\n".utf8)
    )
    exit(64)
}
