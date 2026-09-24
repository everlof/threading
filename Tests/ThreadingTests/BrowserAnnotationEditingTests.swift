import AppKit
import WebKit
import XCTest
@testable import Threading

@MainActor
final class BrowserAnnotationEditingTests: XCTestCase {
    func testAnnotationDeliveryNamesTheElementAndKeepsItsPosition() throws {
        let (browser, _, window) = try fixture(width: 430)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        _ = try script(browser, """
            const target = document.createElement('button');
            target.id = 'review-action';
            target.textContent = 'Save changes';
            target.style.cssText = 'position:fixed;left:120px;top:120px;width:180px;height:50px;z-index:9999';
            document.body.append(target);
            """)
        var message: String?
        browser.deliverAnnotations = { text, _, completion in
            message = text
            completion(.sentNow)
        }
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 140, y: 140))
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        try XCTUnwrap(overlay.editor).noteField.stringValue = "Change this action"
        browser.finishAnnotationEditing(save: true)
        browser.sendPendingAnnotations()
        try waitUntil { message != nil }
        let annotation = try XCTUnwrap(browser.annotationsForActivePage.first)
        XCTAssertEqual(annotation.element?.path, "button#review-action")
        XCTAssertEqual(annotation.element?.role, "button")
        XCTAssertEqual(annotation.element?.name, "Save changes")
        XCTAssertTrue(try XCTUnwrap(message).contains("Element path (page-derived): button#review-action"))
        XCTAssertTrue(try XCTUnwrap(message).contains("Element role (page-derived): button"))
        XCTAssertTrue(try XCTUnwrap(message).contains("Element name (page-derived): Save changes"))
        XCTAssertTrue(try XCTUnwrap(message).contains("Position: (140.0, 140.0) CSS pixels"))
    }

    func testEnterStagesAndCommandReturnSendsToOwningChat() throws {
        let (browser, host, window) = try fixture(width: 430)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        var messages: [String] = []
        var complete: (@MainActor (SessionMessageDelivery.Outcome) -> Void)?
        browser.deliverAnnotations = { text, sessionID, completion in
            XCTAssertEqual(sessionID, host.sessionID)
            messages.append(text)
            complete = completion
        }
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 140, y: 160))
        let editor = try XCTUnwrap(overlay.editor)
        editor.noteField.stringValue = "Move this action"
        XCTAssertTrue(editor.control(editor.noteField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(messages.isEmpty)
        XCTAssertFalse(overlay.sendButton.isHidden)
        XCTAssertEqual(overlay.sendButton.title, "Send (1)")
        browser.addAnnotation(atViewportPoint: CGPoint(x: 200, y: 180))
        try XCTUnwrap(overlay.editor).noteField.stringValue = "Use this second note too"
        XCTAssertTrue(window.firstResponder === overlay.editor?.noteField.currentEditor())
        let commandReturn = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock, .numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 76
        ))
        XCTAssertTrue(window.performKeyEquivalent(with: commandReturn))
        try waitUntil { messages.count == 1 }
        XCTAssertTrue(messages[0].contains("Move this action"))
        XCTAssertTrue(messages[0].contains("Use this second note too"))
        XCTAssertTrue(messages[0].contains("threading-annotation://fixture/review"))
        XCTAssertEqual(overlay.sendButton.title, "Send (2)")
        XCTAssertFalse(overlay.sendButton.isEnabled)
        browser.sendPendingAnnotations()
        XCTAssertEqual(messages.count, 1)
        complete?(.queuedBehindTurn)
        XCTAssertTrue(overlay.sendButton.isHidden)
        XCTAssertEqual(browser.annotationsForActivePage.count, 2)
        // Reopening an unchanged sent note must not put it back in the pending batch.
        browser.editAnnotation(identifier: 1)
        browser.finishAnnotationEditing(save: true)
        XCTAssertTrue(overlay.sendButton.isHidden)
    }

    func testFailedSendAndEditsDuringDeliveryKeepPendingNotes() throws {
        let (browser, _, window) = try fixture(width: 430)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        var complete: (@MainActor (SessionMessageDelivery.Outcome) -> Void)?
        var failures: [SessionMessageDelivery.Outcome] = []
        browser.deliverAnnotations = { _, _, completion in complete = completion }
        browser.onAnnotationSendFailure = { failures.append($0) }
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 140, y: 160))
        try XCTUnwrap(overlay.editor).noteField.stringValue = "Original note"
        browser.sendPendingAnnotations()
        try waitUntil { complete != nil }
        complete?(.busyTerminal)
        XCTAssertEqual(failures, [.busyTerminal])
        XCTAssertFalse(overlay.sendButton.isHidden)
        XCTAssertTrue(overlay.sendButton.isEnabled)
        complete = nil
        XCTAssertTrue(overlay.sendButton.performPrimaryAction())
        try waitUntil { complete != nil }
        browser.editAnnotation(identifier: 1)
        try XCTUnwrap(overlay.editor).noteField.stringValue = "Newer edit"
        browser.finishAnnotationEditing(save: true)
        complete?(.sentNow)
        XCTAssertEqual(overlay.sendButton.title, "Send (1)")
        XCTAssertFalse(overlay.sendButton.isHidden)
        browser.setAnnotationMode(false)
        overlay.layoutSubtreeIfNeeded()
        let buttonPoint = overlay.sendButton.convert(CGPoint(x: 5, y: 5), to: overlay.superview)
        XCTAssertTrue(overlay.hitTest(buttonPoint) === overlay.sendButton)
        XCTAssertNil(overlay.hitTest(overlay.convert(CGPoint(x: 30, y: 30), to: overlay.superview)))
        browser.setAnnotationMode(true)
        browser.editAnnotation(identifier: 1)
        XCTAssertTrue(try XCTUnwrap(overlay.editor).deleteButton.performPrimaryAction())
        XCTAssertTrue(overlay.sendButton.isHidden)
    }

    func testInlineEditingKeepsPageIdentityAndSupportsSaveCancelAndDelete() throws {
        let (browser, host, window) = try fixture(width: 760)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        _ = host
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 140, y: 160))
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        let editor = try XCTUnwrap(overlay.editor)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(overlay.accessibilityRole(), .group)
        XCTAssertFalse((overlay.accessibilityChildren() ?? []).isEmpty)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: editor), [])
        XCTAssertTrue(browser.annotationsForActivePage.isEmpty, "An unfinished draft is not agent context")
        XCTAssertFalse(editor.saveButton.isEnabled)
        editor.noteField.stringValue = "Move this action beside the heading"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.noteField))
        XCTAssertTrue(editor.saveButton.performPrimaryAction())
        let saved = try XCTUnwrap(browser.annotationsForActivePage.first)
        XCTAssertEqual(saved.note, "Move this action beside the heading")
        XCTAssertEqual(saved.documentPoint, CGPoint(x: 140, y: 160))
        XCTAssertNil(overlay.editor)

        browser.editAnnotation(identifier: saved.id)
        let editing = try XCTUnwrap(overlay.editor)
        editing.noteField.stringValue = "Cancelled replacement"
        XCTAssertTrue(editing.control(editing.noteField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(browser.annotationsForActivePage, [saved])

        browser.editAnnotation(identifier: saved.id)
        let next = try XCTUnwrap(overlay.editor)
        next.noteField.stringValue = "Saved while placing the next pin"
        browser.addAnnotation(atViewportPoint: CGPoint(x: 220, y: 200))
        XCTAssertEqual(browser.annotationsForActivePage.first?.note, next.note)
        XCTAssertEqual(overlay.subviews.compactMap { $0 as? BrowserAnnotationEditor }.count, 1)
        browser.finishAnnotationEditing(save: false)
        XCTAssertEqual(browser.annotationsForActivePage.count, 1)

        browser.editAnnotation(identifier: saved.id)
        let beforeNavigation = try XCTUnwrap(overlay.editor)
        beforeNavigation.noteField.stringValue = "Still belongs to the first page"
        try navigate(browser, to: "threading-annotation://fixture/next")
        XCTAssertNil(overlay.editor)
        XCTAssertFalse(overlay.isAnnotating)
        XCTAssertTrue(browser.annotationsForActivePage.isEmpty)
        try navigate(browser, to: "threading-annotation://fixture/review")
        XCTAssertEqual(browser.annotationsForActivePage.first?.note, beforeNavigation.note)
        browser.setAnnotationMode(true)
        browser.editAnnotation(identifier: saved.id)
        let deleting = try XCTUnwrap(overlay.editor)
        XCTAssertTrue(deleting.deleteButton.performPrimaryAction())
        XCTAssertTrue(browser.annotationsForActivePage.isEmpty)
        XCTAssertNil(overlay.editor)
    }

    func testIframePinsFollowNestedScrollingAndKeepTheirEditor() throws {
        let (browser, _, window) = try fixture(width: 760)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        try installFrameFixture(browser)
        browser.setAnnotationMode(true)
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        let point = CGPoint(x: 102, y: 222)
        browser.addAnnotation(atViewportPoint: point)
        let editor = try XCTUnwrap(overlay.editor)
        editor.noteField.stringValue = "Keep this embedded action next to its heading"
        try waitUntil { try self.script(browser, "return globalThis.__threadingAnnotationAnchors?.size === 1", client: true) as? Bool == true }
        // Nested frame is scaled 0.75 inside a frame scaled 0.8. Its scroll is composed once.
        _ = try script(browser, "innerFrame.contentWindow.scrollTo(0, 60)")
        try waitUntil { abs((overlay.markers.first?.point.y ?? 0) - (point.y - 36)) < 1 }
        overlay.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.editor === editor, "Scrolling must preserve the active native field")
        XCTAssertTrue(overlay.bounds.contains(editor.frame))
        XCTAssertEqual(editor.note, "Keep this embedded action next to its heading")
        browser.finishAnnotationEditing(save: true)
        let saved = try XCTUnwrap(browser.annotationsForActivePage.first)
        try waitUntil { browser.annotationsForActivePage.first?.element?.path?.contains("::frame") == true }
        XCTAssertTrue(try XCTUnwrap(browser.annotationsForActivePage.first?.element?.path).contains("button"))
        XCTAssertEqual(saved.documentPoint.y, point.y - 36, accuracy: 1, "Agents receive the updated top-document coordinate")
        _ = try script(browser, "outer.contentWindow.scrollTo(0, 30)")
        try waitUntil { abs((overlay.markers.first?.point.y ?? 0) - (point.y - 60)) < 1 }
        browser.setPageZoom(1.25)
        try waitUntil { abs((overlay.markers.first?.point.y ?? 0) - (point.y - 60) * 1.25) < 1 }
        browser.editAnnotation(identifier: saved.id)
        XCTAssertEqual(overlay.editor?.note, saved.note)
        XCTAssertTrue(try XCTUnwrap(overlay.editor).deleteButton.performPrimaryAction())
        XCTAssertTrue(overlay.markers.isEmpty)
        try waitUntil { try self.script(browser, "return globalThis.__threadingAnnotationAnchors?.size === 0", client: true) as? Bool == true }
    }

    func testIframePinsClipAndNeverTransferToAReplacementDocument() throws {
        let (browser, _, window) = try fixture(width: 760)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        try installFrameFixture(browser)
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 102, y: 222))
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        try XCTUnwrap(overlay.editor).noteField.stringValue = "A note inside the embedded document"
        try waitUntil { try self.script(browser, "return globalThis.__threadingAnnotationAnchors?.size === 1", client: true) as? Bool == true }
        browser.finishAnnotationEditing(save: true)
        _ = try script(browser, "innerFrame.contentWindow.scrollTo(0, 400)")
        try waitUntil { overlay.markers.isEmpty }
        XCTAssertEqual(browser.annotationsForActivePage.count, 1, "Clipping a pin does not delete the note")
        _ = try script(browser, "innerFrame.contentWindow.scrollTo(0, 0)")
        try waitUntil { overlay.markers.count == 1 }
        // Replacing only the child document leaves the outer page URL unchanged.
        _ = try script(browser, "innerFrame.srcdoc = '<body style=background:pink>Replacement document</body>'")
        try waitUntil { overlay.markers.isEmpty }
        XCTAssertEqual(browser.annotationsForActivePage.count, 1)
    }

    func testOpaqueIframeRegionIsAnnotatableWithoutReadingItsDOM() throws {
        let (browser, _, window) = try fixture(width: 760)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        _ = try script(browser, """
            document.body.innerHTML = '<iframe id="opaque" sandbox="" srcdoc="Private content" style="position:absolute;left:40px;top:60px;width:300px;height:200px"></iframe>';
            """)
        try waitUntil { try self.script(browser, "document.querySelector('iframe').contentDocument === null") as? Bool == true }
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 100, y: 100))
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        try XCTUnwrap(overlay.editor).noteField.stringValue = "Review this embedded region"
        try waitUntil { try self.script(browser, "return globalThis.__threadingAnnotationAnchors?.size === 1", client: true) as? Bool == true }
        browser.finishAnnotationEditing(save: true)
        // Reproduce an occluded renderer even when this test runs on an unlocked display.
        _ = try script(browser, "globalThis.requestAnimationFrame = () => 0", client: true)
        _ = try script(browser, "document.querySelector('iframe').style.top = '100px'")
        try waitUntil { abs((overlay.markers.first?.point.y ?? 0) - 140) < 1 }
        XCTAssertEqual(browser.annotationsForActivePage.first?.note, "Review this embedded region")
        XCTAssertEqual(try script(browser, "typeof globalThis.__threadingAnnotationAnchors") as? String, "undefined", "Anchor state is isolated from the page")
        _ = try script(browser, "document.querySelector('iframe').remove()")
        try waitUntil { overlay.markers.isEmpty }
        XCTAssertEqual(browser.annotationsForActivePage.count, 1)
    }

    func testIframeAnchorResolutionHandlesTwoHundredPins() throws {
        let (browser, _, window) = try fixture(width: 760)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        try installFrameFixture(browser)
        let result = try script(browser, """
            const x = 102, y = 222, ref = '', selector = '', locator = null, precise = false;
            async function capture(token) { \(BrowserAgentScripts.captureAnnotationAnchor) }
            async function resolve(tokens, releasedTokens) { \(BrowserAgentScripts.annotationAnchorPositions) }
            const tokens = Array.from({length:200}, (_, i) => 'stress-' + i);
            for (const token of tokens) await capture(token);
            const samples = [];
            let positions;
            for (let sample = 0; sample < 5; sample += 1) {
              const start = performance.now();
              positions = JSON.parse(await resolve(tokens, []));
              samples.push(performance.now() - start);
            }
            const visible = positions.filter(p => p.anchored && p.visible && Math.abs(p.y - 222) < 1).length;
            await resolve([], tokens);
            return {visible, samples, remaining:globalThis.__threadingAnnotationAnchors.size,
              observing:!!globalThis.__threadingAnnotationTracking};
            """, client: true) as? [String: Any]
        XCTAssertEqual(result?["visible"] as? Int, 200)
        XCTAssertEqual(result?["remaining"] as? Int, 0)
        XCTAssertEqual(result?["observing"] as? Bool, false)
        let samples = try XCTUnwrap(result?["samples"] as? [Double]).sorted()
        print("Iframe annotation resolution, 200 pins: median \(samples[2]) ms; max \(samples.last!) ms")
        XCTAssertLessThan(samples.last!, 250, "A bounded batch should not stall a compositor turn for hundreds of milliseconds")
    }

    private func installFrameFixture(_ browser: BrowserViewController) throws {
        _ = try script(browser, """
            document.body.innerHTML = '<iframe id="outer" style="position:absolute;left:40px;top:60px;width:600px;height:320px;border:4px solid #234c88;transform:scale(.8);transform-origin:top left"></iframe>';
            window.framesReady = false;
            window.outer = document.querySelector('#outer');
            outer.onload = () => {
              window.innerFrame = outer.contentDocument.querySelector('iframe');
              innerFrame.onload = () => {
                const host = innerFrame.contentDocument.createElement('div');
                innerFrame.contentDocument.body.append(host);
                host.attachShadow({mode:'open'}).innerHTML = '<button style="position:absolute;left:40px;top:140px;width:180px;height:44px;background:#234c88;color:white;border:0;border-radius:6px"><span>Embedded action</span></button>';
                window.framesReady = true;
              };
              innerFrame.srcdoc = '<body style="margin:0;min-height:1800px;background:#fff"><h3 style="margin:24px">Embedded design</h3></body>';
            };
            outer.srcdoc = '<body style="margin:0;min-height:1800px;background:#e8edf3"><iframe style="position:absolute;left:30px;top:80px;width:400px;height:220px;border:2px solid #637489;transform:scale(.75);transform-origin:top left"></iframe></body>';
            """)
        try waitUntil { try self.script(browser, "window.framesReady") as? Bool == true }
    }

    @discardableResult
    private func script(_ browser: BrowserViewController, _ source: String, client: Bool = false) throws -> Any? {
        let completed = expectation(description: "fixture script")
        var value: Any?
        var failure: Error?
        if client {
            browser.webView.callAsyncJavaScript(source, in: nil, in: .defaultClient) { result in
                switch result { case .success(let result): value = result; case .failure(let error): failure = error }
                completed.fulfill()
            }
        } else {
            browser.webView.evaluateJavaScript(source) { result, error in
                value = result; failure = error; completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 5)
        if let failure { throw failure }
        return value
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while try !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(try condition(), "Iframe annotation state did not settle", file: file, line: line)
    }

    func testEditorClampsAfterViewportShrinks() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        let overlay = BrowserAnnotationOverlay(frame: window.contentView!.bounds)
        window.contentView?.addSubview(overlay)
        overlay.isAnnotating = true
        let editor = BrowserAnnotationEditor(identifier: 1, note: "Keep this note reachable", isExisting: true)
        overlay.showEditor(editor, at: CGPoint(x: 700, y: 450))
        overlay.frame.size = NSSize(width: 260, height: 220)
        overlay.needsLayout = true
        overlay.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.bounds.contains(editor.frame))
        XCTAssertGreaterThan(editor.noteField.frame.width, 150)
        XCTAssertTrue(editor.bounds.contains(editor.convert(editor.saveButton.bounds, from: editor.saveButton)))
    }

    /// Asking for the front before building anything: on a skip, no window is ordered in at all.
    func testEditorTakesKeyboardAndEscapeReturnsItToCanvas() throws {
        try activateHost()
        let (browser, _, window) = try fixture(width: 760, keyPanel: true)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        window.makeKey()
        XCTAssertTrue(pollUntil { window.isKeyWindow }, "the panel never took key status")
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 140, y: 160))
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        let editor = try XCTUnwrap(overlay.editor)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.firstResponder === editor.noteField.currentEditor())
        let fieldEditor = try XCTUnwrap(editor.noteField.currentEditor() as? NSTextView)
        fieldEditor.insertText("Keyboard note", replacementRange: fieldEditor.selectedRange())
        XCTAssertEqual(editor.note, "Keyboard note")
        fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(browser.annotationsForActivePage.first?.note, "Keyboard note")
        XCTAssertTrue(window.firstResponder === overlay)
        XCTAssertTrue(window.isKeyWindow)
        browser.editAnnotation(identifier: try XCTUnwrap(browser.annotationsForActivePage.first?.id))
        let reopened = try XCTUnwrap(overlay.editor)
        let reopenedField = try XCTUnwrap(reopened.noteField.currentEditor() as? NSTextView)
        reopenedField.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(overlay.editor)
        XCTAssertTrue(window.firstResponder === overlay)
        XCTAssertTrue(window.isKeyWindow)
    }

    func testRendersInlineEditorInBrowserHostAcrossThemesAndWidths() throws {
        let original = AppThemePalette.current
        defer { AppThemePalette.set(original) }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua), ("system-dark", .system, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua)
        ]
        for width: CGFloat in [430, 760] {
            let (browser, host, window) = try fixture(width: width)
            defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
            browser.setAnnotationMode(true)
            browser.addAnnotation(atViewportPoint: CGPoint(x: width - 100, y: 150))
            let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
            let editor = try XCTUnwrap(overlay.editor)
            editor.noteField.stringValue = "Give the heading more breathing room"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.noteField))
            window.makeFirstResponder(nil)
            // Keep the same editor alive through every switch: freshly-built forms cannot
            // catch stale label ink, fonts, or geometry after an appearance change.
            for (name, theme, appearance) in variants {
                AppThemePalette.set(theme)
                window.appearance = NSAppearance(named: appearance)
                AppThemeRefresh.repaint(host.view)
                host.view.layoutSubtreeIfNeeded()
                XCTAssertTrue(overlay.bounds.contains(editor.frame), "Editor must stay inside compact viewports")
                XCTAssertGreaterThan(editor.noteField.bounds.width, 200)
                XCTAssertEqual(ThemeBoundaryAudit.violations(in: editor), [])
                let fieldPoint = editor.noteField.convert(CGPoint(x: 10, y: 10), to: overlay.superview)
                XCTAssertTrue(overlay.hitTest(fieldPoint) === editor.noteField, "The overlay must route clicks into its editor")
                let editorRep = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
                editor.cacheDisplay(in: editor.bounds, to: editorRep)
                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(editorRep.colorAt(x: 4, y: editorRep.pixelsHigh / 2)).alphaComponent,
                    0.99, "The page must not show through the note editor"
                )
                let painted = expectation(description: "WebKit paint")
                browser.webView.takeSnapshot(with: nil) { image, error in
                    XCTAssertNil(error); XCTAssertNotNil(image); painted.fulfill()
                }
                wait(for: [painted], timeout: 5)
                try writeImage(host.view, browser: browser, to: directory.appendingPathComponent(
                    "browser-inline-annotation-\(Int(width))-\(name).png"
                ))
            }
            if width == 430 {
                AppThemePalette.set(.system)
                window.appearance = NSAppearance(named: .aqua)
                browser.finishAnnotationEditing(save: true)
                AppThemeRefresh.repaint(host.view)
                host.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(overlay.sendButton.title, "Send (1)")
                try writeImage(host.view, browser: browser, to: directory.appendingPathComponent("browser-inline-annotation-pending.png"))
                browser.editAnnotation(identifier: try XCTUnwrap(browser.annotationsForActivePage.first?.id))
                XCTAssertFalse(try XCTUnwrap(overlay.editor).deleteButton.isHidden)
                window.makeFirstResponder(nil)
                AppThemeRefresh.repaint(host.view)
                host.view.layoutSubtreeIfNeeded()
                try writeImage(host.view, browser: browser, to: directory.appendingPathComponent("browser-inline-annotation-existing.png"))
                browser.finishAnnotationEditing(save: false)
                browser.addAnnotation(atViewportPoint: CGPoint(x: 150, y: 300))
                XCTAssertFalse(try XCTUnwrap(overlay.editor).saveButton.isEnabled)
                window.makeFirstResponder(nil)
                host.view.layoutSubtreeIfNeeded()
                try writeImage(host.view, browser: browser, to: directory.appendingPathComponent("browser-inline-annotation-empty.png"))
            }
        }
        try renderIframeEditor(to: directory)
        try renderContrastPages(to: directory)
    }

    private func renderContrastPages(to directory: URL) throws {
        for (name, theme, appearance) in [
            ("light", AppTheme.system, NSAppearance.Name.aqua),
            ("dark", AppTheme.system, NSAppearance.Name.darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua)
        ] {
            AppThemePalette.set(theme)
            let (browser, host, window) = try fixture(width: 760)
            defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
            window.appearance = NSAppearance(named: appearance)
            var resolvedAccent: NSColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolvedAccent = Design.Annotation.fill.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(resolvedAccent)
            let accent = "rgb(\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)))"
            _ = try script(browser, """
                document.body.innerHTML = `<div style="margin:24px;color:#18263a;font:14px -apple-system">Annotation contrast · matching colour, saturated colour, checkerboard, busy artwork</div>
                <div style="position:absolute;left:24px;right:24px;top:60px;height:290px;display:grid;grid-template-columns:1fr 1fr;gap:0">
                  <div style="background:\(accent)"></div>
                  <div style="background:linear-gradient(120deg,#ff00ab,#faff00,#00efff)"></div>
                  <div style="background:repeating-conic-gradient(#111 0% 25%,#fff 0% 50%) 0 0/12px 12px"></div>
                  <img id="artwork" style="width:100%;height:100%;object-fit:cover">
                </div>`;
                let shapes = '';
                for (let i = 0; i < 90; i++) shapes += `<circle cx="${(i*73)%360}" cy="${(i*47)%150}" r="${10+i%35}" fill="hsl(${i*53%360} 85% 50%)" stroke="${i%2?'white':'black'}" stroke-width="2"/>`;
                document.querySelector('#artwork').src = 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 150"><rect width="360" height="150" fill="#252525"/>${shapes}</svg>`);
                """)
            try waitUntil { try self.script(browser, "document.querySelector('#artwork').complete && document.querySelector('#artwork').naturalWidth > 0") as? Bool == true }
            browser.setAnnotationMode(true)
            let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
            for point in [CGPoint(x: 70, y: 105), CGPoint(x: 420, y: 105), CGPoint(x: 70, y: 265)] {
                browser.addAnnotation(atViewportPoint: point)
                try XCTUnwrap(overlay.editor).noteField.stringValue = "Review this detail"
                browser.finishAnnotationEditing(save: true)
            }
            browser.addAnnotation(atViewportPoint: CGPoint(x: 420, y: 265))
            let editor = try XCTUnwrap(overlay.editor)
            editor.noteField.stringValue = "Keep this readable over the artwork"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.noteField))
            overlay.hoveredTarget = .init(rect: CGRect(x: 100, y: 130, width: 460, height: 100), label: "section · Review target")
            window.makeFirstResponder(nil)
            AppThemeRefresh.repaint(host.view)
            host.view.layoutSubtreeIfNeeded()
            // The send affordance is now the shared AnnotationSendBar; its surface is the ground.
            let sendBar = try XCTUnwrap(overlay.subviews.compactMap { $0 as? AnnotationSendBar }.first)
            XCTAssertFalse(sendBar.isHidden)
            XCTAssertLessThanOrEqual(editor.frame.maxY, sendBar.frame.minY - Design.Spacing.small)
            let sendGround = try XCTUnwrap(sendBar.subviews.compactMap { $0 as? BrowserAnnotationSurfaceView }.first)
            let groundRep = try XCTUnwrap(sendGround.bitmapImageRepForCachingDisplay(in: sendGround.bounds))
            sendGround.cacheDisplay(in: sendGround.bounds, to: groundRep)
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(groundRep.colorAt(x: groundRep.pixelsWide / 2, y: groundRep.pixelsHigh / 2)).alphaComponent,
                0.99, "Outlined theme buttons must have an opaque app-owned ground over the page"
            )
            let painted = expectation(description: "contrast page paint")
            browser.webView.takeSnapshot(with: nil) { image, error in
                XCTAssertNil(error); XCTAssertNotNil(image); painted.fulfill()
            }
            wait(for: [painted], timeout: 5)
            try writeImage(host.view, browser: browser, to: directory.appendingPathComponent("browser-inline-annotation-contrast-\(name).png"))
        }
    }

    private func renderIframeEditor(to directory: URL) throws {
        let (browser, host, window) = try fixture(width: 760)
        defer { browser.webView.stopLoading(); window.orderOut(nil); window.contentViewController = nil }
        AppThemePalette.set(.system)
        window.appearance = NSAppearance(named: .aqua)
        try installFrameFixture(browser)
        browser.setAnnotationMode(true)
        browser.addAnnotation(atViewportPoint: CGPoint(x: 102, y: 222))
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        let editor = try XCTUnwrap(overlay.editor)
        editor.noteField.stringValue = "Keep the embedded action beside its heading"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.noteField))
        try waitUntil { try self.script(browser, "return globalThis.__threadingAnnotationAnchors?.size === 1", client: true) as? Bool == true }
        _ = try script(browser, "innerFrame.contentWindow.scrollTo(0, 60)")
        try waitUntil { abs((overlay.markers.first?.point.y ?? 0) - 186) < 1 }
        window.makeFirstResponder(nil)
        AppThemeRefresh.repaint(host.view)
        host.view.layoutSubtreeIfNeeded()
        let painted = expectation(description: "iframe paint")
        browser.webView.takeSnapshot(with: nil) { image, error in
            XCTAssertNil(error); XCTAssertNotNil(image); painted.fulfill()
        }
        wait(for: [painted], timeout: 5)
        try writeImage(host.view, browser: browser, to: directory.appendingPathComponent("browser-inline-annotation-iframe-scrolled.png"))
    }

    private func writeImage(_ root: NSView, browser: BrowserViewController, to url: URL) throws {
        // Use the existing browser-target evidence path: WebKit supplies its remote page
        // bitmap; the shipping native host and overlay supply chrome, pins and the actual form.
        // This also works when WindowServer has suspended remote-layer commits on a locked Mac.
        // It proves appearance/layout, not keyboard activation or live compositor scheduling.
        let overlay = try XCTUnwrap(descendant(BrowserAnnotationOverlay.self, in: browser.view))
        let target = overlay.hoveredTarget
        let painted = expectation(description: "page evidence bitmap")
        var pageImage: NSImage?
        browser.webView.takeSnapshot(with: nil) { image, error in
            XCTAssertNil(error); pageImage = image; painted.fulfill()
        }
        wait(for: [painted], timeout: 5)
        let page = try XCTUnwrap(pageImage)
        overlay.hoveredTarget = target
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        rep.size = root.bounds.size
        let marks = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: marks)
        let annotationImage = NSImage(size: overlay.bounds.size)
        annotationImage.addRepresentation(marks)
        func destination(_ view: NSView) -> CGRect {
            var rect = view.convert(view.bounds, to: root)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            return rect
        }
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            page.draw(in: destination(browser.webView))
            annotationImage.draw(in: destination(overlay))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }
        // This point is the fixture's page ground, inside the mode frame and outside the card.
        // A white, not-yet-composited WebKit layer must fail rather than become visual evidence.
        let point = browser.webView.convert(CGPoint(x: 20, y: 20), to: root)
        let pixelX = Int(point.x * CGFloat(rep.pixelsWide) / root.bounds.width)
        let topY = root.isFlipped ? point.y : root.bounds.height - point.y
        let pixelY = Int(topY * CGFloat(rep.pixelsHigh) / root.bounds.height)
        let ground = try XCTUnwrap(rep.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(ground.redComponent, 244.0 / 255, accuracy: 0.01)
        XCTAssertEqual(ground.greenComponent, 246.0 / 255, accuracy: 0.01)
        XCTAssertEqual(ground.blueComponent, 248.0 / 255, accuracy: 0.01)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Parking a borderless window at (-10,000, -10,000) buys a real window for WebKit without
    /// putting anything on a display, which is what keeps this class in `fast`. It does not buy
    /// key status: the window server hands the keyboard to no window sitting on no display. So the
    /// one test that is about where the keystrokes go gets a panel where a person could see it,
    /// and is skipped from `fast` for exactly that reason.
    private func fixture(width: CGFloat, keyPanel: Bool = false) throws -> (BrowserViewController, DetachedBrowserHostViewController, NSWindow) {
        let browser = BrowserViewController(urlSchemeHandlers: ["threading-annotation": AnnotationPageHandler()])
        let host = DetachedBrowserHostViewController(sessionID: SessionID(), browserFactory: { _ in browser })
        let origin = keyPanel ? NSPoint(x: 120, y: 120) : NSPoint(x: -10_000, y: -10_000)
        let rect = NSRect(origin: origin, size: NSSize(width: width, height: 520))
        let window: NSWindow = keyPanel
            ? AnnotationKeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.addBrowserTab()
        window.setContentSize(NSSize(width: width, height: 520))
        window.setFrameOrigin(origin)
        window.orderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        try navigate(browser, to: "threading-annotation://fixture/review")
        return (browser, host, window)
    }

    /// `NSApp.keyWindow` is nil for the whole of an inactive application, and since macOS 14 an app
    /// that has not been given the front cannot take it. A command-line run therefore reports this
    /// as skipped rather than blaming the component; it verifies for real with the host frontmost.
    private func activateHost() throws {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        _ = pollUntil { NSApp.isActive }
        try XCTSkipUnless(
            NSApp.isActive,
            "the test host could not come to the front, so no window can hold key status"
        )
    }

    /// Polls without asserting, so a caller can decide between skipping and failing.
    ///
    /// Deliberately *not* an overload of the throwing `waitUntil` above: a non-throwing overload
    /// with a defaulted first argument wins at every `try waitUntil { … }` call site in this file,
    /// which silently turned nine assertions into discarded Bools.
    private func pollUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }

    private func navigate(_ browser: BrowserViewController, to url: String) throws {
        let loaded = expectation(description: "page loaded")
        browser.navigate(to: url) { success, message in
            XCTAssertTrue(success, message)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

private final class AnnotationPageHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let html = """
        <!doctype html><html><head><title>Design review</title><style>
        body{margin:0;background:#f4f6f8;color:#18263a;font:16px -apple-system;min-height:1600px}
        main{margin:32px;padding:28px;background:white;border:1px solid #dce2ea;border-radius:12px}
        small{color:#637489}h1{font-size:30px;line-height:1.1;margin:16px 0}p{line-height:1.6}
        button{background:#234c88;color:white;border:0;border-radius:6px;padding:12px 20px}
        </style></head><body><main><small>WORKSPACE / DESIGN</small><h1>A place for your next idea</h1>
        <p>Collect references, review the details, and share a clear direction with your team.</p>
        <button>Start a project</button></main></body></html>
        """
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private final class AnnotationKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
