import SwiftUI
import ThreadingRemoteKit
import UIKit

/// One Linked Workroom question as a conversation: the question, the form that answers it, every
/// answer and message in the order the Mac stored them, and a box to write in at the bottom.
///
/// A participant answers, writes to the agent and may decline. The owner reads and comments; the
/// form and Decline are the person's alone, and the Mac refuses them whatever this screen shows.
struct WorkroomQuestionView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    let questionID: String

    @State private var question: RemoteWorkroomQuestionDTO?
    @State private var failure: String?
    @State private var draft = WorkroomAnswerDraft()
    /// Set by the first edit, so a refresh never replaces what the person is choosing.
    @State private var draftIsDirty = false
    @State private var showsAnswerForm = false
    @State private var message = ""
    @FocusState private var composerIsFocused: Bool
    // Loaders (status-integrity review): the first load, and one send at a time — answer,
    // message or decline — each an awaited `RemoteClient` request bounded by its timeout. Success
    // replaces the page with the Mac's updated question; failure leaves `problem` or `actionError`
    // with the person's text intact; nothing is restored from cache.
    @State private var isSending = false
    @State private var justSaved = false
    @State private var problem: String?
    @State private var actionError: String?
    @State private var isDeclining = false
    @State private var declineReason = ""
    /// Whether the first copy has placed the page yet; later copies leave the scroll alone.
    @State private var hasPositioned = false

    private static let topID = "workroom.top"
    private static let bottomID = "workroom.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    if let question {
                        page(question)
                    } else if let failure {
                        WorkroomFailureCard(
                            title: MobileL10n.string("Couldn’t open the question"),
                            message: failure,
                            retry: { Task { await load() } }
                        )
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(MobileDesign.Spacing.inset)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await load() }
            .safeAreaInset(edge: .bottom) {
                if question?.canMessage == true { composer(proxy) }
            }
            .onChange(of: justSaved) { _, saved in
                if saved { withAnimation { proxy.scrollTo(Self.topID, anchor: .top) } }
            }
            .onChange(of: question?.version) { _, _ in
                // An answered or closed question is read for its conversation, which is what
                // a "new message" opens it for: start at the newest. An open one starts at the
                // question and its form.
                guard !hasPositioned, let question else { return }
                hasPositioned = true
                if question.state != .open, !question.entries.isEmpty {
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: question?.entries.count) { old, new in
                // A new message arriving or being sent: follow it, the way a chat does.
                guard let old, let new, new > old else { return }
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .background(theme.ground.ignoresSafeArea())
        .navigationTitle(MobileL10n.string("Question"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .task(id: questionID) { await poll() }
        .themedAlert(
            "Couldn’t send",
            message: actionError ?? "",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            actions: [ThemedDialogAction("OK")]
        )
        .themedAlert(
            "Decline the question",
            message: "Say why, for example that someone else should answer. The question closes.",
            isPresented: $isDeclining,
            textField: ThemedDialogTextField("Reason", text: $declineReason),
            actions: [
                ThemedDialogAction("Cancel", role: .cancel) { declineReason = "" },
                ThemedDialogAction("Decline", role: .destructive) { decline() },
            ]
        )
    }

    // MARK: Page

    @ViewBuilder
    private func page(_ question: RemoteWorkroomQuestionDTO) -> some View {
        if justSaved { savedNotice(question) }
        header(question)
        if question.canAnswer { answerSection(question) }
        if !question.entries.isEmpty {
            Text(MobileL10n.string("Conversation"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)
                .padding(.top, MobileDesign.Spacing.small)
            ForEach(question.entries) { entry in
                WorkroomEntryBubble(entry: entry, viewer: question.viewer)
            }
        }
        closingNote(question)
        if question.canDecline {
            Button {
                isDeclining = true
            } label: {
                Text(MobileL10n.string("Can’t answer this? Decline the question"))
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryLabel)
        }
        if !justSaved, question.state != .open, question.viewer == .participant, let next = question.nextQuestionID {
            Button {
                open(next)
            } label: {
                Label(MobileL10n.string("Next question"), systemImage: "arrow.right")
            }
            .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme))
        }
    }

    private func header(_ question: RemoteWorkroomQuestionDTO) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            HStack(spacing: MobileDesign.Spacing.tight) {
                Text(MobileL10n.string("From %@", question.askerName))
                WorkroomTag(text: MobileL10n.string("AI agent"))
            }
            .font(.footnote)
            .foregroundStyle(theme.secondaryLabel)
            Text(question.roomTitle)
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)
            if question.viewer == .owner {
                Text(MobileL10n.string("To %@", question.personName))
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
            }
            HStack(alignment: .top) {
                Text(question.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.label)
                Spacer(minLength: MobileDesign.Spacing.small)
                WorkroomStateBadge(state: question.state)
            }
            Text(question.prompt)
                .font(.body)
                .foregroundStyle(theme.label)
                .textSelection(.enabled)
            if !question.background.isEmpty {
                Divider().overlay(theme.divider)
                Text(MobileL10n.string("Background"))
                    .font(.subheadline.weight(.semibold))
                Text(question.background)
                    .font(.subheadline)
                    .foregroundStyle(theme.label)
                    .textSelection(.enabled)
            }
            if !question.evidence.isEmpty {
                Divider().overlay(theme.divider)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                        ForEach(Array(question.evidence.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                                Text(item.label).font(.subheadline.weight(.semibold))
                                Text(item.text).font(.subheadline).textSelection(.enabled)
                                if let source = item.source {
                                    Text(MobileL10n.string("Source: %@", source))
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryLabel)
                                }
                            }
                        }
                    }
                    .padding(.top, MobileDesign.Spacing.small)
                } label: {
                    Text(MobileL10n.string("Evidence (%ld)", question.evidence.count))
                        .font(.subheadline.weight(.semibold))
                }
                .tint(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileDesign.Spacing.inset)
        .workroomCard(theme)
    }

    private func savedNotice(_ question: RemoteWorkroomQuestionDTO) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            Label(MobileL10n.string("Your answer is saved. %@ has received it.", question.askerName),
                  systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.positive)
            if let next = question.nextQuestionID {
                Button {
                    open(next)
                } label: {
                    Label(MobileL10n.string("Next question"), systemImage: "arrow.right")
                }
                .buttonStyle(MobileThemedActionButtonStyle(kind: .primary, theme: theme))
            } else {
                Text(MobileL10n.string("That was the last open question. Thank you!"))
                    .font(.subheadline)
                    .foregroundStyle(theme.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileDesign.Spacing.inset)
        .workroomCard(theme, emphasized: true)
    }

    @ViewBuilder
    private func answerSection(_ question: RemoteWorkroomQuestionDTO) -> some View {
        let hasAnswer = question.entries.contains { $0.kind == .answer }
        if hasAnswer {
            DisclosureGroup(isExpanded: $showsAnswerForm) {
                answerForm(question, revising: true)
                    .padding(.top, MobileDesign.Spacing.medium)
            } label: {
                Text(MobileL10n.string("Change your answer"))
                    .font(.headline)
                    .foregroundStyle(theme.label)
            }
            .tint(theme.accent)
            .padding(MobileDesign.Spacing.inset)
            .workroomCard(theme)
        } else {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                Text(MobileL10n.string("Your answer")).font(.headline)
                answerForm(question, revising: false)
            }
            .padding(MobileDesign.Spacing.inset)
            .workroomCard(theme)
        }
    }

    private func answerForm(_ question: RemoteWorkroomQuestionDTO, revising: Bool) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
            ForEach(question.fields) { field in
                WorkroomFieldEditor(field: field, draft: draftBinding)
            }
            WorkroomTextEntry(
                label: question.fields.isEmpty
                    ? MobileL10n.string("Your answer")
                    : MobileL10n.string("Comment (optional)"),
                text: Binding(get: { draft.comment }, set: { draft.comment = $0; draftIsDirty = true }),
                isLong: true
            )
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(theme.negative)
            }
            Button {
                submitAnswer(question)
            } label: {
                HStack {
                    if isSending { ProgressView().controlSize(.small) }
                    Text(revising ? MobileL10n.string("Update answer") : MobileL10n.string("Send answer"))
                }
            }
            .buttonStyle(MobileThemedActionButtonStyle(kind: .primary, theme: theme))
            .disabled(isSending)
        }
    }

    /// Edits go through here so a refresh can tell a draft the person touched from one it filled.
    private var draftBinding: Binding<WorkroomAnswerDraft> {
        Binding(get: { draft }, set: { draft = $0; draftIsDirty = true; problem = nil })
    }

    @ViewBuilder
    private func closingNote(_ question: RemoteWorkroomQuestionDTO) -> some View {
        switch question.state {
        case .declined:
            WorkroomNote(text: question.viewer == .participant
                         ? MobileL10n.string("You declined this question.")
                         : MobileL10n.string("This question was declined."))
        case .withdrawn:
            WorkroomNote(text: MobileL10n.string("The agent withdrew this question."))
        case .open, .answered, .unknown:
            EmptyView()
        }
    }

    // MARK: Composer

    private func composer(_ proxy: ScrollViewProxy) -> some View {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let tooLong = message.utf8.count > RemoteWorkroomLimits.messageBytes
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
            if tooLong {
                Text(MobileL10n.string("That text is too long."))
                    .font(.caption)
                    .foregroundStyle(theme.negative)
            }
            HStack(alignment: .bottom, spacing: MobileDesign.Spacing.small) {
                TextField(
                    composerPlaceholder,
                    text: $message,
                    axis: .vertical
                )
                .lineLimit(1 ... 6)
                .focused($composerIsFocused)
                .padding(.horizontal, MobileDesign.Spacing.medium)
                .padding(.vertical, MobileDesign.Spacing.small + 2)
                .background(theme.controlResting, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onChange(of: composerIsFocused) { _, focused in
                    if focused { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
                }

                Button {
                    send()
                } label: {
                    Group {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                        }
                    }
                    .frame(width: MobileDesign.Size.compactControl + 2, height: MobileDesign.Size.compactControl + 2)
                    .foregroundStyle(theme.accentForeground)
                    .background(trimmed.isEmpty || tooLong ? theme.controlHover : theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: MobileDesign.Size.minimumTapTarget, minHeight: MobileDesign.Size.minimumTapTarget)
                .disabled(trimmed.isEmpty || tooLong || isSending)
                .accessibilityLabel(MobileL10n.string("Send"))
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.composerHorizontal)
        .padding(.vertical, MobileDesign.Spacing.composerVertical)
        .background(theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().overlay(theme.divider) }
    }

    private var composerPlaceholder: String {
        guard let question else { return "" }
        return question.viewer == .owner
            ? MobileL10n.string("Write a comment")
            : MobileL10n.string("Write to %@", question.askerName)
    }

    // MARK: Actions

    private func poll() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(RemoteWorkroomLimits.pollInterval))
            guard !Task.isCancelled else { return }
            guard UIApplication.shared.applicationState == .active, !isSending else { continue }
            guard let fresh = try? await model.fetchWorkroomQuestion(id: questionID),
                  fresh.version != question?.version else { continue }
            show(fresh)
        }
    }

    private func load() async {
        do {
            show(try await model.fetchWorkroomQuestion(id: questionID))
            failure = nil
        } catch is CancellationError {
        } catch {
            if question == nil { failure = WorkroomRefusal.message(for: error) }
        }
    }

    /// Takes a fresh copy of the question. What the person has typed into the composer is never
    /// touched, and the form is refilled only while they have not started changing it.
    private func show(_ fresh: RemoteWorkroomQuestionDTO) {
        question = fresh
        if !draftIsDirty { draft = WorkroomAnswerDraft(question: fresh) }
    }

    private func submitAnswer(_ question: RemoteWorkroomQuestionDTO) {
        if let found = draft.problem(for: question.fields) {
            problem = Self.text(for: found)
            return
        }
        problem = nil
        let request = draft.request(for: question.fields)
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let updated = try await model.answerWorkroomQuestion(id: question.id, request)
                draftIsDirty = false
                show(updated)
                showsAnswerForm = false
                justSaved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                actionError = WorkroomRefusal.message(for: error)
            }
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question, !text.isEmpty else { return }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let updated = try await model.messageWorkroomQuestion(id: question.id, text: text)
                message = ""
                show(updated)
            } catch {
                actionError = WorkroomRefusal.message(for: error)
            }
        }
    }

    private func decline() {
        let reason = declineReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question, !reason.isEmpty else {
            actionError = MobileL10n.string("Write why you decline, so the agent knows what to do next.")
            return
        }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                show(try await model.declineWorkroomQuestion(id: question.id, reason: reason))
                declineReason = ""
            } catch {
                actionError = WorkroomRefusal.message(for: error)
            }
        }
    }

    /// The next question replaces this one on the stack, so Back still goes to the inbox.
    private func open(_ next: String) {
        guard let index = model.navigationPath.lastIndex(of: .workroomQuestion(questionID)) else {
            model.navigationPath.append(.workroomQuestion(next))
            return
        }
        model.navigationPath[index] = .workroomQuestion(next)
    }

    static func text(for problem: WorkroomAnswerDraft.Problem) -> String {
        switch problem {
        case .missing: return MobileL10n.string("Fill in every field that is not marked optional.")
        case .number(let label): return MobileL10n.string("Enter a number within the stated range for “%@”.", label)
        case .tooLong: return MobileL10n.string("That text is too long.")
        case .emptyAnswer: return MobileL10n.string("Write your answer.")
        }
    }
}

