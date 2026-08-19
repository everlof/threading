import Foundation

/// What the Remote Access page says about the certificate every routable door presents.
///
/// The certificate is the whole trust root: a phone pins it once, off the screen, and refuses
/// anything else afterwards. So the page shows the code the phone compares, and offers the two
/// operations that change it — a reset, which unpairs every device that did not hear about it,
/// and a rotation, which does not. Both are values here so the copy can be asserted without a
/// keychain, a certificate or a listener.
struct RemoteIdentityCardPresentation: Equatable, Sendable {

    /// The 26-character code of the certificate the doors are presenting now.
    let pairingCode: String?
    /// The successor that has been minted and announced, and is not presented yet.
    let nextPairingCode: String?
    /// Why there is no code, when one was asked for and there is none.
    let failure: String?

    /// A rotation can only start from an identity that exists.
    var canPrepareRotation: Bool { pairingCode != nil }
    /// And can only finish once a successor has been announced.
    var canActivateRotation: Bool { nextPairingCode != nil }

    static func resolve(_ snapshot: RemoteAccessIdentitySnapshot) -> RemoteIdentityCardPresentation {
        RemoteIdentityCardPresentation(
            pairingCode: snapshot.fingerprint?.pairingCode,
            nextPairingCode: snapshot.nextFingerprint?.pairingCode,
            failure: snapshot.failure.map(Self.sentence)
        )
    }

    /// The sentence beside the code. It says what the code is *for*, because a person looking at
    /// 26 characters they cannot read otherwise has no way to know whether it matters.
    static let explanation = L10n.string(
        "Your phone pins this Mac’s certificate when it scans the pairing code, and compares "
            + "this code with what answers every time it connects. Nothing else is trusted, so "
            + "no certificate authority can stand in for this Mac."
    )

    /// What the page says when no identity has been minted yet. Not a failure: nothing has asked
    /// for one, which is the state a Mac with no routable door is in.
    static let notMintedYet = L10n.string(
        "This Mac mints its certificate the first time a way in needs one."
    )

    private static func sentence(_ failure: RemoteIdentityFailure) -> String {
        switch failure {
        case .absent:
            return L10n.string("This Mac has no certificate yet.")
        case .directoryUnavailable:
            return L10n.string(
                "Threading could not open the folder its certificate lives in."
            )
        case .unreadable:
            return L10n.string(
                "Threading could not read its certificate. Resetting the identity mints a new "
                    + "one, and every paired device has to scan again."
            )
        case .unsupportedVersion:
            return L10n.string(
                "This Mac’s certificate was written by a newer version of Threading. Update "
                    + "Threading rather than resetting the identity, which would unpair every "
                    + "device."
            )
        case .corrupt:
            return L10n.string(
                "This Mac’s certificate file is not a certificate. Resetting the identity mints "
                    + "a new one, and every paired device has to scan again."
            )
        case .keyGenerationFailed, .certificateGenerationFailed, .identityImportFailed,
             .keychainUnavailable:
            return L10n.string(
                "Threading could not mint a certificate on this Mac. Try again, and report it if "
                    + "it keeps failing."
            )
        case .noRotationPrepared:
            return L10n.string("No successor certificate has been prepared.")
        }
    }
}
