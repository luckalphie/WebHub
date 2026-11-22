import Foundation
import Network

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

    init?(id: UUID = UUID(), name: String, kind: Kind, host: String, port: UInt16, bypassDomains: String) {
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
        return configuration
    }

}

final class NetworkProxyStore {
    static let shared = NetworkProxyStore()
    private let key = "WebHub.globalNetworkProxy"

    var profile: NetworkProxyProfile? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(NetworkProxyProfile.self, from: $0) }
    }

    func save(_ profile: NetworkProxyProfile?) throws {
        if let profile {
            UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
