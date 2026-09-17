import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The menu behind the sidebar header's arrangement control.
///
/// Same reasoning as `ThemeMenuTests`: a presented menu is unreachable from a script, so the
/// built entries are asserted directly — the rows, their checks, and the one line that is
/// conditional (the lone-branch refinement disables while grouping is off).
@MainActor
final class SidebarArrangementMenuTests: XCTestCase {

    /// Restores what was there rather than removing the key: the bundle is hosted in the app,
    /// so these writes land in the developer's own preferences.
    private func withDefault(_ value: Any?, forKey key: String, run: () throws -> Void) rethrows {
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try run()
    }

    // MARK: - Shape

    /// Visibility first, grouping, presentation, sorting, then the chosen order's direction.
    func testMenuOffersGroupingThenEveryOrderThenBothDirections() throws {
        withCleanNativeFactSelections {
            withDefault(SidebarSessionOrder.manual.rawValue, forKey: "sidebarSessionOrder") {
                let entries = ProjectSidebarViewController().arrangementMenuEntries()

                let titles = entries.map { $0.item?.title ?? "—" }
                XCTAssertEqual(
                    titles,
                    ["Snoozed Sessions", "—", "Group by",
                     "Headings for Lone Branches", "Compact Tree", "Show Five Chats per Project",
                     "—", "Sort by", "—",
                     "Oldest First", "Newest First"]
                )
                XCTAssertEqual(
                    item(in: entries, titled: "Sort by")?.submenu?.compactMap {
                        $0.item?.title
                    },
                    SidebarSessionOrder.allCases.map(\.menuTitle)
                )
            }
        }
    }

