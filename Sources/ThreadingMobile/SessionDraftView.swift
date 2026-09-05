import PhotosUI
import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers

/// The screen a chat is written on before it exists, and the screen it is read on after.
///
/// Starting a chat used to be a sheet: Start created the session, the sheet dismissed, and the
/// dashboard pushed the new chat once the dismissal had finished — two motions, with the list
/// flashing between them. The draft is now a route on the navigation stack. When the Mac
/// answers Start, the model records which session the draft became and this view crossfades
/// into `SessionDetailView` where it stands: the composer that took the prompt is replaced by
/// the composer that will take the next one, at the same edge, without the screen moving.
///
/// The route keeps its draft identity for the life of the stack entry. `RemoteAppModel` resolves
/// it to the session for continuity and for the push dedup, so the chat is the same navigation
/// subject it would have been opened from its row — the alternative, rewriting the path entry
/// to `.session`, rebuilds the detail screen and shows its loading placeholder for a frame.
struct SessionDraftView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: MobileSessionDraft
    /// Whether the drafting screen is still mounted. It outlives Start by the length of its
    /// fade, so the chat underneath is revealed rather than cut to.
    @State private var draftIsMounted = true

    private var startedDraft: MobileStartedDraft? {
        model.startedDrafts[draft.id]
    }

    private var startedSessionID: String? { startedDraft?.sessionID }

    private var startedSession: RemoteSessionSummaryDTO? {
        guard let startedSessionID else { return nil }
        return model.me?.sessions.first { $0.id == startedSessionID }
    }

    private var isDrafting: Bool {
        startedSessionID == nil
    }

    var body: some View {
        // The session's screen is placed underneath at full strength and the draft fades out
        // over it. The other way round — fading the session in — does nothing visible: the
        // surfaces are UIKit-hosted and do not take SwiftUI's opacity ramp, so the chat would
        // cut in over a draft still fading. The draft's own opacity is SwiftUI's to animate.
        ZStack {
            if let startedSession {
                SessionDetailView(
                    session: startedSession,
                    openingStrategy: startedDraft?.openingStrategy ?? .resumeIfNeeded,
                    installsPrincipalTitle: !draftIsMounted
                )
            } else if startedSessionID != nil {
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("The link may have expired or the Mac may be offline.")
                )
            }
            if draftIsMounted {
                SessionDraftComposerScreen(
                    draft: draft,
                    showsNavigationChrome: isDrafting
                )
                    .opacity(isDrafting ? 1 : 0)
                    .scaleEffect(
                        isDrafting || reduceMotion ? 1 : SessionDraftMotion.recedeScale
                    )
                    .allowsHitTesting(isDrafting)
                    .zIndex(1)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: SessionDraftMotion.startDuration),
                        value: isDrafting
                    )
            }
        }
        .background(theme.ground)
        // The route's one navigation title, mounted for as long as the drafting screen is.
        // Start does not swap it for the session's: the same morphing label stays in the bar
        // and is told the chat's name, so "New session" morphs into it while the status line
        // plays its own change to "Opening chat…" — the transition every rename on this bar
        // already has. The terminal surface installs its own principal item, saying the same
        // thing, only once the draft has retired, so the handoff changes no pixels and the two
        // items never race for the slot. A chat opening on the conversation surface is handed
        // off immediately instead: its title is a UIKit `titleView` the controller installs on
        // appearance, and SwiftUI's cleanup of a removed principal item lands on the same
        // navigation item later, wiping whatever stood there — holding the slot through the
        // fade left that chat with no two-line title at all.
        .toolbar {
            if draftIsMounted, isDrafting || startedSession?.surface != .conversation {
                ToolbarItem(placement: .principal) {
                    MobileConnectionStatusButton(
                        title: principalTitle,
                        status: principalStatus,
                        statusColor: principalStatusColor
                    )
                }
            }
        }
        .onChange(of: isDrafting) { _, isDrafting in
            guard !isDrafting else { return }
            retireDraft()
        }
        .onAppear {
            // Reached with the draft already started — a screen rebuilt on the stack — so
            // there is nothing to fade from.
            if !isDrafting { draftIsMounted = false }
        }
    }

    private var principalTitle: String {
        guard let startedSession else { return MobileL10n.string("New session") }
        return MobileSessionChrome.navigationTitle(
            for: startedSession,
            in: model.me,
            liveTitle: nil
        )
    }

    /// The started chat's opening line is the one its own title will show while it connects,
    /// so the status the draft hands over is the status the session picks up.
    private var principalStatus: String {
        guard isDrafting else { return MobileL10n.string("Opening chat…") }
        return model.activeHost?.name ?? MobileL10n.string("Connected")
    }

    private var principalStatusColor: Color {
        guard isDrafting else { return theme.warning }
        switch model.phase {
        case .online: return theme.positive
        case .connecting: return theme.warning
        case .idle, .offline: return theme.tertiaryLabel
        }
    }

    /// Unmounts the drafting screen once its fade has finished.
    private func retireDraft() {
        let duration = reduceMotion ? 0 : SessionDraftMotion.startDuration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            draftIsMounted = false
        }
    }
}

/// The one motion from draft to chat.
enum SessionDraftMetrics {
    /// One caption line under the folded composer: the run it is set up for.
    static var foldedSummaryHeight: CGFloat { 18 }
}

enum SessionDraftMotion {
    /// How long the drafting screen takes to become the session's screen.
    static let startDuration: TimeInterval = 0.35
    /// The draft recedes a touch as the chat arrives over it; a plain crossfade read as a
    /// reload rather than as the same screen changing state.
    static let recedeScale: CGFloat = 0.98
    /// The hint in the empty ground comes and goes with the first character typed.
    static let hintDuration: TimeInterval = 0.2
    /// The action row unfolds under the prompt as the keyboard rises and folds as it goes —
    /// the keyboard's own duration and ease, so the two read as one motion. Measured, not
    /// assumed: a frame-by-frame read of an on-device recording put the keyboard's top edge
    /// on a smooth ~0.25 s deceleration, exactly what its notification announces. An
    /// "accurate keyboard spring" (mass 3, stiffness 1000, damping 500) was tried against it
    /// and shipped visibly worse — overdamped, it starts slow, opening a gap behind the
    /// departing keyboard, then creeps for half a second after the keyboard has gone.
    static let foldDuration: TimeInterval = 0.25
    /// Slack between the announced duration and when the handoff may mount the chat's screen:
    /// one frame of margin, not a parked pause.
    static let rideSettleMargin: TimeInterval = 0.05
    /// How long after appearing a keyboard frame still belongs to the entrance transition.
    /// The navigation push runs about 0.4 s; a keyboard announced inside this window is the
    /// one sliding in with the screen, not one moving on a settled screen.
    static let entranceSettleDuration: TimeInterval = 0.6
}

/// What a keyboard announcement means for a composer standing in the bottom safe-area inset.
enum MobileKeyboardOverlap {
    /// How far the announced end frame reaches above the window's bottom safe-area inset —
    /// the padding that puts the composer's bottom edge on the keyboard's top edge.
    static func target(from notification: Notification) -> CGFloat {
        guard let frame = notification.userInfo?[
            UIResponder.keyboardFrameEndUserInfoKey
        ] as? CGRect,
            let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                .first
        else { return 0 }
        return max(
            0,
            window.screen.bounds.maxY - frame.minY - window.safeAreaInsets.bottom
        )
    }

    /// The duration the keyboard announces for the move, so the composer's ride matches it.
    static func duration(from notification: Notification) -> Double {
        notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0
    }
}

