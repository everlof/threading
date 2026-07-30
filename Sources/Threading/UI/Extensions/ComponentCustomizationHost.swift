import AppKit
import ThreadingExtensionKit

/// The reusable composition helper adopted by public AppKit components.
///
/// It owns registry lookup, semantic rendering, slot population, targeted refresh, action
/// routing, and fallback. The surrounding component remains responsible for selection, reuse,
/// layout outside the content container, and every other host-owned behavior in its contract.
@MainActor
final class ComponentCustomizationHost {
    typealias Lookup = @MainActor (
        ExtensionComponentTarget
    ) -> ComponentCustomizationResolution
    typealias ImageResolver = @MainActor (
        ExtensionImageReference,
        String?
    ) -> NSImage?
    typealias CustomSurfaceResolver = @MainActor (
        ExtensionCustomSurface,
        String
    ) -> NSView?

    private(set) var target: ExtensionComponentTarget
    private let contentContainer: ComponentContentContainer
    private let slots: [ExtensionComponentSlotID: NSStackView]
    private let lookup: Lookup
    private let imageResolver: ImageResolver
    private let customSurfaceResolver: CustomSurfaceResolver
    private let onAction: @MainActor (ComponentCustomizationAction) -> Void
    private let onProperties: (
        [ExtensionComponentPropertyID: ExtensionComponentPropertyValue]
    ) -> Void
    private let onResolution: (ComponentCustomizationResolution) -> Void
    private let appEvents = AppEventObservations()
    private var isActive = true

