import AppKit
import NativeDiffCore
import XCTest
@testable import Threading

/// "Open in" — the way out of Threading and into the app the work is actually done in.
///
/// What is pinned here is everything that can be asserted without launching another
/// application: which apps may be offered for which target, how a line reaches an editor's
/// command line, which app a stored choice resolves to, and that the same offer reaches every
/// surface that makes it. The launch itself is `NSWorkspace`'s and is deliberately not
/// simulated — a test that opened Xcode would be a test nobody could run twice.
@MainActor
final class OpenInTests: XCTestCase {

    // MARK: - The Registry

    /// Two apps sharing an id would make the stored preference ambiguous, and a menu would
    /// offer the same name twice.
    func testEveryAppIsNamedOnce() {
        let ids = ExternalApps.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two apps share an id")

        let names = ExternalApps.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two apps share a name")

        for app in ExternalApps.all {
            XCTAssertFalse(
                app.bundleIdentifiers.isEmpty,
                "\(app.name) has no bundle identifier, so it can never be detected"
            )
        }
    }

    /// **A terminal is offered a directory and never a file**, because handing Terminal a file
    /// runs it. That is the one outcome an "Open in" menu must not be able to produce, and it
    /// is a property of the registry rather than of any one menu.
    func testATerminalIsOnlyEverOfferedAFolder() {
        for id in ["terminal", "iterm", "ghostty", "warp"] {
            guard let app = ExternalApps.app(id: id) else {
                XCTFail("the registry lost \(id)")
                continue
            }

            XCTAssertTrue(
                app.accepts(.folder(URL(fileURLWithPath: "/tmp"))),
                "\(app.name) cannot be offered a checkout, which is all it is here for"
            )
            XCTAssertFalse(
                app.accepts(.file(URL(fileURLWithPath: "/tmp/run.sh"), line: nil)),
                "\(app.name) would be handed a file to execute"
            )
        }
    }

    /// An app that claims it can land on a line needs something to say it with.
    func testAnAppThatCanLandOnALineHasACommandToSayItWith() {
        for app in ExternalApps.all where app.linePosition != .unsupported {
            XCTAssertFalse(
                app.commands.isEmpty,
                "\(app.name) claims a line-number form but ships no command to run"
            )
        }
    }

    // MARK: - Command Lines

    /// The three families spell the same request three different ways, and each was read off
    /// that family's own CLI rather than guessed. A wrong form does not fail loudly — the
    /// editor opens the file and ignores the argument — so the shapes are pinned here.
    func testEachFamilyIsToldAboutTheLineInItsOwnWords() throws {
        let file = URL(fileURLWithPath: "/checkout/Sources/App.swift")

        let vscode = try XCTUnwrap(ExternalApps.app(id: "vscode"))
        XCTAssertEqual(
            vscode.arguments(for: file, line: 42),
            ["--goto", "/checkout/Sources/App.swift:42"]
        )

        let jetbrains = try XCTUnwrap(ExternalApps.app(id: "idea"))
        XCTAssertEqual(
            jetbrains.arguments(for: file, line: 42),
            ["--line", "42", "/checkout/Sources/App.swift"]
        )

        let zed = try XCTUnwrap(ExternalApps.app(id: "zed"))
        XCTAssertEqual(zed.arguments(for: file, line: 42), ["/checkout/Sources/App.swift:42"])

        // Finder has no command line at all, and must not invent one.
        let finder = try XCTUnwrap(ExternalApps.app(id: ExternalApps.finderID))
        XCTAssertEqual(finder.arguments(for: file, line: 42), ["/checkout/Sources/App.swift"])
    }

    // MARK: - Which App a Press Uses