/// The draft before Start: a quiet ground and one composer.
///
/// Three kinds of choice, at three weights. *What and where* — "Agent in AnotherTerminal" —
/// stands in the middle of the ground as one sentence of two dropdowns under the role's glyph,
/// with the branch beneath. *Who* — agent and account — is the disc at the navigation bar's
/// trailing edge, the runtime's mark ringed by the account's usage, the way a profile control
/// sits in a bar; it opens the identity picker, both choices on one popover hanging from it.
/// *How* — model and effort as one line, speed as its own compact choice,
/// permissions and the interface as one glyph each — is the composer's action row under the
/// prompt, and it fits every phone width without scrolling. None of them is a box on the ground. The
/// composer is the screen's one surface: full-bleed,
/// no corner, a hairline above it and nothing else. It rides in the bottom safe-area inset, so
/// it sits on the keyboard's top edge while typing and follows the keyboard's interactive
/// dismissal. The action row comes and goes with the keyboard: while the prompt has focus the
/// chips are unfolded under it, and when the keyboard is down the composer is one thin line —
/// the prompt and Start — resting on the home indicator.
private struct SessionDraftComposerScreen: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: MobileSessionDraft
    /// The draft content remains mounted while it fades over the session it became, but its
    /// toolbar cannot: SwiftUI merges toolbar items from both children in that overlap and drew
    /// two account/usage discs until the fade completed.
    let showsNavigationChrome: Bool

    @State private var projectID = ""
    @State private var agentID = ""
    @State private var accountID = ""
    @State private var modelID = ""
    @State private var reasoningID = ""
    /// Last-successful choices are scoped to this exact identity. A catalogue refresh repairs
    /// the open draft in place; changing Mac, agent, or account loads that identity's memory.
    @State private var runChoiceIdentity: MobileNewSessionChoiceIdentity?
    @State private var didInitializeRunChoice = false
    @State private var speedID = ""
    @State private var permissionID = ""
    /// The agent's supported UI is the safe default; Native stays an explicit experimental opt-in.
    @State private var surface = RemoteSessionSurface.terminal
    @State private var role = SessionDraftRole.agent
    @State private var prompt = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var hintAnimated = false
    @State private var promptSuggestion: String
    /// Set the moment the keyboard announces it is leaving. Focus ends only once it has gone,
    /// and a row folding then is a second motion after the first; folding on the announcement
    /// lets the row fold as the keyboard drops.
    @State private var keyboardIsLeaving = false
    /// The keyboard's announced overlap with the screen's bottom, tracked by hand the way the
    /// conversation composer tracks it. SwiftUI's automatic avoidance moved the composer on its
    /// own schedule: it collapsed the inset the moment Start resigned focus — the composer
    /// teleported behind the still-departing keyboard and was revealed by it — and raised it
    /// mid-push while the keyboard was already standing, so the field arrived after the
    /// keyboard it belongs on. The announcement carries the end frame and the duration, which
    /// is enough to ride the keyboard exactly.
    @State private var keyboardOverlap: CGFloat = 0
    /// How far the composer's picture still is from its laid-out slot. A keyboard move snaps
    /// `keyboardOverlap` — one layout — and puts the distance here, animated back to zero on
    /// the keyboard's own duration. Animating the padding itself re-measured the editor and
    /// re-centred the ground on every frame of the ride, which shipped as a ride-down visibly
    /// below the keyboard's frame rate; an offset is a render-pass transform and costs no
    /// layout at all.
    @State private var keyboardRideOffset: CGFloat = 0
    /// When the ride now animating comes to rest. The handoff to the started chat waits for
    /// this moment: a Mac that answers Start inside the ride would otherwise mount the whole
    /// session screen — terminal view, fonts, socket — on the very frames the ride still
    /// needs, and the composer's move down shipped stuttering under that boot.
    @State private var rideSettlesAt: Date?
    /// When this screen appeared. A keyboard frame announced inside the push that brought the
    /// screen in belongs to that transition, not to an interaction on a settled screen.
    @State private var appearedAt: Date?
    @State private var runPickerIsPresented = false
    @State private var identityPickerIsPresented = false
    @State private var attachmentTray: ComposerAttachmentTray?
    @State private var attachmentItems: [ComposerAttachmentItem] = []
    @State private var attachmentNotice: String?
    @State private var attachmentPhotoItems: [PhotosPickerItem] = []
    @State private var attachmentPicksInFlight = 0
    @State private var isChoosingAttachmentSource = false
    @State private var pendingAttachmentSource: SessionDraftAttachmentSource?
    @State private var isPickingAttachmentPhotos = false
    @State private var isImportingAttachmentFiles = false
    @State private var clipboardOffersFiles = false
    @State private var presentedAttachmentEvidence = false
    @State private var speedChooserIsPresented = false
    @State private var permissionChooserIsPresented = false
    /// UIKit owns the actual first-responder lifecycle. This is plain view state rather than
    /// `FocusState`: no SwiftUI text control exists here for a focus binding to register against.
    @State private var promptIsFocused = false
    /// Once the native editor reaches its cap, its document moves independently of this shell.
    /// The first-line actions then need their own fixed row instead of remaining over the scroll
    /// viewport while the line whose exclusions they share disappears above it.
    @State private var promptIsOverflowing = false
    /// Whether the prompt has wrapped to a second line, which is where the first-line targets
    /// stop reaching below their marks; see `firstLineTarget(around:hangsBelow:)`.
    @State private var promptWraps = false

    /// What the empty prompt suggests. One is drawn per draft, so the set has to be large
    /// enough that a person starting several chats in a sitting does not see the same line
    /// twice in a row. Each is a task a developer would actually type — an imperative with a
    /// specific object, not a mood.
    ///
    /// Each also has to fit the prompt's first line beside Start, in English and in Swedish:
    /// the field grows vertically, so a hint that wraps makes the folded composer two lines
    /// tall before anything is typed. The room is the screen width less the composer's two
    /// insets, the gap and the button — 301pt on a 375pt phone — and every line here measures
    /// under that at the 17pt body size. Measure a new one before adding it.
    private static let promptSuggestions = [
        MobileL10n.string("Hunt down the flaky test…"),
        MobileL10n.string("Make the impossible state impossible…"),
        MobileL10n.string("Find the bug hiding in plain sight…"),
        MobileL10n.string("Delete the code nobody will miss…"),
        MobileL10n.string("Find out why CI went red…"),
        MobileL10n.string("Make the slow path the fast path…"),
        MobileL10n.string("Write the test I should have written…"),
        MobileL10n.string("Reproduce the crash, then end it…"),
        MobileL10n.string("Turn the TODO into a done…"),
        MobileL10n.string("Name the magic numbers…"),
        MobileL10n.string("Squash warnings before they breed…"),
        MobileL10n.string("Find where the leak starts…"),
        MobileL10n.string("Make the retry actually retry…"),
        MobileL10n.string("Cut the launch time in half…"),
        MobileL10n.string("Rename what was named at 2am…"),
        MobileL10n.string("Find the off-by-one…"),
        MobileL10n.string("Explain why this works at all…"),
        MobileL10n.string("Move the work off the main thread…"),
        MobileL10n.string("Kill the race, keep the speed…"),
        MobileL10n.string("Trace the stray pixel to its source…"),
        MobileL10n.string("Bring the prototype up to code…"),
        MobileL10n.string("Make the error message useful…"),
    ]

    init(draft: MobileSessionDraft, showsNavigationChrome: Bool) {
        self.draft = draft
        self.showsNavigationChrome = showsNavigationChrome
        let evidenceID = ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]
        let suggestion: String
        if evidenceID?.contains("new-session-draft-matrix-") == true {
            // Cross-product evidence holds presentation inputs still. The ordinary evidence id
            // deliberately rotates suggestions, but that would make attachment/keyboard columns
            // differ for a reason unrelated to the requested draft state.
            suggestion = Self.promptSuggestions[0]
        } else if let evidenceID {
            let index = evidenceID.unicodeScalars.reduce(0) { $0 + Int($1.value) }
                % Self.promptSuggestions.count
            suggestion = Self.promptSuggestions[index]
        } else {
            suggestion = Self.promptSuggestions.randomElement() ?? Self.promptSuggestions[0]
        }
        _promptSuggestion = State(initialValue: suggestion)
        // Focused from the first layout, not from `onAppear`: a prompt that takes focus after
        // appearing unfolds the action row while the push is still sliding the screen in, and
        // the strip crossfaded at its final position while the field was still travelling.
        // Born focused, the composer is complete — field and actions — before the transition's
        // first frame, and the keyboard rises as part of the push.
#if DEBUG
        _promptIsFocused = State(initialValue: ProcessInfo.processInfo.environment[
            "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE"
        ] == nil)
#else
        _promptIsFocused = State(initialValue: true)
#endif
    }

    // MARK: - Catalogue

    private var catalog: RemoteNewSessionCatalogDTO? {
        appModel.me?.newSessionCatalog
    }

    private var selectedProject: RemoteProjectChoiceDTO? {
        catalog?.projects.first { $0.id == projectID }
    }

    /// A Mac that can confer the manager grant on a remotely started session says so in its
    /// catalogue; one that cannot gets no role to choose, rather than a request it would ignore.
    private var offersManager: Bool {
        catalog?.supportsManagerRole == true
    }

    private var selectedAgent: RemoteAgentChoiceDTO? {
        catalog?.agents.first { $0.id == agentID }
    }

    private var accounts: [RemoteAccountChoiceDTO] {
        selectedAgent?.accounts ?? []
    }

    private var selectedAccount: RemoteAccountChoiceDTO? {
        accounts.first { $0.id == accountID }
    }

    /// Every runtime the Mac offers, for the identity picker's strip.
    private var agents: [RemoteAgentChoiceDTO] {
        let resolved = catalog?.agents ?? []
#if DEBUG
        // The demo Mac is logged into two runtimes; a real one is commonly logged into all
        // five, which is the strip's full width and the case its tile measurements exist for.
        // The evidence state adds the missing three so the shipping layout is photographed at
        // the cardinality it actually ships at.
        if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            == "new-session-identity-picker-full" {
            return resolved + Self.identityEvidenceRuntimes
        }
#endif
        return resolved
    }

#if DEBUG
    /// The runtimes the demo catalogue has no login for. They route no account, which is also
    /// the strip's other real shape: a symbol mark rather than a brand image, and a tile whose
    /// choice ends the panel.
    private static let identityEvidenceRuntimes: [RemoteAgentChoiceDTO] = [
        .init(
            id: "grok",
            name: "Grok",
            models: [],
            defaultModelID: nil,
            supportsConversation: false
        ),
        .init(
            id: "opencode",
            name: "OpenCode",
            models: [],
            defaultModelID: nil,
            supportsConversation: false
        ),
        .init(
            id: "cursor",
            name: "Cursor",
            models: [],
            defaultModelID: nil,
            supportsConversation: false
        ),
    ]
#endif

    private var models: [RemoteModelChoiceDTO] {
        let resolved = selectedAccount?.models ?? selectedAgent?.models ?? []
#if DEBUG
        // The picker evidence state carries one bounded overflow page so the real shipping
        // popover proves both its no-scroll geometry and the pager's full-size touch targets.
        if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            == "new-session-model-effort-picker" {
            return resolved + Self.pickerEvidenceOverflowModels
        }
#endif
        return resolved
    }

