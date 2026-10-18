import Foundation

extension AgentToolDependencies {
  /// Keeps a text comparison where a paired phone can reach it. Built from the stores already
  /// injected here, so a test that substitutes the attachment store substitutes this too.
  var comparisonKeeping: ComparisonKeepingService {
    ComparisonKeepingService(attachments: attachments, notificationTargets: notificationTargets)
  }
}
