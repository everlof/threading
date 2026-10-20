import Foundation
import Security

/// Verifies the code that a signed first-party manifest named, before it can be approved to
/// run without a prompt. The code requirement is checked on the extracted bundle's final path.
enum NativePluginManagedCode {
    static let teamIdentifier = "SMQ3E8Y57T"

    enum VerificationError: LocalizedError, Equatable {
        case requirementUnavailable
        case signatureInvalid(OSStatus)
        case wrongBuild

        var errorDescription: String? {
            switch self {
            case .requirementUnavailable:
                return L10n.string("Threading could not check the plugin’s code requirement.")
            case .signatureInvalid:
                return L10n.string("The plugin is not signed and notarized by Threading.")
            case .wrongBuild:
                return L10n.string("The plugin code does not match the signed release manifest.")
            }
        }
    }

    static func verify(
        bundle: URL,
        expectedIdentifier: String,
        expectedCodeDirectoryHash: String
    ) throws {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            throw VerificationError.signatureInvalid(created)
        }

        let expression =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and notarized"
        var requirement: SecRequirement?
        let compiled = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard compiled == errSecSuccess, let requirement else {
            throw VerificationError.requirementUnavailable
        }
        // A first-party bundle can carry an executable helper. Recursively validate nested
        // code before the managed receipt gives that helper a first-party route.
        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        let checked = SecStaticCodeCheckValidity(staticCode, validationFlags, requirement)
        guard checked == errSecSuccess else {
            throw VerificationError.signatureInvalid(checked)
        }

        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        )
        guard read == errSecSuccess, let fields = information as? [String: Any] else {
            throw VerificationError.signatureInvalid(read)
        }
        let identifier = fields[kSecCodeInfoIdentifier as String] as? String
        let team = fields[kSecCodeInfoTeamIdentifier as String] as? String
        let hash = (fields[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }.joined()
        guard identifier == expectedIdentifier,
              team == teamIdentifier,
              hash == expectedCodeDirectoryHash else {
            throw VerificationError.wrongBuild
        }
    }
}
