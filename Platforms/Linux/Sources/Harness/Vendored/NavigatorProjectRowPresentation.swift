/// Native content for one mounted project navigator row. The host retains project identity,
/// commands, selection, accessibility, extension replacement and count/status receipts.
/// Computing this value is constant work per visible row.
struct NavigatorProjectRowPresentation: Equatable, Sendable {
    enum TitleRole: Equatable, Sendable {
        case emphasizedBody
        case caption
    }

    let title: String
    let secondaryPath: String?
    let showsIdentityMark: Bool
    let titleRole: TitleRole

    var isQuietHeading: Bool { titleRole == .caption }

    static func project(name: String) -> Self {
        Self(title: name, secondaryPath: nil, showsIdentityMark: true,
             titleRole: .emphasizedBody)
    }

    static func checkout(branch: String?, fallbackName: String, abbreviatedPath: String) -> Self {
        Self(title: branch ?? fallbackName, secondaryPath: "[\(abbreviatedPath)]",
             showsIdentityMark: false, titleRole: .emphasizedBody)
    }

    static func repository(name: String, hasRepresentative: Bool) -> Self {
        Self(title: name, secondaryPath: nil, showsIdentityMark: hasRepresentative,
             titleRole: hasRepresentative ? .emphasizedBody : .caption)
    }

    static func heading(name: String) -> Self {
        Self(title: name, secondaryPath: nil, showsIdentityMark: false,
             titleRole: .caption)
    }
}