#if DEBUG
    private static let pickerEvidenceOverflowModels: [RemoteModelChoiceDTO] = [
        .init(
            id: "evidence-gpt-5.5",
            name: "GPT-5.5",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
                .init(id: "xhigh", name: "Extra High"),
                .init(id: "max", name: "Max"),
                .init(id: "ultra", name: "Ultra"),
            ],
            defaultReasoningID: "high",
            supportsFastMode: true
        ),
        .init(
            id: "evidence-gpt-5.4",
            name: "GPT-5.4",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
                .init(id: "xhigh", name: "Extra High"),
                .init(id: "max", name: "Max"),
            ],
            defaultReasoningID: "medium",
            supportsFastMode: true
        ),
        .init(
            id: "evidence-gpt-5.3",
            name: "GPT-5.3",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ],
            defaultReasoningID: "medium",
            supportsFastMode: false
        ),
        .init(
            id: "evidence-gpt-5.2",
            name: "GPT-5.2",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ],
            defaultReasoningID: "medium",
            supportsFastMode: false
        ),
    ]
#endif

    private var defaultModelID: String? {
        selectedAccount?.defaultModelID ?? selectedAgent?.defaultModelID
    }

    /// The model the draft will start: the explicit choice, else the identity's default.
    private var draftModelID: String? {
        modelID.isEmpty ? defaultModelID : modelID
    }

    private var selectedModel: RemoteModelChoiceDTO? {
        models.first { $0.id == draftModelID }
    }

    /// The disc's rings follow the model the draft will start, so picking Fable rings its window
    /// before the chat exists.
    private var selectedUsageReading: MobileAccountUsageReading? {
        MobileAccountUsageReading.resolve(account: selectedAccount, model: draftModelID)
    }

    // MARK: - Body

    var body: some View {
        navigationChrome(around: GeometryReader { proxy in
            // The ground fills what the composer and the keyboard leave, so the hint centres in
            // the space that is actually empty and a drag anywhere on it reaches the keyboard.
            ScrollView {
                hint
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    // Half the composer's ride: the hint centres in the space the composer and
                    // keyboard leave, so a ride that moves the composer by Δ moves this centre
                    // by Δ/2 — carried by the same render-pass offset, not by re-centring
                    // layout every frame.
                    .offset(y: keyboardRideOffset / 2)
            }
            // Immediately rather than interactively: the composer rides `keyboardOverlap`,
            // which the keyboard announces only when it commits a move, so a keyboard dragged
            // down by the finger would leave the composer floating over the gap until release.
            .scrollDismissesKeyboard(.immediately)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .padding(.bottom, keyboardOverlap)
                .offset(y: keyboardRideOffset)
        }
        .background(theme.ground)
        // The composer follows the keyboard through `keyboardOverlap`, on the keyboard's own
        // duration. Automatic avoidance moved it on a schedule of its own — see the state's
        // comment — so it is switched off rather than doubled.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        )
        .onAppear {
            appearedAt = Date()
            applyCatalogDefaults()
            configureAttachments()
            hintAnimated = true
#if DEBUG
            configureDraftMatrixPrompt()
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-multiline" {
                prompt = "Review the keyboard lifecycle, compare the open and dismissed layouts, and summarize any remaining spacing regressions before you make changes."
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-scroll-overflow" {
                // Long enough to put the insertion point below the capped viewport: this proves
                // the fixed first-row controls still own clear space after TextKit scrolls away
                // from the document's original first line.
                prompt = Array(repeating: "G", count: 12).joined(separator: "\n")
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-single-character" {
                // The first glyph used to add line-two clearance despite there being no line
                // two, increasing the editor's fitted height until that glyph was deleted.
                prompt = "G"
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-model-effort-picker" {
                if selectedModel?.reasoning.contains(where: { $0.id == "ultra" }) == true {
                    reasoningID = "ultra"
                }
                runPickerIsPresented = true
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-identity-picker"
                || ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-identity-picker-full" {
                identityPickerIsPresented = true
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-structured-error" {
                errorMessage = RemoteClientError.server(
                    status: 422,
                    code: RemoteRESTErrorCode.unknownModel.rawValue
                ).localizedDescription
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-attachments", !presentedAttachmentEvidence {
                presentedAttachmentEvidence = true
                Task { @MainActor in beginChoosingAttachmentSource() }
            }
#endif
        }
        .onChange(of: agentID) { _, _ in
            applyAgentDefaults()
        }
        .onChange(of: accountID) { _, _ in
            applyAccountDefaults()
        }
        .onChange(of: modelID) { _, _ in
            applyModelDefaults()
        }
        .onChange(of: catalog) { _, _ in
            // Discovery and settings can change while this screen is open. Keep every still-valid
            // choice, but do not submit an identifier the current Mac catalogue has withdrawn.
            applyCatalogDefaults()
        }
        .onChange(of: appModel.client != nil) { _, _ in
            configureAttachments()
        }
        .onChange(of: supportsDraftAttachments) { _, _ in
            configureAttachments()
        }
        .onChange(of: attachmentPhotoItems) { _, items in
            beginLoadingPhotos(items)
        }
        .onChange(of: isChoosingAttachmentSource) { _, isPresented in
            guard !isPresented, let source = pendingAttachmentSource else { return }
            pendingAttachmentSource = nil
            switch source {
            case .photos: isPickingAttachmentPhotos = true
            case .files: isImportingAttachmentFiles = true
            case .clipboard: _ = stageClipboardFiles()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { notification in
            keyboardIsLeaving = true
            updateKeyboardOverlap(from: notification, hiding: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in
            keyboardIsLeaving = false
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )
        ) { notification in
            updateKeyboardOverlap(from: notification)
        }
        .themedAlert(
            "Couldn’t start session",
            message: errorMessage ?? "",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .photosPicker(
            isPresented: $isPickingAttachmentPhotos,
            selection: $attachmentPhotoItems,
            maxSelectionCount: remainingAttachmentSlots,
            matching: .any(of: [.images, .videos])
        )
        .fileImporter(
            isPresented: $isImportingAttachmentFiles,
            allowedContentTypes: ComposerAttachmentSources.documentTypes,
            allowsMultipleSelection: true
        ) { result in
            beginImportingFiles(result)
        }
    }

    /// Removing the modifier itself matters here. Leaving an empty `.toolbar` attached while the
    /// draft fades lets SwiftUI retain its previous items and merge them with the session's bar.
    /// Only the identity disc is this screen's: the principal title belongs to
    /// `SessionDraftView`, which keeps it mounted through Start so the name morphs into the
    /// chat's instead of being swapped with it.
    @ViewBuilder
    private func navigationChrome<Content: View>(around content: Content) -> some View {
        if showsNavigationChrome {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    identityControl
                }
            }
        } else {
            content
        }
    }

    /// Moves the composer to the keyboard's announced end frame.
    ///
    /// A frame that arrives while the push that brought this screen in is still running is part
    /// of that transition: the keyboard slides in with the screen already risen, so the
    /// composer is placed on its top edge without animation and the one motion is the push.
    /// On a settled screen the keyboard's own duration carries the composer with it — up when
    /// the prompt takes focus again after a chooser, down when Start resigns it.
    private func updateKeyboardOverlap(from notification: Notification, hiding: Bool = false) {
        let target = hiding ? 0 : MobileKeyboardOverlap.target(from: notification)
        guard target != keyboardOverlap else { return }
        let isSettled = appearedAt.map {
            Date().timeIntervalSince($0) > SessionDraftMotion.entranceSettleDuration
        } ?? false
        var snap = Transaction()
        snap.disablesAnimations = true
        if isSettled {
            // One layout, then transforms: the padding snaps to the destination while the
            // offset carries the picture back to where it stood, and only the offset animates.
            // `+=` keeps a ride that is retargeted mid-flight visually continuous.
            withTransaction(snap) {
                keyboardRideOffset += target - keyboardOverlap
                keyboardOverlap = target
            }
            let duration = MobileKeyboardOverlap.duration(from: notification)
            rideSettlesAt = Date().addingTimeInterval(
                duration + SessionDraftMotion.rideSettleMargin
            )
            withAnimation(.easeOut(duration: duration)) {
                keyboardRideOffset = 0
            }
        } else {
            withTransaction(snap) {
                keyboardOverlap = target
                keyboardRideOffset = 0
            }
        }
    }

    /// The middle of the ground: the surface's glyph, the project as a plain dropdown, and its
    /// branch. No plate and no tile — the glyph is a symbol in the tertiary ink, and the project
    /// is a line of text with a chevron, which is as quiet as a menu can be and still be found.
    private var hint: some View {
        VStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: hintSymbol)
                .font(.system(size: MobileDesign.Size.draftHintGlyph, weight: .light))
                .foregroundStyle(theme.tertiaryLabel)
                .symbolEffect(
                    .bounce,
                    options: .nonRepeating,
                    value: reduceMotion ? false : hintAnimated
                )
                .padding(.bottom, MobileDesign.Spacing.tight)
            // "Agent in AnotherTerminal": the role and the project as one sentence, each word a
            // menu. Two menus rather than one format string, so each stays its own control; the
            // joining word is the only piece that is not.
            HStack(spacing: MobileDesign.Spacing.small) {
                if offersManager {
                    roleMenu
                    Text("in")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                }
                projectMenu
            }
            if let branch = selectedProject?.branch, !branch.isEmpty {
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.pane)
    }

    /// A manager's glyph is the Mac's for the role; an agent's is its surface's.
    private var hintSymbol: String {
        switch role {
        case .manager: return "person.3"
        case .agent:
            return surface == .conversation ? "bubble.left.and.bubble.right" : "terminal"
        }
    }

    // MARK: - Composer

    /// Whether the action row is unfolded. Focus decides, because focus is what the evidence
    /// harness drives and what a tap on the prompt changes; the keyboard's own announcement
    /// only brings the fold forward to the moment the keyboard starts to go.
    private var showsChoices: Bool {
        ((promptIsFocused && !keyboardIsLeaving) || anyChooserIsPresented) && !isSubmitting
    }

    /// A chooser is still the composer being edited: the strip it was opened from stays
    /// unfolded beneath it whether or not the keyboard is standing, and the prompt takes the
    /// keyboard back when it closes, so choosing a model does not end the writing.
    private var showsFoldedSummary: Bool {
        !showsChoices && !isSubmitting
    }

    private var anyChooserIsPresented: Bool {
        runPickerIsPresented || speedChooserIsPresented || permissionChooserIsPresented
    }

    /// A chooser opens over the keyboard, where the writing is, and the keyboard stays: the
    /// model-by-effort matrix stands above the composer on an iPhone 17 Pro with room to spare.
    /// Every chooser used to drop the keyboard first, for the height it *might* need, which
    /// made picking a model a two-keyboard-animation detour on a phone that had the room. The
    /// popover now measures itself against the screen (`MobileThemedPopoverRoom`) and asks for
    /// the keyboard's room only where there is none — an iPhone SE — by ending focus here; the
    /// prompt takes the keyboard back when the chooser closes, as it always did.
    private func makeRoomForChooser() {
        promptIsFocused = false
    }

    /// What the folded composer says instead of nothing: the run it is set up for, in one
    /// quiet line. Tapping it is tapping the composer.
    private var foldedSummary: String {
        var parts = [runSummary]
        if selectedModel?.supportsFastMode == true { parts.append(selectedSpeedName) }
        if !(selectedAgent?.permissionModes ?? []).isEmpty { parts.append(selectedPermissionName) }
        if selectedAgent?.supportsConversation == true { parts.append(selectedSurfaceTitle) }
        return parts.joined(separator: " · ")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let attachmentNotice {
                Text(attachmentNotice)
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, MobileDesign.Spacing.small)
            }
            if !attachmentItems.isEmpty {
                ComposerAttachmentStrip(
                    items: attachmentItems,
                    theme: theme,
                    isRemovalEnabled: !isSubmitting,
                    remove: { attachmentTray?.remove($0) }
                )
                .padding(.bottom, MobileDesign.Spacing.small)
            }
            VStack(alignment: .leading, spacing: 0) {
                if promptIsOverflowing {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        if attachmentTray != nil { attachmentButtonOnMargin(hangsBelow: true) }
                        Spacer(minLength: 0)
                        sendButtonOnMargin(hangsBelow: true)
                    }
                    .frame(height: SessionDraftPromptMetrics.controlRow)
                    // The send disc sits over full-width text here; the editor's own top inset
                    // alone left the disc reading as resting on the first line.
                    .padding(.bottom, MobileDesign.Spacing.tight)
                }
                promptEditor
            }
            // The actions belong to the first line, not to two permanent columns beside the
            // whole draft. TextKit excludes their footprints from that line; every later line
            // reclaims the composer's full width beneath them.
            .overlay(alignment: .topLeading) {
                if !promptIsOverflowing, attachmentTray != nil {
                    attachmentButtonOnMargin(hangsBelow: !promptWraps)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !promptIsOverflowing { sendButtonOnMargin(hangsBelow: !promptWraps) }
            }
            // Folded to nothing rather than removed: the chips are menus, and a menu that is
            // unmounted under a finger cannot finish what it was asked. Clipping keeps the
            // folded row from painting over the prompt's last line. The air above the strip
            // comes after the clip: a clip is a hit shape as well, and with the padding inside
            // it the strip's empty top eight points took the taps the send target reaches down
            // for — a tap two points under the disc did nothing.
            choiceStrip
                .frame(height: showsChoices ? MobileDesign.Size.compactControl : 0)
                .opacity(showsChoices ? 1 : 0)
                .clipped()
                .padding(.top, showsChoices ? MobileDesign.Spacing.small : 0)
                .allowsHitTesting(showsChoices)
                .accessibilityHidden(!showsChoices)
            // The folded composer says what it is set up for rather than nothing. Not while
            // starting: the strip folds for the handoff too, and a line appearing for that
            // third of a second would read as a glitch.
            Text(foldedSummary)
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: showsFoldedSummary ? SessionDraftMetrics.foldedSummaryHeight : 0)
                .opacity(showsFoldedSummary ? 1 : 0)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { promptIsFocused = true }
                // The air above the line comes after its hit shape, for the strip's reason.
                .padding(.top, showsFoldedSummary ? MobileDesign.Spacing.tight : 0)
                .allowsHitTesting(showsFoldedSummary)
                .accessibilityHidden(!showsFoldedSummary)
        }
        .onChange(of: anyChooserIsPresented) { _, presented in
            if !presented { promptIsFocused = true }
        }
        .padding(.horizontal, MobileDesign.Spacing.composerHorizontal)
        .padding(.top, MobileDesign.Spacing.small)
        .padding(.bottom, MobileDesign.Spacing.small)
        .frame(maxWidth: .infinity)
        .background(theme.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: theme.borderWidth)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: SessionDraftMotion.foldDuration),
            value: showsChoices
        )
    }

    /// The prompt shares its first line with Start, so the composer folded to that one line is
    /// still the whole composer. Top-aligned: a longer prompt grows down from a stable first
    /// row instead of carrying the button away with every line.
    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            SessionDraftPromptEditor(
                text: $prompt,
                isFocused: $promptIsFocused,
                isOverflowing: $promptIsOverflowing,
                isEnabled: !isSubmitting,
                theme: theme,
                offersFiles: { attachmentTray?.canAcceptMore == true
                    && ComposerClipboard.general.hasFiles },
                pasteFiles: stageClipboardFiles,
                firstLineLeadingAccessoryWidth: promptFirstLineLeadingAccessoryWidth,
                firstLineTrailingAccessoryWidth: promptFirstLineTrailingAccessoryWidth,
                firstLineAccessoryHeight: SessionDraftPromptMetrics.controlRow,
                firstLineAccessoriesInline: !promptIsOverflowing
            )
            .mobileUIEvidenceKeyboardFocus($promptIsFocused)
            // Drawn here rather than by the editor: the field's own placeholder takes the
            // system's colour, not the theme's, and disappears behind a prompt that is only
            // whitespace — a stray newline left the phone's composer saying nothing at all.
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(promptPlaceholder)
                    .font(.body)
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
                    .padding(
                        .top,
                        SessionDraftPromptMetrics.textInsets(
                            for: UIFont.preferredFont(forTextStyle: .body)
                        ).top
                    )
                    .padding(.leading, promptFirstLineLeadingAccessoryWidth)
                    .padding(.trailing, promptFirstLineTrailingAccessoryWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: SessionDraftPromptMetrics.controlRow)
        // Whether the prompt has a second line, read from the height the editor took. The
        // first-line targets stop hanging below their marks once it has.
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.height > SessionDraftPromptMetrics.wrapThreshold(
                for: UIFont.preferredFont(forTextStyle: .body)
            )
        } action: { wraps in
            promptWraps = wraps
        }
    }

    /// The inline actions' footprints, stated whether or not the actions are currently inline.
    /// The editor decides their placement by measuring the document against these footprints,
    /// so they must not follow the placement they decide: zeroing them on overflow handed the
    /// decision its own consequence, and a prompt within a line of the cap flickered between
    /// its two layouts forever. `firstLineAccessoriesInline` is what actually releases the
    /// first line's width once the controls move to their fixed row.
    private var promptFirstLineLeadingAccessoryWidth: CGFloat {
        attachmentTray != nil ? SessionDraftPromptMetrics.accessoryExclusionWidth : 0
    }

    private var promptFirstLineTrailingAccessoryWidth: CGFloat {
        SessionDraftPromptMetrics.trailingAccessoryExclusionWidth
    }

    /// The two controls stood on the composer's margins by their marks, not their frames. Each
    /// is the full iPhone target centred on what it shows — the paperclip's glyph, the send
    /// disc — and the target's overhang past that mark is pulled out over the margin, where
    /// nothing else stands. The first line's exclusions begin where the targets end, so a tap
    /// on its words never lands on a control. The row subtracts what the control's own
    /// geometry states rather than a number of its own, the way the Mac composer places its
    /// import button by `ThemedIconButton.opticalHorizontalInset`: aligned by frame, the
    /// paperclip's ink stood nine points inboard of the chip the strip starts with beneath it.
    private func attachmentButtonOnMargin(hangsBelow: Bool) -> some View {
        attachmentButton(hangsBelow: hangsBelow)
            .padding(.leading, -SessionDraftPromptMetrics.attachmentOpticalInset)
            .padding(.top, -SessionDraftPromptMetrics.targetOverhang)
    }

    private func sendButtonOnMargin(hangsBelow: Bool) -> some View {
        sendButton(hangsBelow: hangsBelow)
            .padding(.trailing, -SessionDraftPromptMetrics.sendOpticalInset)
            .padding(.top, -SessionDraftPromptMetrics.targetOverhang)
    }

    /// The full iPhone target around a first-line mark the row lays out at its compact height.
    /// Above the mark it hangs into the composer's own padding; below it, only while the prompt
    /// is one line, because under a wrapped prompt that air is the second line, and a target
    /// over words sends what a caret tap meant to edit. The disc alone was the target before,
    /// and a tap a few points low fell into the icon menu the choice strip keeps beneath it.
    private func firstLineTarget(around mark: some View, hangsBelow: Bool) -> some View {
        let overhang = SessionDraftPromptMetrics.targetOverhang
        return mark
            .padding(.top, overhang)
            .frame(
                width: SessionDraftPromptMetrics.controlTarget,
                height: SessionDraftPromptMetrics.controlRow + overhang
                    + (hangsBelow ? overhang : 0),
                alignment: .top
            )
            .contentShape(Rectangle())
    }

    /// The paperclip in its compact slot. The subheadline face is what
    /// `MobileDesign.Size.compactControlGlyph` measures the mark by.
    private func attachmentButton(hangsBelow: Bool) -> some View {
        Button(action: beginChoosingAttachmentSource) {
            firstLineTarget(
                around: Image(systemName: "paperclip")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.secondaryLabel)
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    ),
                hangsBelow: hangsBelow
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || attachmentTray?.canAcceptMore != true)
        .accessibilityLabel(MobileL10n.string("Attachments"))
        .themedConfirmationDialog(
            "Attachments",
            isPresented: $isChoosingAttachmentSource,
            actions: attachmentSourceActions
        )
    }

    private var attachmentSourceActions: [ThemedDialogAction] {
        var actions: [ThemedDialogAction] = []
        if clipboardOffersFiles {
            actions.append(ThemedDialogAction("From Clipboard") {
                pendingAttachmentSource = .clipboard
            })
        }
        actions.append(ThemedDialogAction("Photo Library") {
            pendingAttachmentSource = .photos
        })
        actions.append(ThemedDialogAction("Files") {
            pendingAttachmentSource = .files
        })
        actions.append(ThemedDialogAction("Cancel", role: .cancel))
        return actions
    }

    /// The run settings — how the chat will run — as one compact, non-scrolling row. Where and
    /// who are not here: the project stands in the ground and the account in the bar.
    private var choiceStrip: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            runMenu
                .layoutPriority(1)
            if selectedModel?.supportsFastMode == true {
                speedMenu
            }
            Spacer(minLength: MobileDesign.Spacing.small)
            if !(selectedAgent?.permissionModes ?? []).isEmpty {
                permissionMenu
            }
            if selectedAgent?.supportsConversation == true {
                surfaceMenu
            }
        }
    }

    /// The toolbar circles' disc, in the first-line target.
    private func sendButton(hangsBelow: Bool) -> some View {
        Button {
            submit()
        } label: {
            firstLineTarget(
                around: ZStack {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .opacity(isSubmitting ? 0 : 1)
                    ProgressView()
                        // The ink chosen against the accent itself, like the arrow it
                        // replaces. `ground` was near-invisible on the accent disc: a dark
                        // theme's ground over an orange accent is orange-on-orange.
                        .tint(theme.accentForeground)
                        .opacity(isSubmitting ? 1 : 0)
                }
                .frame(
                    width: MobileDesign.Size.compactControl,
                    height: MobileDesign.Size.compactControl
                )
                .background(
                    canSubmit || isSubmitting ? theme.accent : theme.controlResting,
                    in: Circle()
                ),
                hangsBelow: hangsBelow
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit || isSubmitting ? theme.accentForeground : theme.tertiaryLabel)
        .disabled(!canSubmit)
        .accessibilityLabel(MobileL10n.string("Start session"))
    }

    /// A chat gets one of the task suggestions; a manager is briefed, not tasked.
    private var promptPlaceholder: String {
        role == .manager ? MobileL10n.string("Brief the manager…") : promptSuggestion
    }

    // MARK: - Choices

    private var projectMenu: some View {
        Menu {
            ForEach(catalog?.projects ?? []) { project in
                Button {
                    projectID = project.id
                } label: {
                    Label(
                        projectLabel(project),
                        systemImage: project.id == projectID ? "checkmark" : "folder"
                    )
                }
            }
        } label: {
            DraftMenuLabel(title: selectedProject?.name ?? MobileL10n.string("Project"))
        }
        // A menu's button keeps the width it was first measured at, so a label that changes
        // length — "Agent" to "Manager", one project to another — is clipped inside the old
        // frame. A fresh identity per value is a fresh button, measured for what it says.
        .id(projectID)
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Project"))
        .accessibilityValue(selectedProject?.name ?? "")
    }

    private var roleMenu: some View {
        Menu {
            ForEach(SessionDraftRole.allCases, id: \.self) { candidate in
                Button {
                    role = candidate
                } label: {
                    Label(
                        candidate.title,
                        systemImage: candidate == role ? "checkmark" : candidate.symbol
                    )
                }
            }
        } label: {
            DraftMenuLabel(title: role.title)
        }
        .id(role)
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Role"))
        .accessibilityValue(role.title)
    }

    /// The bar's disc opens the identity picker: the runtime strip and the login rows on one
    /// popover, hanging from the disc they change. A system menu here listed both decisions as
    /// one scrolling column and closed on the first of them; see `MobileIdentityPicker`. Choosing
    /// a runtime leaves the popover open — the rows beneath follow it — and choosing a login
    /// closes it, so the common case is one opening.
    private var identityControl: some View {
        Button {
            identityPickerIsPresented = true
        } label: {
            MobileAccountDisc(
                identity: .resolve(agentID),
                reading: selectedUsageReading
            )
        }
        // Deliberately *not* `.plain`: a bar item's own plate is what the chat's disc wears,
        // because that disc is a `Menu` there. The two bars show one control for one login, so
        // the draft keeps the plate rather than becoming the one screen without it.
        .disabled(isSubmitting)
        // The control changes both halves of *who* now, so it is named for both.
        .accessibilityLabel(MobileL10n.string("Agent and account"))
        .accessibilityValue(selectedIdentityAccessibilityValue)
        .mobileThemedPopover(
            isPresented: $identityPickerIsPresented,
            theme: theme,
            arrowEdge: .top,
            // This panel hangs *down* from the bar, so the keyboard is the far edge of its room
            // rather than the near one, and a phone with the height keeps it up — which the
            // composer's own choosers cannot promise. A small phone is still a small phone: the
            // login rows cap and scroll, and below that cap the presenter drops the keyboard
            // rather than letting UIKit shrink the panel and clip the last login away.
            makeRoom: makeRoomForChooser
        ) {
            MobileIdentityPicker(
                agents: agents,
                selectedAgentID: agentID,
                accounts: accounts,
                selectedAccountID: accountID,
                draftModelID: draftModelID,
                onChooseAgent: { chosen in
                    agentID = chosen
                    // A runtime that routes no second login has nothing further to say, so it
                    // closes the panel the way a login does. The catalogue is asked rather than
                    // this screen's `accounts`, which still describes the runtime being left:
                    // a state write is visible to the next update, not inside this closure.
                    if agents.first(where: { $0.id == chosen })?.accounts?.isEmpty != false {
                        identityPickerIsPresented = false
                    }
                },
                onChooseAccount: { chosen in
                    accountID = chosen
                    identityPickerIsPresented = false
                }
            )
        }
    }

    private var surfaceMenu: some View {
        Menu {
            Button {
                surface = .conversation
            } label: {
                Label(
                    "Native (Experimental)",
                    systemImage: surface == .conversation
                        ? "checkmark"
                        : "bubble.left.and.bubble.right"
                )
            }
            Button {
                surface = .terminal
            } label: {
                Label(
                    originalUISurfaceTitle,
                    systemImage: surface == .terminal ? "checkmark" : "terminal"
                )
            }
        } label: {
            // The icon is the value: a terminal for the agent's own UI, a bubble for Native.
            DraftIconMenuLabel(
                symbol: surface == .conversation ? "bubble.left.and.bubble.right" : "terminal",
                isSet: surface == .conversation
            )
        }
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Interface"))
        .accessibilityValue(selectedSurfaceTitle)
    }

    private var originalUISurfaceTitle: String {
        MobileL10n.string(
            "%@ UI",
            selectedAgent?.name ?? MobileL10n.string("Agent")
        )
    }

    private var selectedSurfaceTitle: String {
        surface == .conversation
            ? MobileL10n.string("Native · Experimental")
            : originalUISurfaceTitle
    }

    /// Model and effort keep one unchanged one-line trigger. The popover shows the two as the
    /// relationship they actually are, while speed remains the simpler independent three-way
    /// choice beside it. All three draft choosers share the theme-owned popover chrome below.
    private var runMenu: some View {
        Button {
            runPickerIsPresented = true
        } label: {
            DraftMenuLabel(symbol: "cpu", title: runSummary)
        }
        .buttonStyle(.plain)
        .id(runSummary)
        .disabled(models.isEmpty && selectedModel == nil)
        .accessibilityLabel(MobileL10n.string("Model and effort"))
        .accessibilityValue(runSummary)
        .mobileThemedPopover(
            isPresented: $runPickerIsPresented,
            theme: theme,
            arrowEdge: .bottom,
            makeRoom: makeRoomForChooser
        ) {
            MobileModelEffortPicker(
                models: models,
                defaultModelID: defaultModelID,
                selectedModelID: modelID,
                selectedEffortID: reasoningID,
                onChoose: { model, effort in
                    modelID = model ?? ""
                    reasoningID = effort ?? ""
                    runPickerIsPresented = false
                }
            )
        }
    }

    private var runSummary: String {
        SessionDraftRunSummary.text(
            model: selectedModel?.name,
            effort: selectedModel?.reasoning.first(where: { $0.id == reasoningID })?.name
        )
    }

    private var speedMenu: some View {
        Button {
            speedChooserIsPresented = true
        } label: {
            DraftMenuLabel(
                symbol: selectedSpeedSymbol,
                title: selectedSpeedName,
                isSet: !speedID.isEmpty
            )
        }
        .buttonStyle(.plain)
        .id("speed-\(speedID)")
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Speed"))
        .accessibilityValue(selectedSpeedName)
        .mobileThemedPopover(
            isPresented: $speedChooserIsPresented,
            theme: theme,
            arrowEdge: .bottom,
            makeRoom: makeRoomForChooser
        ) {
            MobileDraftChooser(
                title: MobileL10n.string("Speed"),
                choices: speedChoices,
                selectedID: speedID,
                onChoose: { choice in
                    speedID = choice
                    speedChooserIsPresented = false
                }
            )
        }
    }

    private var speedChoices: [MobileDraftChoice] {
        [
            MobileDraftChoice(
                id: "",
                name: MobileL10n.string("Inherit"),
                detail: MobileL10n.string("Follows the Conversation Speed setting on the Mac"),
                symbol: MobilePermissionModeGlyph.inheritSymbol,
                rank: nil
            ),
            MobileDraftChoice(
                id: "standard",
                name: MobileL10n.string("Standard"),
                detail: MobileL10n.string("Normal speed and usage"),
                symbol: "gauge.with.dots.needle.50percent",
                rank: 0
            ),
            MobileDraftChoice(
                id: "fast",
                name: MobileL10n.string("Fast"),
                detail: MobileL10n.string("1.5× speed, increased usage"),
                symbol: "bolt.fill",
                rank: 1
            ),
        ]
    }

    private var selectedSpeedName: String {
        switch speedID {
        case "fast": return MobileL10n.string("Fast")
        case "standard": return MobileL10n.string("Standard")
        default: return MobileL10n.string("Inherit")
        }
    }

    /// The bolt is the meaning of Fast, not of the speed control itself. Keep the trigger's
    /// glyph aligned with the value so an inherited or standard run never looks accelerated.
    private var selectedSpeedSymbol: String {
        switch speedID {
        case "fast": return "bolt.fill"
        case "standard": return "gauge.with.dots.needle.50percent"
        default: return "arrow.triangle.branch"
        }
    }

    private var permissionMenu: some View {
        Button {
            permissionChooserIsPresented = true
        } label: {
            DraftIconMenuLabel(symbol: selectedPermissionSymbol, isSet: !permissionID.isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Permissions"))
        .accessibilityValue(selectedPermissionName)
        .mobileThemedPopover(
            isPresented: $permissionChooserIsPresented,
            theme: theme,
            arrowEdge: .bottom,
            makeRoom: makeRoomForChooser
        ) {
            MobileDraftChooser(
                title: MobileL10n.string("Permissions"),
                choices: permissionChoices,
                selectedID: permissionID,
                onChoose: { choice in
                    permissionID = choice
                    permissionChooserIsPresented = false
                }
            )
        }
    }

    /// Inherit first, then the agent's modes in the order the Mac sends them, which is the
    /// shared vocabulary's own: from asking before anything to checking nothing.
    private var permissionChoices: [MobileDraftChoice] {
        [MobileDraftChoice(
            id: "",
            name: MobileL10n.string("Inherit"),
            detail: MobileL10n.string("Uses the agent's setting on the Mac"),
            symbol: MobilePermissionModeGlyph.inheritSymbol,
            rank: nil
        )] + (selectedAgent?.permissionModes ?? []).map { mode in
            MobileDraftChoice(
                id: mode.id,
                name: mode.name,
                detail: mode.detail,
                symbol: MobilePermissionModeGlyph.symbol(for: mode.id),
                rank: MobilePermissionModeGlyph.rank(for: mode.id)
            )
        }
    }

    /// The chip's glyph follows the value: an open lock says Bypass where a raised hand said
    /// only "permissions".
    private var selectedPermissionSymbol: String {
        permissionID.isEmpty
            ? MobilePermissionModeGlyph.unsetSymbol
            : MobilePermissionModeGlyph.symbol(for: permissionID)
    }

    private var selectedPermissionName: String {
        selectedAgent?.permissionModes?.first(where: { $0.id == permissionID })?.name
            ?? MobileL10n.string("Inherit")
    }

    private var selectedIdentityLabel: String {
        guard let selectedAgent else { return MobileL10n.string("Agent") }
        guard let selectedAccount else { return selectedAgent.name }
        return "\(selectedAgent.name) · \(selectedAccount.name)"
    }

    /// The chip carries the usage as a ring; VoiceOver gets the words the ring stands for.
    private var selectedIdentityAccessibilityValue: String {
        guard selectedAccount != nil else { return selectedIdentityLabel }
        guard let usage = selectedUsageReading?.summary else { return selectedIdentityLabel }
        return "\(selectedIdentityLabel), \(usage)"
    }

    private func projectLabel(_ project: RemoteProjectChoiceDTO) -> String {
        guard let branch = project.branch, !branch.isEmpty else { return project.name }
        return "\(project.name) · \(branch)"
    }

    // MARK: - Attachments

    /// An older Mac ignores the create request's additive fields. The affordance therefore
    /// follows explicit discovery: showing it without this feature could upload successfully
    /// against the draft UUID and then launch a first prompt that silently omitted every file.
    private var supportsDraftAttachments: Bool {
        if appModel.me?.features?.contains(
            RemoteRESTFeature.sessionDraftAttachmentUploads.rawValue
        ) == true {
            return true
        }
#if DEBUG
        let demo = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
        return demo == "new-session-attachments"
            || demo == "new-session-draft-matrix"
            || demo == "new-session-single-character"
            || demo == "new-session-scroll-overflow"
#else
        return false
#endif
    }

    private var remainingAttachmentSlots: Int {
        max(
            1,
            RemoteAttachmentUploadLimits.maximumPerMessage
                - (attachmentTray?.items.count ?? 0)
        )
    }

    private func configureAttachments() {
        guard attachmentTray == nil, supportsDraftAttachments,
              let client = appModel.client else { return }
        let tray = ComposerAttachmentTray(
            client: client,
            uploadScopeID: draft.id.uuidString
        )
        tray.onChange = { [weak tray] in
            guard let tray else { return }
            attachmentItems = tray.items
            attachmentNotice = tray.notice
        }
        attachmentTray = tray
#if DEBUG
        configureDraftMatrixAttachments(tray)
#endif
    }

#if DEBUG
    /// The requested visual cross-product shares one product fixture. The evidence id chooses
    /// only bounded state; keyboard ownership remains with the catalogue runner.
    private func configureDraftMatrixPrompt() {
        guard ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-draft-matrix",
              let evidenceID = ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_UI_EVIDENCE_ID"
              ] else { return }
        if evidenceID.contains("-empty-") {
            prompt = ""
        } else if evidenceID.contains("-words-") {
            prompt = "Review the notification flow"
        } else if evidenceID.contains("-scroll-") {
            prompt = (1...12)
                .map { "Draft line \(String(format: "%02d", $0))" }
                .joined(separator: "\n")
        }
    }

    private func configureDraftMatrixAttachments(_ tray: ComposerAttachmentTray) {
        guard ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-draft-matrix",
              let evidenceID = ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_UI_EVIDENCE_ID"
              ] else { return }
        let count = evidenceID.contains("-a4-") ? 4 : (evidenceID.contains("-a1-") ? 1 : 0)
        tray.configureEvidenceItems(count: count)
    }
#endif

    private func beginChoosingAttachmentSource() {
        guard attachmentTray?.canAcceptMore == true else { return }
        // This asks only for type availability. Bytes are read after an explicit Paste/source
        // choice, preserving iOS's paste privacy prompt and keeping body recomputation cheap.
        clipboardOffersFiles = ComposerClipboard.general.hasFiles
        isChoosingAttachmentSource = true
    }

    @discardableResult
    private func stageClipboardFiles() -> Bool {
        guard let tray = attachmentTray, tray.canAcceptMore else { return false }
        let files = ComposerClipboard.general.files()
        guard !files.isEmpty else { return false }
        for file in files {
            tray.add(data: file.data, name: file.name, type: file.type)
        }
        return true
    }

    private func beginLoadingPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        attachmentPicksInFlight += 1
        Task { @MainActor in
            defer { attachmentPicksInFlight -= 1 }
            guard let tray = attachmentTray else { return }
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let type = item.supportedContentTypes.first else {
                    tray.reportUnreadableFile()
                    continue
                }
                tray.add(
                    data: data,
                    name: "photo-\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "jpg")",
                    type: type
                )
            }
            attachmentPhotoItems = []
        }
    }

    private func beginImportingFiles(_ result: Result<[URL], Error>) {
        guard let urls = try? result.get() else {
            attachmentTray?.reportUnreadableFile()
            return
        }
        guard !urls.isEmpty else { return }
        attachmentPicksInFlight += 1
        Task { @MainActor in
            defer { attachmentPicksInFlight -= 1 }
            guard let tray = attachmentTray else { return }
            for url in urls.prefix(remainingAttachmentSlots) {
                let accessed = url.startAccessingSecurityScopedResource()
                let loaded = await Task.detached(priority: .userInitiated) {
                    let data = ComposerAttachmentSources.readFile(at: url)
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                        ?? UTType(filenameExtension: url.pathExtension)
                    return data.map { ($0, type ?? .data) }
                }.value
                if accessed { url.stopAccessingSecurityScopedResource() }
                guard let (data, type) = loaded else {
                    tray.reportUnreadableFile()
                    continue
                }
                tray.add(data: data, name: url.lastPathComponent, type: type)
            }
        }
    }

    // MARK: - Defaults

    private var canSubmit: Bool {
        !isSubmitting
            && !projectID.isEmpty
            && !agentID.isEmpty
            && attachmentPicksInFlight == 0
            && attachmentTray?.isSettling != true
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyCatalogDefaults() {
        projectID = SessionDraftCatalogReconciliation.projectID(
            current: projectID,
            draftProjectName: draft.projectName,
            catalog: catalog
        )
        agentID = SessionDraftCatalogReconciliation.agentID(
            current: agentID,
            catalog: catalog
        )
        if role == .manager, !offersManager { role = .agent }
        applyAgentDefaults()
    }

    private func applyAgentDefaults() {
        guard let selectedAgent else { return }
        if !accounts.contains(where: { $0.id == accountID }) {
            accountID = accounts.first(where: { $0.id == "default" })?.id
                ?? accounts.first?.id
                ?? ""
        }
        if !selectedAgent.supportsConversation { surface = .terminal }
        if !(selectedAgent.permissionModes ?? []).contains(where: { $0.id == permissionID }) {
            permissionID = ""
        }
        applyAccountDefaults()
    }

    private func applyAccountDefaults() {
        let identity = appModel.newSessionChoiceIdentity(
            agentID: agentID,
            accountID: accountID
        )
        let current = MobileNewSessionRunChoice(
            modelID: modelID,
            reasoningID: reasoningID
        )
        let resolved: MobileNewSessionRunChoice
        if !didInitializeRunChoice || identity != runChoiceIdentity {
            resolved = SessionDraftRunChoiceResolution.initial(
                remembered: identity.flatMap { appModel.rememberedNewSessionChoice(for: $0) },
                defaultModelID: defaultModelID,
                models: models
            )
            runChoiceIdentity = identity
            didInitializeRunChoice = true
        } else {
            resolved = SessionDraftRunChoiceResolution.repair(
                current: current,
                defaultModelID: defaultModelID,
                models: models
            )
        }
        modelID = resolved.modelID ?? ""
        reasoningID = resolved.reasoningID ?? ""
        applyModelDefaults()
    }

    private func applyModelDefaults() {
        guard let selectedModel else {
            reasoningID = ""
            speedID = ""
            return
        }
        // Empty is the deliberate Auto column. Bootstrap and withdrawal repair materialize the
        // live effective default elsewhere; changing a model must not erase an Auto choice.
        if !reasoningID.isEmpty,
           !selectedModel.reasoning.contains(where: { $0.id == reasoningID }) {
            reasoningID = selectedModel.defaultReasoningID.flatMap { id in
                selectedModel.reasoning.contains(where: { $0.id == id }) ? id : nil
            } ?? ""
        }
        if selectedModel.supportsFastMode != true { speedID = "" }
    }

    // MARK: - Start

    /// Start is the first half of the motion: the keyboard goes and the composer rides down
    /// with it, so by the time the Mac answers the screen is already the shape the chat will
    /// take. The second half — this screen becoming the session's — is `SessionDraftView`'s,
    /// triggered by the model learning which session the draft became.
    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        promptIsFocused = false
        let openingAttachmentUploadIDs = attachmentTray?.readyUploadIDs ?? []
        let launchChoice = SessionDraftRunChoiceResolution.launch(
            current: MobileNewSessionRunChoice(modelID: modelID, reasoningID: reasoningID),
            defaultModelID: defaultModelID,
            models: models
        )
        let launchIdentity = appModel.newSessionChoiceIdentity(
            agentID: agentID,
            accountID: accountID
        )
        Task {
            do {
                let creation = try await appModel.createSession(
                    projectID: projectID,
                    agentKind: agentID,
                    accountHandle: accountID.isEmpty ? nil : accountID,
                    model: launchChoice.modelID,
                    reasoningEffort: launchChoice.reasoningID,
                    fastMode: speedID == "fast" ? true : (speedID == "standard" ? false : nil),
                    permissionMode: permissionID.isEmpty ? nil : permissionID,
                    surface: surface,
                    role: role.wireValue,
                    openingAttachmentScopeID: openingAttachmentUploadIDs.isEmpty
                        ? nil
                        : draft.id.uuidString,
                    openingAttachmentUploadIDs: openingAttachmentUploadIDs,
                    prompt: prompt
                )
                if let launchIdentity {
                    appModel.rememberNewSessionChoice(launchChoice, for: launchIdentity)
                }
                attachmentTray?.clear()
                // The second half of the motion waits for the first. A Mac can answer inside
                // the composer's ride down; mounting the chat's screen then puts its whole
                // boot on the frames the ride still needs. The hold is bounded by the
                // keyboard's own duration and is zero whenever the answer took longer.
                if let rideSettlesAt {
                    let remaining = rideSettlesAt.timeIntervalSinceNow
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                }
                // Turns this screen into the session's: `SessionDraftView` fades this one
                // out over the chat the model now says the draft became.
                appModel.noteDraftStarted(draft, creation: creation)
            } catch is CancellationError {
                isSubmitting = false
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                isSubmitting = false
                errorMessage = error.localizedDescription
                if let remote = error as? RemoteClientError,
                   remote.requiresLaunchCatalogRefresh {
                    // The refusal is authoritative, while this draft's catalogue may be an old
                    // snapshot. Refresh behind the alert and reconcile only invalid selections;
                    // the prompt and every still-valid choice remain untouched.
                    await appModel.refresh()
                    applyCatalogDefaults()
                }
            }
        }
    }
}

