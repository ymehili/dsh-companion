import SwiftUI

/// Provider metadata only. Credential values and references belong to the schema-driven settings form.
struct MobileProviderMetadata: Identifiable, Decodable {
    struct NativeAuth: Decodable {
        let env: [String]
        let oauth: Bool
    }
    var id: String { provider }
    let provider: String
    let displayName: String
    let settingsNs: String
    let settingsPath: [String]
    let declared: Bool?
    let defaultBaseURL: String?
    let baseURLEnv: [String]?
    let nativeAuth: NativeAuth?
    let error: String?
}

struct MobileProviderModel: Identifiable, Decodable {
    let id: String
    let name: String?
    let contextWindow: Double?
    let maxTokens: Double?
    let inputModalities: [String]?
}

/// Deliberately excludes authorizeUrl: the current Host callback is not an iPhone callback contract.
struct MobileProviderAccountState: Decodable {
    struct Attempt: Decodable {
        let id: String
        let phase: String
        let expiresAt: Double?
        let errorCode: String?
    }
    let status: String
    let attempt: Attempt?
}

@MainActor
@Observable
final class MobileProvidersController {
    private(set) var providers: [MobileProviderMetadata] = []
    private(set) var loading = false
    private(set) var listError: String?
    private(set) var account: MobileProviderAccountState?
    private(set) var accountError: String?
    private(set) var watchStatus = "Not connected"
    private(set) var discovering: Set<String> = []
    private(set) var models: [String: [MobileProviderModel]] = [:]
    private(set) var discoveryErrors: [String: String] = [:]
    private var rpc: (any MobileSettingsRPC)?
    private var watchID: String?
    private var generation = UUID()

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    func load(store: NativeStore) async {
        guard !loading else { return }
        // This branch must precede construction/use of a live gateway adapter.
        let service: any MobileSettingsRPC
        if store.usesFixture { service = MobileSettingsFixtureRPC() }
        else { service = MobileSettingsNativeRPC(store: store) }
        await load(rpc: service)
        guard !Task.isCancelled else { return }
        if store.usesFixture {
            watchStatus = "Fixture snapshot · no live account subscription"
            return
        }
        await startWatching(store: store)
    }

    /// Injectable snapshot loader: exactly metadata + safe account projection, no stream,
    /// discovery, credential access, profile/balance request, sign-in or settings mutation.
    func load(rpc service: any MobileSettingsRPC) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        rpc = service
        listError = nil
        do {
            let value = try await service.call("llm/listConfigurableProviders", [:])
            try Task.checkCancellation()
            let entries = try decode([MobileProviderMetadata].self, value)
            var seen: Set<String> = []
            providers = entries.filter { seen.insert($0.id).inserted }
        } catch is CancellationError { return }
        catch { listError = "Provider metadata could not be loaded. Retry when your Mac is connected." }
        await refreshAccount()
    }

    func refreshAccount() async {
        guard let rpc else { return }
        accountError = nil
        do {
            let value = try await rpc.call("account/getState", [:])
            try Task.checkCancellation()
            account = try decode(MobileProviderAccountState.self, value)
        } catch is CancellationError { return }
        catch { accountError = "DeepSeek account state is unavailable. No account status has been inferred." }
    }

    private func startWatching(store: NativeStore) async {
        await stopWatching(store: store)
        let token = UUID()
        generation = token
        watchStatus = "Connecting to account updates…"
        do {
            let id = try await store.openAuxiliaryStream("account/watch", args: .obj([:]), onEvent: { [weak self] value in
                guard let self, self.generation == token else { return }
                do {
                    self.account = try self.decode(MobileProviderAccountState.self, value)
                    self.accountError = nil
                    self.watchStatus = "Live account updates"
                } catch {
                    self.watchStatus = "Account update could not be decoded"
                }
            }, onClose: { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.watchID = nil
                self.watchStatus = "Account updates disconnected · refresh to reconnect"
            })
            guard generation == token, !Task.isCancelled else {
                await store.closeAuxiliaryStream(id)
                return
            }
            watchID = id
        } catch {
            watchStatus = "Live account updates unavailable · refresh for current state"
        }
    }

    func stopWatching(store: NativeStore) async {
        generation = UUID()
        if let id = watchID {
            watchID = nil
            await store.closeAuxiliaryStream(id)
        }
    }

    /// Call only from the explicit confirmation action, never from load/task/navigation.
    func discover(_ provider: MobileProviderMetadata) async {
        guard let rpc, !discovering.contains(provider.id) else { return }
        discovering.insert(provider.id)
        discoveryErrors[provider.id] = nil
        defer { discovering.remove(provider.id) }
        do {
            let value = try await rpc.call("llm/discoverModels", [
                "settingsNs": .text(provider.settingsNs),
                "request": .obj(["provider": .text(provider.provider)])
            ])
            try Task.checkCancellation()
            models[provider.id] = try decode([MobileProviderModel].self, value)
        } catch is CancellationError { return }
        catch {
            // Do not display raw transport failures: they may contain endpoint credentials.
            discoveryErrors[provider.id] = "Discovery failed. Check this provider’s server settings, then explicitly try again."
        }
    }
}