    init(
        target: ExtensionComponentTarget,
        contentContainer: ComponentContentContainer,
        slots: [ExtensionComponentSlotID: NSStackView] = [:],
        lookup: @escaping Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        },
        imageResolver: @escaping ImageResolver = { reference, _ in
            guard case .systemSymbol(let name) = reference else { return nil }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        },
        customSurfaceResolver: @escaping CustomSurfaceResolver = { _, _ in nil },
        onAction: @escaping @MainActor (ComponentCustomizationAction) -> Void = { _ in },
        onProperties: @escaping (
            [ExtensionComponentPropertyID: ExtensionComponentPropertyValue]
        ) -> Void = { _ in },
        onResolution: @escaping (ComponentCustomizationResolution) -> Void = { _ in }
    ) {
        self.target = target
        self.contentContainer = contentContainer
        self.slots = slots
        self.lookup = lookup
        self.imageResolver = imageResolver
        self.customSurfaceResolver = customSurfaceResolver
        self.onAction = onAction
        self.onProperties = onProperties
        self.onResolution = onResolution

        appEvents.observe(ComponentCustomizationDidChange.self) { [weak self] event in
            guard let self, self.isAffected(by: event.targets) else { return }
            self.refresh()
        }
    }

    func updateTarget(_ target: ExtensionComponentTarget) {
        self.target = target
        isActive = true
        refresh()
    }

    /// Restores the native subtree and ignores family-wide publications until a real entity
    /// target is installed again. Reused row classes use this for headings which deliberately
    /// are not part of the public component contract.
    func deactivate() {
        isActive = false
        clearRenderedCustomization()
    }

    func refresh() {
        guard isActive else {
            clearRenderedCustomization()
            return
        }
        let resolution = lookup(target)
        onResolution(resolution)
        onProperties(resolution.properties)
        renderComposition(resolution)
        renderSlots(resolution.slots)
    }

    private func clearRenderedCustomization() {
        onProperties([:])
        contentContainer.installReplacement(nil)
        renderSlots([:])
    }

    private func renderNode(
        _ node: ExtensionNode,
        extensionIdentifier: String?
    ) -> ExtensionNodeHostView? {
        guard allImagesResolve(
            in: node,
            extensionIdentifier: extensionIdentifier
        ) else {
            return nil
        }

        do {
            let rendered = try ExtensionNodeRenderer.render(
                node,
                imageResolver: { [imageResolver] reference in
                    imageResolver(reference, extensionIdentifier)
                },
                customSurfaceRenderer: { [customSurfaceResolver] surface in
                    guard let extensionIdentifier else { return nil }
                    return customSurfaceResolver(surface, extensionIdentifier)
                },
                onAction: { [weak self] actionID in
                    guard let self else { return }
                    self.onAction(
                        ComponentCustomizationAction(
                            target: self.target,
                            extensionIdentifier: extensionIdentifier,
                            actionID: actionID
                        )
                    )
                }
            )
            return rendered
        } catch {
            return nil
        }
    }

    /// Builds an around-hook chain inside-out. A bad hook is skipped, matching swizzle
    /// libraries' "call next" fallback without letting one extension blank the component.
    private func renderComposition(_ resolution: ComponentCustomizationResolution) {
        // Nothing to compose — which is every component in an app with no extension patching
        // it. Detaching the native subtree and putting it back to arrive at the tree already
        // on screen buys nothing and costs a layout pass and, until it was preserved, the
        // caret of anything being typed into.
        guard resolution.replacement != nil || !resolution.hooks.isEmpty else {
            contentContainer.installReplacement(nil)
            return
        }

        contentContainer.preservingFocus {
            composeContent(resolution)
        }
    }

    private func composeContent(_ resolution: ComponentCustomizationResolution) {
        var content: NSView
        var containsDefaultContent = false

        if let replacement = resolution.replacement,
           let rendered = renderNode(
               replacement,
               extensionIdentifier: resolution.replacementExtensionIdentifier
           ) {
            rendered.setAccessibilityIdentifier("extension.component.replacement")
            content = rendered
        } else {
            contentContainer.prepareDefaultContentForComposition()
            content = contentContainer.defaultContent
            containsDefaultContent = true
        }

        var installedHook = false
        for hook in resolution.hooks.reversed() {
            guard let rendered = renderNode(
                hook.node,
                extensionIdentifier: hook.extensionIdentifier
            ), rendered.installProceedContent(content) else {
                continue
            }
            rendered.setAccessibilityIdentifier(
                "extension.component.hook.\(hook.extensionIdentifier)"
            )
            content = rendered
            installedHook = true
        }

        if installedHook {
            if containsDefaultContent {
                contentContainer.installComposition(content)
            } else {
                contentContainer.installReplacement(content)
            }
        } else if resolution.replacement != nil, !containsDefaultContent {
            contentContainer.installReplacement(content)
        } else {
            contentContainer.installReplacement(nil)
        }
    }

    private func renderSlots(
        _ values: [ExtensionComponentSlotID: [ExtensionNode]]
    ) {
        for (id, stack) in slots {
            for child in stack.arrangedSubviews {
                stack.removeArrangedSubview(child)
                child.removeFromSuperview()
            }

            for node in values[id] ?? [] {
                guard let rendered = try? ExtensionNodeRenderer.render(
                    node,
                    imageResolver: { [imageResolver] reference in
                        imageResolver(reference, nil)
                    },
                    // Slot provenance becomes part of the resolution when interactive slots
                    // are exposed. Current public slots are status-only, so accepting a click
                    // without a source identity would be less safe than ignoring it.
                    onAction: { _ in }
                ) else {
                    continue
                }
                rendered.setAccessibilityIdentifier(
                    "extension.component.slot.\(id.rawValue)"
                )
                stack.addArrangedSubview(rendered)
            }
            stack.isHidden = stack.arrangedSubviews.isEmpty
        }
    }

    private func isAffected(
        by changedTargets: Set<ExtensionComponentTarget>?
    ) -> Bool {
        guard isActive else { return false }
        guard let changedTargets else { return true }
        return changedTargets.contains {
            $0.component == target.component
                && $0.contractVersion == target.contractVersion
                && ($0.entityID == nil || $0.entityID == target.entityID)
        }
    }

    /// A replacement is atomic: one unavailable package resource or contextual host image
    /// restores the native subtree instead of drawing a misleading half-identity.
    private func allImagesResolve(
        in node: ExtensionNode,
        extensionIdentifier: String?
    ) -> Bool {
        switch node {
        case .image(let reference, _, _):
            return imageResolver(reference, extensionIdentifier) != nil
        case .stack(_, _, let children):
            return children.allSatisfy {
                allImagesResolve(
                    in: $0,
                    extensionIdentifier: extensionIdentifier
                )
            }
        case .overlay(let base, let overlay):
            return allImagesResolve(
                in: base,
                extensionIdentifier: extensionIdentifier
            ) && allImagesResolve(
                in: overlay,
                extensionIdentifier: extensionIdentifier
            )
        default:
            return true
        }
    }
}
