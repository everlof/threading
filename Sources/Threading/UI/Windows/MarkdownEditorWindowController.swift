import AppKit
import UniformTypeIdentifiers

/// A document window with themed content and host-owned save/close authority.
final class MarkdownEditorWindowController: ThemedWindowController, NSWindowDelegate {
    let editor = MarkdownEditorViewController()
    private(set) var fileURL: URL?
    private var baseline: Data?
    private var savedText: String
    private var currentText: String
    private var isSaving = false
    private var isReviewingClose = false
    private var permitsClose = false
    private var keyMonitor: Any?
    var onClose: (() -> Void)?
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?

    var isDirty: Bool { currentText != savedText }
    var needsQuitReview: Bool { isDirty || isSaving }
    private(set) var editRevision = 0

    init(url: URL? = nil, contents: MarkdownEditorFileStore.Contents? = nil) {
        fileURL = contents?.url ?? url
        baseline = contents?.bytes
        savedText = contents?.text ?? ""
        currentText = savedText
        let window = TitlebarActionWindow(
            contentRect: NSRect(origin: .zero, size: MarkdownEditorDefaults.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = MarkdownEditorDefaults.minimumSize
        window.backgroundColor = Design.Surface.ground
        window.isReleasedWhenClosed = false
        super.init(window: window)
        editor.view.setFrameSize(MarkdownEditorDefaults.windowSize)
        contentViewController = editor
        window.delegate = self
        editor.setSource(currentText)
        editor.onChange = { [weak self] text in
            self?.currentText = text
            self?.editRevision += 1
            self?.updateTitle()
        }
        editor.onSave = { [weak self] in self?.save() }
        updateTitle()
        // Mount before placing the divider so its first share uses the actual document width.
        window.setContentSize(MarkdownEditorDefaults.windowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        editor.splitView.layoutSubtreeIfNeeded()
        editor.splitView.setPosition((editor.splitView.bounds.width - editor.splitView.dividerThickness) / 2, ofDividerAt: 0)
        editor.splitView.layoutSubtreeIfNeeded()
        window.center()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  self.window?.isKeyWindow == true, !isReviewingClose,
                  self.window?.attachedSheet == nil else { return event }
            return handleDocumentKey(event) ? nil : event
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(editor.sourceScroll.textView)
    }

    /// Document keys are scoped to this window; the main window keeps its existing bindings.
    func handleDocumentKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": save(asCopy: modifiers.contains(.shift)); return true
        case "o" where modifiers == .command: onOpen?(); return true
        case "n" where modifiers == .command: onNew?(); return true
        case "w" where modifiers == .command: window?.performClose(nil); return true
        default: return false
        }
    }

    func save(asCopy: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !isSaving, let window else { completion?(false); return }
        if let url = fileURL, !asCopy {
            write(to: url, baseline: baseline, completion: completion)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [MarkdownFileAssociation.contentType, MarkdownFileAssociation.mcContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion?(false); return }
            // Save As to the current path still has to honor the external-change baseline.
            let sameFile = url.standardizedFileURL == fileURL?.standardizedFileURL
            write(to: url, baseline: sameFile ? baseline : nil, completion: completion)
        }
    }

    private func write(to url: URL, baseline: Data?, completion: ((Bool) -> Void)?) {
        let snapshot = currentText
        isSaving = true
        updateTitle()
        Task { [weak self] in
            guard let self else { completion?(false); return }
            do {
                let bytes = try await MarkdownEditorFileStore.shared.save(snapshot, to: url, baseline: baseline)
                fileURL = url
                self.baseline = bytes
                savedText = snapshot
                isSaving = false
                updateTitle()
                completion?(true)
            } catch {
                isSaving = false
                updateTitle()
                present(error)
                completion?(false)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSaving else { return false }
        if permitsClose || !isDirty { return true }
        reviewUnsavedChanges { [weak self] confirmed in
            guard confirmed, let self else { return }
            permitsClose = true
            window?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func reviewUnsavedChanges(completion: @escaping (Bool) -> Void) {
        guard !isSaving, !isReviewingClose, let window else { completion(false); return }
        guard isDirty else { completion(true); return }
        isReviewingClose = true
        window.makeKeyAndOrderFront(nil)
        let request = ChoiceRequest(
            prompt: .closeMarkdownDocument,
            title: L10n.format("Save changes to %@?", fileURL?.lastPathComponent ?? L10n.string("Untitled")),
            message: L10n.string("Your changes will be lost if you close without saving."),
            options: [ConfirmationOption(title: L10n.string("Save")), ConfirmationOption(title: L10n.string("Don't Save"))]
        )
        ConfirmationAlert.choose(request, in: window) { [weak self] choice in
            guard let self else { completion(false); return }
            isReviewingClose = false
            switch choice {
            case 0:
                save { [weak self] succeeded in
                    completion(succeeded && self?.isDirty == false)
                }
            case 1: completion(true)
            default: completion(false)
            }
        }
    }

    private func updateTitle() {
        window?.title = L10n.format("%@ — Markdown", fileURL?.lastPathComponent ?? L10n.string("Untitled"))
        window?.representedURL = fileURL
        window?.isDocumentEdited = isDirty
        editor.saveButton.isEnabled = !isSaving && (isDirty || fileURL == nil)
    }

    private func present(_ error: Error) {
        guard let window else { return }
        ThemedAlert(error: error).beginSheetModal(for: window)
    }
}

/// Opening the same URL twice raises its existing document. All entry points share this owner.
@MainActor
final class MarkdownEditorWindows {
    private(set) var windows: [MarkdownEditorWindowController] = []
    private var opening = Set<URL>()
    private var reviewingQuit = false
    private var quitWasReviewed = false
    private var reviewedRevisions: [ObjectIdentifier: Int] = [:]

    var active: MarkdownEditorWindowController? { windows.first { $0.window === NSApp.keyWindow } }

    func newDocument() { show(MarkdownEditorWindowController()) }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [MarkdownFileAssociation.contentType, MarkdownFileAssociation.mcContentType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open($0) }
        }
    }

    func open(_ url: URL) {
        let identity = url.standardizedFileURL
        if let existing = windows.first(where: { $0.fileURL?.standardizedFileURL == identity }) {
            existing.showWindow(nil)
            return
        }
        guard opening.insert(identity).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { opening.remove(identity) }
            do {
                let contents = try await MarkdownEditorFileStore.shared.read(url)
                if let existing = windows.first(where: { $0.fileURL == contents.url }) {
                    existing.showWindow(nil)
                } else {
                    show(MarkdownEditorWindowController(url: url, contents: contents))
                }
            } catch {
                ThemedAlert(error: error).runModal()
            }
        }
    }

    private func show(_ controller: MarkdownEditorWindowController) {
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        controller.onNew = { [weak self] in self?.newDocument() }
        controller.onOpen = { [weak self] in self?.openDocument() }
        controller.showWindow(nil)
    }

    /// Return false while the themed reviews are pending. Re-enter ordinary app termination
    /// only after all documents have been reviewed, before any agent shutdown begins.
    func permitsQuit() -> Bool {
        if quitWasReviewed {
            quitWasReviewed = false
            let unchanged = windows.allSatisfy { !($0.needsQuitReview) || reviewedRevisions[ObjectIdentifier($0)] == $0.editRevision }
            reviewedRevisions.removeAll()
            if unchanged { return true }
        }
        guard windows.contains(where: { $0.needsQuitReview }) else { return true }
        guard !reviewingQuit else { return false }
        reviewingQuit = true
        reviewedRevisions.removeAll()
        reviewForQuit(windows[...])
        return false
    }

    private func reviewForQuit(_ remaining: ArraySlice<MarkdownEditorWindowController>) {
        guard let next = remaining.first else {
            reviewingQuit = false
            quitWasReviewed = true
            NSApp.terminate(nil)
            return
        }
        next.reviewUnsavedChanges { [weak self] confirmed in
            guard let self else { return }
            guard confirmed else { reviewingQuit = false; return }
            reviewedRevisions[ObjectIdentifier(next)] = next.editRevision
            reviewForQuit(remaining.dropFirst())
        }
    }
}
