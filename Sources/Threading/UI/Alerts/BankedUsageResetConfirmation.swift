import Foundation

/// Shared wording for every local surface that can spend a provider-issued reset credit.
/// Keeping it here makes `/usage`, the dashboard, and limit recovery ask the same irreversible
/// question and describe the same continuation boundary.
@MainActor
enum BankedUsageResetConfirmation {
    static func request(for offer: BankedUsageResetOffer) -> ConfirmationRequest {
        let countLine = L10n.format(
            "This permanently spends 1 of %lld banked resets for %@.",
            Int64(offer.availableCount),
            offer.accountName
        )
        let creditLine: String
        if offer.letsProviderChooseCredit {
            creditLine = L10n.string(
                "Codex did not report individual credits, so Codex will choose which reset to use."
            )
        } else {
            let title = offer.selectedCreditTitle ?? L10n.string("Banked usage reset")
            let expiry = offer.selectedCreditExpiresAt.map {
                L10n.format("expires %@", exactDateFormatter.string(from: $0))
            } ?? L10n.string("no expiry reported")
            creditLine = L10n.format("Credit: %@ · %@.", title, expiry)
        }
        let windows = offer.eligibleWindowLabels.isEmpty
            ? L10n.string("Eligible windows: determined by Codex.")
            : L10n.format(
                "Eligible windows: %@.",
                offer.eligibleWindowLabels.joined(separator: ", ")
            )
        let continuations: String
        if offer.owedContinuationCount == 0 {
            continuations = L10n.string(
                "No chat message will be created or sent by this reset."
            )
        } else {
            continuations = L10n.format(
                "%lld existing “continue on reset” messages for this account will be released only after Codex confirms new headroom. No message will be created or sent for any other chat.",
                Int64(offer.owedContinuationCount)
            )
        }
        return ConfirmationRequest(
            prompt: .consumeBankedUsageReset,
            title: L10n.string("Use a banked reset?"),
            message: [
                countLine,
                creditLine,
                windows,
                L10n.string("The next reset date for an affected window may move."),
                continuations
            ].joined(separator: "\n\n"),
            confirmTitle: L10n.string("Use Banked Reset")
        )
    }

    static func resultMessage(_ result: BankedUsageResetResult) -> String {
        switch result.outcome {
        case .reset:
            if !result.hasVerifiedHeadroom {
                return L10n.string(
                    "Codex used the reset, but the account still reports a full usage window. Waiting chats were not released."
                )
            }
            if result.continuationReleaseFailed {
                return L10n.string(
                    "Codex used the reset, but Threading could not release waiting continuations."
                )
            }
            return result.releasedContinuationCount == 0
                ? L10n.string("Codex used the banked reset.")
                : L10n.format(
                    "Codex used the reset · %lld continuations released.",
                    Int64(result.releasedContinuationCount)
                )
        case .alreadyRedeemed:
            if !result.hasVerifiedHeadroom {
                return L10n.string(
                    "Codex confirmed that reset was already used, but the account still reports a full usage window."
                )
            }
            return L10n.string("Codex confirmed that reset was already used.")
        case .nothingToReset:
            return L10n.string("Codex found no eligible limit to reset.")
        case .noCredit:
            return L10n.string("Codex found no banked reset available.")
        }
    }

    private static let exactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
