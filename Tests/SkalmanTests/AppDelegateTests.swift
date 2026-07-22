import AppKit
import XCTest
@testable import Skalman

/// The delegate methods the system can call in an instance that never started up.
///
/// This is not a hypothetical: a hosted test bundle *is* a running `NSApplication` with this
/// delegate installed, and `applicationDidFinishLaunching` deliberately returns early there —
/// so the window controller is nil while the app is otherwise live. Any test that waits on a
/// main-queue completion pumps the run loop, and a Dock click delivered into that window used
/// to take the whole run down on a force-unwrap.
@MainActor
final class AppDelegateTests: XCTestCase {

    func testReopenWithoutAWindowControllerDoesNotCrash() {
        let delegate = AppDelegate()

        // Both arms: `false` is the one that used to reach for the window.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    }

    func testOpeningFoldersIsIgnoredWithoutTheStateLock() {
        // Adopting a folder instantiates ProjectStore, and instantiating it writes
        // projects.json — the user's real one. An instance that does not own the lock must not.
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [URL(fileURLWithPath: NSTemporaryDirectory())])
    }
}
