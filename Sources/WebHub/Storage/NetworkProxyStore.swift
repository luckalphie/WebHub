import Foundation
import Network
import Security

struct NetworkProxyProfile: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case httpConnect, socks5
    }

    let id: UUID
    let name: String
    let kind: Kind
    let host: String
    let port: UInt16
    let bypassDomains: [String]
    let username: String?
    var password: String? = nil

    private enum CodingKeys: String, CodingKey { case id, name, kind, host, port, bypassDomains, username }

    init?(id: UUID = UUID(), name: String, kind: Kind, host: String, port: UInt16, bypassDomains: String, username: String = "", password: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let domains = bypassDomains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !name.isEmpty, port != 0, Self.isHostname(host) || IPv6Address(host) != nil,
              domains.allSatisfy(Self.isHostname) else { return nil }
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.bypassDomains = domains
        self.username = username.isEmpty ? nil : username
        self.password = password
    }

    private static func isHostname(_ value: String) -> Bool {
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return !value.isEmpty && value.unicodeScalars.allSatisfy(ascii.contains)
            && value.unicodeScalars.contains(where: { $0 != "." && $0 != "-" && $0 != "_" })
    }

    var configuration: ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        var configuration: ProxyConfiguration
        switch kind {
        case .httpConnect: configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5: configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        configuration.excludedDomains = bypassDomains
        configuration.allowFailover = false
        if let username, let password { configuration.applyCredential(username: username, password: password) }
        return configuration
    }

}

final class NetworkProxyStore {
    static let shared = NetworkProxyStore()
    private let key = "WebHub.globalNetworkProxy"
    private let credentialQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cn.webhub.proxy",
        kSecAttrAccount as String: "global"
    ]

    var profile: NetworkProxyProfile? {
        guard let data = UserDefaults.standard.data(forKey: key), var profile = try? JSONDecoder().decode(NetworkProxyProfile.self, from: data) else { return nil }
        if profile.username != nil {
            var query = credentialQuery
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                profile.password = String(data: data, encoding: .utf8)
            }
        }
        return profile
    }

    func save(_ profile: NetworkProxyProfile?) throws {
        let data = try profile.map { try JSONEncoder().encode($0) }
        let status: OSStatus
        if let password = profile?.password {
            let passwordData = Data(password.utf8)
            let update = [kSecValueData as String: passwordData]
            let updated = SecItemUpdate(credentialQuery as CFDictionary, update as CFDictionary)
            if updated == errSecItemNotFound {
                var query = credentialQuery
                query[kSecValueData as String] = passwordData
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = SecItemAdd(query as CFDictionary, nil)
            } else { status = updated }
        } else {
            let deleted = SecItemDelete(credentialQuery as CFDictionary)
            status = deleted == errSecItemNotFound ? errSecSuccess : deleted
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if profile != nil {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
