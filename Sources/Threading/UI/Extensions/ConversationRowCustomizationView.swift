import AppKit
import ThreadingExtensionKit

/// Retains one native conversation row inside the generic component-composition host.
///
/// Conversation rows are stateful AppKit objects: tool results attach after creation and a
/// permission card settles in place. Keeping the original object as `nativeContent` means an
/// extension hook decorates that state instead of receiving a snapshot or forcing Threading to
/// reconstruct it. The public contracts admit hooks only, so this wrapper can never detach the
/// native row without immediately placing it at `.proceed`.
@MainActor
final class ConversationRowCustomizationView: NSView {
    let target: ExtensionComponentTarget
    let nativeContent: NSView

    private let contentContainer: ComponentContentContainer
    private let customizationHost: ComponentCustomizationHost

    init(
        nativeContent: NSView,
        target: ExtensionComponentTarget,
        lookup: @escaping ComponentCustomizationHost.Lookup,
        onAction: @escaping @MainActor (ComponentCustomizationAction) -> Void
    ) {
        self.target = target
        self.nativeContent = nativeContent

        let container = ComponentContentContainer(defaultContent: nativeContent)
        contentContainer = container
        customizationHost = ComponentCustomizationHost(
            target: target,
            contentContainer: container,
            lookup: lookup,
            imageResolver: ExtensionComponentResourceResolver.image,
            onAction: onAction
        )

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(
            "conversation.component.\(target.component.rawValue)"
        )

        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        customizationHost.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
