import Foundation

struct NativeQuestionOption: Equatable, Sendable {
    let label: String
    let description: String?

    init?(_ value: JSONValue) {
        guard let fields = value.object,
              let label = fields["label"]?.string, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let description = fields["description"], description != .null, description.string == nil { return nil }
        self.label = label
        description = fields["description"]?.string
    }
}

struct NativeQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let header: String?
    let question: String
    let options: [NativeQuestionOption]
    let multiSelect: Bool

    init?(_ value: JSONValue) {
        guard let fields = value.object,
              let id = fields["id"]?.string, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let question = fields["question"]?.string, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let header = fields["header"], header != .null, header.string == nil { return nil }
        let multi = fields["multiSelect"] ?? fields["multi_select"]
        if let multi, multi != .null, multi.bool == nil { return nil }
        let options: [NativeQuestionOption]
        if let raw = fields["options"], raw != .null {
            guard case .array(let items) = raw else { return nil }
            let parsed = items.compactMap(NativeQuestionOption.init)
            guard parsed.count == items.count, Set(parsed.map(\.label)).count == parsed.count else { return nil }
            options = parsed
        } else { options = [] }
        self.id = id
        header = fields["header"]?.string
        self.question = question
        self.options = options
        multiSelect = multi?.bool ?? false
    }

    /// Validates exact known labels, then restores the server's display order.
    func validatedAnswer(selected: [String], custom: String?) -> NativeQuestionAnswer? {
        let labels = Set(options.map(\.label))
        let selection = Set(selected)
        guard selection.count == selected.count, selection.isSubset(of: labels), multiSelect || selection.count <= 1 else { return nil }
        let text = custom?.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = text.flatMap { $0.isEmpty ? nil : $0 }
        guard !selection.isEmpty || custom != nil else { return nil }
        return NativeQuestionAnswer(id: id, selected: options.map(\.label).filter { selection.contains($0) }, custom: custom)
    }
}

struct NativeQuestionAnswer: Equatable, Sendable {
    let id: String
    let selected: [String]
    let custom: String?

    init(id: String, selected: [String], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }

    var wire: JSONValue {
        var fields: [String: JSONValue] = ["id": .text(id), "selected": .array(selected.map { .text($0) })]
        if let custom { fields["custom"] = .text(custom) }
        return .obj(fields)
    }
}

struct NativeQuestionCard: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let callId: String?
    let continued: Bool
    let timed: Bool
    let questions: [NativeQuestion]

    /// `request` is the request object, or a continued descriptor with a root callId.
    init?(id: String, sessionId: String, request: JSONValue, continued: Bool = false) {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let fields = request.object,
              case .array(let items)? = fields["questions"], !items.isEmpty else { return nil }
        let questions = items.compactMap(NativeQuestion.init)
        guard questions.count == items.count, Set(questions.map(\.id)).count == questions.count else { return nil }

        var callId: String?
        var timed = false
        if let wait = fields["wait"], wait != .null {
            guard let waitFields = wait.object,
                  let waitCallId = waitFields["callId"]?.string, !waitCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let waitTimed = waitFields["timed"]?.bool else { return nil }
            callId = waitCallId
            timed = waitTimed
        }
        if continued {
            if let rootCallId = fields["callId"], rootCallId != .null {
                guard let root = rootCallId.string, !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      callId == nil || callId == root else { return nil }
                callId = root
            }
            guard callId != nil else { return nil }
        }
        self.id = id
        self.sessionId = sessionId
        self.callId = callId
        self.continued = continued
        self.timed = timed
        self.questions = questions
    }

    /// A complete batch only; rejects unknown/duplicate IDs and invalid selections.
    func validatedAnswers(_ answers: [NativeQuestionAnswer]) -> [NativeQuestionAnswer]? {
        guard answers.count == questions.count, Set(answers.map(\.id)).count == answers.count else { return nil }
        var ordered: [NativeQuestionAnswer] = []
        for question in questions {
            guard let answer = answers.first(where: { $0.id == question.id }),
                  let validated = question.validatedAnswer(selected: answer.selected, custom: answer.custom) else { return nil }
            ordered.append(validated)
        }
        return ordered
    }
}

/// The person's in-progress choices for one card. Never pre-filled: nothing is
/// selected or submitted until the person acts. Validation stays the strict
/// `NativeQuestion.validatedAnswer` / `NativeQuestionCard.validatedAnswers` path.
struct NativeQuestionDraft: Equatable, Sendable {
    var selections: [String: Set<String>] = [:]
    var custom: [String: String] = [:]

