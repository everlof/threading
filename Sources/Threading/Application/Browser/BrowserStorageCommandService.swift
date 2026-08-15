import Foundation

struct BrowserSiteDataClearReport: Equatable {
    let recordsRemoved: Int?
    let context: BrowserContextKind
}

/// The UI adapter for one exact browser document. Presentation and WebKit mutation remain in the
/// adapter; command sequencing and refusal behavior live in `BrowserStorageCommandService`.
@MainActor
struct BrowserStorageCommandContext {
    let origin: BrowserOrigin
    let authorize: (@escaping (Bool) -> Void) -> Void
    let confirmClear: (@escaping (Bool) -> Void) -> Void
    let isCurrent: () -> Bool
    let clearSiteData: (@escaping (BrowserSiteDataClearReport) -> Void) -> Void
}

struct BrowserStorageCommandResult: Equatable {
    let succeeded: Bool
    let message: String

    static func success(_ message: String) -> Self {
        Self(succeeded: true, message: message)
    }

    static func failure(_ message: String) -> Self {
        Self(succeeded: false, message: message)
    }
}

/// Owns the destructive browser-storage command from decoded action through completion.
///
/// Its dependencies are narrow callbacks over one page lease, so refusal and race behavior can be
/// tested without constructing AgentToolCoordinator, AppKit, WebKit, or a window.
@MainActor
final class BrowserStorageCommandService {
    func execute(
        action rawAction: String?,
        context: () -> BrowserStorageCommandContext?,
        completion: @escaping (BrowserStorageCommandResult) -> Void
    ) {
        guard rawAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "clear_site_data" else {
            completion(.failure("action must be clear_site_data."))
            return
        }
        guard let context = context() else {
            completion(.failure(
                "Open an http or https page before clearing browser site data."
            ))
            return
        }

        context.authorize { allowed in
            guard allowed else {
                completion(.failure(
                    "The user did not allow browser access to \(context.origin.displayName)."
                ))
                return
            }
            guard context.isCurrent() else {
                completion(.failure(
                    "The shared browser page changed while access was being decided; retry "
                        + "against the site now on screen."
                ))
                return
            }

            context.confirmClear { confirmed in
                guard confirmed else {
                    completion(.failure("The user cancelled clearing browser site data."))
                    return
                }
                guard context.isCurrent() else {
                    completion(.failure(
                        "The browser page or tab changed before site data could be cleared; "
                            + "nothing was removed."
                    ))
                    return
                }

                context.clearSiteData { report in
                    completion(.success(Self.successMessage(
                        report: report,
                        origin: context.origin
                    )))
                }
            }
        }
    }

    private static func successMessage(
        report: BrowserSiteDataClearReport,
        origin: BrowserOrigin
    ) -> String {
        let detail: String
        if report.context == .private {
            detail = "Cleared the active tab's unique private WebKit data store."
        } else if let count = report.recordsRemoved, count > 0 {
            detail = "Cleared \(count) WebKit website data "
                + "\(count == 1 ? "record" : "records") for \(origin.displayName)."
        } else {
            detail = "WebKit reported no stored website data records for "
                + "\(origin.displayName); nothing needed removal."
        }
        return detail + "\nThe current document stayed loaded. Reload it explicitly "
            + "to fetch server-side signed-out state."
    }
}
