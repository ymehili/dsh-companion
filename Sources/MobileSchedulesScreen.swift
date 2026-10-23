import SwiftUI

/// No-argument production entry point; tests can inject a service without constructing native transport.
struct MobileSchedulesScreen: View {
    @Environment(NativeStore.self) private var store
    private let injectedRPC: (any MobileSettingsRPC)?
    @State private var model: MobileSchedulesModel?

    init(rpc: (any MobileSettingsRPC)? = nil) { injectedRPC = rpc }

    var body: some View {
        Group {
            if let model { MobileSchedulesList(model: model, selectedSessionId: store.selected?.id, synthetic: store.usesFixture) }
            else { ProgressView("Loading schedules") }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobile-schedules")
        .task {
            guard model == nil else { return }
            let rpc: any MobileSettingsRPC
            if let injectedRPC { rpc = injectedRPC }
            else if store.usesFixture { rpc = MobileSchedulesFixtureRPC() }
            else { rpc = MobileSettingsNativeRPC(store: store) }
            let next = MobileSchedulesModel(rpc: rpc)
            model = next
            await next.load()
        }
    }
}

private struct MobileSchedulesList: View {
    @Bindable var model: MobileSchedulesModel
    let selectedSessionId: String?
    let synthetic: Bool
    @State private var selectedScope = ""

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $selectedScope) {
                    Text("All Host schedules").tag("")
                    if let selectedSessionId { Text("Active in selected thread").tag(selectedSessionId) }
                }
                .accessibilityIdentifier("schedules-scope")
                .onChange(of: selectedScope) { _, value in Task { await model.load(sessionId: value) } }
                if synthetic {
                    Label("Synthetic schedules — no network or Agent calls. Recurring dates are illustrative.", systemImage: "testtube.2")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(selectedScope.isEmpty ? "Catalog includes active and inactive schedules from all Host threads." : "Thread list includes active schedules only.")
            }
            if let error = model.error {
                Section("Could not load schedules") {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("schedules-error")
                    Button("Retry") { Task { await model.load(sessionId: selectedScope) } }.accessibilityIdentifier("schedules-retry")
                }
            }
            if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("schedules-notice") }
            Section("Reminders") {
                if model.loading { ProgressView("Loading schedules") }
                else if model.rows.isEmpty, model.error == nil { Text("No schedules in this scope.").foregroundStyle(.secondary).accessibilityIdentifier("schedules-empty") }
                ForEach(model.rows) { record in
                    NavigationLink {
                        MobileScheduleDetail(model: model, initial: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(record.title).font(.headline); Spacer(); Text(record.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                            Text(record.timingSummary).font(.subheadline).foregroundStyle(.secondary)
                            Text(record.scheduledAt).font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("schedule-row-\(record.id)")
                }
            }
            Section("Capabilities") {
                Label("New schedule", systemImage: "plus.circle").foregroundStyle(.secondary)
                    .accessibilityIdentifier("schedules-create-unavailable")
                Text("Creation is unavailable through the current Host Remote API. The Host has a scheduling engine, but exposes no schedule/create endpoint. Use an authorized Host interface to create reminders.")
                Text("Enable/disable and webhook rules are also not exposed. Inactive is a status, not a phone toggle.")
            }.font(.footnote)
        }
        .refreshable { await model.load(sessionId: selectedScope) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load(sessionId: selectedScope) } }
                    .disabled(model.loading || model.mutating).accessibilityIdentifier("schedules-refresh")
            }
        }
    }
}

private struct MobileScheduleDetail: View {
    @Bindable var model: MobileSchedulesModel
    let initial: MobileScheduleRecord
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingDelete = false
    private var record: MobileScheduleRecord { model.rows.first { $0.id == initial.id && $0.sessionId == initial.sessionId } ?? initial }

    var body: some View {
        Form {
            Section("Reminder") {
                LabeledContent("Title", value: record.title)
                Text(record.prompt).textSelection(.enabled)
                LabeledContent("Status", value: record.status)
                LabeledContent("Thread", value: record.sessionId).textSelection(.enabled)
                LabeledContent("ID", value: record.id).textSelection(.enabled)
            }
            Section("Timing") {
                Text(record.timingSummary)
                LabeledContent(record.status == "active" ? "Next target (UTC)" : "Final target (UTC)", value: record.scheduledAt)
                if let delivered = record.lastDelivery["deliveredAt"].string { LabeledContent("Last delivered (UTC)", value: delivered) }
            }
            Section {
                Button("Edit schedule", systemImage: "pencil") { model.error = nil; editing = true }
                    .disabled(record.status != "active" || model.mutating).accessibilityIdentifier("schedule-edit")
                NavigationLink("Delivery history") { MobileScheduleHistory(model: model, record: record) }
                    .accessibilityIdentifier("schedule-history")
                Button("Delete schedule", role: .destructive) { confirmingDelete = true }
                    .disabled(model.mutating).accessibilityIdentifier("schedule-delete")
            } footer: {
                Text("Edits use the complete original record for compare-and-swap. Delete has no compare-and-swap protection and may remove a concurrently edited schedule.")
            }
            if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("schedule-detail-error") }
        }
        .navigationTitle(record.title)
        .sheet(isPresented: $editing) { NavigationStack { MobileScheduleEditor(model: model, record: record) } }
        .confirmationDialog("Delete this schedule?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete schedule", role: .destructive) {
                Task { if await model.delete(record) { dismiss() } }
            }.accessibilityIdentifier("schedule-delete-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the task and saved delivery history, not already queued messages. The API has no CAS check: concurrent edits cannot be detected before deletion.")
        }
    }
}

