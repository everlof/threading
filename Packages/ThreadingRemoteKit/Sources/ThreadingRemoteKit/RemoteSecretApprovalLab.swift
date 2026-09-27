import Foundation

/// Deliberately fixed experiment: no caller-selected credential, URL, command, or payload.
/// These values carry no authority without the Mac's live, locally enabled experiment.
public enum RemoteSecretApprovalLab {
    public static let path = "/api/labs/secret-approval"
    public static let operation = "authenticate-disposable-test-credential"
    public static let credential = "Threading disposable test credential"
    public static let githubOperation = "read-github-profile"
    public static let githubCredential = "GitHub profile trial token"
    public static let githubURL = "https://api.github.com/user"
    public static let githubMethod = "GET"
    public static let signingDomain = "Threading.SecretApprovalLab.v1\n"
    public static let enrollmentLifetime: TimeInterval = 300
    public static let approvalLifetime: Int64 = 60
    public static let maximumEnrollmentAttempts = 5
    public static let enrollmentCodeDigits = 8
    public static let enrollmentCodeUpperBound: UInt32 = 100_000_000
    public static let maximumRequestBytes = 2048
    public static let maximumResponseBytes = 4096
    public static let requestTimeout: TimeInterval = 10
    public static let publicKeyBytes = 65
    public static let maximumSignatureBytes = 80
    public static let allowedClockSkew: Int64 = 5

    public enum Action: String, Codable, Sendable {
        case enroll, challenge, approve, cancel
    }

    public struct Request: Codable, Sendable {
        public let action: Action
        public let enrollmentCode: String?
        public let publicKey: Data?
        public let challengeID: UUID?
        public let signature: Data?

        public init(action: Action, enrollmentCode: String? = nil, publicKey: Data? = nil,
                    challengeID: UUID? = nil, signature: Data? = nil) {
            self.action = action
            self.enrollmentCode = enrollmentCode
            self.publicKey = publicKey
            self.challengeID = challengeID
            self.signature = signature
        }
    }

    public struct Challenge: Codable, Equatable, Sendable {
        public let experimentID: UUID
        public let id: UUID
        public let deviceID: String
        public let expiresAt: Int64
        public let operation: String
        public let credential: String
        public let destination: String?
        public let method: String?

        public init(experimentID: UUID, id: UUID, deviceID: String, expiresAt: Int64, githubProfile: Bool = false) {
            self.experimentID = experimentID
            self.id = id
            self.deviceID = deviceID
            self.expiresAt = expiresAt
            operation = githubProfile ? RemoteSecretApprovalLab.githubOperation : RemoteSecretApprovalLab.operation
            credential = githubProfile ? RemoteSecretApprovalLab.githubCredential : RemoteSecretApprovalLab.credential
            destination = githubProfile ? RemoteSecretApprovalLab.githubURL : nil
            method = githubProfile ? RemoteSecretApprovalLab.githubMethod : nil
        }

        public var isGitHubProfile: Bool {
            operation == RemoteSecretApprovalLab.githubOperation
                && credential == RemoteSecretApprovalLab.githubCredential
                && destination == RemoteSecretApprovalLab.githubURL
                && method == RemoteSecretApprovalLab.githubMethod
        }

        public var isSupported: Bool {
            isGitHubProfile || (operation == RemoteSecretApprovalLab.operation
                && credential == RemoteSecretApprovalLab.credential && destination == nil && method == nil)
        }

        /// Same canonical bytes on both platforms; domain separation excludes other protocols.
        public func signingData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var result = Data(RemoteSecretApprovalLab.signingDomain.utf8)
            result.append(try encoder.encode(self))
            return result
        }
    }

    public struct Response: Codable, Sendable {
        public let challenge: Challenge?
        public let receipt: UUID?
        public let githubLogin: String?
        public init(challenge: Challenge? = nil, receipt: UUID? = nil, githubLogin: String? = nil) {
            self.challenge = challenge
            self.receipt = receipt
            self.githubLogin = githubLogin
        }
    }

    public static func isValidGitHubLogin(_ login: String) -> Bool {
        !login.isEmpty && login.utf8.count <= 39 && login.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }
}
