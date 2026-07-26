import AppKit
import SkalmanExtensionKit

/// Hosts one existing view controller behind the generic component-hook renderer.
///
/// The child remains the real controller and owns all behavior. Around-hooks only compose its
/// view with host-rendered extension content through `.proceed`.
@MainActor
final class ExtensionComponentHookViewController: NSViewController {
    private let child: NSViewController
    private let contentContainer: ComponentContentContainer
    private let customizationHost: ComponentCustomizationHost
    private let contentInsets: NSEdgeInsets
    private let fixedWidth: CGFloat?
    private let containerView: NSView?

    init(
        target: ExtensionComponentTarget,
        child: NSViewController,
        contentInsets: NSEdgeInsets = .init(),
        fixedWidth: CGFloat? = nil,
        containerView: NSView? = nil,
        lookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        },
        imageResolver: @escaping ComponentCustomizationHost.ImageResolver =
            ExtensionComponentResourceResolver.image,
        customSurfaceResolver: @escaping ComponentCustomizationHost.CustomSurfaceResolver = {
            _, _ in nil
        },
        onAction: @escaping @MainActor (ComponentCustomizationAction) -> Void = {
            ComponentCustomizationProviderSlot.shared.perform($0)
        },
        onResolution: @escaping (ComponentCustomizationResolution) -> Void = { _ in }
    ) {
        self.child = child
        self.contentInsets = contentInsets
        self.fixedWidth = fixedWidth
        self.containerView = containerView
        contentContainer = ComponentContentContainer(defaultContent: child.view)
        customizationHost = ComponentCustomizationHost(
            target: target,
            contentContainer: contentContainer,
            lookup: lookup,
            imageResolver: imageResolver,
            customSurfaceResolver: customSurfaceResolver,
            onAction: onAction,
            onResolution: onResolution
        )
        super.init(nibName: nil, bundle: nil)
        addChild(child)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hasInsets = contentInsets.top != 0
            || contentInsets.left != 0
            || contentInsets.bottom != 0
            || contentInsets.right != 0
        guard fixedWidth != nil || hasInsets else {
            view = contentContainer
            customizationHost.refresh()
            return
        }

        let container = containerView ?? NSView()
        container.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: contentInsets.top
            ),
            contentContainer.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -contentInsets.bottom
            ),
            contentContainer.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: contentInsets.left
            ),
            contentContainer.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -contentInsets.right
            )
        ])
        if let fixedWidth {
            container.widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true
        }
        view = container
        customizationHost.refresh()
    }
}

/// A zero-content `.proceed` target for extension-created presentations.
///
/// Keeping this as a real child controller means the composition host needs no special
/// "there is no native view" branch. Hooks can still call `.proceed`, and replacement fallback
/// remains the exact empty native state.
final class EmptyComponentContentViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}