/// The new-session prompt's native editor.
///
/// SwiftUI's axis-expanding `TextField` was visually compact, but it left this one composer on a
/// different edit-menu path from every existing-session composer. Hosting the shared
/// `IntrinsicTextView` restores UIKit's selection, insertion-point paste, undo, accessibility,
/// and file-paste interception while keeping SwiftUI responsible for the surrounding layout.
/// Focus is an explicit binding because the UIKit view, not a SwiftUI text control, is the focus
/// target; the coordinator reports user focus and `updateUIView` applies programmatic requests.
struct SessionDraftPromptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isOverflowing: Bool
    let isEnabled: Bool
    let theme: RemoteThemePalette
    let offersFiles: () -> Bool
    let pasteFiles: () -> Bool
    let firstLineLeadingAccessoryWidth: CGFloat
    let firstLineTrailingAccessoryWidth: CGFloat
    let firstLineAccessoryHeight: CGFloat
    let firstLineAccessoriesInline: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            isOverflowing: $isOverflowing
        )
    }

    func makeUIView(context: Context) -> IntrinsicTextView {
        let view = IntrinsicTextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isOpaque = false
        view.font = font
        view.textContainerInset = SessionDraftPromptMetrics.textInsets(for: font)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = MobileL10n.string("Prompt")
        view.minimumIntrinsicHeight = SessionDraftPromptMetrics.controlRow
        view.maximumIntrinsicHeight = SessionDraftPromptMetrics.maximumHeight(for: font)
        view.firstLineLeadingAccessoryWidth = firstLineLeadingAccessoryWidth
        view.firstLineTrailingAccessoryWidth = firstLineTrailingAccessoryWidth
        view.firstLineAccessoryHeight = firstLineAccessoryHeight
        view.firstLineAccessoriesInline = firstLineAccessoriesInline
        view.preferredCaretHeight = font.pointSize
        view.onFirstLineAccessoryOverflowChange = context.coordinator.reportAccessoryOverflow
        view.keyboardAppearance = MobileKeyboardAppearance.matching(theme.colorScheme)
        return view
    }

    func updateUIView(_ view: IntrinsicTextView, context: Context) {
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        let font = UIFont.preferredFont(forTextStyle: .body)
        view.font = font
        view.textContainerInset = SessionDraftPromptMetrics.textInsets(for: font)
        view.textColor = theme.uiLabel
        view.tintColor = theme.uiAccent
        view.isEditable = isEnabled
        view.isSelectable = true
        view.minimumIntrinsicHeight = SessionDraftPromptMetrics.controlRow
        view.maximumIntrinsicHeight = SessionDraftPromptMetrics.maximumHeight(for: font)
        view.firstLineLeadingAccessoryWidth = firstLineLeadingAccessoryWidth
        view.firstLineTrailingAccessoryWidth = firstLineTrailingAccessoryWidth
        view.firstLineAccessoryHeight = firstLineAccessoryHeight
        view.firstLineAccessoriesInline = firstLineAccessoriesInline
        view.preferredCaretHeight = font.pointSize
        view.offersFiles = offersFiles
        view.pasteFiles = pasteFiles
        let keyboardAppearance = MobileKeyboardAppearance.matching(theme.colorScheme)
        if view.keyboardAppearance != keyboardAppearance {
            view.keyboardAppearance = keyboardAppearance
        }

        if isFocused, !view.isFirstResponder {
            Task { @MainActor [weak view] in
                guard let view, isFocused, view.window != nil else { return }
                view.becomeFirstResponder()
            }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// Measured once per distinct input, not once per layout pass. While the action row folds
    /// or the composer rides the keyboard, SwiftUI lays the composer out on every animation
    /// frame and asks this editor its size each time; crossing into TextKit for an answer that
    /// cannot have changed was a per-frame cost the ride paid in dropped frames. The cache key
    /// is everything the measurement reads.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: IntrinsicTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let key = Coordinator.MeasurementKey(
            width: width,
            text: uiView.text ?? "",
            fontPointSize: uiView.font?.pointSize ?? 0,
            leadingAccessoryWidth: firstLineLeadingAccessoryWidth,
            trailingAccessoryWidth: firstLineTrailingAccessoryWidth,
            accessoryHeight: firstLineAccessoryHeight,
            accessoriesInline: firstLineAccessoriesInline
        )
        if let cached = context.coordinator.cachedMeasurement, cached.key == key {
            return CGSize(width: width, height: cached.height)
        }
        uiView.updateFirstLineAccessoryExclusions(for: width)
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let height = min(
            max(measured.height, SessionDraftPromptMetrics.controlRow),
            uiView.maximumIntrinsicHeight
        )
        context.coordinator.cachedMeasurement = (key, height)
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        struct MeasurementKey: Equatable {
            let width: CGFloat
            let text: String
            let fontPointSize: CGFloat
            let leadingAccessoryWidth: CGFloat
            let trailingAccessoryWidth: CGFloat
            let accessoryHeight: CGFloat
            let accessoriesInline: Bool
        }

        /// The last measurement and the inputs it was taken under; see `sizeThatFits`.
        var cachedMeasurement: (key: MeasurementKey, height: CGFloat)?

        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var isOverflowing: Binding<Bool>

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            isOverflowing: Binding<Bool>
        ) {
            self.text = text
            self.isFocused = isFocused
            self.isOverflowing = isOverflowing
        }

        func reportAccessoryOverflow(_ overflows: Bool) {
            guard isOverflowing.wrappedValue != overflows else { return }
            // Layout is in progress when the native view discovers the threshold. Move the
            // SwiftUI state change to the next main-actor turn instead of mutating the shell
            // from inside its representable's layout pass.
            Task { @MainActor [weak self] in
                guard let self, self.isOverflowing.wrappedValue != overflows else { return }
                self.isOverflowing.wrappedValue = overflows
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused.wrappedValue = false
        }
    }
}