    func isSelected(_ label: String, in question: NativeQuestion) -> Bool {
        selections[question.id]?.contains(label) == true
    }

    mutating func toggle(_ label: String, in question: NativeQuestion) {
        var current = selections[question.id] ?? []
        if current.contains(label) { current.remove(label) }
        else if question.multiSelect { current.insert(label) }
        else { current = [label] }
        selections[question.id] = current
    }

    /// A complete, server-ordered batch, or nil until every question is answered validly.
    func answers(for card: NativeQuestionCard) -> [NativeQuestionAnswer]? {
        let answers = card.questions.compactMap {
            $0.validatedAnswer(selected: Array(selections[$0.id] ?? []), custom: custom[$0.id])
        }
        return card.validatedAnswers(answers)
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// View-layer drafts shared by the inline composer-slot card and the Questions
/// list, so choices survive collapse, navigation and a failed submit/retry.
/// Bounded; the Store remains the owner of pending cards and submission.
@MainActor @Observable final class NativeQuestionDrafts {
    func reset() { values.removeAll(); order.removeAll() }
    private var values: [String: NativeQuestionDraft] = [:]
    private var order: [String] = []

    func draft(_ id: String) -> NativeQuestionDraft { values[id] ?? NativeQuestionDraft() }

    func update(_ id: String, _ draft: NativeQuestionDraft) {
        values[id] = draft
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 32 { values[order.removeFirst()] = nil }
    }

    func binding(_ id: String) -> Binding<NativeQuestionDraft> {
        Binding(get: { self.draft(id) }, set: { self.update(id, $0) })
    }
}

/// Reference-counts visible holders of a timed question so the Store's single
/// `userQuestions/attachWait` lease is released only when no surface shows it.
@MainActor final class NativeQuestionLeases {
    private var holders: [String: Set<UUID>] = [:]
    private var revisions: [String: Int] = [:]
    private var epoch = UUID()
    private var work: [UUID: Task<Void, Never>] = [:]
    func reset() {
        epoch = UUID(); holders.removeAll(); revisions.removeAll()
        for task in work.values { task.cancel() }
    }
    func drain() async { for task in Array(work.values) { await task.value } }

    /// Synchronous holder decisions precede async transport. A newer presentation
    /// revision invalidates queued work from a rapid collapse/expand or re-pair.
    func sync(holder: UUID, cards: [NativeQuestionCard], previous: [String: NativeQuestionCard], store: NativeStore) -> [String: NativeQuestionCard] {
        var wanted: [String: NativeQuestionCard] = [:], changed: [String: NativeQuestionCard] = [:]
        for card in cards where card.timed { wanted[card.id] = card }
        for (id, card) in previous where wanted[id] == nil {
            let key = store.questionPresentationKey(card)
            if holders[key]?.remove(holder) != nil { changed[key] = card }
            if holders[key]?.isEmpty == true { holders[key] = nil }
        }
        for card in wanted.values {
            let key = store.questionPresentationKey(card)
            holders[key, default: []].insert(holder); changed[key] = card
        }
        let currentEpoch = epoch, scope = store.imageAuthorizationScope
        for (key, card) in changed {
            let revision = (revisions[key] ?? 0) + 1; revisions[key] = revision
            let job = UUID()
            work[job] = Task { @MainActor [weak self, weak store] in
                guard let self else { return }
                defer { self.work[job] = nil }
                guard !Task.isCancelled, let store, self.epoch == currentEpoch,
                      store.imageAuthorizationScope == scope, self.revisions[key] == revision else { return }
                await store.setQuestionVisible(card, visible: self.holders[key]?.isEmpty == false)
                if self.revisions[key] == revision, self.holders[key] == nil { self.revisions[key] = nil }
            }
        }
        return wanted
    }
}

/// Reusable question editor. `.form` emits List/Form sections (Questions list);
/// `.card` emits the T3 inline-card layout (composer slot). AX identifiers are
/// `<idPrefix>-option-<question>-<index>` and `<idPrefix>-custom-<question>`.
struct NativeQuestionEditor: View {
    enum Style { case form, card }
    let card: NativeQuestionCard
    @Binding var draft: NativeQuestionDraft
    let disabled: Bool
    var style: Style = .form
    var idPrefix = "question"
    @ScaledMetric(relativeTo: .caption) private var microSize: CGFloat = 12
    @ScaledMetric(relativeTo: .subheadline) private var smallSize: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var questionSize: CGFloat = 16

    var body: some View {
        switch style {
        case .form:
            ForEach(card.questions) { question in
                Section {
                    Text(question.question).textSelection(.enabled)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        formOption(option, question: question, index: index)
                    }
                    TextField(placeholder(question), text: customBinding(question), axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("\(idPrefix)-custom-\(question.id)")
                        .disabled(disabled)
                } header: {
                    if let header = question.header, !header.isEmpty { Text(header) }
                } footer: {
                    Text(footer(question))
                }
            }
        case .card:
            VStack(alignment: .leading, spacing: T3Metric.steps(4)) {
                ForEach(card.questions) { question in cardQuestion(question) }
            }
        }
    }

    private func placeholder(_ question: NativeQuestion) -> String {
        question.options.isEmpty ? "Your answer (required)" : "Custom answer (optional)"
    }

    private func footer(_ question: NativeQuestion) -> String {
        question.options.isEmpty ? "Type an answer to continue."
            : (question.multiSelect ? "Choose one or more options, add a custom answer, or both." : "Choose one option, add a custom answer, or both.")
    }

    private func customBinding(_ question: NativeQuestion) -> Binding<String> {
        Binding(get: { draft.custom[question.id] ?? "" }, set: { draft.custom[question.id] = $0 })
    }

    private func formOption(_ option: NativeQuestionOption, question: NativeQuestion, index: Int) -> some View {
        let selected = draft.isSelected(option.label, in: question)
        return Button { draft.toggle(option.label, in: question) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark" : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(selected ? DSHTheme.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("\(idPrefix)-option-\(question.id)-\(index)")
        .disabled(disabled)
    }

    private func cardQuestion(_ question: NativeQuestion) -> some View {
        VStack(alignment: .leading, spacing: T3Metric.steps(2)) {
            if let header = question.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: microSize, weight: .bold)).tracking(1)
                    .foregroundStyle(DSHTheme.tertiary)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(question.question)
                .font(.system(size: questionSize))
                .foregroundStyle(DSHTheme.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                VStack(spacing: T3Metric.steps(2)) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        cardOption(option, question: question, index: index)
                    }
                }
            }
            TextField(placeholder(question), text: customBinding(question), axis: .vertical)
                .font(.system(size: smallSize))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, T3Metric.steps(3.5)).padding(.vertical, T3Metric.steps(3))
                .frame(minHeight: T3Metric.steps(12))
                .background(ChatAppearance.input, in: RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous).strokeBorder(ChatAppearance.border, lineWidth: 1))
                .accessibilityIdentifier("\(idPrefix)-custom-\(question.id)")
                .disabled(disabled)
            Text(footer(question)).font(.system(size: microSize)).foregroundStyle(DSHTheme.tertiary)
        }
    }

    private func cardOption(_ option: NativeQuestionOption, question: NativeQuestion, index: Int) -> some View {
        let selected = draft.isSelected(option.label, in: question)
        let shape = RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous)
        return Button { draft.toggle(option.label, in: question) } label: {
            HStack(alignment: .center, spacing: T3Metric.steps(3)) {
                VStack(alignment: .leading, spacing: T3Metric.steps(0.5)) {
                    Text(option.label)
                        .font(.system(size: smallSize, weight: .bold))
                        .foregroundStyle(selected ? DSHTheme.label : DSHTheme.secondary)
                    if let description = option.description, !description.isEmpty, description != option.label {
                        Text(description).font(.system(size: smallSize)).foregroundStyle(DSHTheme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : (question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? DSHTheme.accent : DSHTheme.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, T3Metric.steps(3.5)).padding(.vertical, T3Metric.steps(3))
            .frame(minHeight: T3Metric.steps(12))
            .background(selected ? DSHTheme.accent.opacity(0.10) : ChatAppearance.input, in: shape)
            .overlay(shape.strokeBorder(selected ? DSHTheme.accent : ChatAppearance.border, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(question.multiSelect ? "Multiple choice" : "Single choice")
        .accessibilityIdentifier("\(idPrefix)-option-\(question.id)-\(index)")
        .disabled(disabled)
    }
}

/// Pending questions for every session. Navigation-free: each card is answered
/// in place, so it works pushed from Settings (no nested NavigationStack) or
/// presented. Use `NativeQuestionsSheet` when presenting modally.
struct NativeQuestions: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var holder = UUID()
    @State private var leased: [String: NativeQuestionCard] = [:]

    var body: some View {
        List {
            if !store.connected {
                Label("Reconnect to answer questions", systemImage: "wifi.slash").foregroundStyle(.secondary)
            }
            if store.questions.isEmpty {
                ContentUnavailableView("All questions answered", systemImage: "checkmark.bubble", description: Text("No pending questions across your sessions."))
            }
            ForEach(store.questions) { card in
                NativeQuestionForm(card: card)
            }
        }
        .navigationTitle("Questions").navigationBarTitleDisplayMode(.inline)
        .onAppear { onScreen = true; syncLeases() }
        .onDisappear { onScreen = false; syncLeases() }
        .onChange(of: store.questions.map(\.id)) { _, _ in syncLeases() }
        .onChange(of: store.connected) { _, _ in syncLeases() }
        .onChange(of: scenePhase) { _, _ in syncLeases() }
    }

    /// Timed leases only while this list is on screen in an active scene.
    private func syncLeases() {
        let visible = onScreen && store.connected && scenePhase == .active
        leased = store.questionLeaseBook.sync(holder: holder, cards: visible ? store.questions : [], previous: leased, store: store)
    }
}

/// Modal presentation of `NativeQuestions` with its own stack and Done.
struct NativeQuestionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            NativeQuestions()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// One card's sections inside the Questions list.
private struct NativeQuestionForm: View {
    @Environment(NativeStore.self) private var store
    let card: NativeQuestionCard
    @State private var submitting = false
    private var drafts: NativeQuestionDrafts { store.questionDraftBook }

    private var isSubmitting: Bool { submitting || store.questionSubmitting.contains(card.id) }
    private var isPending: Bool { store.questions.contains(where: { $0 == card }) }
    private var answers: [NativeQuestionAnswer]? { drafts.draft(store.questionPresentationKey(card)).answers(for: card) }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.sessions.first(where: { $0.id == card.sessionId })?.title ?? "Session \(card.sessionId)").font(.headline)
                if card.questions.count > 1 {
                    Text("\(card.questions.count) questions — answer together").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("question-card-\(card.id)")
        }
        NativeQuestionEditor(card: card, draft: drafts.binding(store.questionPresentationKey(card)), disabled: isSubmitting || !isPending, style: .form, idPrefix: "question")
        Section {
            if !store.connected {
                Label("Reconnect to submit answers", systemImage: "wifi.slash").foregroundStyle(.secondary)
            }
            if let error = store.questionErrors[card.id] {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(DSHTheme.statusFailed)
            }
            if isSubmitting { ProgressView("Submitting answers…") }
            Button(store.questionErrors[card.id] == nil ? "Submit answers" : "Retry answers", action: submit)
                .disabled(!store.connected || !isPending || isSubmitting || answers == nil)
                .accessibilityIdentifier("question-submit")
        } footer: { Text("Answer every question before submitting. Answers go to this session’s question request, not to chat.") }
    }

    private func submit() {
        // Capture the validated batch before any suspension.
        guard store.connected, isPending, !isSubmitting, let answers else { return }
        submitting = true
        Task {
            defer { submitting = false }
            _ = await store.submitAnswers(card, answers: answers)
            // The Store keeps the card until acceptance/cancellation is authoritative.
        }
    }
}

/// Selected-session question that owns the composer slot (T3
/// `PendingUserInputCard`). Collapses to a bar; the real composer stays mounted
/// but hidden by the parent so its draft and editor identity survive.
struct NativeInlineQuestionSlot: View {
    let card: NativeQuestionCard
    let position: Int
    let total: Int
    @Binding var collapsed: Bool
    let maxHeight: CGFloat
    @Environment(NativeStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var microSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var smallSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var buttonSize: CGFloat = 14
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 18
    @State private var submitting = false
    @State private var onScreen = false
    @State private var holder = UUID()
    @State private var leased: [String: NativeQuestionCard] = [:]
    @State private var contentHeight: CGFloat = 0
    private var drafts: NativeQuestionDrafts { store.questionDraftBook }

    private var isPending: Bool { store.questions.contains(where: { $0 == card }) }
    private var isSubmitting: Bool { submitting || store.questionSubmitting.contains(card.id) }
    private var answers: [NativeQuestionAnswer]? { drafts.draft(store.questionPresentationKey(card)).answers(for: card) }
    private var canStop: Bool { store.connected && store.selected?.id == card.sessionId && store.selected?.isSubagent != true && store.conversation.running }
    private var countLabel: String { "\(card.questions.count) question\(card.questions.count == 1 ? "" : "s")" }
    private var leaseVisible: Bool { onScreen && !collapsed && store.connected && scenePhase == .active }

    var body: some View {
        Group {
            if collapsed { bar } else { expanded }
        }
        .onAppear { onScreen = true; syncLease() }
        .onDisappear { onScreen = false; syncLease() }
        .onChange(of: leaseVisible) { _, _ in syncLease() }
    }

    /// Timed lease only while the expanded card is visible in an active scene.
    private func syncLease() {
        leased = store.questionLeaseBook.sync(holder: holder, cards: leaseVisible ? [card] : [], previous: leased, store: store)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { collapsed.toggle() }
    }

    private var micro: some View {
        Text(total > 1 ? "USER INPUT NEEDED · \(position) OF \(total)" : "USER INPUT NEEDED")
            .font(.system(size: microSize, weight: .bold)).tracking(1.1)
            .foregroundStyle(DSHTheme.secondary)
    }

    private var bar: some View {
        HStack(spacing: T3Metric.steps(2)) {
            Button(action: toggle) {
                HStack(spacing: T3Metric.steps(2)) {
                    micro
                    Text(countLabel).font(.system(size: smallSize)).foregroundStyle(DSHTheme.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(DSHTheme.tertiary)
                }
                .frame(minHeight: T3Metric.steps(10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand question, \(countLabel)")
            .accessibilityIdentifier("inline-question-bar")
            if canStop {
                Button { Task { await store.stop() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: T3Metric.steps(9), height: T3Metric.steps(9))
                        .background(ChatAppearance.danger, in: Circle())
                        .frame(width: T3Metric.actionTarget, height: T3Metric.actionTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -6)
                .accessibilityLabel("Stop agent")
            }
        }
        .padding(.vertical, T3Metric.steps(1.5))
        .padding(.leading, T3Metric.steps(4))
        .padding(.trailing, T3Metric.steps(1.5))
        .background(ChatAppearance.card, in: Capsule())
        .overlay(Capsule().strokeBorder(ChatAppearance.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-question-collapsed-\(card.id)")
    }

    private var expanded: some View {
        let shape = RoundedRectangle(cornerRadius: T3Metric.cardRadius, style: .continuous)
        // Header, error, submit and footnote take roughly 150pt; the questions scroll.
        let scrollLimit = max(T3Metric.steps(30), maxHeight - 150)
        return VStack(alignment: .leading, spacing: T3Metric.steps(2.5)) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: T3Metric.steps(2)) {
                    VStack(alignment: .leading, spacing: T3Metric.steps(2.5)) {
                        micro
                        Text("Answer to continue")
                            .font(.system(size: titleSize, weight: .bold))
                            .foregroundStyle(DSHTheme.label)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(DSHTheme.tertiary)
                        .frame(width: T3Metric.steps(8), height: T3Metric.steps(8))
                        .background(ChatAppearance.subtleStrong, in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse question")
            .accessibilityIdentifier("inline-question-collapse")

            ScrollView {
                NativeQuestionEditor(card: card, draft: drafts.binding(store.questionPresentationKey(card)), disabled: isSubmitting || !isPending, style: .card, idPrefix: "inline-question")
                    .padding(.bottom, T3Metric.steps(1))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .frame(height: min(max(contentHeight, 1), scrollLimit))

            if !store.connected {
                Label("Reconnect to submit answers", systemImage: "wifi.slash")
                    .font(.system(size: smallSize)).foregroundStyle(DSHTheme.secondary)
            }
            if let error = store.questionErrors[card.id] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: smallSize)).foregroundStyle(DSHTheme.statusFailed)
            }
            Button(action: submit) {
                Group {
                    if isSubmitting { Text("Submitting answers…") }
                    else { Text(store.questionErrors[card.id] == nil ? "Submit answers" : "Retry answers") }
                }
                .font(.system(size: buttonSize, weight: .heavy))
                .foregroundStyle(answers == nil ? DSHTheme.label : .white)
                .frame(maxWidth: .infinity, minHeight: T3Metric.actionTarget)
                .background(answers == nil ? ChatAppearance.subtleStrong : DSHTheme.accent,
                            in: RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!store.connected || !isPending || isSubmitting || answers == nil)
            .opacity(!store.connected || !isPending || isSubmitting ? 0.5 : 1)
            .accessibilityIdentifier("inline-question-submit")
            Text("Answers go to this session’s question request, not to chat.")
                .font(.system(size: microSize)).foregroundStyle(DSHTheme.tertiary)
        }
        .padding(T3Metric.steps(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatAppearance.card, in: shape)
        .overlay(shape.strokeBorder(ChatAppearance.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-question-card-\(card.id)")
    }

    private func submit() {
        // Validated answers are captured before the Store's async submission.
        guard store.connected, isPending, !isSubmitting, let answers else { return }
        submitting = true
        Task {
            defer { submitting = false }
            _ = await store.submitAnswers(card, answers: answers)
        }
    }
}
#endif