    /// Last-used-wins, and an app that is no longer on offer falls back rather than leaving the
    /// control pointed at nothing.
    ///
    /// The second half is the one that matters: the stored id outlives the app it names — an
    /// editor gets uninstalled, and a *file* menu cannot offer the terminal a folder menu could.
    func testTheStoredChoiceFallsBackWhenItIsNotOnOffer() throws {
        let apps = [
            try XCTUnwrap(ExternalApps.app(id: "vscode")),
            try XCTUnwrap(ExternalApps.app(id: "zed")),
            try XCTUnwrap(ExternalApps.app(id: ExternalApps.finderID))
        ]

        XCTAssertEqual(
            ExternalApps.resolvePreferred(storedID: "zed", among: apps)?.id,
            "zed",
            "the app the user last opened something in was not the one offered back"
        )
        XCTAssertEqual(
            ExternalApps.resolvePreferred(storedID: "rider", among: apps)?.id,
            "vscode",
            "an uninstalled stored choice should fall back to the first app on offer"
        )
        XCTAssertEqual(
            ExternalApps.resolvePreferred(storedID: nil, among: apps)?.id,
            "vscode",
            "a user who has never chosen still gets a working press"
        )
        XCTAssertNil(
            ExternalApps.resolvePreferred(storedID: "vscode", among: []),
            "nothing installed cannot resolve to something"
        )
    }

