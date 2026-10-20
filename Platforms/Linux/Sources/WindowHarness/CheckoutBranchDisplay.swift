/// A live HEAD reading may deliberately have no branch while the checkout is detached.
enum CheckoutBranchDisplay: Equatable {
    case named(String)
    case detached

    var name: String? {
        if case .named(let name) = self { return name }
        return nil
    }
}
