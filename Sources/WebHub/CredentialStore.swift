import Foundation
import Security

// MARK: - 凭据模型

struct Credential: Codable {
    var username: String
    var password: String
}

struct CredentialEntry {
    var host: String
    var credential: Credential
}

// MARK: - Keychain 凭据存储
//
// 所有站点窗口共用同一个 Keychain service，
// 因此 A 站点保存过的账号，下次在任意窗口打开同域名都会自动填充。

final class CredentialStore {
    static let shared = CredentialStore()

    private let service = "cn.webhub.credentials"
    private let queue = DispatchQueue(label: "cn.webhub.credentials.queue")

    private init() {}

    /// 保存凭据；独立登录态使用 WebApp 专属的 Keychain service。
    @discardableResult
    func save(host: String, username: String, password: String, appID: String? = nil) -> Bool {
        guard !host.isEmpty, !username.isEmpty else { return false }
        let cred = Credential(username: username, password: password)
        guard let data = try? JSONEncoder().encode(cred) else { return false }
        let credentialService = serviceName(appID: appID)

        // 先删旧的，保证唯一
        delete(host: host, appID: appID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: credentialService,
            kSecAttrAccount as String: host,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func load(host: String, appID: String? = nil) -> Credential? {
        guard !host.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(appID: appID),
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let cred = try? JSONDecoder().decode(Credential.self, from: data) else { return nil }
        return cred
    }

    func delete(host: String, appID: String? = nil) {
        guard !host.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(appID: appID),
            kSecAttrAccount as String: host
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 删除指定 WebApp 专属的全部 Keychain 凭据。
    func deleteAll(appID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(appID: appID)
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 列出所有已保存站点
    func all() -> [CredentialEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        var entries: [CredentialEntry] = []
        for item in items {
            guard let host = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let cred = try? JSONDecoder().decode(Credential.self, from: data) else { continue }
            entries.append(CredentialEntry(host: host, credential: cred))
        }
        return entries.sorted { $0.host < $1.host }
    }

    /// 站点根域（用于跨子域匹配，如 login.example.com → example.com）
    static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return host.lowercased() }
        // 粗略处理二级后缀（com.cn / co.uk 等）
        let twoLevelSuffixes: Set<String> = ["com.cn", "net.cn", "org.cn", "gov.cn",
                                             "co.uk", "org.uk", "co.jp", "com.hk"]
        if parts.count >= 3 {
            let lastTwo = "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
            if twoLevelSuffixes.contains(lastTwo) {
                return "\(parts[parts.count - 3]).\(lastTwo)"
            }
        }
        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    /// 先按完整 host 找，找不到再按根域找（支持 SSO 跨子域）
    func find(forHost host: String, appID: String? = nil) -> (host: String, credential: Credential)? {
        if let cred = load(host: host, appID: appID) {
            return (host, cred)
        }
        let root = CredentialStore.registrableDomain(host)
        if root != host, let cred = load(host: root, appID: appID) {
            return (root, cred)
        }
        return nil
    }

    private func serviceName(appID: String?) -> String {
        guard let appID = appID, !appID.isEmpty else { return service }
        return "\(service).webapp.\(appID)"
    }
}