    /// The preference is a *choice the user made*, so it goes through `PreferenceStore` and a
    /// hosted test writes to a scratch suite instead of the developer's own defaults — the
    /// mistake that once made the app forget its theme between launches.
    func testThePreferenceIsWrittenWhereAHostedTestCannotStealIt() throws {
        XCTAssertTrue(
            PreferenceStore.isRedirected,
            "a hosted test is writing the developer's real preferences"
        )

        let key = ExternalAppDefaults.preferredKey
        let previous = PreferenceStore.shared.string(forKey: key)
        defer { PreferenceStore.shared.set(previous, forKey: key) }

        // Compared before-and-after rather than asserted nil: the key is a real choice the
        // *app* legitimately stores in `.standard`, so on a machine whose developer has picked
        // an Open In app the value exists before this test does anything. What must hold is
        // that the test's own write did not land there.
        let standardBefore = UserDefaults.standard.string(forKey: key)

        let finder = try XCTUnwrap(ExternalApps.app(id: ExternalApps.finderID))
        ExternalAppLauncher.shared.setPreferred(finder)

        XCTAssertEqual(PreferenceStore.shared.string(forKey: key), ExternalApps.finderID)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            standardBefore,
            "the choice leaked into the defaults the running app reads"
        )
    }

    /// Finder is installed on every Mac, so the list is never empty — which is what lets the
    /// header's control and every context menu assume they have something to offer.
    func testFinderIsAlwaysOnOfferForBothKindsOfTarget() {
        let launcher = ExternalAppLauncher.shared
        launcher.refresh()

        let folder = launcher.installed(for: .folder(URL(fileURLWithPath: "/tmp")))
        let file = launcher.installed(for: .file(URL(fileURLWithPath: "/tmp/a.txt"), line: 3))

        XCTAssertTrue(folder.contains { $0.id == ExternalApps.finderID })
        XCTAssertTrue(file.contains { $0.id == ExternalApps.finderID })
        XCTAssertFalse(
            file.contains { $0.id == "terminal" },
            "a file's menu offered a terminal, which would run it"
        )
    }

    // MARK: - The Menus

    /// One builder serves the platform's context menus, so a second surface cannot quietly
    /// offer fewer apps than the first — the drift `populateSessionActions` exists to prevent
    /// for session actions, applied to this one.
    func testTheSubmenuNamesEveryOfferedAppAndCarriesItBack() throws {
        let target = ExternalAppTarget.folder(URL(fileURLWithPath: "/tmp"))
        let item = try XCTUnwrap(
            OpenInMenu.item(for: target, action: #selector(openInAppClicked), owner: self)
        )
        let submenu = try XCTUnwrap(item.submenu)

        let offered = ExternalAppLauncher.shared.installed(for: target)
        XCTAssertEqual(
            submenu.items.map(\.title),
            offered.map(\.name),
            "the submenu and the launcher disagree about what is installed"
        )

        let finderItem = try XCTUnwrap(submenu.items.first { $0.title == "Finder" })
        XCTAssertEqual(
            OpenInMenu.app(in: finderItem)?.id,
            ExternalApps.finderID,
            "a chosen item cannot say which app it named"
        )
        XCTAssertNotNil(
            finderItem.image,
            "an app is recognised by its own icon before its name is read"
        )
        XCTAssertTrue(finderItem.target === self, "the item would act on nobody")
    }

    /// The themed dropdown marks the app a plain press would use, which is the only thing that
    /// tells the two halves of the split control apart.
    func testTheThemedDropdownMarksTheAppThePressWouldUse() throws {
        let target = ExternalAppTarget.folder(URL(fileURLWithPath: "/tmp"))
        let entries = OpenInMenu.entries(for: target) { _ in }

        let items: [ThemedMenuItem] = entries.compactMap {
            guard case .item(let item) = $0 else { return nil }
            return item
        }
        XCTAssertFalse(items.isEmpty)

        let preferred = try XCTUnwrap(ExternalAppLauncher.shared.preferred(for: target))
        XCTAssertEqual(
            items.filter(\.isSelected).map(\.title),
            [preferred.name],
            "exactly one row should read as the one the press beside the chevron uses"
        )
    }

    /// A menu that would open nothing is not shown at all — the design system's rule that a
    /// control offering nothing hides rather than sitting there dead.
    func testNothingIsOfferedWhenNothingCanTakeTheTarget() {
        let apps = ExternalApps.all.filter { $0.accepts(.file(URL(fileURLWithPath: "/a"), line: nil)) }
        XCTAssertFalse(apps.isEmpty, "the registry can no longer open a file in anything")

        // The empty case is reachable only through the launcher, so the rule is asserted where
        // it is decided: no apps in, no submenu out.
        XCTAssertNil(
            ExternalApps.resolvePreferred(storedID: nil, among: []),
            "an empty offer must not resolve to an app"
        )
    }

    // MARK: - Where a Diff Sends You

    /// A review is the one surface that knows *which line* the reader is looking at, and the
    /// new numbering is what an editor needs: a removed line's old number points into a version
    /// that is no longer on disk.
    func testADiffOpensAtTheFirstLineItActuallyChanges() {
        let file = DiffFile(
            path: "Sources/App.swift",
            change: .modified,
            hunks: [
                DiffHunk(header: "@@ -10,4 +10,5 @@", lines: [
                    DiffLine(kind: .context, text: "struct App {", oldNumber: 10, newNumber: 10),
                    DiffLine(kind: .context, text: "", oldNumber: 11, newNumber: 11),
                    DiffLine(kind: .added, text: "    let name: String", oldNumber: nil, newNumber: 12)
                ])
            ],
            added: 1,
            removed: 0
        )

        XCTAssertEqual(
            GitReviewFileRow.firstChangedLine(in: file),
            12,
            "the editor would open on a context line rather than on the change"
        )
    }

    /// A hunk of pure removals has no new line of its own, so the reader lands on the context
    /// beside it — the closest place the working copy still has.
    func testAPureRemovalLandsBesideWhereTheChangeWas() {
        let file = DiffFile(
            path: "Sources/App.swift",
            change: .modified,
            hunks: [
                DiffHunk(header: "@@ -30,3 +30,2 @@", lines: [
                    DiffLine(kind: .removed, text: "    let unused = 1", oldNumber: 30, newNumber: nil),
                    DiffLine(kind: .context, text: "}", oldNumber: 31, newNumber: 30)
                ])
            ],
            added: 0,
            removed: 1
        )

        XCTAssertEqual(GitReviewFileRow.firstChangedLine(in: file), 30)
    }

    /// A binary change carries no numbered line at all, and must not invent one.
    func testAPictureOpensNowhereInParticular() {
        let file = DiffFile(path: "Icon.png", change: .binary, hunks: [], added: 0, removed: 0)
        XCTAssertNil(GitReviewFileRow.firstChangedLine(in: file))
    }

    // MARK: - The Header Control

    /// The pane header carries the split control, and it is *its own group* beside the session's
    /// actions rather than a sixth button inside them: those four act on the pane, this one
    /// leaves for another app.
    func testThePaneHeaderCarriesTheOpenInControlAsItsOwnGroup() throws {
        let controller = MainWindowController()
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        root.layoutSubtreeIfNeeded()

        let open = try XCTUnwrap(controller.openInToolbarButton, "the header has no Open in button")
        let choose = try XCTUnwrap(controller.openInMenuToolbarButton, "the control cannot be re-aimed")

        XCTAssertTrue(open.isDescendant(of: root), "the Open in button is not in the window")
        XCTAssertTrue(
            open.superview === choose.superview,
            "the press and its chevron drifted into separate groups"
        )
        XCTAssertNotNil(
            open.superview?.superview as? ToolbarButtonGroupView,
            "the pair is spaced by NSStackView's rules rather than ours"
        )
        XCTAssertFalse(
            controller.sessionContextToolbarButton?.superview === open.superview,
            "leaving for another app reads as a fifth way to act on this pane"
        )
    }

    /// No checkout, nothing to open: a fresh window shows no session and no composer, so the
    /// control hides rather than pointing at whatever was open last.
    func testTheControlHidesWhereThereIsNoCheckout() throws {
        let controller = MainWindowController()
        _ = controller.window?.contentView
        controller.updateOpenInControls()

        XCTAssertNil(controller.currentFolderURL, "a fresh window claims a checkout")
        XCTAssertTrue(
            controller.openInToolbarButton?.isHidden == true,
            "the button offers to open a checkout that is not there"
        )
        XCTAssertTrue(controller.openInMenuToolbarButton?.isHidden == true)
    }

    /// A control added to the header costs the *narrowest* window its room, and that room is
    /// finite: the content pane stops at `MainWindowDefaults.minContentWidth`.
    ///
    /// Measured against the running layout rather than added up by hand, because the answer
    /// includes the page tab's floor, the optical insets and the stack's own gaps — the kind of
    /// arithmetic that is wrong by one control and reads as right.
    func testTheHeaderStillFitsWithTheOpenInPairAtTheNarrowestPane() throws {
        let controller = MainWindowController()
        let root = try XCTUnwrap(controller.window?.contentView)
        let header = try XCTUnwrap(controller.pageTabView.superview as? NSStackView)

        // Shown by hand: a fresh window has no checkout, so the pair hides itself and the
        // measurement would be of the header *without* the thing being measured.
        controller.openInToolbarButton?.isHidden = false
        controller.openInMenuToolbarButton?.isHidden = false

        controller.window?.setContentSize(
            NSSize(
                width: SidebarDefaults.minWidth + MainWindowDefaults.minContentWidth,
                height: 700
            )
        )
        root.layoutSubtreeIfNeeded()

        let needed = header.fittingSize.width
        let available = header.bounds.width
        print("pane header wants \(needed)pt and has \(available)pt at the narrowest pane")

        XCTAssertLessThanOrEqual(
            needed,
            available,
            "the header overflows its own pane once the Open in pair is in it"
        )
    }

    /// The button wears the target app's own icon, which is the whole reason it is a picture
    /// rather than a symbol — and the accessible name still says where the press goes, because
    /// an icon says nothing to VoiceOver.
    func testTheButtonWearsTheAppsOwnMarkAndStillSaysWhereItGoes() throws {
        let button = ThemedIconButton(symbolName: "arrow.up.forward.app", accessibility: "Open")
        let finder = try XCTUnwrap(ExternalApps.app(id: ExternalApps.finderID))
        let icon = try XCTUnwrap(ExternalAppLauncher.shared.icon(for: finder))

        button.setImage(icon, accessibility: "Open in Finder")

        XCTAssertEqual(button.accessibilityTitle(), "Open in Finder")
        let images = descendantGlyphViews(of: button).compactMap(\.image)
        XCTAssertTrue(images.contains { $0 === icon }, "the button is not showing the app's icon")
    }

    /// Stands in for the real handler: a menu item needs a selector its owner answers to, and
    /// what is being asserted is which app the item names, not what pressing it does.
    @objc private func openInAppClicked(_ sender: NSMenuItem) {}

    private func descendantGlyphViews(of view: NSView) -> [GlyphView] {
        view.subviews.flatMap { subview -> [GlyphView] in
            let nested = descendantGlyphViews(of: subview)
            return (subview as? GlyphView).map { [$0] + nested } ?? nested
        }
    }
}
