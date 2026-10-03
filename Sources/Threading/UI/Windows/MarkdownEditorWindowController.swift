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
    /// The file went away after it was read; saving writes it back rather than comparing.
    private(set) var fileIsMissing = false
    private var watcher: MarkdownDocumentWatcher?
    private var diskCheck: Task<Void, Never>?
    private var checksDiskAfterSave = false
    /// Questions waiting on a save in flight, which decides their answer.
    private var afterSave: [() -> Void] = []
    nonisolated(unsafe) private var keyMonitor: Any?
    var onClose: (() -> Void)?
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?

    /// Edited since it was read or saved — or its file is gone, so closing would lose it.
    var isDirty: Bool { hasEdits || fileIsMissing }
    var needsQuitReview: Bool { isDirty || isSaving }
    /// Whether a document command may begin now: never under a sheet or a close question.
    var acceptsDocumentCommands: Bool { window?.attachedSheet == nil && !isReviewingClose }
    private var hasEdits: Bool { currentText != savedText }

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
                  self.window?.isKeyWindow == true, acceptsDocumentCommands else { return event }
            return handleDocumentKey(event) ? nil : event
        }
        watchFile()
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

    // MARK: - Document Commands

    /// Document keys are scoped to this window; the main window keeps its existing bindings.
    /// The chords come from the same table the File menu shows while this window is key.
    func handleDocumentKey(_ event: NSEvent) -> Bool {
        guard let command = MarkdownEditorDefaults.documentShortcuts.first(where: { $0.value.matches(event) })?.key else {
            return false
        }
        perform(documentCommand: command)
        return true
    }

    func perform(documentCommand command: String) {
        switch command {
        case AppCommands.ID.newMarkdown: onNew?()
        case AppCommands.ID.openMarkdown: onOpen?()
        case AppCommands.ID.closeMarkdown: window?.performClose(nil)
        case AppCommands.ID.saveMarkdown: save()
        case AppCommands.ID.saveMarkdownAs: save(asCopy: true)
        default: break
        }
    }

    // MARK: - Saving

    func save(asCopy: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !isSaving, let window else { completion?(false); return }
        if let url = fileURL, !asCopy {
            write(to: url, baseline: fileIsMissing ? nil : baseline, completion: completion)
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
            write(to: url, baseline: sameFile && !fileIsMissing ? baseline : nil, completion: completion)
        }
    }

    /// Writes the current text over whatever the file now holds. Only a person's explicit
    /// Replace reaches this; an ordinary save compares the disk with the last read first.
    func replaceOnDisk(completion: ((Bool) -> Void)? = nil) {
        guard !isSaving, let url = fileURL else { completion?(false); return }
        write(to: url, baseline: nil, completion: completion)
    }

    private func write(to url: URL, baseline: Data?, completion: ((Bool) -> Void)?) {
        let snapshot = currentText
        isSaving = true
        updateTitle()
        Task { [weak self] in
            guard let self else { completion?(false); return }
            do {
                let bytes = try await MarkdownEditorFileStore.shared.save(snapshot, to: url, baseline: baseline)
                let moved = fileURL != url
                fileURL = url
                self.baseline = bytes
                savedText = snapshot
                fileIsMissing = false
                editor.showNotice(nil)
                if moved { watchFile() }
                finishSaving()
                completion?(true)
            } catch MarkdownEditorFileStore.Failure.changedOnDisk {
                finishSaving()
                resolveConflict(at: url, completion: completion)
            } catch {
                finishSaving()
                present(error)
                completion?(false)
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        updateTitle()
        let waiting = afterSave
        afterSave.removeAll()
        waiting.forEach { $0() }
        if checksDiskAfterSave {
            checksDiskAfterSave = false
            checkDisk()
        }
    }

    /// The file changed after it was read or last saved. Replacing it is a decision, so it is
    /// asked for: in Threading the other writer is usually an agent working in the same folder.
    private func resolveConflict(at url: URL, completion: ((Bool) -> Void)?) {
        guard let window else { completion?(false); return }
        let request = ChoiceRequest(
            prompt: .replaceChangedMarkdownDocument,
            title: L10n.format("“%@” changed on disk", url.lastPathComponent),
            message: L10n.string("Another app changed this file after you opened it. Replace it with your version, or save yours as a new file."),
            options: [ConfirmationOption(title: L10n.string("Replace")), ConfirmationOption(title: L10n.string("Save As…"))]
        )
        ConfirmationAlert.choose(request, in: window) { [weak self] choice in
            guard let self else { completion?(false); return }
            switch choice {
            case 0: write(to: url, baseline: nil, completion: completion)
            case 1: save(asCopy: true, completion: completion)
            default: completion?(false)
            }
        }
    }

    // MARK: - The File on Disk

    private func watchFile() {
        watcher?.stop()
        watcher = fileURL.map { url in
            MarkdownDocumentWatcher(url: url) { [weak self] in self?.checkDisk() }
        }
    }

    /// Compares what is on disk with what this document last read or wrote. Its own saves
    /// match and change nothing; an unedited document follows the file, as one undoable edit;
    /// edits are never replaced without a decision.
    func checkDisk() {
        guard let url = fileURL else { return }
        guard !isSaving else { checksDiskAfterSave = true; return }
        diskCheck?.cancel()
        diskCheck = Task { [weak self] in
            let read: Result<MarkdownEditorFileStore.Contents, Error>
            do { read = .success(try await MarkdownEditorFileStore.shared.read(url)) } catch { read = .failure(error) }
            guard let self, !Task.isCancelled, fileURL == url else { return }
            guard !isSaving else { checksDiskAfterSave = true; return }
            apply(read, from: url)
        }
    }

    /// Lets deterministic evidence wait for the comparison a watcher event started.
    func waitForDiskCheck() async { await diskCheck?.value }

    private func apply(_ read: Result<MarkdownEditorFileStore.Contents, Error>, from url: URL) {
        defer { updateTitle() }
        let name = url.lastPathComponent
        switch read {
        case .success(let contents):
            fileIsMissing = false
            if contents.bytes == baseline {
                // Back to what this document last read or wrote: nothing is left to say.
                editor.showNotice(nil)
            } else if !hasEdits {
                adopt(contents)
            } else {
                showNotice(
                    L10n.format("“%@” changed on disk. Reload it, or keep editing — saving will ask before replacing it.", name),
                    actions: [PaneNoticeAction(title: L10n.string("Reload")) { [weak self] in self?.reloadFromDisk() }]
                )
            }
        case .failure(let error) where Self.isMissing(error):
            fileIsMissing = true
            showNotice(
                L10n.format("“%@” was moved or deleted. Save to write your text back to it.", name),
                actions: [PaneNoticeAction(title: L10n.string("Save")) { [weak self] in self?.save() }]
            )
        case .failure:
            showNotice(
                L10n.format("“%@” changed on disk and can no longer be opened here. Saving will ask before replacing it.", name),
                actions: []
            )
        }
    }

    /// Takes the disk's text as the document's own. Undo brings back what was on screen.
    private func adopt(_ contents: MarkdownEditorFileStore.Contents) {
        baseline = contents.bytes
        savedText = contents.text
        editor.replaceSource(with: contents.text, actionName: L10n.string("Reload"))
        currentText = editor.source
        editor.showNotice(nil)
        updateTitle()
    }

    private func reloadFromDisk() {
        guard let url = fileURL else { return }
        Task { [weak self] in
            do {
                let contents = try await MarkdownEditorFileStore.shared.read(url)
                guard let self, fileURL == url else { return }
                adopt(contents)
            } catch {
                self?.present(error)
            }
        }
    }

    private func showNotice(_ message: String, actions: [PaneNoticeAction]) {
        editor.showNotice(PaneNoticeView(
            tone: .attention,
            message: message,
            actions: actions,
            onDismiss: { [weak self] in self?.editor.showNotice(nil) }
        ))
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSaving else {
            // The save in flight decides whether anything is left to ask about.
            afterSave.append { [weak self] in self?.window?.performClose(nil) }
            return false
        }
        if permitsClose || !isDirty { return true }
        reviewUnsavedChanges { [weak self] confirmed in
            guard confirmed, let self else { return }
            permitsClose = true
            window?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // A closed document stops claiming keys and watching its file now, not when released.
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        watcher?.stop()
        watcher = nil
        diskCheck?.cancel()
        onClose?()
    }

    func reviewUnsavedChanges(completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        guard !isSaving else {
            // Waiting for the write answers the question honestly; refusing it made a quit
            // pressed during a save do nothing at all.
            afterSave.append { [weak self] in
                guard let self else { completion(false); return }
                reviewUnsavedChanges(completion: completion)
            }
            return
        }
        guard !isReviewingClose else { completion(false); return }
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
    private(set) var isReviewingQuit = false

    var active: MarkdownEditorWindowController? { windows.first { $0.window === NSApp.keyWindow } }
    var needsQuitReview: Bool { windows.contains { $0.needsQuitReview } }

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
        // Each document steps down from the one before it; centring them all stacked new
        // windows exactly over each other, so a second document looked like nothing happened.
        if let anchor = (active ?? windows.last)?.window, anchor.isVisible, let window = controller.window {
            let next = window.cascadeTopLeft(from: NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY))
            window.cascadeTopLeft(from: next)
        }
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        controller.onNew = { [weak self] in self?.newDocument() }
        controller.onOpen = { [weak self] in self?.openDocument() }
        controller.showWindow(nil)
    }

    /// Asks about every document that would lose work, one sheet at a time, before the app
    /// shuts anything down. The answer arrives once: true when every document may close.
    func reviewForQuit(completion: @escaping (Bool) -> Void) {
        guard !isReviewingQuit else { completion(false); return }
        isReviewingQuit = true
        review(windows[...]) { [weak self] confirmed in
            self?.isReviewingQuit = false
            completion(confirmed)
        }
    }

    private func review(
        _ remaining: ArraySlice<MarkdownEditorWindowController>,
        completion: @escaping (Bool) -> Void
    ) {
        guard let next = remaining.first else { completion(true); return }
        next.reviewUnsavedChanges { [weak self] confirmed in
            guard confirmed, let self else { completion(false); return }
            review(remaining.dropFirst(), completion: completion)
        }
    }
}
