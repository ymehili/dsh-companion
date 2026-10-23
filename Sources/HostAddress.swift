import Foundation

enum HostAddress {
    static func parse(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !isLoopback(host),
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }

    static let mobileHost = URL(string: "https://dsh.ymehili.com/")!

    // Pairing keys are passed only to the existing bridge page, never saved as host preferences.
    static func pairingURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = parts.url, sameOrigin(url, mobileHost),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.path == "/__pair", let fragment = parts.fragment,
              let items = URLComponents(string: "https://fragment.invalid/?" + fragment)?.queryItems,
              items.count == 1, items[0].name == "key", let key = items[0].value,
              (20...128).contains(key.utf8.count),
              key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return name == "localhost" || name.hasSuffix(".localhost") || name == "::1" || name.hasPrefix("127.")
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() &&
        a.host?.lowercased() == b.host?.lowercased() &&
        (a.port ?? 443) == (b.port ?? 443)
    }
}
