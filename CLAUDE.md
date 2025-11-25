# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skalman is a native macOS terminal emulator built with **Swift** and **AppKit**, using **SwiftTerm** for terminal emulation. Targets **macOS 13+**.

## Build & Run Commands

```bash
# Build the project
swift build

# Build for release
swift build -c release

# Run after building
.build/debug/Skalman
```

## Dependencies

- **SwiftTerm** (via SPM): Terminal emulation engine handling VT100/xterm, ANSI parsing, PTY communication
  - Repository: https://github.com/migueldeicaza/SwiftTerm

## Architecture

### Core Components

- **LocalProcessTerminalView**: SwiftTerm's AppKit view that combines terminal rendering + PTY handling
- **EmojiFixedTerminalView**: Subclass that fixes emoji rendering with proper background compositing
- **TerminalSession**: Manages SwiftTerm view lifecycle, shell process, and session state
- **TerminalWindowController**: NSWindowController hosting terminal sessions
- **TerminalProfile**: User preferences for font, colors, shell configuration

### Data Flow

```
User Input → LocalProcessTerminalView → PTY → Shell Process
                       ↓
Shell Output ← LocalProcessTerminalView ← PTY
                       ↓
             (SwiftTerm handles parsing internally)
```

### Key Protocols (SwiftTerm)

- `LocalProcessTerminalViewDelegate`: Receives process lifecycle events
- `TerminalViewDelegate`: Receives terminal state changes (title, size, etc.)

## Code Style Guidelines

### Constants & Configuration

All magic numbers and string literals must be defined as constants:

```swift
enum TerminalDefaults {
    static let columns = 80
    static let rows = 24
    static let scrollbackLines = 10_000
    static let defaultShell = "/bin/bash"
    static let defaultFont = "SF Mono"
    static let defaultFontSize: CGFloat = 13
}

enum WindowDefaults {
    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 300
}
```

### Naming Conventions

- Types: `PascalCase` (e.g., `TerminalSession`, `CursorStyle`)
- Properties/Methods: `camelCase` (e.g., `currentDirectory`, `startShell()`)
- Constants: `camelCase` within enum namespaces
- File names match primary type name

### Structure Organization

```swift
// MARK: - Properties (public, then private)
// MARK: - Initialization
// MARK: - Public Methods
// MARK: - Private Methods
// MARK: - Protocol Conformance (each protocol gets its own extension)
```

### DRY Principles

- Extract repeated logic into well-named helper methods
- Use protocol extensions for shared behavior
- Centralize color/theme definitions in a single source
- No hardcoded literals - use constants

### Error Handling

```swift
enum TerminalError: LocalizedError {
    case shellNotFound(path: String)
    case sessionCreationFailed

    var errorDescription: String? { /* ... */ }
}
```

## File Organization

```
Sources/Skalman/
├── App/                    # App entry point, AppDelegate
├── Core/
│   ├── Constants/          # TerminalConstants.swift
│   └── Session/            # TerminalSession management
├── UI/
│   ├── Windows/            # Window controllers
│   ├── Views/              # Custom NSViews
│   └── Preferences/        # Settings UI
├── Models/                 # TerminalProfile, TerminalTheme
├── Extensions/             # NSColor+Terminal, etc.
└── Resources/              # Assets, fonts
```

## Testing

- Unit tests for `TerminalSession` state management
- Unit tests for `TerminalProfile` serialization
- Integration tests for shell spawning
- UI tests for keyboard input handling

## Important Notes

- **No App Sandbox**: PTY operations require sandbox to be disabled
- **Hardened Runtime**: Enable with exceptions for PTY
- **SwiftTerm handles**: Escape sequence parsing, screen buffer, cursor management, Unicode
