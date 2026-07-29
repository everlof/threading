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

private enum ThemedDialogStyle {
    case alert
    case confirmation
}

private struct ThemedDialogModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool

    let title: String
    let message: String?
    let style: ThemedDialogStyle
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
                        style: style,
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
        switch style {
        case .alert:
            return .scale(scale: 0.94).combined(with: .opacity)
        case .confirmation:
            return .move(edge: .bottom).combined(with: .opacity)
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

private struct ThemedDialogPresentation: View {
    private enum Metrics {
        static let alertMaximumWidth: CGFloat = 420
        static let confirmationMaximumWidth: CGFloat = 560
        static let bottomClearance: CGFloat = 48
        static let regularScrollHeight: CGFloat = 280
        static let accessibilityScrollHeight: CGFloat = 360
    }

    @Environment(\.remoteTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var textFieldIsFocused: Bool

    let title: String
    let message: String?
    let style: ThemedDialogStyle
    let textField: ThemedDialogTextField?
    let actions: [ThemedDialogAction]
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                scrim

                if style == .alert {
                    dialogCard
                        .frame(maxWidth: Metrics.alertMaximumWidth)
                        .padding(.horizontal, MobileDesign.Spacing.large)
                } else {
                    VStack {
                        Spacer(minLength: Metrics.bottomClearance)
                        dialogCard
                            .frame(maxWidth: Metrics.confirmationMaximumWidth)
                            .padding(.horizontal, MobileDesign.Spacing.medium)
                            .padding(
                                .bottom,
                                max(geometry.safeAreaInsets.bottom, MobileDesign.Spacing.medium)
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            guard textField != nil else { return }
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
            .contentShape(Rectangle())
            .onTapGesture {
                guard style == .confirmation else { return }
                dismiss()
            }
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
        VStack(
            alignment: style == .alert ? .center : .leading,
            spacing: 10
        ) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.label)
                .multilineTextAlignment(style == .alert ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: titleAlignment)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
                    .multilineTextAlignment(style == .alert ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: titleAlignment)
            }

            if let textField {
                TextField(textField.title, text: textField.text)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($textFieldIsFocused)
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
        if style == .alert, actions.count <= 2, !dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: MobileDesign.Spacing.medium) {
                ForEach(actions) { action in
                    actionButton(action, filled: action.role == .standard)
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
                            .padding(.leading, MobileDesign.Spacing.large)
                    }
                    actionButton(action, filled: false)
                }
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.medium)
        }
    }

    private func actionButton(
        _ action: ThemedDialogAction,
        filled: Bool
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
            }
        }
        .opacity(action.isEnabled ? 1 : 0.42)
        .disabled(!action.isEnabled)
        .accessibilityHint(
            action.role == .destructive ? MobileL10n.string("Destructive action") : ""
        )
    }

    private var titleAlignment: Alignment {
        style == .alert ? .center : .leading
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
        if filled { return theme.ground }
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
                style: .alert,
                textField: textField,
                actions: actions
            )
        )
    }

    /// Presents a themed action dialog anchored to the bottom of the screen.
    func themedConfirmationDialog(
        _ title: String,
        message: String? = nil,
        isPresented: Binding<Bool>,
        actions: [ThemedDialogAction]
    ) -> some View {
        modifier(
            ThemedDialogModifier(
                isPresented: isPresented,
                title: MobileL10n.string(title),
                message: message.map { MobileL10n.string($0) },
                style: .confirmation,
                textField: nil,
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
