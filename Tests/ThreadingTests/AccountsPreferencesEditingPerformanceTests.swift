import AppKit
import XCTest
@testable import Threading

/// What renaming a login actually costs, in the page it ships in.
///
/// Opt-in (`THREADING_STRESS=1`) because it types into a real field editor and prints numbers
/// rather than asserting a wall-clock budget; a timing threshold in the ordinary plan would fail
/// on a loaded machine and say nothing about the code. It exists because the Accounts page is
/// covered by no performance span, so a report of "editing a name is slow" had nothing to read.
@MainActor
final class AccountsPreferencesEditingPerformanceTests: XCTestCase {

    private enum Fixture {
        static let accounts = 6
        static let keystrokes = 12
        static let paneWidth = SettingsUIDefaults.pageWidth
        static let paneHeight: CGFloat = 900
    }

    func testReportsWhatOneKeystrokeAndOneCommitCostInTheAccountsPage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_STRESS"] == "1")

        let accounts = (0..<Fixture.accounts).map { index in
            AgentAccount(
                provider: index.isMultiple(of: 2) ? .claude : .codex,
                handle: .named("fixture-account-\(index)"),
                configPath: "/Users/dev/.fixture-account-\(index)",
                displayName: "Fixture \(index)"
            )
        }
        let controller = AccountsPreferencesViewController(accountsProvider: { accounts })

        // A pane states its width the way a split view does; a detached frame constrains nothing.
        // The window is never ordered on screen: it is here so the name field can take the field
        // editor, which is what makes a keystroke cost what it costs in the app.
        let bounds = NSRect(x: 0, y: 0, width: Fixture.paneWidth, height: Fixture.paneHeight)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: bounds)
        window.contentView = host
        let page = controller.view
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        let reload = elapsed { controller.viewWillAppear() }
        // A virtual table materializes a cell when it lays out *and draws*, not when it reloads.
        settle(host)

        let field = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? ThemedTextField }
                .first,
            "the first account row's editable name field"
        )
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())

        // Layout and draw are timed apart: this fixture redraws the whole 396-point pane into a
        // fresh bitmap, which the app never does for one keystroke, so a combined number would
        // charge the harness's cost to the page.
        var keystrokes: [Double] = []
        for character in "Renamed Login".prefix(Fixture.keystrokes) {
            keystrokes.append(elapsed {
                editor.insertText(String(character))
                host.layoutSubtreeIfNeeded()
            })
            draw(host)
        }

        let commit = elapsed {
            controller.controlTextDidEndEditing(Notification(
                name: NSControl.textDidEndEditingNotification,
                object: field
            ))
        }
        let commitLayout = elapsed { host.layoutSubtreeIfNeeded() }
        let commitDraw = elapsed { draw(host) }

        // The durable write on its own, so the page's share of the commit is not the store's.
        let store = AccountPreferencesStore.shared
        let storeWrite = elapsed {
            store.setDisplayNameOverride("Timing Probe", for: accounts[0].id)
        }
        store.clearPresentation(for: accounts[0].id)

        // The same commit with no field editor installed. AppKit's text input session is the
        // suspect for the difference: a row rebuild removes the field being edited, and
        // activating or tearing down an input session is tens of milliseconds on this machine.
        window.makeFirstResponder(nil)
        let unfocusedField = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? ThemedTextField }
                .first
        )
        unfocusedField.stringValue = "Unfocused Commit"
        let unfocusedCommit = elapsed {
            controller.controlTextDidEndEditing(Notification(
                name: NSControl.textDidEndEditingNotification,
                object: unfocusedField
            ))
        }

        let sorted = keystrokes.sorted()
        print("""
            accounts-page editing, \(accounts.count) logins, \(keystrokes.count) keystrokes
              reload+layout   \(milliseconds(reload))
              keystroke med   \(milliseconds(sorted[sorted.count / 2]))
              keystroke max   \(milliseconds(sorted.last ?? 0))
              keystroke total \(milliseconds(keystrokes.reduce(0, +)))
              commit          \(milliseconds(commit))
              commit layout   \(milliseconds(commitLayout))
              commit draw     \(milliseconds(commitDraw))
              store write     \(milliseconds(storeWrite))
              commit unfocused\(milliseconds(unfocusedCommit))
              virtual rows    \(controller.virtualRowCountForTesting)
              live cells      \(controller.materializedRowCountForTesting)
            """)

        page.removeFromSuperview()
        window.contentView = nil
    }

    /// One layout and one draw, which together are what a virtual table needs before its cells
    /// exist at all.
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        draw(host)
    }

    private func draw(_ host: NSView) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
    }

    // MARK: - Helpers

    private func elapsed(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%8.2f ms", value)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
