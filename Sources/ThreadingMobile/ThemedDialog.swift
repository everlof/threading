import SwiftUI
import UIKit

/// The explicit localization boundary for app-owned strings that must cross a `String` API.
///
/// SwiftUI localizes literal `LocalizedStringKey` values automatically. UIKit, shared dialog
/// models, error descriptions, and computed labels do not, so those paths resolve through this
/// helper instead. Human-readable English source text is the catalog key and remains the fallback
/// when a locale or individual translation is unavailable.
enum MobileL10n {
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, arguments: arguments)
    }

    static func string(_ key: String, arguments: [String]) -> String {
        string(key, arguments: arguments.map { $0 as CVarArg })
    }

    private static func string(_ key: String, arguments: [CVarArg]) -> String {
        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: key,
            comment: ""
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}

/// A semantic action shown by ``themedAlert`` or ``themedConfirmationDialog``.
///
/// Add new dialog capabilities to this primitive as soon as a real use case appears. Internal
/// app dialogs should not fall back to a one-off overlay or a system alert just because the
/// primitive does not support a new control yet; extending this model keeps every call site in
/// step with the shared Mac/iPhone theme. OS-owned surfaces such as notification permission and
/// the share sheet remain system UI.
struct ThemedDialogAction: Identifiable {
    enum Role {
        case standard
        case cancel
        case destructive
    }

    let id = UUID()
    let title: String
    let systemImage: String?
    let role: Role
    let isEnabled: Bool
    let perform: () -> Void

    /// `systemImage` decorates an alert's own buttons. A confirmation is the operating system's
    /// action sheet, which draws titles only, so the glyph is deliberately dropped there rather
    /// than re-skinned back in.
    init(
        _ title: String,
        systemImage: String? = nil,
        role: Role = .standard,
        isEnabled: Bool = true,
        perform: @escaping () -> Void = {}
    ) {
        self.title = MobileL10n.string(title)
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.perform = perform
    }

    var buttonRole: ButtonRole? {
        switch role {
        case .standard: nil
        case .cancel: .cancel
        case .destructive: .destructive
        }
    }
}

/// Optional text input for an alert. Extend this type instead of adding a separate rename sheet
/// when another input behaviour (secure entry, validation, multiple fields) becomes necessary.
struct ThemedDialogTextField {
    let title: String
    let text: Binding<String>

    init(_ title: String, text: Binding<String>) {
        self.title = MobileL10n.string(title)
        self.text = text
    }
}

private struct ThemedDialogModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool

    let title: String
    let message: String?
    let textField: ThemedDialogTextField?
    let actions: [ThemedDialogAction]

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!isPresented)
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    ThemedDialogPresentation(
                        title: title,
                        message: message,
                        textField: textField,
                        actions: actions,
                        dismiss: dismiss
                    )
                    .transition(transition)
                    .zIndex(10_000)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88),
                value: isPresented
            )
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: 0.94).combined(with: .opacity)
    }

    private func dismiss() {
        isPresented = false
    }
}

/// The bottom-anchored confirmation, which is the operating system's and not ours.
///
/// It used to be a card of our own: the theme's panel fill, our radii, our divider, our spring.
/// Two things were wrong with that. It read as nothing — an iPhone owner knows what an action
/// sheet standing on the bottom edge is, and a themed slab floating in the middle of the list
/// is a message from no one. And it *was* floating, because the overlay it lived in is only as
/// tall as the view it decorates, so "anchored to the bottom" meant the bottom of whatever the
/// modifier happened to be attached to rather than the bottom of the screen.
///
/// This is the same exception the boundary already makes for the share sheet and the permission
/// prompts: a surface whose presentation and trust story belong to iOS stays native and is not
/// imitated. `ThemedDialog` remains the single seam, so a call site still says
/// `themedConfirmationDialog` and still hands over `ThemedDialogAction` values.
///
/// **An item-backed dialog captures its item.** The system clears `isPresented` as part of
/// dismissing, and the button's handler runs after that, so a handler that reads the `@State`
/// the presentation binding nils out reads nothing. Build the actions from the item and let the
/// closures capture it.
private struct ThemedConfirmationDialogModifier: ViewModifier {
    @Binding var isPresented: Bool

