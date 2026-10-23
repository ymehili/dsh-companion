import SwiftUI
import VisionKit
import AVFoundation

@main @MainActor
struct DSHApp: App {
    @State private var store = NativeStore()
    @AppStorage("dsh.mobile.appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            DSHShell().environment(store)
                .preferredColorScheme(fixtureScheme)
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await store.setForeground(false) } }
                    if phase == .active { Task { await store.setForeground(true) } }
                }
        }
    }
    private var fixtureScheme: ColorScheme? {
        #if DEBUG
        if store.usesFixture { return ProcessInfo.processInfo.arguments.contains("-native-dark-fixture") ? .dark : .light }
        #endif
        return appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
    }
}

struct NativePairing: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false
    @State private var scanError: String?
    @State private var pendingLink: String?
    @State private var confirm = false
    var body: some View {
        Form {
            Section {
                DSHBrandWordmark().frame(width: 190, height: 25).padding(.vertical, 12)
                Text("Your sessions and tools stay on your Mac. Pair using the same DSH Mobile connection.").foregroundStyle(.secondary)
            }
            Section {
                Label("Open DSH Mobile on your Mac", systemImage: "1.circle")
                Label("Create a fresh pairing QR", systemImage: "2.circle")
                Button("Scan pairing QR", systemImage: "qrcode.viewfinder", action: scan).disabled(store.busy)
                PasteButton(payloadType: String.self) { values in if let text = values.first { accept(text, fromScanner: false) } }.accessibilityLabel("Paste pairing link").disabled(store.busy)
                if store.busy { ProgressView("Authorizing…") }
                if let message = scanError ?? store.pairingError { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).accessibilityIdentifier("pairingError") }
            } header: { Text("Pair this iPhone") } footer: { Text("Only authorize a QR you generated yourself. Invitation links expire after ten minutes and work once.") }
            Section {
                Label("Device login is kept in Keychain. Model credentials stay on your Mac.", systemImage: "lock.shield")
            } footer: { Text("Connects only to dsh.ymehili.com. You can revoke this device in the Mac’s DSH Mobile manager.") }
        }
        .fullScreenCover(isPresented: $showScanner, onDismiss: {
            // Present the next native dialog only after the camera actually dismisses.
            if pendingLink != nil { confirm = true }
        }) {
            NavigationStack {
                QRScanner(onScan: { accept($0, fromScanner: true) }, onError: { message in scanError = message; pendingLink = nil; showScanner = false })
                    .navigationTitle("Scan pairing QR").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { pendingLink = nil; showScanner = false } }
            }
        }
        .alert("Authorize this iPhone?", isPresented: $confirm) {
            Button("Authorize") {
                let link = pendingLink; pendingLink = nil
                if let link { Task { if await store.pair(link) { dismiss() } } }
            }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        } message: { Text("This device will be able to control DSH on your Mac. Only continue if you created this invitation.") }
    }
    private func accept(_ text: String, fromScanner: Bool) {
        store.pairingError = nil
        guard HostAddress.pairingURL(text) != nil else { pendingLink = nil; scanError = "This isn’t a valid DSH Mobile invitation. Create a fresh QR on your Mac."; showScanner = false; return }
        scanError = nil; pendingLink = text
        if fromScanner { showScanner = false } else { confirm = true }
    }
    private func scan() {
        Task { @MainActor in
            store.pairingError = nil
            guard DataScannerViewController.isSupported else { scanError = "Camera scanning is unavailable here. Paste the pairing link instead."; return }
            guard await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable else { scanError = "Allow Camera in Settings, or paste the pairing link."; return }
            scanError = nil; pendingLink = nil; showScanner = true
        }
    }
}

struct NativeApprovals: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: ApprovalCard?
    var body: some View {
        NavigationStack {
            List {
                if !store.connected { Label("Reconnect to answer approvals", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                if store.approvals.isEmpty { ContentUnavailableView("No pending approvals", systemImage: "checkmark.shield") }
                ForEach(store.approvals) { card in
                    Section {
                        Label(card.tool, systemImage: "hand.raised").font(.headline)
                        Text(store.sessions.first(where: { $0.id == card.sessionId })?.title ?? "Session \(card.sessionId)").font(.caption).foregroundStyle(.secondary)
                        Text(card.reason).textSelection(.enabled)
                        HStack {
                            Button("Deny", role: .destructive) { Task { await store.decide(card, allow: false) } }.buttonStyle(.bordered)
                            Spacer()
                            Button("Allow once") { confirming = card }.buttonStyle(.borderedProminent)
                        }.disabled(!store.connected || store.deciding.contains(card.id))
                    }
                }
            }
            .navigationTitle("Approvals").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .alert("Allow this action on your Mac?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                Button("Allow once") { if let card = confirming { Task { await store.decide(card, allow: true) } }; confirming = nil }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: { Text(confirming?.tool ?? "") }
            .onChange(of: store.approvals.map(\.id)) { _, ids in if let card = confirming, !ids.contains(card.id) { confirming = nil } }
        }
    }
}
