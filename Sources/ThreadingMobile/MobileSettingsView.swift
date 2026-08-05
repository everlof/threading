import SwiftUI
import UIKit

struct MobileSettingsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showsNotifications = false
    @State private var showsDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    NavigationLink {
                        MobileAppIconSettingsView()
                    } label: {
                        SettingsRow(
                            symbol: "app.dashed",
                            title: "App icon",
                            detail: LocalizedStringKey(MobileAppIconChoice.current.displayName)
                        )
                    }

                    if model.canManageThemes {
                        NavigationLink {
                            MacAppearanceSettingsView()
                        } label: {
                            SettingsRow(
                                symbol: "paintpalette",
                                title: "Mac appearance",
                                detail: model.me?.theme.map {
                                    LocalizedStringKey($0.name)
                                }
                            )
                        }
                    }
                }

                Section("On this iPhone") {
                    NavigationLink {
                        CollaborationSettingsView()
                    } label: {
                        SettingsRow(
                            symbol: "person.2",
                            title: "Collaboration",
                            detail: "Presence, typing and drafts"
                        )
                    }

                    Button {
                        showsNotifications = true
                    } label: {
                        SettingsRow(
                            symbol: "bell",
                            title: "Notifications",
                            detail: notificationStatus
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section("Support") {
                    Button {
                        showsDiagnostics = true
                    } label: {
                        SettingsRow(
                            symbol: "stethoscope",
                            title: "Diagnostics",
                            detail: model.activeHost.map {
                                LocalizedStringKey($0.name)
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    Text("These iPhone preferences are available before you connect a Mac.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.ground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showsNotifications) {
            NotificationSettingsView()
                .environmentObject(notifications)
                .environmentObject(model)
                .environment(\.remoteTheme, theme)
        }
        .sheet(isPresented: $showsDiagnostics) {
            RemoteDiagnosticsView()
                .environmentObject(notifications)
                .environmentObject(model)
                .environment(\.remoteTheme, theme)
        }
        .presentationDetents([.large])
    }

    private var notificationStatus: LocalizedStringKey {
        switch notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "On"
        case .denied:
            return "Off"
        case .notDetermined:
            return "Not set"
        @unknown default:
            return "Unavailable"
        }
    }
}

private struct SettingsRow: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: MobileDesign.Size.minimumTapTarget
                )
                .background(
                    theme.accentMuted,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(title)
                    .foregroundStyle(theme.label)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct CollaborationSettingsView: View {
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        List {
            Section {
                Toggle("People in open sessions", isOn: $notifications.peoplePresenceEnabled)
                Toggle("Typing indicators", isOn: $notifications.typingIndicatorsEnabled)
                Toggle(
                    "Independent terminal drafts",
                    isOn: $notifications.independentTerminalDraftsEnabled
                )
            } footer: {
                Text(MobileL10n.string(
                    """
                    Presence stays inside the live session. Independent drafts keep devices \
                    from mixing keystrokes in the same terminal.
                    """
                ))
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle("Collaboration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MacAppearanceSettingsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @State private var pendingThemeID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let choices = model.me?.themeCatalog?.appThemes {
                ForEach(choices, id: \.id) { option in
                    Button {
                        choose(option.id)
                    } label: {
                        HStack(spacing: MobileDesign.Spacing.medium) {
                            Circle()
                                .fill(Color(uiColor: UIColor(remoteHex:
                                    option.colors["accent"] ?? "#FFFFFF") ?? .white))
                                .frame(width: 18, height: 18)
                                .overlay {
                                    Circle().stroke(theme.border, lineWidth: theme.borderWidth)
                                }
                            Text(option.name)
                                .foregroundStyle(theme.label)
                            Spacer()
                            if pendingThemeID == option.id {
                                ProgressView().controlSize(.small)
                            } else if model.me?.theme?.id == option.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingThemeID != nil)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(theme.negative)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.ground)
        .navigationTitle("Mac appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ id: String) {
        pendingThemeID = id
        errorMessage = nil
        Task {
            defer { pendingThemeID = nil }
            do {
                try await model.selectAppTheme(id)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MobileAppIconSettingsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @State private var selectedIconName = UIApplication.shared.alternateIconName
    @State private var pendingIconName: String?
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 96, maximum: 118), spacing: MobileDesign.Spacing.inset)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                if let recommendation {
                    Label(
                        MobileL10n.string("Your Mac uses %@", recommendation.displayName),
                        systemImage: "laptopcomputer"
                    )
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
                    .padding(MobileDesign.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.panel,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius)
                    )
                }

                LazyVGrid(columns: columns, spacing: MobileDesign.Spacing.large) {
                    ForEach(MobileAppIconChoice.all) { choice in
                        Button {
                            select(choice)
                        } label: {
                            VStack(spacing: MobileDesign.Spacing.small) {
                                ZStack(alignment: .topTrailing) {
                                    Image(choice.previewAssetName)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 76, height: 76)
                                        .clipShape(RoundedRectangle(cornerRadius: 17))
                                        .shadow(color: .black.opacity(0.22), radius: 5, y: 3)

                                    if selectedIconName == choice.alternateIconName {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(theme.ground, theme.accent)
                                            .background(theme.ground, in: Circle())
                                            .offset(x: 6, y: -6)
                                    } else if pendingIconName == choice.alternateIconName {
                                        ProgressView()
                                            .controlSize(.small)
                                            .padding(4)
                                            .background(theme.elevated, in: Circle())
                                            .offset(x: 6, y: -6)
                                    }
                                }

                                Text(choice.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(theme.label)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(minHeight: 32, alignment: .top)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(pendingIconName != nil)
                        .accessibilityLabel(choice.displayName)
                        .accessibilityAddTraits(
                            selectedIconName == choice.alternateIconName ? .isSelected : []
                        )
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(theme.negative)
                }

                Text("iOS asks for confirmation when you change an app icon. Threading never changes it automatically.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(MobileDesign.Spacing.large)
        }
        .background(theme.ground)
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selectedIconName = UIApplication.shared.alternateIconName }
    }

    private var recommendation: MobileAppIconChoice? {
        guard let id = model.me?.theme?.id else { return nil }
        return MobileAppIconChoice.all.first { $0.themeID == id }
    }

    private func select(_ choice: MobileAppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons,
              selectedIconName != choice.alternateIconName else { return }
        pendingIconName = choice.alternateIconName
        errorMessage = nil
        UIApplication.shared.setAlternateIconName(choice.alternateIconName) { error in
            Task { @MainActor in
                pendingIconName = nil
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    selectedIconName = choice.alternateIconName
                }
            }
        }
    }
}

struct MobileAppIconChoice: Identifiable, Equatable {
    let themeID: String?
    let displayName: String
    let alternateIconName: String?
    let previewAssetName: String

    var id: String { alternateIconName ?? "default" }

    static let all: [MobileAppIconChoice] = [
        .init(
            themeID: "system",
            displayName: "Threading",
            alternateIconName: nil,
            previewAssetName: "AppIconPreviewDefault"
        ),
        themed("editorial", "Editorial", "Editorial"),
        themed("cyberpunk", "Cyberpunk", "Cyberpunk"),
        themed("swiss-minimalist", "Swiss Minimalist", "SwissMinimalist"),
        themed("bauhaus", "Bauhaus", "Bauhaus"),
        themed("art-deco", "Art Deco", "ArtDeco"),
        themed("neo-brutalism", "Neo Brutalism", "NeoBrutalism"),
        themed("claymorphism", "Claymorphism", "Claymorphism"),
        themed("vaporwave", "Vaporwave", "Vaporwave"),
        themed("newsprint", "Newsprint", "Newsprint"),
        themed("botanical", "Botanical", "Botanical"),
        themed("industrial", "Industrial", "Industrial"),
        themed("platinum-9", "Mac OS 9 Platinum", "Platinum"),
        themed("beos-r5", "BeOS R5", "BeOS"),
        themed("openstep-42", "OPENSTEP 4.2", "OpenStep"),
        themed("irix-indigo-magic", "IRIX Indigo Magic", "IRIX"),
        themed("amiga-workbench-31", "Amiga Workbench 3.1", "Amiga"),
        themed("retro-98", "Windows 98", "Windows98"),
        themed("christmas", "Christmas", "Christmas"),
    ]

    @MainActor static var current: MobileAppIconChoice {
        let name = UIApplication.shared.alternateIconName
        return all.first { $0.alternateIconName == name } ?? all[0]
    }

    private static func themed(
        _ themeID: String,
        _ displayName: String,
        _ suffix: String
    ) -> MobileAppIconChoice {
        MobileAppIconChoice(
            themeID: themeID,
            displayName: displayName,
            alternateIconName: "AppIconTheme\(suffix)",
            previewAssetName: "AppIconPreview\(suffix)"
        )
    }
}
