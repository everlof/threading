import Foundation
import ThreadingExtensionKit

struct ComponentCustomizationHook: Equatable {
    let node: ExtensionNode
    let extensionIdentifier: String
}

/// The host-owned result consumed synchronously by AppKit components.
///
/// The provider has already validated and ordered extension patches. Views never know which
/// process produced them and never perform IPC while configuring or laying out.
struct ComponentCustomizationResolution: Equatable {
    let properties: [ExtensionComponentPropertyID: ExtensionComponentPropertyValue]
    let slots: [ExtensionComponentSlotID: [ExtensionNode]]
    let replacement: ExtensionNode?
    let replacementExtensionIdentifier: String?
    let replacementCandidates: [String]
    /// Ordered outermost-first, like an around-hook chain. Each node contains exactly one
    /// `.proceed`, which invokes the next hook and eventually the native component.
    let hooks: [ComponentCustomizationHook]

    static let empty = Self(
        properties: [:],
        slots: [:],
        replacement: nil,
        replacementExtensionIdentifier: nil,
        replacementCandidates: [],
        hooks: []
    )

    var isEmpty: Bool {
        properties.isEmpty && slots.isEmpty && replacement == nil && hooks.isEmpty
    }
}

/// A semantic action raised by host-rendered component content.
///
/// AppKit objects never cross this seam. The selected replacement's extension identifier is
/// retained so the process transport can route the action without trusting an action ID to be
/// globally unique.
struct ComponentCustomizationAction: Equatable {
    let target: ExtensionComponentTarget
    let extensionIdentifier: String?
    let actionID: String
    let value: ExtensionJSONValue?

    init(
        target: ExtensionComponentTarget,
        extensionIdentifier: String?,
        actionID: String,
        value: ExtensionJSONValue? = nil
    ) {
        self.target = target
        self.extensionIdentifier = extensionIdentifier
        self.actionID = actionID
        self.value = value
    }
}

/// The complete optional seam exposed to customizable UI.
///
/// An extension registry is one implementation. Tests and the Component Gallery can install an
/// in-memory fixture. With no provider, the default UI remains the whole implementation.
@MainActor
protocol ComponentCustomizationProvider: AnyObject {
    func customization(
        for target: ExtensionComponentTarget
    ) -> ComponentCustomizationResolution
}

struct ComponentCustomizationDidChange: AppEvent {
    static let name = Notification.Name("componentCustomizationDidChange")

    /// Nil means every exposed component may have changed.
    let targets: Set<ExtensionComponentTarget>?
}

/// The replaceable process-wide provider slot installed at the app composition root.
@MainActor
final class ComponentCustomizationProviderSlot {
    static let shared = ComponentCustomizationProviderSlot()

    var actionHandler: ((ComponentCustomizationAction) -> Void)?

    var provider: (any ComponentCustomizationProvider)? {
        didSet {
            NotificationCenter.default.post(
                ComponentCustomizationDidChange(targets: nil)
            )
        }
    }

    func customization(
        for target: ExtensionComponentTarget
    ) -> ComponentCustomizationResolution {
        provider?.customization(for: target) ?? .empty
    }

    func perform(_ action: ComponentCustomizationAction) {
        actionHandler?(action)
    }
}