private enum SessionDraftPromptMetrics {
    static let maximumLines: CGFloat = 6

    /// The first line is the compact row the choice strip beneath it is, and its two controls
    /// are the full iPhone target around a mark that row lays out — the paperclip's glyph, the
    /// send disc. The row stands each on the composer's margin by that mark: the target's
    /// overhang past the mark is its optical inset, pulled out over the margin. Vertically the
    /// target hangs `targetOverhang` above the row, and below it only under a one-line prompt
    /// (`firstLineTarget(around:hangsBelow:)`), so the second line starts where it always did.
    static let controlRow = MobileDesign.Size.compactControl
    static let controlTarget = MobileDesign.Size.minimumTapTarget
    static let targetOverhang = MobileDesign.Size.opticalInset(
        target: controlTarget,
        mark: controlRow
    )
    /// The editor height above which the prompt has a second line. One line is not exactly the
    /// row: TextKit's line fragment runs two points past the font's nominal line height, so a
    /// one-line body editor stands 36 tall against a 34 row. A second line adds a whole line,
    /// so half of one separates the two states whatever the reader's text size.
    static func wrapThreshold(for font: UIFont) -> CGFloat {
        controlRow + font.lineHeight / 2
    }

    /// Read when asked: the glyph follows the reader's text size.
    static var attachmentOpticalInset: CGFloat {
        MobileDesign.Size.opticalInset(
            target: controlTarget,
            mark: MobileDesign.Size.compactControlGlyph
        )
    }

