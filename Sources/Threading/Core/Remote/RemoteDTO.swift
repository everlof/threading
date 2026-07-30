// The remote-access wire types now live in the ThreadingRemoteKit package, so the macOS server
// and any future client (an iOS app first) share exactly one definition and cannot drift.
//
// Re-exported so `@testable import Threading` — and any other importer of the app module — sees
// the wire types without importing the package directly. App files that name these types still
// carry their own `import ThreadingRemoteKit`, as Swift imports are file-scoped.
@_exported import ThreadingRemoteKit
