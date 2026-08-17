import SwiftUI
import ThreadingRemoteKit

/// The display name a key-bar surface uses for an agent kind. The wire sends the raw kind
/// string; anything unknown keeps a readable capitalized form rather than disappearing.
func terminalKeyboardAgentName(for agentKind: String) -> String {
    MobileAgentIdentity.resolve(agentKind).displayName
}

/// The sheet the key bar opens: the editor content under its own navigation stack, with
/// Done returning to the terminal.
struct TerminalKeyboardEditorView: View {
    let agentKind: String
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TerminalKeyboardEditorContent(agentKind: agentKind)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(MobileL10n.string("Done")) { dismiss() }
                    }
                }
        }
        .preferredColorScheme(theme.colorScheme)
    }
}

/// The Settings route to the same editor: pick which agent's bar to edit, without needing a
/// live session of that kind.
struct TerminalKeyboardAgentList: View {
    @EnvironmentObject private var keyboards: MobileTerminalKeyboardStore
    @Environment(\.remoteTheme) private var theme

    private let agentKinds = ["claude", "codex", "grok", "opencode"]

    var body: some View {
        List {
            Section {
                ForEach(agentKinds, id: \.self) { kind in
                    NavigationLink {
                        TerminalKeyboardEditorContent(agentKind: kind)
                    } label: {
                        HStack {
                            Text(terminalKeyboardAgentName(for: kind))
                            Spacer()
                            if keyboards.hasCustomLayout(forAgentKind: kind) {
                                Text(MobileL10n.string("Customized"))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryLabel)
                            }
                        }
                    }
                }
            } footer: {
                Text(MobileL10n.string(
                    "The key bar under a remote terminal. Keyboards are stored on this device only."
                ))
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle(MobileL10n.string("Terminal Keys"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Termius-style keyboard editor: reorder and remove the keys of one agent kind's bar,
/// add chord keys from the catalogue or snippet keys with their own text, and return to the
/// stock bar. Edits save as they are made — a bar behind the sheet follows live.
struct TerminalKeyboardEditorContent: View {
    let agentKind: String
    @EnvironmentObject private var keyboards: MobileTerminalKeyboardStore
    @Environment(\.remoteTheme) private var theme
    @State private var keys: [RemoteTerminalKeyDefinition] = []
    @State private var confirmsReset = false

    var body: some View {
        List {
                Section {
                    ForEach(keys) { key in
                        NavigationLink {
                            TerminalKeyEditForm(key: key) { updated in
                                replace(updated)
                            }
                        } label: {
                            TerminalKeyRow(key: key)
                        }
                    }
                    .onMove { source, destination in
                        keys.move(fromOffsets: source, toOffset: destination)
                        save()
                    }
                    .onDelete { offsets in
                        keys.remove(atOffsets: offsets)
                        save()
                    }
                } header: {
                    Text(MobileL10n.string("Keys"))
                } footer: {
                    Text(MobileL10n.string(
                        "Drag to reorder with Edit. These keys apply to %@ sessions on this device.",
                        terminalKeyboardAgentName(for: agentKind)
                    ))
                }

                Section {
                    NavigationLink {
                        TerminalKeyCatalogView(existing: keys) { added in
                            append(added)
                        }
                    } label: {
                        Label(
                            MobileL10n.string("Add key"),
                            systemImage: "plus.square"
                        )
                    }
                    NavigationLink {
                        TerminalSnippetForm { added in
                            append(added)
                        }
                    } label: {
                        Label(
                            MobileL10n.string("Add snippet"),
                            systemImage: "text.badge.plus"
                        )
                    }
                }

                if keyboards.hasCustomLayout(forAgentKind: agentKind) {
                    Section {
                        Button(role: .destructive) {
                            confirmsReset = true
                        } label: {
                            Text(MobileL10n.string("Reset to standard keys"))
                        }
                    }
                }

                if let recoveryMessage = keyboards.recoveryMessage {
                    Section {
                        Label(recoveryMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(theme.warning)
                    }
                }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle(MobileL10n.string("Terminal Keys"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .themedConfirmationDialog(
            "Reset to standard keys?",
            message: MobileL10n.string(
                "Your customized %@ keys on this device will be removed.",
                terminalKeyboardAgentName(for: agentKind)
            ),
            isPresented: $confirmsReset,
            actions: [
                ThemedDialogAction("Reset", role: .destructive) { reset() },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
        .onAppear {
            keys = keyboards.layout(forAgentKind: agentKind).keys
        }
    }

    private func append(_ key: RemoteTerminalKeyDefinition) {
        keys.append(key)
        save()
    }

    private func replace(_ key: RemoteTerminalKeyDefinition) {
        guard let index = keys.firstIndex(where: { $0.id == key.id }) else { return }
        keys[index] = key
        save()
    }

    private func save() {
        keyboards.setLayout(RemoteTerminalKeyboardLayout(keys: keys), forAgentKind: agentKind)
    }

    private func reset() {
        keyboards.resetLayout(forAgentKind: agentKind)
        keys = keyboards.layout(forAgentKind: agentKind).keys
    }
}

/// One key as the editor lists it: the cap it will wear on the bar, then what it does.
private struct TerminalKeyRow: View {
    let key: RemoteTerminalKeyDefinition
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            Text(terminalKeyDisplayLabel(key))
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, MobileDesign.Spacing.small)
                .frame(minWidth: 44, minHeight: 30)
                .background(
                    theme.controlResting,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
            Text(terminalKeyDescription(for: key.action))
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
        }
    }
}

/// A one-line English description of what a key action does, localized at render.
func terminalKeyDescription(for action: RemoteTerminalKeyAction) -> String {
    switch action {
    case .named(let key, let modifiers):
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append(MobileL10n.string("Control")) }
        if modifiers.contains(.alt) { parts.append(MobileL10n.string("Option")) }
        if modifiers.contains(.shift) { parts.append(MobileL10n.string("Shift")) }
        parts.append(terminalNamedKeyDisplayName(key))
        return parts.joined(separator: " + ")
    case .sequence:
        return MobileL10n.string("Escape sequence")
    case .snippet(let text, let submits):
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return submits
            ? MobileL10n.string("Types “%@” and Return", line)
            : MobileL10n.string("Types “%@”", line)
    case .latch(let modifier):
        return modifier == .control
            ? MobileL10n.string("Holds Control for the next key")
            : MobileL10n.string("Holds Option for the next key")
    }
}

func terminalNamedKeyDisplayName(_ key: RemoteTerminalNamedKey) -> String {
    switch key {
    case .escape: return MobileL10n.string("Escape")
    case .tab: return MobileL10n.string("Tab")
    case .enter: return MobileL10n.string("Return")
    case .backspace: return MobileL10n.string("Delete")
    case .forwardDelete: return MobileL10n.string("Forward Delete")
    case .up: return MobileL10n.string("Up Arrow")
    case .down: return MobileL10n.string("Down Arrow")
    case .left: return MobileL10n.string("Left Arrow")
    case .right: return MobileL10n.string("Right Arrow")
    case .home: return MobileL10n.string("Home")
    case .end: return MobileL10n.string("End")
    case .pageUp: return MobileL10n.string("Page Up")
    case .pageDown: return MobileL10n.string("Page Down")
    case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
        return key.rawValue.uppercased()
    }
}

/// The catalogue: pick modifiers, then tap a key to add it as one chord. The two latching
/// modifiers are offered once each — a second ⌃ on the bar would fight the first.
private struct TerminalKeyCatalogView: View {
    let existing: [RemoteTerminalKeyDefinition]
    let onAdd: (RemoteTerminalKeyDefinition) -> Void
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var includesControl = false
    @State private var includesAlt = false
    @State private var includesShift = false

    var body: some View {
        List {
            Section {
                Toggle(MobileL10n.string("Control"), isOn: $includesControl)
                Toggle(MobileL10n.string("Option"), isOn: $includesAlt)
                Toggle(MobileL10n.string("Shift"), isOn: $includesShift)
            } header: {
                Text(MobileL10n.string("Combine with"))
            } footer: {
                Text(MobileL10n.string(
                    "The key is added as one chord — ⇧ Tab becomes a single ⇧tab key."
                ))
            }

            Section(MobileL10n.string("Keys")) {
                ForEach(RemoteTerminalNamedKey.allCases, id: \.rawValue) { key in
                    Button {
                        onAdd(RemoteTerminalKeyDefinition(action: .named(key, modifiers)))
                        dismiss()
                    } label: {
                        TerminalKeyRow(
                            key: RemoteTerminalKeyDefinition(action: .named(key, modifiers))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                ForEach(RemoteTerminalLatchingModifier.allCases, id: \.rawValue) { modifier in
                    Button {
                        onAdd(RemoteTerminalKeyDefinition(action: .latch(modifier)))
                        dismiss()
                    } label: {
                        TerminalKeyRow(
                            key: RemoteTerminalKeyDefinition(action: .latch(modifier))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(existing.contains { $0.action == .latch(modifier) })
                }
            } header: {
                Text(MobileL10n.string("Latching modifiers"))
            } footer: {
                Text(MobileL10n.string(
                    "Tap once to apply to the next key, twice to lock, again to release."
                ))
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle(MobileL10n.string("Add Key"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modifiers: RemoteTerminalKeyModifiers {
        var value: RemoteTerminalKeyModifiers = []
        if includesControl { value.insert(.control) }
        if includesAlt { value.insert(.alt) }
        if includesShift { value.insert(.shift) }
        return value
    }
}

/// The snippet form: a caption, the text it types, and whether Return follows.
private struct TerminalSnippetForm: View {
    let onAdd: (RemoteTerminalKeyDefinition) -> Void
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var text = ""
    @State private var submits = false

    var body: some View {
        List {
            Section(MobileL10n.string("Label")) {
                TextField(MobileL10n.string("Optional — the text leads otherwise"), text: $label)
            }
            Section {
                TextField(MobileL10n.string("Text to type"), text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .monospaced))
                Toggle(MobileL10n.string("Submit with Return"), isOn: $submits)
            } header: {
                Text(MobileL10n.string("Snippet"))
            } footer: {
                Text(MobileL10n.string(
                    "A long-press on a submitting snippet key inserts its text without running it."
                ))
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle(MobileL10n.string("Add Snippet"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(MobileL10n.string("Add")) {
                    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(RemoteTerminalKeyDefinition(
                        customLabel: trimmedLabel.isEmpty ? nil : trimmedLabel,
                        action: .snippet(text: text, submits: submits)
                    ))
                    dismiss()
                }
                .disabled(text.isEmpty)
            }
        }
    }
}

/// Editing one existing key: its caption always, its snippet text and Return behaviour when
/// it is a snippet, its chord when it is a catalogue key.
private struct TerminalKeyEditForm: View {
    let onSave: (RemoteTerminalKeyDefinition) -> Void
    @Environment(\.remoteTheme) private var theme
    @State private var key: RemoteTerminalKeyDefinition
    @State private var label: String
    @State private var snippetText: String
    @State private var snippetSubmits: Bool
    @State private var includesControl: Bool
    @State private var includesAlt: Bool
    @State private var includesShift: Bool

    init(key: RemoteTerminalKeyDefinition, onSave: @escaping (RemoteTerminalKeyDefinition) -> Void) {
        self.onSave = onSave
        _key = State(initialValue: key)
        _label = State(initialValue: key.customLabel ?? "")
        if case .snippet(let text, let submits) = key.action {
            _snippetText = State(initialValue: text)
            _snippetSubmits = State(initialValue: submits)
        } else {
            _snippetText = State(initialValue: "")
            _snippetSubmits = State(initialValue: false)
        }
        if case .named(_, let modifiers) = key.action {
            _includesControl = State(initialValue: modifiers.contains(.control))
            _includesAlt = State(initialValue: modifiers.contains(.alt))
            _includesShift = State(initialValue: modifiers.contains(.shift))
        } else {
            _includesControl = State(initialValue: false)
            _includesAlt = State(initialValue: false)
            _includesShift = State(initialValue: false)
        }
    }

    var body: some View {
        List {
            Section(MobileL10n.string("Label")) {
                TextField(
                    MobileL10n.string("Optional — the key names itself otherwise"),
                    text: $label
                )
            }

            if case .snippet = key.action {
                Section(MobileL10n.string("Snippet")) {
                    TextField(
                        MobileL10n.string("Text to type"),
                        text: $snippetText,
                        axis: .vertical
                    )
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .monospaced))
                    Toggle(MobileL10n.string("Submit with Return"), isOn: $snippetSubmits)
                }
            }

            if case .named(let namedKey, _) = key.action {
                Section {
                    Toggle(MobileL10n.string("Control"), isOn: $includesControl)
                    Toggle(MobileL10n.string("Option"), isOn: $includesAlt)
                    Toggle(MobileL10n.string("Shift"), isOn: $includesShift)
                } header: {
                    Text(MobileL10n.string("Combine with"))
                } footer: {
                    Text(terminalNamedKeyDisplayName(namedKey))
                }
            }

            Section {
                TerminalKeyRow(key: edited)
            } header: {
                Text(MobileL10n.string("Preview"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle(MobileL10n.string("Edit Key"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            commit()
        }
    }

    private var edited: RemoteTerminalKeyDefinition {
        var updated = key
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.customLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
        switch key.action {
        case .snippet:
            if !snippetText.isEmpty {
                updated.action = .snippet(text: snippetText, submits: snippetSubmits)
            }
        case .named(let namedKey, _):
            var modifiers: RemoteTerminalKeyModifiers = []
            if includesControl { modifiers.insert(.control) }
            if includesAlt { modifiers.insert(.alt) }
            if includesShift { modifiers.insert(.shift) }
            updated.action = .named(namedKey, modifiers)
        case .sequence, .latch:
            break
        }
        return updated
    }

    private func commit() {
        let updated = edited
        guard updated != key else { return }
        onSave(updated)
    }
}