// MARK: - Form fields

/// One field of the answer form in a native control: choices as cards that say what choosing
/// them leads to, yes/no and agree/disagree as a row of buttons, a number on the decimal pad.
private struct WorkroomFieldEditor: View {
    @Environment(\.remoteTheme) private var theme
    let field: RemoteWorkroomFieldDTO
    @Binding var draft: WorkroomAnswerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            HStack(spacing: MobileDesign.Spacing.tight) {
                Text(field.label).font(.subheadline.weight(.semibold))
                if !field.required {
                    Text(MobileL10n.string("(optional)"))
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
            if let help = field.help {
                Text(help).font(.footnote).foregroundStyle(theme.secondaryLabel)
            }
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .singleChoice, .multiChoice:
            let multiple = field.kind == .multiChoice
            VStack(spacing: MobileDesign.Spacing.small) {
                ForEach(field.options) { option in
                    let selected = draft.contains(option.id, in: field.id)
                    Button {
                        if multiple { draft.toggle(option.id, in: field.id) } else { draft.choose(option.id, in: field.id) }
                    } label: {
                        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                            Image(systemName: multiple
                                  ? (selected ? "checkmark.square.fill" : "square")
                                  : (selected ? "checkmark.circle.fill" : "circle"))
                                .font(.title3)
                                .foregroundStyle(selected ? theme.accent : theme.tertiaryLabel)
                            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                                Text(option.label)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(theme.label)
                                if let consequence = option.consequence {
                                    Text(consequence)
                                        .font(.footnote)
                                        .foregroundStyle(theme.secondaryLabel)
                                }
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(MobileDesign.Spacing.medium)
                        .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.minimumTapTarget, alignment: .leading)
                        .background(selected ? theme.accentMuted : theme.controlResting,
                                    in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                                .strokeBorder(selected ? theme.accent : theme.border, lineWidth: selected ? 1.5 : 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        case .yesNo:
            choiceRow(RemoteWorkroomYesNo.allCases.map { ($0.rawValue, Self.title(of: $0)) })
        case .confirm:
            choiceRow(RemoteWorkroomConfirmation.allCases.map { ($0.rawValue, Self.title(of: $0)) })
        case .number:
            HStack(spacing: MobileDesign.Spacing.small) {
                WorkroomInput(text: textBinding, prompt: "", keyboard: .decimalPad)
                    .frame(maxWidth: 180)
                if let unit = field.unit {
                    Text(unit).font(.body).foregroundStyle(theme.secondaryLabel)
                }
            }
            if let range = rangeText {
                Text(range).font(.caption).foregroundStyle(theme.secondaryLabel)
            }
        case .shortText:
            WorkroomInput(text: textBinding, prompt: "", keyboard: .default)
        case .longText:
            WorkroomTextEntry(label: nil, text: textBinding, isLong: true)
        case .unknown:
            EmptyView()
        }
    }

    private func choiceRow(_ choices: [(value: String, title: String)]) -> some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            ForEach(choices, id: \.value) { choice in
                let selected = draft.single(field.id) == choice.value
                Button {
                    draft.choose(choice.value, in: field.id)
                } label: {
                    Text(choice.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(selected ? theme.accentForeground : theme.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.minimumTapTarget)
                        .background(selected ? theme.accent : theme.controlResting,
                                    in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                                .strokeBorder(selected ? theme.accent : theme.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { draft.single(field.id) ?? "" }, set: { draft.setText($0, in: field.id) })
    }

    private var rangeText: String? {
        let format = FloatingPointFormatStyle<Double>.number
        switch (field.minimum, field.maximum) {
        case let (minimum?, maximum?):
            return MobileL10n.string("Between %@ and %@", minimum.formatted(format), maximum.formatted(format))
        case let (minimum?, nil):
            return MobileL10n.string("At least %@", minimum.formatted(format))
        case let (nil, maximum?):
            return MobileL10n.string("At most %@", maximum.formatted(format))
        case (nil, nil):
            return nil
        }
    }

    static func title(of value: RemoteWorkroomYesNo) -> String {
        switch value {
        case .yes: return MobileL10n.string("Yes")
        case .no: return MobileL10n.string("No")
        }
    }

    static func title(of value: RemoteWorkroomConfirmation) -> String {
        switch value {
        case .agree: return MobileL10n.string("Agree")
        case .disagree: return MobileL10n.string("Disagree")
        case .unsure: return MobileL10n.string("Not sure")
        }
    }
}

private struct WorkroomInput: View {
    @Environment(\.remoteTheme) private var theme
    @Binding var text: String
    let prompt: String
    let keyboard: UIKeyboardType

    var body: some View {
        TextField(prompt, text: $text)
            .keyboardType(keyboard)
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
    }
}

private struct WorkroomTextEntry: View {
    @Environment(\.remoteTheme) private var theme
    let label: String?
    @Binding var text: String
    let isLong: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            if let label {
                Text(label).font(.subheadline.weight(.semibold))
            }
            TextField("", text: $text, axis: .vertical)
                .lineLimit(isLong ? 3 ... 10 : 1 ... 3)
                .padding(MobileDesign.Spacing.medium)
                .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
        }
    }
}

// MARK: - Conversation

/// One step of the conversation. The viewer's own words stand on the right; the agent's carry
/// the AI-agent tag and the owner's say so, so a person always knows who is speaking.
struct WorkroomEntryBubble: View {
    @Environment(\.remoteTheme) private var theme
    let entry: RemoteWorkroomEntryDTO
    let viewer: RemoteWorkroomViewer

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: MobileDesign.Spacing.pane * 2) }
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                HStack(spacing: MobileDesign.Spacing.tight) {
                    Text(who)
                    if let tag { WorkroomTag(text: tag) }
                    Text(Self.timeLine(entry.at))
                }
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
                if let kindTitle {
                    Text(kindTitle).font(.subheadline.weight(.semibold))
                }
                ForEach(Array(entry.shown.enumerated()), id: \.offset) { _, shown in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shown.label).font(.caption).foregroundStyle(theme.secondaryLabel)
                        Text(shown.value).font(.body.weight(.medium))
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(theme.label)
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .padding(.vertical, MobileDesign.Spacing.small + 2)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isClosing ? theme.secondaryLabel : (isMine ? Color.clear : theme.border),
                        style: StrokeStyle(lineWidth: 1, dash: isClosing ? [4, 3] : [])
                    )
            }
            if !isMine { Spacer(minLength: MobileDesign.Spacing.pane * 2) }
        }
        .accessibilityElement(children: .combine)
    }

    /// `· 7 nov. 14:03` in the reader's own zone and language.
    static func timeLine(_ at: Double) -> String {
        "· " + Date(timeIntervalSince1970: at).formatted(.dateTime.day().month().hour().minute())
    }

    private var isMine: Bool {
        switch (viewer, entry.author) {
        case (.participant, .person), (.owner, .owner): return true
        default: return false
        }
    }

    private var isClosing: Bool { entry.kind == .decline || entry.kind == .withdrawal }

    private var who: String {
        isMine ? MobileL10n.string("You") : entry.authorName
    }

    private var tag: String? {
        switch entry.author {
        case .agent: return MobileL10n.string("AI agent")
        case .owner where !isMine: return MobileL10n.string("owner")
        default: return nil
        }
    }

    private var kindTitle: String? {
        switch entry.kind {
        case .answer:
            return (entry.revision ?? 1) > 1 ? MobileL10n.string("Changed answer") : MobileL10n.string("Answer")
        case .decline: return MobileL10n.string("Declined")
        case .withdrawal: return MobileL10n.string("Withdrawn")
        case .message, .unknown: return nil
        }
    }

    private var background: Color {
        if isMine { return theme.accentMuted }
        return entry.author == .owner ? theme.elevated : theme.panel
    }
}

struct WorkroomTag: View {
    @Environment(\.remoteTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border, lineWidth: 1))
            .fixedSize()
    }
}

private struct WorkroomNote: View {
    @Environment(\.remoteTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(theme.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MobileDesign.Spacing.medium)
            .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
    }
}
