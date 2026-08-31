import XCTest

@testable import Threading

final class RegistrySearchProviderTests: XCTestCase {
    func testCommandsAndSettingsUseSeparateTypedGroupsAndLocators() async throws {
        let descriptors = [
            descriptor(id: "workspace.open", title: "Open Workspace", origin: .builtIn),
            descriptor(
                id: "settings.row.general#Workspace",
                title: "Workspace",
                origin: .settings
            ),
        ]
        let provider = RegistrySearchProvider(descriptors: descriptors)

        let batches = try await search(provider, "workspace")

        XCTAssertEqual(batches.map(\.group), [.destinations, .settings])
        XCTAssertEqual(batches.flatMap(\.hits).map(\.locator), [
            .command("workspace.open"),
            .setting(destinationID: "settings.row.general#Workspace"),
        ])
    }

    func testUnavailableAndExcludedCommandsNeverBecomeRows() async throws {
        let provider = RegistrySearchProvider(descriptors: [
            descriptor(id: "safe", title: "Safe Action", origin: .builtIn),
            descriptor(
                id: "gone",
                title: "Unavailable Action",
                origin: .builtIn,
                availability: .unavailable(reason: "Gone")
            ),
        ])

        let batches = try await search(provider, "action -unavailable type:command")

        XCTAssertEqual(batches.flatMap(\.hits).map(\.locator), [.command("safe")])
    }

    func testProviderFilterFindsOnlyMatchingExtension() async throws {
        let provider = RegistrySearchProvider(descriptors: [
            descriptor(
                id: "extension.one.deploy",
                title: "Deploy",
                origin: .extensionCommand(identifier: "one", name: "Ship It", localID: "deploy")
            ),
            descriptor(
                id: "extension.two.deploy",
                title: "Deploy",
                origin: .extensionCommand(identifier: "two", name: "Other", localID: "deploy")
            ),
        ])

        let batches = try await search(provider, "deploy provider:\"Ship It\"")

        XCTAssertEqual(batches.flatMap(\.hits).map(\.locator), [.command("extension.one.deploy")])
    }

    private func search(
        _ provider: RegistrySearchProvider,
        _ text: String
    ) async throws -> [SearchBatch] {
        let query = try SearchQueryParser.parse(text, scope: .everywhere, generation: 1).get()
        var batches: [SearchBatch] = []
        for await batch in provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )) {
            batches.append(batch)
        }
        return batches
    }

    private func descriptor(
        id: String,
        title: String,
        origin: HostCommandDescriptor.Origin,
        availability: HostCommandDescriptor.Availability = .available
    ) -> HostCommandDescriptor {
        HostCommandDescriptor(
            id: id,
            title: title,
            detail: nil,
            group: "Test",
            shortcut: nil,
            origin: origin,
            scope: .application,
            risk: .ordinary,
            availability: availability
        )
    }
}
