import SwiftUI

struct MobileSettings: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dsh.mobile.appearance") private var appearance = "system"
    @State private var fixtureAppearance = "system"
    @State private var fixtureFollowUpMode = "steer"
    private var currentAppearance: String { store.usesFixture ? fixtureAppearance : appearance }
    private var currentFollowUpMode: String { store.usesFixture ? fixtureFollowUpMode : store.followUpMode }
    @State private var showQuestions = false
    @State private var showApprovals = false
    @State private var showDetails = false
    var body: some View {
        NavigationStack {
            MobilePage {
                MobileSection(title: "Connections") {
                    NavigationLink { MobileMacConnection() } label: {
                        MobileRow(title: "Your Mac", symbol: "desktopcomputer", subtitle: store.status)
                    }.accessibilityIdentifier("settings-connection")
                    Button { showQuestions = true } label: {
                        MobileRow(title: "Questions", symbol: "questionmark.bubble", detail: "\(store.questions.count)")
                    }.accessibilityIdentifier("settings-questions")
                    Button { showApprovals = true } label: {
                        MobileRow(title: "Approvals", symbol: "hand.raised", detail: "\(store.approvals.count)")
                    }.accessibilityIdentifier("settings-approvals")
                }
                MobileSection(title: "Interface") {
                    NavigationLink {
                        MobilePage {
                            MobileSection(title: "Appearance", footer: "Applies to this iPhone. Your Mac’s appearance is unchanged.") {
                                ForEach([("system", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { mode in
                                    Button { if store.usesFixture { fixtureAppearance = mode.0 } else { appearance = mode.0 } } label: {
                                        HStack {
                                            MobileRow(title: mode.1, symbol: mode.0 == "system" ? "circle.lefthalf.filled" : (mode.0 == "light" ? "sun.max" : "moon"), disclosure: false)
                                            if currentAppearance == mode.0 { Image(systemName: "checkmark").padding(.trailing, 18) }
                                        }
                                    }.buttonStyle(.plain).accessibilityIdentifier("appearance-\(mode.0)")
                                        .accessibilityAddTraits(currentAppearance == mode.0 ? .isSelected : [])
                                }
                            }
                        }.navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        MobileRow(title: "Appearance", symbol: "paintpalette", detail: currentAppearance.capitalized)
                    }.accessibilityIdentifier("settings-appearance")
                }
                MobileSection(title: "Threads") {
                    NavigationLink {
                        MobilePage {
                            MobileSection(title: "While the agent is working", footer: "Steer changes direction at the next step boundary and is the default. Queue waits for another turn. Long-press Send to choose for one message. Retrying keeps the original choice.") {
                                ForEach([("steer", "Steer now", "arrow.turn.left.up"), ("queue", "Queue", "list.number")], id: \.0) { option in
                                    Button { if store.usesFixture { fixtureFollowUpMode = option.0 } else { store.setFollowUpMode(option.0) } } label: {
                                        HStack {
                                            MobileRow(title: option.1, symbol: option.2, disclosure: false)
                                            if currentFollowUpMode == option.0 { Image(systemName: "checkmark").padding(.trailing, 18) }
                                        }
                                    }.buttonStyle(.plain).accessibilityIdentifier("followup-\(option.0)")
                                        .accessibilityAddTraits(currentFollowUpMode == option.0 ? .isSelected : [])
                                }
                            }
                        }.navigationTitle("Follow-ups").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        MobileRow(title: "Follow-ups", symbol: "arrow.turn.left.up", detail: currentFollowUpMode == "steer" ? "Steer" : "Queue")
                    }.accessibilityIdentifier("settings-followups")
                    if store.selected != nil {
                        NavigationLink { DSHModelList() } label: {
                            MobileRow(title: "Model", symbol: "cpu", subtitle: "Selected thread")
                        }
                        Button { showDetails = true } label: {
                            MobileRow(title: "Thread details", symbol: "info.circle")
                        }
                    }
                }
                MobileSection(title: "Projects") {
                    NavigationLink { MobileProjects() } label: { MobileRow(title: "Manage projects", symbol: "folder", subtitle: "Mac directories and project order") }
                        .accessibilityIdentifier("settings-projects")
                }
                MobileSection(title: "App") {
                    NavigationLink { MobileAbout() } label: { MobileRow(title: "About", symbol: "info.circle") }
                        .accessibilityIdentifier("settings-about")
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close settings", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("close-settings") } }
        }.tint(DSHTheme.accent).accessibilityIdentifier("mobile-settings")
            .sheet(isPresented: $showQuestions) { NativeQuestionsSheet() }
            .sheet(isPresented: $showApprovals) { NativeApprovals() }
            .sheet(isPresented: $showDetails) { DSHConversationInfo() }
    }
}

struct MobileMacConnection: View {
    @Environment(NativeStore.self) private var store
    var body: some View {
        MobilePage {
            MobileSection(title: "Connection") {
                MobileRow(title: "Your Mac", symbol: "desktopcomputer", subtitle: store.status, disclosure: false)
                MobileRow(title: "Address", symbol: "network", detail: "dsh.ymehili.com", disclosure: false)
                Button { Task { guard !store.usesFixture else { return }; await store.connect(force: true) } } label: {
                    MobileRow(title: "Reconnect", symbol: "arrow.clockwise", disclosure: false)
                }.buttonStyle(.plain).disabled(store.usesFixture || !store.paired || store.connecting)
                    .accessibilityIdentifier("settings-reconnect")
                NavigationLink { NativePairing().navigationTitle("Pair iPhone").navigationBarTitleDisplayMode(.inline) } label: {
                    MobileRow(title: store.paired ? "Pair again" : "Pair this iPhone", symbol: "qrcode.viewfinder")
                }.disabled(store.usesFixture).accessibilityIdentifier("settings-pair")
            }
            MobileSection(title: "Security", footer: "Only use an invitation you generated yourself. Device login is stored in Keychain. Revoke devices in your Mac’s DSH Mobile manager.") {
                MobileRow(title: "Credentials stay on your Mac", symbol: "lock.shield", subtitle: "Device login is scoped to this iPhone. Your Mac keeps its model credentials.", disclosure: false)
            }
        }.navigationTitle("Your Mac").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileAbout: View {
    var body: some View {
        MobilePage {
            DSHBrandWordmark().frame(width: 182, height: 24).padding(.vertical, 24).frame(maxWidth: .infinity)
            MobileSection {
                MobileRow(title: "DeepSeek Harness", symbol: "app", detail: version, disclosure: false)
                MobileRow(title: "Native iPhone client", symbol: "iphone", subtitle: "Controls your Mac’s existing DSH sessions.", disclosure: false)
            }
            MobileSection(title: "Open source") {
                NavigationLink {
                    ScrollView {
                        Text(Self.bundledNotices).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.navigationTitle("Third-party licenses").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("settings-third-party-notices")
                } label: {
                    MobileRow(title: "Third-party licenses", symbol: "doc.text", subtitle: "T3 Code and SwiftTerm · full bundled notices")
                }.accessibilityIdentifier("settings-licenses")
            }
            Text("DSH branding and backend are independent of T3 Tools. UI adaptations retain the upstream MIT notice.").font(.footnote).foregroundStyle(DSHTheme.secondary)
        }.navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
    private static var bundledNotices: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return MobileServerSettingsNotices.fallback }
        return text
    }
    private var version: String {
        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
    }
}
