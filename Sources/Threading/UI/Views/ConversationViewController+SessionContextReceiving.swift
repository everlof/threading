import Foundation

/// The native conversation is an adapter for Core's context destination capability. Core routes
/// to the capability and never needs to know which controller owns the composer.
extension ConversationViewController: SessionContextReceiving {}