private struct MobileScheduleEditor: View {
    @Bindable var model: MobileSchedulesModel
    /// Immutable snapshot captured when this editor opens. Never replaced during a save retry.
    let record: MobileScheduleRecord
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var prompt: String
    @State private var changeTiming = false
    @State private var confirmingSave = false
    @State private var timing: MobileScheduleTimingDraft

    init(model: MobileSchedulesModel, record: MobileScheduleRecord) {
        self.model = model
        self.record = record
        _title = State(initialValue: record.title)
        _prompt = State(initialValue: record.prompt)
        _timing = State(initialValue: MobileScheduleTimingDraft(record: record))
    }

    var body: some View {
        Form {
            Section("Reminder") {
                TextField("Title", text: $title).accessibilityIdentifier("schedule-title")
                TextEditor(text: $prompt).frame(minHeight: 110).accessibilityLabel("Reminder instruction").accessibilityIdentifier("schedule-prompt")
            }
            Section {
                Toggle("Change timing", isOn: $changeTiming).accessibilityIdentifier("schedule-change-timing")
            } footer: {
                Text("Off preserves the exact committed target, including delayed one-shot records. Turning this on can replace any timing kind. There is no 'after' update type; choose a one-time date instead.")
            }
            if changeTiming {
                Section("Timing") {
                    Picker("Rule", selection: $timing.kind) {
                        Text("One time").tag("at")
                        Text("Fixed interval").tag("every")
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Cron").tag("cron")
                    }.accessibilityIdentifier("schedule-timing-kind")
                    if timing.kind != "every" {
                        Picker("Time zone", selection: $timing.timeZone) {
                            ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC", timing.timeZone])).sorted(), id: \.self) { zone in Text(zone).tag(zone) }
                        }.pickerStyle(.navigationLink).accessibilityIdentifier("schedule-timezone")
                    }
                    if timing.kind == "at" {
                        DatePicker("Date and time", selection: $timing.date, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, TimeZone(identifier: timing.timeZone) ?? .gmt)
                            .accessibilityIdentifier("schedule-date")
                    }
                    if timing.kind == "every" {
                        TextField("Interval in seconds (minimum 60)", text: $timing.everySeconds).keyboardType(.numberPad)
                            .accessibilityIdentifier("schedule-interval")
                    }
                    if timing.kind == "daily" || timing.kind == "weekly" {
                        DatePicker("Local time", selection: $timing.clock, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TimeZone(identifier: timing.timeZone) ?? .gmt)
                            .accessibilityIdentifier("schedule-time")
                    }
                    if timing.kind == "weekly" {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][day - 1], isOn: Binding(
                                get: { timing.weekdays.contains(day) },
                                set: { checked in if checked { timing.weekdays.insert(day) } else { timing.weekdays.remove(day) } }
                            )).accessibilityIdentifier("schedule-weekday-\(day)")
                        }
                    }
                    if timing.kind == "cron" {
                        TextField("minute hour day month weekday", text: $timing.expression).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("schedule-cron")
                        Text("Five-field Vixie cron. The Host validates the expression and frequency.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.error {
                Section("Not saved") {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("schedule-save-error")
                    Text("For a conflict, close this draft, refresh schedules and reopen the editor. No automatic overwrite or retry with a newer expected record is performed.").font(.footnote)
                }
            }
        }
        .disabled(model.mutating)
        .navigationTitle("Edit schedule")
        .interactiveDismissDisabled(model.mutating)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.mutating) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { confirmingSave = true }
                    .disabled(model.mutating).accessibilityIdentifier("schedule-save")
            }
        }
        .confirmationDialog("Change reminder automation?", isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("Confirm schedule change") {
                Task { if await model.update(record, title: title, prompt: prompt, timing: changeTiming ? timing : nil) { dismiss() } }
            }.disabled(model.mutating).accessibilityIdentifier("schedule-save-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(changeTiming
                 ? "This updates the active reminder’s title and instruction and replaces its timing rule. Future automatic deliveries to the original thread may occur at different times. Saved deliveries and already queued messages are unchanged. Confirm only after reviewing the fields above."
                 : "This updates the active reminder’s title and instruction used for future automatic deliveries to the original thread. The committed timing, saved deliveries and already queued messages are unchanged. Confirm only after reviewing the fields above.")
        }
    }
}

private struct MobileScheduleHistory: View {
    @Bindable var model: MobileSchedulesModel
    let record: MobileScheduleRecord
    var body: some View {
        List {
            if let note = model.historyNote { Section { Text(note).font(.footnote) } }
            if let error = model.historyError {
                Section("History unavailable") {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("schedule-history-error")
                    Button("Reload history") { Task { await model.history(record) } }.accessibilityIdentifier("schedule-history-retry")
                }
            }
            Section("Saved deliveries") {
                if model.historyLoading { ProgressView("Loading history") }
                if model.deliveries.isEmpty, !model.historyLoading, model.historyError == nil { Text("No saved deliveries.").foregroundStyle(.secondary) }
                ForEach(model.deliveries) { delivery in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(delivery.raw["prompt"].string ?? "Instruction unavailable for this legacy receipt.")
                        Text("Scheduled (UTC): \(delivery.raw["scheduledAt"].string ?? "")")
                        Text("Delivered (UTC): \(delivery.raw["deliveredAt"].string ?? "")")
                        Text("Message: \(delivery.id)").textSelection(.enabled)
                    }.font(.footnote).accessibilityIdentifier("schedule-delivery-\(delivery.id)")
                }
                if model.nextBefore != nil {
                    Button("Load older deliveries") { Task { await model.history(record, more: true) } }
                        .disabled(model.historyLoading).accessibilityIdentifier("schedule-history-more")
                }
            }
        }
        .navigationTitle("Delivery history")
        .accessibilityIdentifier("schedule-history-screen")
        .task { await model.history(record) }
        .refreshable { await model.history(record) }
    }
}
