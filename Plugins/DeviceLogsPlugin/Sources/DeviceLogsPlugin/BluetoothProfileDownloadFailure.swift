import Foundation
import ThreadingDesignKit

enum BluetoothProfileDownloadFailure: Error {
    case httpStatus(Int)
    case unexpectedProfile
    case blockedNavigation
    case webProcessTerminated

    /// Never display NSError.userInfo or localizedDescription from authentication: they may
    /// contain a sign-in URL, account identifier or token. Known categories and codes suffice.
    static func message(for error: Error) -> String {
        if let failure = error as? Self {
            switch failure {
            case .httpStatus(let status):
                return L10n.format("Apple returned HTTP %lld. Try downloading the profile again.", Int64(status))
            case .unexpectedProfile:
                return L10n.string("Apple did not return the expected Bluetooth profile. Try again, or choose a profile downloaded from Apple's Profiles and Logs page.")
            case .blockedNavigation:
                return L10n.string("The sign-in page tried to leave Apple's secure website. Reopen Install from Apple to try again.")
            case .webProcessTerminated:
                return L10n.string("The Apple sign-in page stopped unexpectedly. Reopen Install from Apple to try again.")
            }
        }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled:
                return L10n.string("Profile download cancelled.")
            case NSURLErrorTimedOut:
                return L10n.string("The Apple profile download timed out. Check your connection and try again.")
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return L10n.string("Could not connect to Apple. Check your internet connection and try again.")
            case NSURLErrorDataLengthExceedsMaximum:
                return L10n.string("The downloaded profile exceeds the 1 MiB size limit. Choose the Bluetooth profile from Apple's Profiles and Logs page.")
            case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile:
                return L10n.string("Could not save the Apple profile temporarily. Check available disk space and try again.")
            default:
                return L10n.format("The Apple profile download failed (network error %lld). Try again, or download the profile in your browser and choose the file here.", Int64(error.code))
            }
        }
        return L10n.format("The Apple profile download failed (browser error %lld). Reopen Install from Apple to try again.", Int64(error.code))
    }
}
