import SwiftUI
import ThreadingExtensionKit
import ThreadingRemoteKit
import UIKit

/// The iPhone host for the same semantic panel tree the Mac renders with AppKit.
///
/// The extension stays on the Mac. Only its validated `ExtensionPanel` value and native control
/// events cross Remote Access; this view is not an HTML or pixel projection of the Mac sidepane.
struct RemoteExtensionPanelView: View {
    let session: RemoteSessionSummaryDTO
    let extensionIdentifier: String
    let panelID: String
    let client: RemoteClient

    @Environment(\.remoteTheme) private var theme
    @State private var panel: ExtensionPanel?
    @State private var extensionName: String?
    @State private var processGeneration: String?
    @State private var loadedProcessGeneration: String?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var loadError: String?
    @State private var actionSequence = 0
    @State private var renderRevision = 0

    var body: some View {
        Group {
            if let panel {
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(statusIsError ? theme.negative : theme.secondaryLabel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("extension.panel.status")
                        }

                        RemoteExtensionNodeView(
                            node: panel.root,
                            parentAxis: nil,
                            sessionID: session.id,
                            extensionIdentifier: extensionIdentifier,
                            panelID: panelID,
                            client: client,
                            onEvent: invoke
                        )
                        .id(renderRevision)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(MobileDesign.Spacing.inset)
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Extension panel unavailable", systemImage: "puzzlepiece.extension")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                MobileLoadingPlaceholder(MobileL10n.string("Opening extension panel…"))
            }
        }
        .background(theme.ground)
        .navigationTitle(panel?.title ?? extensionName ?? "Extension")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(MobileL10n.string("Refresh extension panel"))
            }
        }
        .task(id: "\(session.id)|\(extensionIdentifier)|\(panelID)") {
            await load()
        }
    }

    @MainActor
    private func load() async {
        do {
            let payload = try await client.extensionPanel(
                sessionID: session.id,
                extensionIdentifier: extensionIdentifier,
                panelID: panelID
            )
            try ExtensionPanel.nodeConstraints.validate(payload.panel.root)

            panel = payload.panel
            extensionName = payload.extensionName
            processGeneration = payload.processGeneration
            loadError = nil
            statusMessage = nil
            statusIsError = false
            renderRevision &+= 1

            guard loadedProcessGeneration != payload.processGeneration,
                  let loadActionID = payload.panel.loadActionID else { return }
            loadedProcessGeneration = payload.processGeneration
            await invokeAndWait(
                loadActionID,
                value: nil,
                pendingMessage: MobileL10n.string("Loading…")
            )
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.extensionPanelLoad, error: error)
            panel = nil
            loadError = error.localizedDescription
        }
    }

    private func invoke(_ actionID: String, _ value: ExtensionJSONValue?) {
        Task { await invokeAndWait(actionID, value: value) }
    }

    @MainActor
    private func invokeAndWait(
        _ actionID: String,
        value: ExtensionJSONValue?,
        pendingMessage: String? = nil
    ) async {
        guard let expectedGeneration = processGeneration else {
            statusMessage = MobileL10n.string("The extension panel is not ready yet.")
            statusIsError = true
            return
        }
        actionSequence &+= 1
        let sequence = actionSequence
        statusMessage = pendingMessage ?? MobileL10n.string("Running “%@”…", actionID)
        statusIsError = false

        do {
            let response = try await client.invokeExtensionPanelAction(
                sessionID: session.id,
                extensionIdentifier: extensionIdentifier,
                panelID: panelID,
                processGeneration: expectedGeneration,
                actionID: actionID,
                value: value
            )
            guard sequence == actionSequence else { return }
            let generationChanged = response.processGeneration != expectedGeneration
            processGeneration = response.processGeneration
            if generationChanged {
                loadedProcessGeneration = nil
            }
            if let replacement = response.panel {
                try ExtensionPanel.nodeConstraints.validate(replacement.root)
                panel = replacement
                renderRevision &+= 1
            }
            statusMessage = generationChanged
                ? MobileL10n.string(
                    "The extension restarted. Its current panel has been restored."
                )
                : response.error ?? response.message
            statusIsError = generationChanged || response.error != nil
            if generationChanged,
               loadedProcessGeneration != response.processGeneration,
               let loadActionID = panel?.loadActionID {
                loadedProcessGeneration = response.processGeneration
                await invokeAndWait(
                    loadActionID,
                    value: nil,
                    pendingMessage: MobileL10n.string("Loading…")
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard sequence == actionSequence else { return }
            MobileDiagnostics.logDegraded(.extensionPanelAction, error: error)
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }
}

private struct RemoteExtensionNodeView: View {
    let node: ExtensionNode
    let parentAxis: ExtensionAxis?
    let sessionID: String
    let extensionIdentifier: String
    let panelID: String
    let client: RemoteClient
    let onEvent: (String, ExtensionJSONValue?) -> Void

    @Environment(\.remoteTheme) private var theme

    @ViewBuilder
    var body: some View {
        switch node {
        case .text(let text, let role):
            Text(text)
                .font(textFont(role))
                .foregroundStyle(textColor(role))
                .lineLimit(isCompact(role) ? 1 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("extension.text.\(role.rawValue)")

        case .image(let reference, let role, let accessibilityLabel):
            RemoteExtensionImageView(
                reference: reference,
                role: role,
                accessibilityLabel: accessibilityLabel,
                sessionID: sessionID,
                extensionIdentifier: extensionIdentifier,
                panelID: panelID,
                client: client
            )

        case .button(let id, let title, let role, let isEnabled):
            extensionButton(id: id, title: title, role: role, isEnabled: isEnabled)

        case .textInput(
            let id,
            let value,
            let placeholder,
            let accessibilityLabel,
            let role,
            let isEnabled
        ):
            RemoteExtensionTextInput(
                id: id,
                initialValue: value,
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                role: role,
                isEnabled: isEnabled,
                onEvent: onEvent
            )

        case .picker(let id, let selection, let options, let accessibilityLabel, let isEnabled):
            RemoteExtensionPicker(
                id: id,
                initialSelection: selection,
                options: options,
                accessibilityLabel: accessibilityLabel,
                isEnabled: isEnabled,
                onEvent: onEvent
            )

        case .scene(let scene):
            RemoteExtensionSceneView(scene: scene, onEvent: onEvent)

        case .media(let document):
            let message = MobileL10n.string("This animation plays on your Mac.")
            Label(message, systemImage: "play.rectangle")
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(document.accessibilityLabel)
                .accessibilityIdentifier("extension.media.\(document.id)")

        case .status(let text, let role):
            Text(text)
                .font(.callout)
                .foregroundStyle(statusColor(role))
                .lineLimit(1)
                .accessibilityIdentifier("extension.status")

        case .disclosure(let id, let summary, let detail):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    ForEach(Array(detail.enumerated()), id: \.offset) { _, child in
                        childView(child, parentAxis: .vertical)
                    }
                }
                .padding(.top, MobileDesign.Spacing.small)
            } label: {
                childView(summary, parentAxis: parentAxis)
            }
            .id(id)

        case .proceed:
            EmptyView()

        case .overlay(let base, let overlay):
            ZStack {
                childView(base, parentAxis: nil)
                childView(overlay, parentAxis: nil)
            }

        case .customSurface(_, let accessibilityLabel):
            Label(
                "This custom extension surface is available on your Mac.",
                systemImage: "display"
            )
            .font(.footnote)
            .foregroundStyle(theme.secondaryLabel)
            .accessibilityLabel(accessibilityLabel ?? "Custom extension surface")

        case .divider:
            if parentAxis == .horizontal {
                Rectangle()
                    .fill(theme.divider)
                    .frame(width: max(1, theme.borderWidth))
                    .frame(maxHeight: .infinity)
            } else {
                Divider().overlay(theme.divider)
            }

        case .spacer(let spacing):
            Color.clear.frame(
                width: parentAxis == .horizontal ? spacingValue(spacing) : nil,
                height: parentAxis == .horizontal ? nil : spacingValue(spacing)
            )

        case .flexibleSpacer:
            Spacer(minLength: 0)

        case .stack(let axis, let spacing, let children):
            if axis == .horizontal {
                HStack(alignment: .center, spacing: spacingValue(spacing)) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        childView(child, parentAxis: axis)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: spacingValue(spacing)) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        childView(child, parentAxis: axis)
                    }
                }
            }
        }
    }

    private func childView(_ child: ExtensionNode, parentAxis: ExtensionAxis?) -> some View {
        RemoteExtensionNodeView(
            node: child,
            parentAxis: parentAxis,
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            client: client,
            onEvent: onEvent
        )
    }

    @ViewBuilder
    private func extensionButton(
        id: String,
        title: String,
        role: ExtensionButtonRole,
        isEnabled: Bool
    ) -> some View {
        switch role {
        case .primary:
            Button(title) { onEvent(id, nil) }
                .buttonStyle(MobileThemedActionButtonStyle(
                    kind: .primary,
                    theme: theme,
                    width: .intrinsic
                ))
                .disabled(!isEnabled)
                .accessibilityIdentifier("extension.action.\(id)")
        case .destructive:
            Button(title, role: .destructive) { onEvent(id, nil) }
                .buttonStyle(.bordered)
                .tint(theme.negative)
                .disabled(!isEnabled)
                .accessibilityIdentifier("extension.action.\(id)")
        case .standard:
            Button(title) { onEvent(id, nil) }
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .disabled(!isEnabled)
                .accessibilityIdentifier("extension.action.\(id)")
        }
    }

    private func textFont(_ role: ExtensionTextRole) -> Font {
        switch role {
        case .heading: .headline
        case .body: .body
        case .detail: .footnote
        case .code: .system(.body, design: .monospaced)
        case .compactBody: .callout
        case .compactDetail: .caption
        }
    }

    private func textColor(_ role: ExtensionTextRole) -> Color {
        switch role {
        case .detail, .compactDetail: theme.secondaryLabel
        default: theme.label
        }
    }

    private func isCompact(_ role: ExtensionTextRole) -> Bool {
        role == .compactBody || role == .compactDetail
    }

    private func statusColor(_ role: ExtensionStatusRole) -> Color {
        switch role {
        case .neutral: theme.secondaryLabel
        case .positive: theme.positive
        case .warning: theme.warning
        case .negative: theme.negative
        }
    }

    private func spacingValue(_ spacing: ExtensionSpacing) -> CGFloat {
        switch spacing {
        case .none: 0
        case .tight: MobileDesign.Spacing.tight
        case .small: MobileDesign.Spacing.small
        case .medium: MobileDesign.Spacing.medium
        case .large: MobileDesign.Spacing.large
        }
    }
}

