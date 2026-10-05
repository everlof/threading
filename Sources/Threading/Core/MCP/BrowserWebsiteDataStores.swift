import WebKit

/// Website state belongs to the owning project, independently of a tab's session or host.
@MainActor
enum BrowserWebsiteDataStores {
    // WebKit raises an Objective-C exception for this UUID rather than returning an error.
    private static let invalidProfileIdentifier = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
    // Reuse live stores without retaining one WebKit profile for every project ever visited.
    // Lookup is O(1); WebKit owns disk access and persistence for named profiles.
    private static let projectStores = NSMapTable<NSUUID, WKWebsiteDataStore>(
        keyOptions: .strongMemory,
        valueOptions: .weakMemory
    )

    static func store(
        for contextKind: BrowserContextKind,
        projectID: ProjectID?
    ) -> WKWebsiteDataStore {
        // A missing owner must never fall back to the app-wide signed-in profile.
        guard contextKind == .shared, let projectID else { return .nonPersistent() }

        let identifier = projectID.rawValue as NSUUID
        if let existing = projectStores.object(forKey: identifier) { return existing }

        let store: WKWebsiteDataStore
        if #available(macOS 14.0, *), projectID.rawValue != invalidProfileIdentifier {
            store = WKWebsiteDataStore(forIdentifier: projectID.rawValue)
        } else {
            // macOS 13 exposes only one persistent store. Keep project isolation there too;
            // shared state lasts while at least one of the project's browsers is alive.
            store = .nonPersistent()
        }
        projectStores.setObject(store, forKey: identifier)
        return store
    }
}
