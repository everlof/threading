import Foundation

struct PTYHostLaunchError: LocalizedError, Equatable, Sendable {
    let cause: String

    var errorDescription: String? {
        L10n.string(
            "The background session host is unavailable. Threading kept this session stopped "
                + "so it would not be interrupted when the app closes."
        )
    }
}