    static let sendOpticalInset = MobileDesign.Size.opticalInset(
        target: controlTarget,
        mark: MobileDesign.Size.compactControl
    )

    /// What the first line keeps clear of words: the control's target as far as it reaches into
    /// the line — measured from the margin, so the overhang pulled out over it is not counted —
    /// plus the gap the old horizontal stack held beside it. Every later line uses those points.
    static var accessoryExclusionWidth: CGFloat {
        controlTarget - attachmentOpticalInset + MobileDesign.Spacing.small
    }

    /// The send control is a filled accent disc, not a bare glyph like the paperclip, and text
    /// running the standard gap up to a solid plate reads as touching it. Its exclusion holds
    /// wider air.
    static var trailingAccessoryExclusionWidth: CGFloat {
        controlTarget - sendOpticalInset + MobileDesign.Spacing.medium
    }

    /// The editor shares its first row with the two marks. `UITextView` otherwise puts a
    /// zero-inset line against the row's top while both marks are centred, which is the visual
    /// split in the issue report. Keep equal air around a single line; larger Dynamic Type lines
    /// consume the row instead of gaining negative inset.
    static func textInsets(for font: UIFont) -> UIEdgeInsets {
        let vertical = max(0, (controlRow - font.lineHeight) / 2)
        return UIEdgeInsets(top: vertical, left: 0, bottom: vertical, right: 0)
    }