private struct RemoteExtensionTextInput: View {
    let id: String
    let placeholder: String?
    let accessibilityLabel: String
    let role: ExtensionTextInputRole
    let isEnabled: Bool
    let onEvent: (String, ExtensionJSONValue?) -> Void

    @State private var value: String

    init(
        id: String,
        initialValue: String,
        placeholder: String?,
        accessibilityLabel: String,
        role: ExtensionTextInputRole,
        isEnabled: Bool,
        onEvent: @escaping (String, ExtensionJSONValue?) -> Void
    ) {
        self.id = id
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.role = role
        self.isEnabled = isEnabled
        self.onEvent = onEvent
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        TextField(placeholder ?? "", text: $value)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(role == .search ? .never : .sentences)
            .autocorrectionDisabled(role == .search)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("extension.input.\(id)")
            .onSubmit { onEvent(id, .string(value)) }
    }
}

private struct RemoteExtensionPicker: View {
    let id: String
    let options: [ExtensionPickerOption]
    let accessibilityLabel: String
    let isEnabled: Bool
    let onEvent: (String, ExtensionJSONValue?) -> Void

    @State private var selection: String

    init(
        id: String,
        initialSelection: String?,
        options: [ExtensionPickerOption],
        accessibilityLabel: String,
        isEnabled: Bool,
        onEvent: @escaping (String, ExtensionJSONValue?) -> Void
    ) {
        self.id = id
        self.options = options
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.onEvent = onEvent
        _selection = State(initialValue: initialSelection ?? "")
    }