struct MobileProvidersScreen: View {
    @Environment(NativeStore.self) private var store
    @State private var controller = MobileProvidersController()

    var body: some View {
        MobilePage {
            MobileSection(title: "DeepSeek account", footer: "Account status is separate from provider environment variables and API keys. No profile or balance requests are made.") {
                MobileRow(title: accountTitle, symbol: "person.crop.circle", subtitle: controller.watchStatus, disclosure: false)
                    .accessibilityIdentifier("providers-account-state")
                if let attempt = controller.account?.attempt {
                    MobileRow(title: "Sign-in attempt", symbol: "clock", detail: attempt.phase, disclosure: false)
                        .accessibilityIdentifier("providers-account-attempt")
                    if let code = attempt.errorCode {
                        Text("Sign-in error: \(code)").font(.footnote).padding(14)
                            .accessibilityIdentifier("providers-account-attempt-error")
                    }
                }
                if let error = controller.accountError { notice(error, id: "providers-account-error") }
                MobileRow(title: "Sign in on your Mac", symbol: "desktopcomputer", subtitle: "The Host requires a loopback HTTP callback. Native iPhone sign-in is not supported by this callback contract.", disclosure: false)
                    .accessibilityIdentifier("providers-account-signin-capability")
            }
            MobileSection(title: "Providers", footer: "Configuration and credentials are managed through server settings. Environment variable names below describe Host capabilities, not whether a secret is configured.") {
                if controller.loading { ProgressView("Loading providers…").padding(14).accessibilityIdentifier("providers-loading") }
                if let error = controller.listError { notice(error, id: "providers-error") }
                if !controller.loading && controller.listError == nil && controller.providers.isEmpty {
                    notice("The Host reported no configurable providers.", id: "providers-empty")
                }
                ForEach(controller.providers) { provider in
                    NavigationLink {
                        MobileProviderDetailScreen(provider: provider, controller: controller)
                    } label: {
                        MobileRow(title: provider.displayName, symbol: "cpu", subtitle: provider.provider)
                    }.accessibilityIdentifier("provider-\(provider.id)")
                }
            }
            Button {
                Task { await controller.load(store: store) }
            } label: {
                MobileRow(title: "Refresh providers and account", symbol: "arrow.clockwise", disclosure: false)
            }.buttonStyle(.plain).disabled(controller.loading).accessibilityIdentifier("providers-refresh")
        }
        .navigationTitle("Providers").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobile-providers")
        .task(id: store.connected) { await controller.load(store: store) }
        .onDisappear { Task { await controller.stopWatching(store: store) } }
    }

    private var accountTitle: String {
        switch controller.account?.status {
        case "credential-stored": "DeepSeek credential stored on Mac"
        case "signed-out": "DeepSeek signed out"
        case .some: "Unknown account state"
        case nil: "Account state not loaded"
        }
    }

