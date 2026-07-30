import Foundation

/// One kind of OK-only statement the app can show — and the user can decline to see again.
///
/// The sibling of `ConfirmationPrompt`, for alerts that ask nothing: a confirmation's box says
/// "Don't ask again" and needs an accepted answer to remember, while a notice's box says
/// "Don't show this message again" and there is no answer to wait for. The two registers stay
/// separate because their policies are different shapes — a question needs `alwaysAsks`
/// reasons and a Return-key decision; a statement needs neither, and an *error* statement is
/// simply never given a key at all, which is how "errors always show" is enforced by
/// construction rather than by a flag someone could set wrongly.
///
/// Unlike `ConfirmationPrompt` this is not a closed enum, because the first notices are
/// extension command receipts and extension commands are dynamic — there is no compile-time
/// case per command to hang a policy switch on. What holds instead: a notice is only ever
/// minted through a named factory here, each factory prefixes its own namespace into the
/// stored key, and the Settings ▸ General Confirmations card carries the one switch that
/// un-hides everything (`GeneralSettingsRenderTests` holds the row to existing). A notice
/// with nowhere to be un-hidden is the same one-way door the confirmation register closes.
struct AppNotice: Hashable {

    /// The raw value in the stored hidden set. Never derived from display text — a rename
    /// must not un-hide a message somebody switched off.
    let storageKey: String

    /// The "done" receipt an extension command answers with. Keyed per command, so hiding
    /// "Checks refreshed." says nothing about another command of the same extension.
    ///
    /// `commandID` is the registry's qualified id (`extension.<identifier>.<command>`), which
    /// already namespaces the extension — the prefix here namespaces the notice *kind*, so a
    /// future static notice cannot collide with a receipt.
    static func extensionCommandReceipt(commandID: String) -> AppNotice {
        AppNotice(storageKey: "extensionCommandReceipt.\(commandID)")
    }
}