    var body: some View {
        Picker(accessibilityLabel, selection: $selection) {
            if selection.isEmpty {
                Text("Choose…").tag("")
            }
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.title)
                    .tag(option.value)
                    .disabled(!option.isEnabled)
            }
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("extension.picker.\(id)")
        .onChange(of: selection) { _, value in
            guard !value.isEmpty else { return }
            onEvent(id, .string(value))
        }
    }
}

private struct RemoteExtensionImageView: View {
    let reference: ExtensionImageReference
    let role: ExtensionImageRole
    let accessibilityLabel: String?
    let sessionID: String
    let extensionIdentifier: String
    let panelID: String
    let client: RemoteClient

    @State private var image: UIImage?

    var body: some View {
        Group {
            switch reference {
            case .systemSymbol(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
            case .extensionResource:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                }
            case .hostAsset:
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(accessibilityLabel ?? "")
        .accessibilityHidden(accessibilityLabel == nil)
        .task(id: reference) {
            guard case .extensionResource(let path) = reference else { return }
            if let data = try? await client.extensionPanelResourceData(
                sessionID: sessionID,
                extensionIdentifier: extensionIdentifier,
                panelID: panelID,
                path: path
            ) {
                image = UIImage(data: data)
            }
        }
    }

    private var side: CGFloat {
        switch role {
        case .identity: 20
        case .icon: 16
        case .decoration: 14
        // A panel's vocabulary is `ExtensionImageRole.inline`; the fill role belongs to the
        // Mac's sidebar backdrop and never crosses to the phone. Sized as a decoration so a
        // validated tree cannot trap the renderer.
        case .backdrop: 14
        }
    }
}

/// The phone's semantic hierarchy projection has the same tens-of-marks expectation and 500-mark
/// stress bound as the Mac. One child traversal plus one source-order scan replaces a full parent
/// walk per mark whenever focus changes.
struct RemoteExtensionSceneHierarchyIndex {
    struct Traversal {
        let visibleItems: [ExtensionSceneItem]
        let workCount: Int
    }

    private let items: [ExtensionSceneItem]
    private let indexByID: [String: Int]
    private let childrenByParent: [String: [Int]]

    init(items: [ExtensionSceneItem]) {
        self.items = items
        self.indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map {
            ($0.element.id, $0.offset)
        })
        self.childrenByParent = Dictionary(grouping: items.enumerated().compactMap {
            index, item in item.parentID.map { ($0, index) }
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    func traversal(focusedOn focusID: String) -> Traversal {
        guard let focusIndex = indexByID[focusID] else {
            return Traversal(visibleItems: [], workCount: 0)
        }
        var depths = Array(repeating: -1, count: items.count)
        var stack = [(focusIndex, 0)]
        var traversed = 0
        var maximumDepth = 0
        while let (index, depth) = stack.popLast() {
            guard depths[index] < 0 else { continue }
            depths[index] = depth
            maximumDepth = max(maximumDepth, depth)
            traversed += 1
            for child in (childrenByParent[items[index].id] ?? []).reversed() {
                stack.append((child, depth + 1))
            }
        }
        var byDepth = Array(repeating: [ExtensionSceneItem](), count: maximumDepth + 1)
        for index in items.indices {
            let depth = depths[index]
            if depth >= 0 { byDepth[depth].append(items[index]) }
        }
        let visible = byDepth.flatMap { $0 }
        return Traversal(
            visibleItems: visible,
            workCount: traversed + items.count + visible.count
        )
    }
}

private struct RemoteExtensionSceneView: View {
    let scene: ExtensionScene
    let onEvent: (String, ExtensionJSONValue?) -> Void
    private let itemByID: [String: ExtensionSceneItem]
    private let parentIDs: Set<String>
    private let hierarchyIndex: RemoteExtensionSceneHierarchyIndex

    @State private var focusID: String?

    @Environment(\.remoteTheme) private var theme

    init(
        scene: ExtensionScene,
        onEvent: @escaping (String, ExtensionJSONValue?) -> Void
    ) {
        self.scene = scene
        self.onEvent = onEvent
        self.itemByID = Dictionary(uniqueKeysWithValues: scene.items.map { ($0.id, $0) })
        self.parentIDs = Set(scene.items.compactMap(\.parentID))
        self.hierarchyIndex = RemoteExtensionSceneHierarchyIndex(items: scene.items)
        _focusID = State(initialValue: scene.hierarchy?.rootID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            if scene.hierarchy != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MobileDesign.Spacing.tight) {
                        ForEach(Array(focusPath.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                // localization-ignore: Semantic breadcrumb separator, not prose.
                                Text("›")
                                    .font(.caption)
                                    .foregroundStyle(theme.tertiaryLabel)
                                    .accessibilityHidden(true)
                            }
                            if item.id == focusID {
                                Text(item.label ?? item.accessibilityLabel ?? item.id)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .accessibilityIdentifier("semantic-scene.breadcrumb.current")
                            } else {
                                Button(item.label ?? item.accessibilityLabel ?? item.id) {
                                    focusID = item.id
                                }
                                .buttonStyle(.plain)
                                .font(.callout)
                                .accessibilityIdentifier("semantic-scene.breadcrumb.\(item.id)")
                            }
                        }
                    }
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(visibleItems, id: \.id) { item in
                        sceneItem(item, size: geometry.size)
                    }
                }
            }
            .aspectRatio(scene.preferredAspectRatio, contentMode: .fit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(scene.accessibilityLabel)
        .accessibilityIdentifier("extension.scene")
    }

    @ViewBuilder
    private func sceneItem(_ item: ExtensionSceneItem, size: CGSize) -> some View {
        let normalized = transformedFrame(for: item)
        let frame = CGRect(
            x: size.width * normalized.x,
            y: size.height * normalized.y,
            width: size.width * normalized.width,
            height: size.height * normalized.height
        )
        if item.isEnabled, isNavigable(item) || item.actionID != nil {
            Button {
                activate(item)
            } label: {
                mark(item)
            }
            .buttonStyle(.plain)
            .frame(width: max(0, frame.width), height: max(0, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel(item.accessibilityLabel ?? item.label ?? item.id)
            .accessibilityValue(item.accessibilityValue ?? item.detail ?? "")
        } else {
            mark(item)
                .frame(width: max(0, frame.width), height: max(0, frame.height))
                .position(x: frame.midX, y: frame.midY)
                .accessibilityElement()
                .accessibilityLabel(item.accessibilityLabel ?? item.label ?? item.id)
                .accessibilityValue(item.accessibilityValue ?? item.detail ?? "")
        }
    }

    private var visibleItems: [ExtensionSceneItem] {
        guard let focusID else { return scene.items }
        return hierarchyIndex.traversal(focusedOn: focusID).visibleItems
    }

    private var focusPath: [ExtensionSceneItem] {
        guard var cursor = focusID else { return [] }
        var result: [ExtensionSceneItem] = []
        for _ in 0...scene.items.count {
            guard let item = itemByID[cursor] else { break }
            result.append(item)
            guard let parentID = item.parentID else { break }
            cursor = parentID
        }
        return result.reversed()
    }

    private func transformedFrame(for item: ExtensionSceneItem) -> ExtensionSceneRect {
        guard let focusID,
              let focus = itemByID[focusID] else {
            return item.frame
        }
        return ExtensionSceneRect(
            x: (item.frame.x - focus.frame.x) / focus.frame.width,
            y: (item.frame.y - focus.frame.y) / focus.frame.height,
            width: item.frame.width / focus.frame.width,
            height: item.frame.height / focus.frame.height
        )
    }

    private func isNavigable(_ item: ExtensionSceneItem) -> Bool {
        if item.id == focusID { return item.parentID != nil }
        return parentIDs.contains(item.id)
    }

    private func activate(_ item: ExtensionSceneItem) {
        if item.id == focusID, let parentID = item.parentID {
            focusID = parentID
        } else if parentIDs.contains(item.id) {
            focusID = item.id
        } else if let actionID = item.actionID {
            onEvent(actionID, .string(item.id))
        }
    }

    @ViewBuilder
    private func mark(_ item: ExtensionSceneItem) -> some View {
        let color = sceneColor(item.color).opacity(item.isEnabled ? 1 : 0.45)
        switch item.shape {
        case .rectangle:
            Rectangle()
                .fill(color)
                .overlay(Rectangle().stroke(item.isSelected ? theme.accent : .clear, lineWidth: 2))
                .overlay(markLabel(item))
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: theme.controlRadius)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: theme.controlRadius)
                    .stroke(item.isSelected ? theme.accent : .clear, lineWidth: 2))
                .overlay(markLabel(item))
        case .ellipse:
            Ellipse()
                .fill(color)
                .overlay(Ellipse().stroke(item.isSelected ? theme.accent : .clear, lineWidth: 2))
                .overlay(markLabel(item))
        }
    }

    @ViewBuilder
    private func markLabel(_ item: ExtensionSceneItem) -> some View {
        if let label = item.label {
            VStack(spacing: 1) {
                Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
                if let detail = item.detail {
                    Text(detail).font(.caption2).lineLimit(1)
                }
            }
            .foregroundStyle(theme.label)
            .padding(2)
        }
    }

    private func sceneColor(_ role: ExtensionSceneColorRole) -> Color {
        switch role {
        case .neutral: theme.controlResting
        case .accent: theme.accentMuted
        case .positive: theme.positive.opacity(0.7)
        case .warning: theme.warning.opacity(0.7)
        case .negative: theme.negative.opacity(0.7)
        case .category1: theme.accentMuted
        case .category2: theme.positive.opacity(0.55)
        case .category3: theme.warning.opacity(0.55)
        case .category4: theme.negative.opacity(0.55)
        case .category5: theme.selection
        case .category6: theme.secondaryLabel.opacity(0.5)
        }
    }
}
