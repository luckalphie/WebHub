import Foundation

enum SafariUserAgent {
    static let value: String = {
        let safariBundle = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))
        // Safari 不可读取时使用部署下限 macOS 14 自带的 Safari 17。
        let version = safariBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "17.0"
        // macOS Safari 的系统版本和架构标识固定，Apple Silicon 也沿用此格式。
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()
}
