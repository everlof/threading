// The remote-access wire types now live in the SkalmanRemoteKit package, so the macOS server
// and any future client (an iOS app first) share exactly one definition and cannot drift.
//
// Re-exported so `@testable import Skalman` — and any other importer of the app module — sees
// the wire types without importing the package directly. App files that name these types still
// carry their own `import SkalmanRemoteKit`, as Swift imports are file-scoped.
@_exported import SkalmanRemoteKit
