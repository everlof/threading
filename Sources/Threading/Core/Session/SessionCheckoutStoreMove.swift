import Foundation

struct SessionCheckoutStoreDestination: Equatable {
    let projectID: ProjectID
    let checkoutPath: String
    let branch: String
    let createdProject: Bool
}

enum SessionCheckoutStoreMoveResult: Equatable {
    case moved(SessionCheckoutStoreDestination)
    case unchanged(SessionCheckoutStoreDestination)
    case sessionNotFound
    case persistenceRefused
}