    private func notice(_ message: String, id: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(DSHTheme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).accessibilityIdentifier(id)
    }
}

private struct MobileProviderDetailScreen: View {
    let provider: MobileProviderMetadata
    @Bindable var controller: MobileProvidersController
    @State private var confirmDiscovery = false

    var body: some View {
        MobilePage {
            MobileSection(title: "Configuration") {
                MobileRow(title: "Provider route", symbol: "cpu", subtitle: provider.provider, disclosure: false)
                MobileRow(title: "Settings namespace", symbol: "gearshape", subtitle: provider.settingsNs, disclosure: false)
                MobileRow(title: "Profile path", symbol: "point.topleft.down.to.point.bottomright.curvepath", subtitle: provider.settingsPath.isEmpty ? "Namespace root" : provider.settingsPath.joined(separator: " → "), disclosure: false)
                if let declared = provider.declared {
                    MobileRow(title: "Route origin", symbol: "info.circle", subtitle: declared ? "Declared in configuration" : "Known to adapter", disclosure: false)
                }
                if provider.error != nil {
                    Text("The Host reported a configuration diagnostic. Review this namespace in server settings.")
                        .font(.footnote).padding(14).accessibilityIdentifier("provider-diagnostic")
                }
                NavigationLink { MobileServerSettingsScreen(namespace: provider.settingsNs) } label: {
                    MobileRow(title: "Server settings and credentials", symbol: "slider.horizontal.3")
                }.accessibilityIdentifier("provider-settings")
            }
            MobileSection(title: "Native authentication", footer: "These are adapter-reported capabilities, not credential checks. OAuth support does not imply a phone-compatible sign-in flow.") {
                if let auth = provider.nativeAuth {
                    MobileRow(title: "Authentication environment", symbol: "terminal", subtitle: auth.env.isEmpty ? "No authentication variables reported" : auth.env.joined(separator: ", "), disclosure: false)
                        .accessibilityIdentifier("provider-auth-env")
                    MobileRow(title: "Stored OAuth grant", symbol: "person.badge.key", subtitle: auth.oauth ? "Supported by adapter" : "Not supported by adapter", disclosure: false)
                        .accessibilityIdentifier("provider-auth-oauth")
                } else {
                    Text("The adapter did not report native authentication capabilities.").font(.footnote).padding(14)
                }
                if let env = provider.baseURLEnv, !env.isEmpty {
                    MobileRow(title: "Endpoint environment", symbol: "network", subtitle: env.joined(separator: ", "), disclosure: false)
                }
            }
            MobileSection(title: "Model discovery", footer: "Never runs automatically. The Host may contact the configured provider endpoint. This does not select a model or save configuration.") {
                Button { confirmDiscovery = true } label: {
                    MobileRow(title: controller.discovering.contains(provider.id) ? "Discovering…" : "Discover models…", symbol: "magnifyingglass", disclosure: false)
                }.buttonStyle(.plain).disabled(controller.discovering.contains(provider.id))
                    .accessibilityIdentifier("provider-discover")
                if let error = controller.discoveryErrors[provider.id] {
                    Text(error).font(.footnote).padding(14).accessibilityIdentifier("provider-discovery-error")
                }
                if let models = controller.models[provider.id] {
                    if models.isEmpty { Text("No models were returned.").font(.footnote).padding(14).accessibilityIdentifier("provider-models-empty") }
                    ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                        MobileRow(title: model.name ?? model.id, symbol: "cpu", subtitle: model.id, disclosure: false)
                            .accessibilityIdentifier("provider-model-\(model.id)")
                    }
                }
            }
        }
        .navigationTitle(provider.displayName).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("provider-detail")
        .confirmationDialog("Discover models from this provider?", isPresented: $confirmDiscovery, titleVisibility: .visible) {
            Button("Discover models") { Task { await controller.discover(provider) } }
                .accessibilityIdentifier("provider-discover-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This explicitly authorizes a model-discovery request for \(provider.provider) using its Mac configuration. It may contact the provider endpoint.")
        }
    }
}
