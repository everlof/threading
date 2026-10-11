import AppKit

/// The editor a local terminal agent opens through VISUAL/EDITOR. It runs in a short-lived
/// Threading child process so the provider can wait for the window to close and then reread its
/// own draft file. No session state or prompt text crosses into the running app.
@MainActor
enum ExternalPromptEditor {
    static func requestedFile(arguments: [String]) -> URL? {
        guard arguments.count == 3, arguments[1] == "--prompt-editor",
              !arguments[2].isEmpty else { return nil }
        return URL(fileURLWithPath: arguments[2])
    }

    static func run(file: URL) {
        let app = ThreadingApplication.shared
        app.setActivationPolicy(.accessory)
        AppThemeLibrary.prepareCustomFonts()
        AppThemeLibrary.restore()
        let window = ExternalPromptEditorWindowController(file: file)
        window.showWindow(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// This is a CLI-owned temporary draft, not a project file. Reads and writes stay off the UI
/// actor, accept UTF-8 only, and refuse a changed file rather than replacing another edit.
actor ExternalPromptEditorFileStore {
    enum Failure: LocalizedError {
        case invalidFile
        case tooLarge
        case invalidText
        case changed

        var errorDescription: String? {
            switch self {
            case .invalidFile: return L10n.string("The prompt file is unavailable.")
            case .tooLarge: return L10n.string("The prompt is too large to open here (1 MB maximum).")
            case .invalidText: return L10n.string("The prompt file is not UTF-8 text.")
            case .changed: return L10n.string("The prompt file changed while this editor was open.")
            }
        }
    }

    private let maximumBytes = 1_048_576

    func read(_ url: URL) throws -> (text: String, bytes: Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalidText }
        return (text, bytes)
    }

    func write(_ text: String, to url: URL, replacing baseline: Data) throws {
        let bytes = Data(text.utf8)
        guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
        let current = try read(url).bytes
        guard current == baseline else { throw Failure.changed }
        try bytes.write(to: url, options: .atomic)
    }
}

final class ExternalPromptEditorWindowController: ThemedWindowController, NSWindowDelegate {
    private let file: URL
    private let fileStore = ExternalPromptEditorFileStore()
    let source = ThemedTextView.scrolling()
    private let status = NSTextField(labelWithString: "")
    private let done = ThemedButton()
    nonisolated(unsafe) private var keyMonitor: Any?
    private var baseline: Data?
    private var isWriting = false
    private var loadTask: Task<Void, Never>?

    init(file: URL) {
        self.file = file
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 520, height: 330)
        window.title = L10n.string("Edit Prompt")
        window.backgroundColor = Design.Surface.ground
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command, event.charactersIgnoringModifiers == "s" {
                self.saveAndReturn()
                return nil
            }
            if modifiers == .command, event.keyCode == 36 {
                self.saveAndReturn()
                return nil
            }
            if modifiers.isEmpty, event.keyCode == 53 {
                self.cancel()
                return nil
            }
            return event
        }
        loadTask = Task { [weak self] in await self?.loadDraft() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(source.textView)
    }

    private func buildContent() {
        guard let window else { return }
        let root = ThemedSurfaceView()
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        window.contentView = root

        let title = NSTextField(labelWithString: L10n.string("Edit your message"))
        title.applyFont(.body)
        title.textColor = Design.Text.label
        title.translatesAutoresizingMaskIntoConstraints = false

        source.fillsViewport = true
        source.translatesAutoresizingMaskIntoConstraints = false
        source.applySurface(
            fill: Design.Surface.field,
            radius: .control,
            border: Design.Surface.border
        )
        source.textView.isRichText = false
        source.textView.isAutomaticQuoteSubstitutionEnabled = false
        source.textView.isAutomaticDashSubstitutionEnabled = false
        source.textView.isAutomaticTextReplacementEnabled = false
        source.textView.applyFont(.body)
        source.textView.textContainerInset = NSSize(width: Design.Spacing.medium, height: Design.Spacing.medium)
        source.textView.setAccessibilityLabel(L10n.string("Prompt text"))
        source.textView.setAccessibilityIdentifier("external-prompt-editor.text")

        status.applyFont(.caption)
        status.textColor = Design.Text.tertiary
        status.stringValue = L10n.string("Save and return to your draft. The message is not sent yet.")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = ThemedButton(title: L10n.string("Cancel"), target: self, action: #selector(cancel))
        cancel.setAccessibilityIdentifier("external-prompt-editor.cancel")
        done.title = L10n.string("Save and Return")
        done.emphasis = .primary
        done.target = self
        done.action = #selector(saveAndReturn)
        done.isEnabled = false
        done.setAccessibilityIdentifier("external-prompt-editor.done")

        let actions = NSStackView(views: [cancel, done])
        actions.orientation = .horizontal
        actions.spacing = Design.Spacing.small
        actions.translatesAutoresizingMaskIntoConstraints = false

        for child in [title, source, status, actions] { root.addSubview(child) }
        let inset = Design.Spacing.large
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -inset),
            source.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Design.Spacing.medium),
            source.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            source.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            status.topAnchor.constraint(equalTo: source.bottomAnchor, constant: Design.Spacing.medium),
            status.leadingAnchor.constraint(equalTo: source.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -Design.Spacing.small),
            actions.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
        ])
    }

    func waitForDraft() async {
        await loadTask?.value
    }

    private func loadDraft() async {
        do {
            let loaded = try await fileStore.read(file)
            baseline = loaded.bytes
            source.textView.string = loaded.text
            source.textView.setSelectedRange(NSRange(location: (loaded.text as NSString).length, length: 0))
            source.textView.undoManager?.removeAllActions()
            done.isEnabled = true
            window?.makeFirstResponder(source.textView)
        } catch {
            status.stringValue = error.localizedDescription
            status.textColor = Design.Text.label
        }
    }

    @objc private func saveAndReturn() {
        guard !isWriting, let baseline else { return }
        let draft = source.textView.string
        isWriting = true
        done.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await fileStore.write(draft, to: file, replacing: baseline)
                isWriting = false
                window?.close()
            } catch {
                isWriting = false
                done.isEnabled = true
                status.stringValue = error.localizedDescription
                status.textColor = Design.Text.label
            }
        }
    }

    @objc private func cancel() {
        guard !isWriting else { return }
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isWriting
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
