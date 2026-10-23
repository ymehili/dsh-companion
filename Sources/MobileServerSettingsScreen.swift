import SwiftUI

struct MobileServerSettingsScreen: View {
    @Environment(NativeStore.self) private var store
    var namespace: String? = nil
    @State private var rpc: (any MobileSettingsRPC)?
    @State private var namespaces: [MobileSettingsNamespace] = []
    @State private var writable = false
    @State private var issue: String?
    @State private var loading = false
    init(namespace: String? = nil, rpc: (any MobileSettingsRPC)? = nil) {
        self.namespace = namespace
        _rpc = State(initialValue: rpc)
    }
    var body: some View {
        MobilePage {
            if store.usesFixture { Text("DEMO · synthetic settings · no host access").font(.caption).foregroundStyle(DSHTheme.secondary) }
            if loading { ProgressView("Reading settings schema") }
            if let issue { MobileSection(title: "Settings unavailable") { Text(issue).padding(); Button("Retry") { Task { await load() } }.padding() } }
            ForEach(namespaces) { ns in
                MobileSection(title: ns.id, footer: "Live · revision \(ns.revision)\(writable ? "" : " · read only")") {
                    ForEach(ns.fields) { field in
                        if field.secret {
                            MobileRow(title: field.title, symbol: "lock", subtitle: "Declared secret · redacted by host. Direct secret slots require a credential reference.", disclosure: false)
                        } else if field.credentialReference, let ref = ns.value(at: field.path).string, MobileCredentialEditor.validReference(ref), let rpc {
                            NavigationLink { MobileCredentialEditor(reference: ref, rpc: rpc) } label: { MobileRow(title: "Credential for \(field.title)", symbol: "key", detail: ref) }
                                .disabled(!writable).accessibilityIdentifier("server-settings-credential-\(ns.id)-\(field.id)")
                            NavigationLink { MobileSettingsFieldEditor(namespace: ns, field: field, writable: writable, rpc: rpc) { Task { await load() } } } label: {
                                MobileRow(title: "Credential reference", symbol: "pencil", detail: ref)
                            }.accessibilityIdentifier("server-settings-field-\(ns.id)-\(field.id)")
                        } else if let rpc {
                            NavigationLink { MobileSettingsFieldEditor(namespace: ns, field: field, writable: writable, rpc: rpc) { Task { await load() } } } label: {
                                MobileRow(title: field.path.joined(separator: " › "), symbol: "slider.horizontal.3", detail: display(ns.value(at: field.path)))
                            }.accessibilityIdentifier("server-settings-field-\(ns.id)-\(field.id)")
                        }
                    }
                }
            }
            if !loading && namespaces.isEmpty && issue == nil { Text("No settings namespaces are exposed by this host.").foregroundStyle(DSHTheme.secondary) }
        }.navigationTitle("Server settings").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("server-settings-screen").task { if rpc == nil { if store.usesFixture { rpc = MobileSettingsFixtureRPC() } else { rpc = MobileSettingsNativeRPC(store: store) } }; await load() }
            .refreshable { await load() }
    }
    private func display(_ value: JSONValue) -> String { value.string ?? value.bool.map { $0 ? "On" : "Off" } ?? value.number.map { String($0) } ?? "Not set" }
    private func load() async {
        guard let rpc, !loading else { return }; loading = true; defer { loading = false }
        do {
            let value = try await rpc.call("settings/describe", [:])
            guard let canWrite = value["writable"].bool, case .array = value["namespaces"] else { throw MobileSettingsFailure.invalid("Invalid settings description.") }
            writable = canWrite
            namespaces = try value["namespaces"].array.filter { namespace == nil || $0["ns"].string == namespace }.map(MobileSettingsNamespace.init)
            issue = nil
        } catch { writable = false; issue = "Could not read settings. Try reconnecting or reloading." }
    }
}