    static func maximumHeight(for font: UIFont) -> CGFloat {
        let insets = textInsets(for: font)
        return ceil(font.lineHeight * maximumLines + insets.top + insets.bottom)
    }
}

private enum SessionDraftAttachmentSource {
    case clipboard
    case photos
    case files
}

/// Pure catalogue repair for an already-mounted draft. Selection state lives in SwiftUI, but
/// the rule is transport-facing: preserve a value while the current Mac still advertises it and
/// choose a deterministic fallback once it does not.
enum SessionDraftCatalogReconciliation {
    static func projectID(
        current: String,
        draftProjectName: String?,
        catalog: RemoteNewSessionCatalogDTO?
    ) -> String {
        guard catalog?.projects.contains(where: { $0.id == current }) != true else {
            return current
        }
        return draftProjectName.flatMap { name in
            catalog?.projects.first {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }?.id
        } ?? catalog?.projects.first?.id ?? ""
    }

    static func agentID(
        current: String,
        catalog: RemoteNewSessionCatalogDTO?
    ) -> String {
        guard catalog?.agents.contains(where: { $0.id == current }) != true else {
            return current
        }
        return catalog?.agents.first(where: { $0.id == "codex" })?.id
            ?? catalog?.agents.first?.id
            ?? ""
    }
}

