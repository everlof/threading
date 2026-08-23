import AppKit
import ThreadingExtensionKit

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

        // **This container is sized by constraints, so it must not also be sized by its frame.**
        //
        // A fresh `NSView` starts with `translatesAutoresizingMaskIntoConstraints` on and a zero
        // frame, which AppKit turns into *required* `width == 0` / `height == 0`. Against the
        // required inset constraints below — and against `fixedWidth`, which states the popover's
        // 300pt outright — that is unsatisfiable from the first layout pass, and
        // `customizationHost.refresh()` at the end of this method takes one before any parent has
        // handed the view a frame.
        //
        // It cost nothing visible and roughly 8,000 breaks an hour in the log: every hover over a
        // sidebar row builds one of these, so `Unable to simultaneously satisfy constraints` for
        // `ComponentContentContainer` and everything under it was the ordinary sound of using the
        // app, and buried anything else worth reading there. The no-inset branch above already
        // returns a constraint-sized view — `ComponentContentContainer` turns translation off in
        // its own initializer — so this is the contract the callers already have, stated on the
        // one path that had forgotten it.
        let container = containerView ?? NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
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