    /// The direction rows are worded for whichever order is chosen: "Descending" describes a
    /// comparator, where these have to describe a list of sessions.
    func testDirectionWordingFollowsTheChosenOrder() throws {
        withCleanNativeFactSelections {
            withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
                let titles = ProjectSidebarViewController().arrangementMenuEntries()
                    .compactMap(\.item?.title)

                XCTAssertTrue(titles.contains("A to Z"))
                XCTAssertTrue(titles.contains("Z to A"))
                XCTAssertFalse(titles.contains("Oldest First"))
            }
        }
    }

    func testTypeOrderOffersChatAndTerminalDirections() throws {
        withCleanNativeFactSelections {
            withDefault(SidebarSessionOrder.type.rawValue, forKey: "sidebarSessionOrder") {
                let titles = ProjectSidebarViewController().arrangementMenuEntries()
                    .compactMap(\.item?.title)

                XCTAssertTrue(titles.contains("Chats First"))
                XCTAssertTrue(titles.contains("Terminals First"))
            }
        }
    }

    /// The seeded defaults: both grouping toggles on, the store's own order chosen.
    func testDefaultsCarryTheirChecks() throws {
        withDefault(true, forKey: "groupsSessionsByBranch") {
            withDefault(true, forKey: "groupsLoneBranches") {
                withDefault(false, forKey: "compactsSidebarTree") {
                    withDefault(
                        SidebarSessionOrder.manual.rawValue,
                        forKey: "sidebarSessionOrder"
                    ) {
                        withCleanNativeFactSelections {
                            let entries = ProjectSidebarViewController()
                                .arrangementMenuEntries()

                            XCTAssertEqual(
                                item(in: entries, titled: "Branch")?.isSelected,
                                true
                            )
                            XCTAssertEqual(
                                item(in: entries, titled: "Headings for Lone Branches")?.isSelected,
                                true
                            )
                            XCTAssertEqual(
                                item(in: entries, titled: "Compact Tree")?.isSelected,
                                false
                            )
                            // Unchosen, the preview is on — the iPhone app's arrangement.
                            UserDefaults.standard.removeObject(forKey: "previewsSidebarChats")
                            XCTAssertEqual(
                                ProjectSidebarViewController().arrangementMenuEntries()
                                    .compactMap(\.item)
                                    .first { $0.title == "Show Five Chats per Project" }?
                                    .isSelected,
                                true
                            )

                            let orderTitles = Set(SidebarSessionOrder.allCases.map(\.menuTitle))
                            let checkedOrders = flattenedItems(in: entries)
                                .filter { $0.isSelected && orderTitles.contains($0.title) }
                            XCTAssertEqual(
                                checkedOrders.map(\.title),
                                [SidebarSessionOrder.manual.menuTitle],
                                "exactly the chosen order should carry the check"
                            )
                        }
                    }
                }
            }
        }
    }

    /// The refinement refines the grouping rule, so without grouping it has nothing to say —
    /// disabled, not hidden, because a control that vanishes explains less than one that waits.
    func testLoneBranchItemDisablesWhileGroupingIsOff() throws {
        try withCleanNativeFactSelections {
            try withDefault(false, forKey: "groupsSessionsByBranch") {
                let entries = ProjectSidebarViewController().arrangementMenuEntries()
                let lone = try XCTUnwrap(item(in: entries, titled: "Headings for Lone Branches"))
                XCTAssertFalse(lone.isEnabled)
            }
        }
    }

    // MARK: - Wiring

    /// Choosing an order writes the setting the tree builder reads. Performed through the
    /// row's own closure, which is the route the menu takes.
    func testChoosingAnOrderWritesTheSetting() throws {
        defer {
            UserDefaults.standard.removeObject(forKey: "sidebarSessionOrder")
            UserDefaults.standard.removeObject(forKey: "sidebarSessionOrderIsReversed")
        }

        try withCleanNativeFactSelections {
            let sidebar = ProjectSidebarViewController()
            let row = try XCTUnwrap(item(
                in: sidebar.arrangementMenuEntries(),
                titled: SidebarSessionOrder.name.menuTitle
            ))

            row.onChoose?()

            XCTAssertEqual(AppSettings.shared.sidebarSessionOrder, .name)
        }
    }

    func testRegisteredFactsJoinExclusiveGroupAndSortControls() throws {
        let key = ExtensionFactKey(id: "gitlab.mr.state", version: 1)
        let definition = ExtensionFactDefinition(
            key: key,
            displayName: "Merge request state",
            valueType: .string,
            subjectKinds: [.repositoryBranch],
            usages: [.groupable, .sortable]
        )
        try withCleanNativeFactSelections {
            let sidebar = ProjectSidebarViewController(
                registeredFactChoicesProvider: { _, _ in [.available(definition)] }
            )
            let entries = sidebar.arrangementMenuEntries()
            let groupChoice = try XCTUnwrap(item(
                in: item(in: entries, titled: "Group by")?.submenu ?? [],
                titled: "Merge request state"
            ))
            groupChoice.onChoose?()

            XCTAssertEqual(NativeSidebarPipelineOptions.current.groupByFact, key)
            let groupedEntries = sidebar.arrangementMenuEntries()
            XCTAssertEqual(
                item(in: groupedEntries, titled: "Group by")?.subtitle,
                "Merge request state"
            )
            XCTAssertNotEqual(item(in: groupedEntries, titled: "Branch")?.isSelected, true)

            let sortChoice = try XCTUnwrap(item(
                in: item(in: groupedEntries, titled: "Sort by")?.submenu ?? [],
                titled: "Merge request state"
            ))
            sortChoice.onChoose?()
            XCTAssertEqual(NativeSidebarPipelineOptions.current.sortByFact, key)

            let sortedEntries = sidebar.arrangementMenuEntries()
            XCTAssertNotNil(item(in: sortedEntries, titled: "Ascending"))
            XCTAssertNotNil(item(in: sortedEntries, titled: "Descending"))
            let nameChoice = try XCTUnwrap(item(
                in: item(in: sortedEntries, titled: "Sort by")?.submenu ?? [],
                titled: SidebarSessionOrder.name.menuTitle
            ))
            nameChoice.onChoose?()
            XCTAssertNil(NativeSidebarPipelineOptions.current.sortByFact)
        }
    }

    func testChangingBetweenRegisteredAndBuiltInSortsStartsInNaturalDirection() throws {
        let key = ExtensionFactKey(id: "gitlab.mr.state", version: 1)
        let definition = ExtensionFactDefinition(
            key: key,
            displayName: "Merge request state",
            valueType: .string,
            subjectKinds: [.repositoryBranch],
            usages: [.sortable]
        )
        try withCleanNativeFactSelections {
            try withDefault(SidebarSessionOrder.manual.rawValue, forKey: "sidebarSessionOrder") {
                try withDefault(true, forKey: "sidebarSessionOrderIsReversed") {
                    let sidebar = ProjectSidebarViewController(
                        registeredFactChoicesProvider: { _, _ in [.available(definition)] }
                    )
                    let factChoice = try XCTUnwrap(item(
                        in: item(
                            in: sidebar.arrangementMenuEntries(),
                            titled: "Sort by"
                        )?.submenu ?? [],
                        titled: "Merge request state"
                    ))

                    factChoice.onChoose?()

                    XCTAssertEqual(NativeSidebarPipelineOptions.current.sortByFact, key)
                    XCTAssertFalse(AppSettings.shared.sidebarSessionOrderIsReversed)

                    let descending = try XCTUnwrap(item(
                        in: sidebar.arrangementMenuEntries(),
                        titled: "Descending"
                    ))
                    descending.onChoose?()
                    XCTAssertTrue(AppSettings.shared.sidebarSessionOrderIsReversed)

                    let sameBuiltInOrder = try XCTUnwrap(item(
                        in: sidebar.arrangementMenuEntries(),
                        titled: SidebarSessionOrder.manual.menuTitle
                    ))
                    sameBuiltInOrder.onChoose?()

                    XCTAssertNil(NativeSidebarPipelineOptions.current.sortByFact)
                    XCTAssertFalse(AppSettings.shared.sidebarSessionOrderIsReversed)
                }
            }
        }
    }

    func testLegacyProjectGroupingActionSwitchesFromRegisteredFactToBranch() throws {
        let key = ExtensionFactKey(id: "gitlab.mr.state", version: 1)
        try withDefault(true, forKey: "groupsSessionsByBranch") {
            try withDefault(
                NativeSidebarPipelineOptions.registeredFactWire(key),
                forKey: "nativeSidebarGroupByFact"
            ) {
                let sidebar = ProjectSidebarViewController()
                let entries = sidebar.projectMenuEntries(row: 0)
                let branch = try XCTUnwrap(item(
                    in: entries,
                    titled: "Group Sessions by Branch"
                ))

                XCTAssertFalse(branch.isSelected)
                XCTAssertNil(item(in: entries, titled: "Headings for Lone Branches"))
                branch.onChoose?()

                let values = NativeSidebarPipelineOptions.current
                XCTAssertNil(values.groupByFact)
                XCTAssertTrue(values.branchGrouping)
            }
        }
    }

    func testUnavailableRegisteredFactRemainsVisibleAndClearableByBuiltInChoice() throws {
        let wire = NativeSidebarPipelineOptions.registeredFactWire(
            ExtensionFactKey(id: "gitlab.mr.state", version: 1)
        )
        withDefault(wire, forKey: "nativeSidebarGroupByFact") {
            withDefault(wire, forKey: "nativeSidebarSortByFact") {
                let sidebar = ProjectSidebarViewController()
                let entries = sidebar.arrangementMenuEntries()
                XCTAssertEqual(
                    item(in: entries, titled: "Group by")?.subtitle,
                    "gitlab.mr.state@1 (Unavailable)"
                )
                XCTAssertEqual(
                    item(in: entries, titled: "Sort by")?.subtitle,
                    "gitlab.mr.state@1 (Unavailable)"
                )
                XCTAssertEqual(
                    item(in: entries, titled: "gitlab.mr.state@1 (Unavailable)")?.isEnabled,
                    false
                )

                item(in: entries, titled: "Branch")?.onChoose?()
                item(in: entries, titled: SidebarSessionOrder.manual.menuTitle)?.onChoose?()
                XCTAssertNil(NativeSidebarPipelineOptions.current.groupByFact)
                XCTAssertNil(NativeSidebarPipelineOptions.current.sortByFact)
            }
        }
    }

    /// Each order ships in its natural direction, and exactly one of the pair carries the check.
    func testTheNaturalDirectionCarriesTheCheckByDefault() throws {
        withCleanNativeFactSelections {
            withDefault(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder") {
                withDefault(false, forKey: "sidebarSessionOrderIsReversed") {
                    let entries = ProjectSidebarViewController().arrangementMenuEntries()

                    XCTAssertEqual(item(in: entries, titled: "Most Recent First")?.isSelected, true)
                    XCTAssertEqual(item(in: entries, titled: "Least Recent First")?.isSelected, false)
                }
            }
        }
    }

    func testChoosingTheReversedDirectionWritesTheSetting() throws {
        try withCleanNativeFactSelections {
            try withDefault(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder") {
                try withDefault(false, forKey: "sidebarSessionOrderIsReversed") {
                    let sidebar = ProjectSidebarViewController()
                    let row = try XCTUnwrap(
                        item(in: sidebar.arrangementMenuEntries(), titled: "Least Recent First")
                    )

                    row.onChoose?()

                    XCTAssertTrue(AppSettings.shared.sidebarSessionOrderIsReversed)
                }
            }
        }
    }

    /// A direction is a statement about one order's field, so the next order chosen starts at
    /// its own natural end rather than inheriting a reversal made about something else.
    func testChoosingADifferentOrderResetsTheDirection() throws {
        try withCleanNativeFactSelections {
            try withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
                try withDefault(true, forKey: "sidebarSessionOrderIsReversed") {
                    let sidebar = ProjectSidebarViewController()
                    let row = try XCTUnwrap(
                        item(
                            in: sidebar.arrangementMenuEntries(),
                            titled: SidebarSessionOrder.recentActivity.menuTitle
                        )
                    )

                    row.onChoose?()

                    XCTAssertFalse(AppSettings.shared.sidebarSessionOrderIsReversed)
                }
            }
        }
    }

    /// Re-choosing the order already checked is not a change, so it must not quietly undo a
    /// flip the user just made.
    func testRechoosingTheSameOrderKeepsItsDirection() throws {
        try withCleanNativeFactSelections {
            try withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
                try withDefault(true, forKey: "sidebarSessionOrderIsReversed") {
                    let sidebar = ProjectSidebarViewController()
                    let row = try XCTUnwrap(
                        item(
                            in: sidebar.arrangementMenuEntries(),
                            titled: SidebarSessionOrder.name.menuTitle
                        )
                    )

                    row.onChoose?()

                    XCTAssertTrue(AppSettings.shared.sidebarSessionOrderIsReversed)
                }
            }
        }
    }

    // MARK: - Helpers

    private func item(in entries: [ThemedMenuEntry], titled title: String) -> ThemedMenuItem? {
        flattenedItems(in: entries).first { $0.title == title }
    }

    private func flattenedItems(in entries: [ThemedMenuEntry]) -> [ThemedMenuItem] {
        entries.compactMap(\.item).flatMap { item in
            [item] + flattenedItems(in: item.submenu ?? [])
        }
    }

    private func withCleanNativeFactSelections(run: () throws -> Void) rethrows {
        try withDefault(nil, forKey: "nativeSidebarGroupByFact") {
            try withDefault(nil, forKey: "nativeSidebarSortByFact", run: run)
        }
    }
}