    let title: String
    let message: String?
    let actions: [ThemedDialogAction]

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            ForEach(actions) { action in
                Button(action.title, role: action.buttonRole) { action.perform() }
                    .disabled(!action.isEnabled)
            }
        } message: {
            if let message, !message.isEmpty {
                Text(message)
            }
        }
    }
}

private struct ThemedDialogPresentation: View {
    private enum Metrics {
        static let alertMaximumWidth: CGFloat = 420
        static let headerSpacing: CGFloat = 10
        static let regularScrollHeight: CGFloat = 280
        static let accessibilityScrollHeight: CGFloat = 360
    }

    @Environment(\.remoteTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var textFieldIsFocused: Bool

    let title: String
    let message: String?
    let textField: ThemedDialogTextField?
    let actions: [ThemedDialogAction]
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            scrim

            dialogCard
                .frame(maxWidth: Metrics.alertMaximumWidth)
                .padding(.horizontal, MobileDesign.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            guard textField != nil else { return }
#if DEBUG
            // The evidence coordinator focuses and dismisses the real field itself when a
            // keyboard lifecycle is declared. Let it establish the unfocused baseline first.
            guard ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE"
            ] == nil else { return }
#endif
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                textFieldIsFocused = true
            }
        }
    }

    private var scrim: some View {
        Color.black
            .opacity(theme.colorScheme == .light ? 0.28 : 0.58)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var dialogCard: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                dialogHeader
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    dialogHeader
                }
                .frame(
                    maxHeight: dynamicTypeSize.isAccessibilitySize
                        ? Metrics.accessibilityScrollHeight
                        : Metrics.regularScrollHeight
                )
            }

            Divider().overlay(theme.divider)

            actionArea
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .remoteThemeGlow(theme)
        .shadow(color: .black.opacity(0.24), radius: 28, y: 14)
        .padding(.vertical, MobileDesign.Spacing.small)
    }

    private var dialogHeader: some View {
        VStack(alignment: .center, spacing: Metrics.headerSpacing) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let textField {
                TextField(textField.title, text: textField.text)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($textFieldIsFocused)
                    .mobileUIEvidenceKeyboardFocus($textFieldIsFocused)
                    .padding(.horizontal, MobileDesign.Spacing.medium)
                    .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                    .foregroundStyle(theme.label)
                    .tint(theme.accent)
                    .background(
                        theme.controlResting,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.controlRadius)
                            .stroke(theme.border, lineWidth: theme.borderWidth)
                    }
                    .padding(.top, MobileDesign.Spacing.small)
                    .onSubmit {
                        guard let primaryAction else { return }
                        run(primaryAction)
                    }
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.top, MobileDesign.Spacing.large)
        .padding(.bottom, MobileDesign.Spacing.large)
    }

    @ViewBuilder
    private var actionArea: some View {
        if actions.count <= 2, !dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: MobileDesign.Spacing.medium) {
                ForEach(actions) { action in
                    actionButton(
                        action,
                        filled: action.role == .standard,
                        outlined: action.role != .standard
                    )
                }
            }
            .frame(height: MobileDesign.Size.dialogActionHeight)
            .padding(MobileDesign.Spacing.inset)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 {
                        Divider()
                            .overlay(theme.divider)
                            .padding(.horizontal, MobileDesign.Spacing.large)
                    }
                    actionButton(action, filled: false, outlined: false)
                }
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.medium)
        }
    }

    private func actionButton(
        _ action: ThemedDialogAction,
        filled: Bool,
        outlined: Bool
    ) -> some View {
        Button {
            run(action)
        } label: {
            HStack(spacing: 8) {
                if let systemImage = action.systemImage {
                    Image(systemName: systemImage)
                }
                Text(action.title)
                    .font(.body.weight(action.role == .standard ? .semibold : .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: MobileDesign.Size.dialogActionHeight)
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground(for: action, filled: filled))
        .background {
            if filled {
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .fill(theme.accent)
            } else if outlined {
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .fill(theme.controlResting)
            }
        }
        .overlay {
            if outlined {
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }
        }
        .opacity(action.isEnabled ? 1 : 0.42)
        .disabled(!action.isEnabled)
        .accessibilityHint(
            action.role == .destructive ? MobileL10n.string("Destructive action") : ""
        )
    }

    private var cardRadius: CGFloat {
        theme.panelRadius
    }

    private var primaryAction: ThemedDialogAction? {
        actions.first { $0.role == .standard && $0.isEnabled }
    }

    private func foreground(
        for action: ThemedDialogAction,
        filled: Bool
    ) -> Color {
        if filled { return theme.accentForeground }
        switch action.role {
        case .standard: return theme.accent
        case .cancel: return theme.secondaryLabel
        case .destructive: return theme.negative
        }
    }

    private func run(_ action: ThemedDialogAction) {
        guard action.isEnabled else { return }
        action.perform()
        dismiss()
    }
}

extension View {
    /// Presents a compact, themed modal alert. Add newly required alert behaviours to
    /// `ThemedDialog` instead of bypassing it at an individual call site.
    func themedAlert(
        _ title: String,
        message: String? = nil,
        isPresented: Binding<Bool>,
        textField: ThemedDialogTextField? = nil,
        actions: [ThemedDialogAction]
    ) -> some View {
        modifier(
            ThemedDialogModifier(
                isPresented: isPresented,
                title: MobileL10n.string(title),
                message: message.map { MobileL10n.string($0) },
                textField: textField,
                actions: actions
            )
        )
    }

    /// Presents the operating system's action sheet, anchored to the bottom of the screen.
    ///
    /// This is the one place in `ThreadingMobile` that may say `confirmationDialog`;
    /// `check_mobile_theme_boundaries.py` enforces that, for the same reason the settings row
    /// plate has one owner. An item-backed call site builds its actions from the item and lets
    /// the handlers capture it: the system clears `isPresented` before the handler runs.
    func themedConfirmationDialog(
        _ title: String,
        message: String? = nil,
        isPresented: Binding<Bool>,
        actions: [ThemedDialogAction]
    ) -> some View {
        modifier(
            ThemedConfirmationDialogModifier(
                isPresented: isPresented,
                title: MobileL10n.string(title),
                message: message.map { MobileL10n.string($0) },
                actions: actions
            )
        )
    }
}

#if DEBUG
struct ThemedDialogDemoView: View {
    enum Kind {
        case alert
        case confirmation
    }

    @Environment(\.remoteTheme) private var theme
    @State private var isPresented = false
    @State private var sessionName = "Remote access review"

    let kind: Kind

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Themed dialogs")
                    .font(.largeTitle.bold())
                Text("A deterministic debug surface for visual review and future UI tests.")
                    .foregroundStyle(theme.secondaryLabel)
                Button("Show again") { isPresented = true }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .foregroundStyle(theme.accentForeground)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MobileDesign.Spacing.pane)
            .background(theme.ground)
            .navigationTitle("Code")
            .navigationBarTitleDisplayMode(.inline)
        }
        .themedAlert(
            "Rename session",
            message: "This name is shared with the Mac.",
            isPresented: alertBinding,
            textField: ThemedDialogTextField("Session name", text: $sessionName),
            actions: [
                ThemedDialogAction("Cancel", role: .cancel),
                ThemedDialogAction("Rename"),
            ]
        )
        .themedConfirmationDialog(
            "Share “Remote access review”",
            message: "Choose what this person can do in this chat.",
            isPresented: confirmationBinding,
            actions: [
                ThemedDialogAction("View only", systemImage: "eye"),
                ThemedDialogAction("Allow collaboration", systemImage: "person.2"),
                ThemedDialogAction(
                    "Collaboration + approvals",
                    systemImage: "checkmark.shield"
                ),
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            isPresented = true
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { kind == .alert && isPresented },
            set: { isPresented = $0 }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { kind == .confirmation && isPresented },
            set: { isPresented = $0 }
        )
    }
}
#endif
