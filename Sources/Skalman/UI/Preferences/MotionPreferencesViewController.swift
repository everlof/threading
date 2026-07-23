import AppKit

/// Motion preferences with the real components as previews. Effects expose
/// only their meaningful choice; timing and intensity remain app-owned.
final class MotionPreferencesViewController: NSViewController {

    private let orbStylePopUp = ThemedPopUp()
    private let orbPreview = WorkingOrbView()
    private let nameStylePopUp = ThemedPopUp()
    private let namePreview = MorphingTitleLabel()
    private var previewNameIndex = 0

    private let previewNames = [
        "Rename this conversation",
        "Polish the release notes",
        "Trace the session lifecycle"
    ]

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    private func setupControls() {
        for style in WorkingOrbStyle.allCases {
            orbStylePopUp.addItem(
                ThemedMenuItem(title: style.displayName, representedValue: style)
            )
        }
        let orbStyle = AppSettings.shared.workingOrbStyle
        orbStylePopUp.selectItem(
            at: WorkingOrbStyle.allCases.firstIndex(of: orbStyle) ?? 0
        )
        orbStylePopUp.target = self
        orbStylePopUp.action = #selector(orbStyleChanged)
        orbStylePopUp.translatesAutoresizingMaskIntoConstraints = false
        orbStylePopUp.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.controlWidth
        ).isActive = true
        orbPreview.prepareForWorking(style: orbStyle)

        for style in ChatNameMorphStyle.allCases {
            nameStylePopUp.addItem(
                ThemedMenuItem(title: style.displayName, representedValue: style)
            )
        }
        let nameStyle = AppSettings.shared.chatNameMorphStyle
        nameStylePopUp.selectItem(
            at: ChatNameMorphStyle.allCases.firstIndex(of: nameStyle) ?? 0
        )
        nameStylePopUp.target = self
        nameStylePopUp.action = #selector(nameStyleChanged)
        nameStylePopUp.translatesAutoresizingMaskIntoConstraints = false
        nameStylePopUp.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.controlWidth
        ).isActive = true

        namePreview.font = Design.Typography.emphasizedBody()
        namePreview.morphStyleOverride = nameStyle
        namePreview.setStringValue(previewNames[0], animated: false)
    }

    private func setupLayout() {
        let orbControl = NSStackView(views: [orbPreview, orbStylePopUp])
        orbControl.orientation = .horizontal
        orbControl.alignment = .centerY
        orbControl.spacing = Design.Spacing.medium

        let indicatorCard = SettingsCard(rows: [
            SettingsUI.row(
                title: "Working indicator",
                subtitle: "Random chooses a new visual for each turn without repeating "
                    + "the previous one. Choose a named orb to keep it fixed.",
                control: orbControl
            )
        ])

        let transitionCard = SettingsCard(rows: [
            SettingsUI.row(
                title: "Chat name transition",
                subtitle: "Used when the active chat is renamed. Animation timing is "
                    + "tuned by Skalman and follows Reduce Motion.",
                control: nameStylePopUp
            ),
            SettingsUI.fullRow(namePreviewRow())
        ])

        let page = SettingsUI.page([
            SettingsUI.heading("Motion"),
            SettingsUI.section("Working", indicatorCard),
            SettingsUI.section("Chat names", transitionCard)
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func namePreviewRow() -> NSView {
        let replay = SettingsUI.button(
            "Preview",
            target: self,
            action: #selector(previewNameMorph)
        )
        namePreview.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [namePreview, replay])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        return row
    }

    @objc private func orbStyleChanged() {
        guard let style = orbStylePopUp.selectedItem?.representedValue
                as? WorkingOrbStyle else { return }
        AppSettings.shared.workingOrbStyle = style
        orbPreview.prepareForWorking(style: style)
    }

    @objc private func nameStyleChanged() {
        guard let style = nameStylePopUp.selectedItem?.representedValue
                as? ChatNameMorphStyle else { return }
        AppSettings.shared.chatNameMorphStyle = style
        namePreview.morphStyleOverride = style
        previewNameMorph()
    }

    @objc private func previewNameMorph() {
        previewNameIndex = (previewNameIndex + 1) % previewNames.count
        namePreview.setStringValue(previewNames[previewNameIndex], animated: true)
    }
}