/// What the draft will start: an agent on a task, or a manager coordinating the project.
///
/// A manager is the Mac's role, not a runtime: the same session with its project's control
/// grant. The phone only names it; `RemoteSessionRole` carries the word and the Mac confers
/// the authority.
enum SessionDraftRole: CaseIterable {
    case agent
    case manager

    var title: String {
        switch self {
        case .agent: return MobileL10n.string("Agent")
        case .manager: return MobileL10n.string("Manager")
        }
    }

    /// The Mac's own glyph for each role, as its composer's role chip draws them.
    var symbol: String {
        switch self {
        case .agent: return "bubble.left"
        case .manager: return "person.3"
        }
    }

    /// Nil for an agent: a chat is what an older Mac starts for a request with no role, and
    /// what every request meant before the field existed.
    var wireValue: RemoteSessionRole? {
        switch self {
        case .agent: return nil
        case .manager: return RemoteSessionRole.manager
        }
    }
}

/// The run menu's one line: the model, then only the choices that depart from its defaults.
enum SessionDraftRunSummary {
    static let separator = " · "

    /// `model` nil is the catalogue's default model and `effort` nil means inherited, which the
    /// line leaves unsaid — "GPT-5.6 Sol" says more than "GPT-5.6 Sol · Default". Speed owns
    /// the neighbouring control instead of making this relationship read as a three-axis grid.
    static func text(model: String?, effort: String?) -> String {
        [model ?? MobileL10n.string("Default model"), effort]
            .compactMap { $0 }
            .joined(separator: separator)
    }
}

/// A menu that is a line of text: an optional glyph, the chosen value, a chevron. No plate —
/// the project in the middle of the ground and the run settings in the composer are the same
/// kind of control and read as the same kind of thing. An explicit, non-inherited choice
/// promotes only its value glyph to the accent; otherwise the glyph stays secondary.
private struct DraftMenuLabel: View {
    @Environment(\.remoteTheme) private var theme
    var symbol: String? = nil
    let title: String
    var isSet = false

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.tight) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(isSet ? theme.accent : theme.secondaryLabel)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.label)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: MobileDesign.Size.chipChevron, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
        }
        // The toolbar control's height rather than the full 44: in the ground the branch sits
        // under this line, and a taller hit area pushed it off the name it belongs to.
        .frame(minHeight: MobileDesign.Size.compactControl)
        .contentShape(Rectangle())
    }
}

/// A menu that is one glyph, for the choices almost always left alone — permissions, the
/// interface. The glyph takes the accent when the choice departs from the default, so a row
/// of quiet icons still says which one has been touched.
///
/// The glyph sits on its frame's trailing edge, not in its middle. These menus stand at the
/// row's trailing end, and the last one's ink then meets the margin the send disc stands on
/// above it; centred in its target, it sat nine points inboard, whichever symbol it drew. The
/// target keeps its full width, reaching inboard, where the finger comes from. Alignment
/// rather than a pull sized to the point size because these symbols differ in width — the
/// terminal is wider than it is tall — and a pull that puts one on the line puts another past it.
private struct DraftIconMenuLabel: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let isSet: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSet ? theme.accent : theme.secondaryLabel)
            .frame(
                width: MobileDesign.Size.compactControl,
                height: MobileDesign.Size.compactControl,
                alignment: .trailing
            )
            .contentShape(Rectangle())
    }
}
