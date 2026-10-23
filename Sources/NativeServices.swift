import Foundation

@MainActor
protocol NativePairingClient: AnyObject {
    func pair(_ link: String) async throws -> String
}
extension BridgeHTTP: NativePairingClient {}

enum ConversationLoadState: Equatable {
    case idle, loading, loaded, failed(String)
    var isLoaded: Bool { self == .loaded }
}
