import Foundation
import Security

/// This device's bridge credential only; never the Mac's DSH/API credentials.
enum DeviceCredential {
    private static let service = "com.dsh.native.mobile-bridge"
    private static let account = "dsh.ymehili.com"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        guard let value = String(data: data, encoding: .utf8), valid(value) else { return nil }
        return value
    }
    private static func valid(_ value: String) -> Bool {
        (20...128).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func save(_ value: String) throws {
        guard valid(value) else { throw CredentialError.failed }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialError.failed }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CredentialError.failed }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.failed }
    }
    enum CredentialError: LocalizedError {
        case failed
        var errorDescription: String? { "Could not securely access this device’s login. Unlock your iPhone and retry." }
    }
}

final class BridgeHTTP: NSObject, URLSessionTaskDelegate {
    static let origin = "https://dsh.ymehili.com"
    static let cookieName = "__Host-dshmobile"
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Refuse redirects rather than forwarding a device cookie to another origin.
        completionHandler(nil)
    }
    func pair(_ text: String) async throws -> String {
        guard let url = HostAddress.pairingURL(text),
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              let key = URLComponents(string: "https://fragment.invalid/?" + fragment)?.queryItems?.first?.value else {
            throw BridgeError.message("Scan a fresh DSH Mobile QR generated on your Mac.")
        }
        var request = URLRequest(url: URL(string: Self.origin + "/__pair")!)
        request.httpMethod = "POST"
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["key": key, "label": "DSH native iPhone"])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BridgeError.message("Invalid bridge response.") }
        guard response.statusCode == 200 else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == "expired_invite" || code == "invalid_invite" { throw BridgeError.message("This QR expired or was already used. Create a fresh one on your Mac.") }
            throw BridgeError.message("Pairing was refused (HTTP \(response.statusCode)). Please try a fresh QR.")
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name] = value }
        }, for: url)
        guard let token = cookies.first(where: { $0.name == Self.cookieName && $0.isSecure && $0.path == "/" })?.value,
              token.utf8.count >= 20, token.utf8.count <= 128 else { throw BridgeError.message("Bridge did not return a valid device credential.") }
        try DeviceCredential.save(token)
        return token
    }
    enum BridgeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