private struct MobileSettingsFieldEditor: View {
    let namespace: MobileSettingsNamespace
    let field: MobileSettingsField
    let writable: Bool
    let rpc: any MobileSettingsRPC
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var flag = false
    @State private var selected = 0
    @State private var confirm = false
    @State private var reset = false
    @State private var busy = false
    @State private var stale = false
    @State private var issue: String?
    var body: some View {
        Form {
            Section(field.path.joined(separator: " › ")) {
                switch field.kind {
                case .boolean: Toggle(field.title, isOn: $flag)
                case .number: TextField("Number", text: $text).keyboardType(.numbersAndPunctuation)
                case .string: TextField(field.title, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                case .enumeration(let options): Picker(field.title, selection: $selected) { ForEach(options.indices, id: \.self) { index in Text(options[index].string ?? options[index].number.map { String($0) } ?? "Option \(index + 1)").tag(index) } }
                case .unsupported: Text("This schema type is not safely editable yet. Existing values are preserved.")
                }
            }.disabled(!writable || stale || busy)
            if let description = field.schema["meta"]["description"].string { Section { Text(description) } }
            Section {
                Text("Changes apply live to the host. Automation, provider defaults, and permissions may be affected. Nothing is written until you confirm.")
                Button("Review change") { reset = false; confirm = true }.disabled(!canSave)
                    .accessibilityIdentifier("server-settings-review")
                Button("Use inherited default") { reset = true; confirm = true }.disabled(!canSave)
            }
            if let issue { Section("Could not save") { Text(issue) } }
            if stale { Section { Button("Close and reload settings") { didSave(); dismiss() } } }
        }.navigationTitle(field.title).navigationBarTitleDisplayMode(.inline)
            .task { let v = namespace.value(at: field.path); text = v.string ?? v.number.map { String($0) } ?? ""; flag = v.bool ?? false; if case .enumeration(let options) = field.kind { selected = options.firstIndex(of: v) ?? 0 } }
            .confirmationDialog("Apply live host settings change?", isPresented: $confirm, titleVisibility: .visible) {
                Button(reset ? "Confirm inherited default" : "Confirm change", role: .destructive) { Task { await save() } }
            } message: { Text("Revision \(namespace.revision) will be checked. Review automation, provider-default and permission effects before continuing.") }
    }
    private var canSave: Bool { writable && !busy && !stale && field.kind != .unsupported }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            let value: JSONValue
            if reset { value = .null } else {
            switch field.kind {
            case .boolean: value = .bool(flag)
            case .number: guard let number = Double(text), number.isFinite else { throw MobileSettingsFailure.invalid("Enter a finite number.") }; value = .number(number)
            case .string: value = .text(text)
            case .enumeration(let options): guard options.indices.contains(selected) else { return }; value = options[selected]
            case .unsupported: return
            }
            }
            let args = try namespace.mutation(field: field, value: reset ? nil : value, confirmed: true)
            guard writable, !stale else { return }
            _ = try await rpc.call("settings/mutate", args); didSave(); dismiss()
        } catch {
            // Host error strings may contain configuration input. Never echo them.
            stale = (error as? NativeRPCError)?.code == "settings/conflict" || error as? MobileSettingsFailure == .conflict
            issue = stale ? "Settings changed elsewhere. Reload before trying again." : "Change refused. Check the value and permissions, then retry. No automatic retry was made."
        }
    }
}

struct MobileCredentialEditor: View {
    let reference: String
    let rpc: any MobileSettingsRPC
    @State private var secret = ""
    @State private var configured = false
    @State private var writable = false
    @State private var issue: String?
    @State private var confirm = false
    @State private var removing = false
    @State private var busy = false
    static func validReference(_ ref: String) -> Bool { ref.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
    var body: some View {
        Form {
            Section(reference) {
                LabeledContent("Status", value: configured ? "Configured" : "Not configured")
                SecureField("New credential (write only)", text: $secret).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("settings-credential-secret")
                Button("Replace credential") { removing = false; confirm = true }.disabled(secret.isEmpty || !writable || busy).accessibilityIdentifier("settings-credential-set")
                Button("Remove credential", role: .destructive) { removing = true; confirm = true }.disabled(!configured || !writable || busy).accessibilityIdentifier("settings-credential-unset")
            }
            Section { Text("The existing credential is never read. This reference may be shared by providers; changing it can affect authentication immediately.") }
            if let issue { Section { Text(issue) } }
        }.navigationTitle("Credential").task { await describe() }.onDisappear { secret = "" }
            .confirmationDialog("Change shared host credential?", isPresented: $confirm, titleVisibility: .visible) {
                Button(removing ? "Confirm removal" : "Confirm replacement", role: .destructive) { Task { await write() } }
            }
    }
    private func describe() async {
        guard Self.validReference(reference) else { issue = "Invalid credential reference."; return }
        do { let value = try await rpc.call("credentials/describe", ["refs": .array([.text(reference)])]); configured = value[reference]["configured"].bool ?? false; writable = value[reference]["writable"].bool ?? false; issue = nil }
        catch { issue = "Credential status unavailable. No secret was read."; writable = false }
    }
    private func write() async {
        guard writable, Self.validReference(reference), removing || !secret.isEmpty else { return }
        busy = true; defer { busy = false; secret = "" }
        do {
            var args: [String: JSONValue] = ["ref": .text(reference)]
            if !removing { args["value"] = .text(secret) }
            _ = try await rpc.call(removing ? "credentials/unset" : "credentials/set", args)
            secret = ""; await describe()
        } catch { issue = "Credential change refused. No automatic retry was made." }
    }
}
