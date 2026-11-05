import Foundation
import WebKit

// MARK: - 共享存储
//
// 默认站点共用一个 WKWebsiteDataStore；启用独立登录态时按 WebApp ID 使用持久化仓库。

enum SharedStorage {

    private static let identifierFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("store-id.txt")
    }()

    /// 固定不变的存储标识，保证每次启动都落到同一个数据目录
    static let identifier: UUID = loadOrCreateIdentifier()

    private static func loadOrCreateIdentifier() -> UUID {
        if let text = try? String(contentsOf: identifierFile, encoding: .utf8),
           let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return uuid
        }
        // store-id.txt 不见了（2026-11-04 出现过整个 Application Support/WebHub
        // 被外部清掉的情况）。这时**不能**直接生成新 UUID —— 那等于悄悄换到一个
        // 空白数据仓库，用户会看到「所有站点都要求重新登录」。
        // 先从 WebKit 已有的数据目录反推：取 cookie 数据最多的那个。
        if let recovered = recoverIdentifierFromDisk() {
            try? recovered.uuidString.write(to: identifierFile, atomically: true, encoding: .utf8)
            return recovered
        }
        let uuid = UUID()
        try? uuid.uuidString.write(to: identifierFile, atomically: true, encoding: .utf8)
        return uuid
    }

    /// 从 `~/Library/WebKit/cn.webhub.launcher/WebsiteDataStore/<uuid>/` 里
    /// 找回原来的 store 标识，避免登录态「凭空消失」。
    private static func recoverIdentifierFromDisk() -> UUID? {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit/cn.webhub.launcher/WebsiteDataStore", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return nil }

        func weight(_ dir: URL) -> Int {
            let cookies = dir.appendingPathComponent("Cookies/Cookies.binarycookies")
            let size = (try? FileManager.default.attributesOfItem(atPath: cookies.path))?[.size]
            return (size as? NSNumber)?.intValue ?? 0
        }

        let candidates = dirs.compactMap { dir -> (Int, UUID)? in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            return (weight(dir), id)
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    /// 预热：确保 store-id 文件存在（供启动器显示/调试用）
    static func warmUp() {
        _ = identifier
    }

    /// 根据站点配置获取共享或独立的持久化数据仓库。
    static func dataStore(for app: WebApp) -> WKWebsiteDataStore {
        guard app.usesIsolatedLogin else { return sharedDataStore() }
        if #available(macOS 14.0, *) {
            let storeID = UUID(uuidString: app.id) ?? UUID()
            return WKWebsiteDataStore(forIdentifier: storeID)
        }
        return sharedDataStore()
    }

    /// 清除指定站点所在仓库的全部网站数据。
    static func clear(for app: WebApp, completion: (() -> Void)? = nil) {
        clear(store: dataStore(for: app), completion: completion)
    }

    /// 清除共享登录态。
    static func clearAll(completion: (() -> Void)? = nil) {
        clear(store: sharedDataStore(), completion: completion)
    }

    /// 删除独立 WebApp 的网站数据仓库及其磁盘目录。
    static func deletePersistentStore(for app: WebApp) {
        guard app.usesIsolatedLogin,
              let storeID = UUID(uuidString: app.id),
              let directory = persistentStoreDirectory(for: storeID) else { return }

        let store = dataStore(for: app)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        if #available(macOS 14.0, *) {
            Task {
                await store.removeData(ofTypes: types, modifiedSince: .distantPast)
                removeStoreFiles(at: directory)
            }
        } else {
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                removeStoreFiles(at: directory)
            }
        }
    }

    private static func sharedDataStore() -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
        return .default()
    }

    private static func persistentStoreDirectory(for identifier: UUID) -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "cn.webhub.launcher"
        return library
            .appendingPathComponent("WebKit/\(bundleID)/WebsiteDataStore", isDirectory: true)
            .appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
    }

    private static func removeStoreFiles(at directory: URL) {
        // 等 WebKit 完成数据清理并释放当前数据仓库后再删目录，避免残留文件被重新写回。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func clear(store: WKWebsiteDataStore, completion: (() -> Void)?) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        if #available(macOS 14.0, *) {
            Task {
                await store.removeData(ofTypes: types, modifiedSince: .distantPast)
                await MainActor.run { completion?() }
            }
        } else {
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }
}

// MARK: - 自动填充注入脚本

enum AutofillScript {

    /// 在页面加载时注入：检测登录表单，向原生查询凭据，然后自动填充
    static func make(host: String) -> WKUserScript {
        let js = """
        (function () {
          if (window.__webhubAutofillInstalled) return;
          window.__webhubAutofillInstalled = true;

          const HOST = \(jsLiteral(host));
          let asked = false;

          function visible(el) {
            if (!el) return false;
            const r = el.getBoundingClientRect();
            if (r.width < 8 || r.height < 8) return false;
            const st = getComputedStyle(el);
            if (st.visibility === 'hidden' || st.display === 'none' || st.opacity === '0') return false;
            return true;
          }

          function scoreInput(el) {
            let s = 0;
            const t = (el.type || '').toLowerCase();
            const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
            const name = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '')).toLowerCase();
            if (t === 'password') s += 100;
            if (ac.indexOf('username') >= 0) s += 60;
            if (ac.indexOf('password') >= 0) s += 60;
            if (/user|account|login|email|phone|mobile|name/.test(name)) s += 30;
            if (t === 'email' || t === 'tel') s += 40;
            if (t === 'search' || t === 'hidden' || t === 'checkbox' || t === 'radio') s -= 80;
            return s;
          }

          function findFields() {
            const all = Array.from(document.querySelectorAll('input'))
              .filter(el => visible(el) && !el.disabled && !el.readOnly);
            const pwd = all.filter(el => (el.type || '').toLowerCase() === 'password')
                           .sort((a, b) => scoreInput(b) - scoreInput(a))[0] || null;
            if (!pwd) return null;
            // 密码框之前最近的文本框 = 用户名
            let user = null;
            const idx = all.indexOf(pwd);
            for (let i = idx - 1; i >= 0; i--) {
              const el = all[i];
              const t = (el.type || '').toLowerCase();
              if (t === 'password') continue;
              if (t === 'text' || t === 'email' || t === 'tel' || t === '') {
                user = el; break;
              }
            }
            if (!user) {
              user = all.filter(el => scoreInput(el) > 0 && el !== pwd)[0] || null;
            }
            return { user, pwd };
          }

          function setValue(el, value) {
            if (!el || value == null) return;
            el.focus();
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
            // React/Vue 受控组件补充触发
            el.dispatchEvent(new Event('blur', { bubbles: false }));
          }

          function tryFill() {
            const fields = findFields();
            if (!fields) return false;

            // 已经在页面里登录成功（没有密码框）就不打扰
            if (!asked) {
              asked = true;
              try {
                window.webkit.messageHandlers.autofill.postMessage({
                  type: 'requestCredential',
                  host: location.hostname
                });
              } catch (e) {}
            }
            return true;
          }

          // 供原生回调
          window.__webhubFill = function (username, password) {
            const fields = findFields();
            if (!fields) return false;
            if (username) setValue(fields.user, username);
            if (password) setValue(fields.pwd, password);
            return true;
          };

          window.__webhubCaptureCredential = function () {
            const fields = findFields();
            if (!fields || !fields.pwd) return null;
            const u = fields.user ? fields.user.value : '';
            const p = fields.pwd.value;
            if (!u || !p) return null;
            return { username: u, password: p, host: location.hostname };
          };

          // 页面变化/异步渲染时重试
          let tries = 0;
          const timer = setInterval(() => {
            if (tryFill() || ++tries > 20) clearInterval(timer);
          }, 500);

          document.addEventListener('DOMContentLoaded', tryFill);
          window.addEventListener('load', () => setTimeout(tryFill, 300));

          // 监听登录表单提交，捕获账号密码
          document.addEventListener('submit', function (e) {
            const cred = window.__webhubCaptureCredential();
            if (cred) {
              try {
                window.webkit.messageHandlers.autofill.postMessage({
                  type: 'saveCredential', host: cred.host,
                  username: cred.username, password: cred.password
                });
              } catch (err) {}
            }
          }, true);

          // 部分站点不用 submit 而是按钮点击
          document.addEventListener('click', function (e) {
            const btn = e.target.closest && e.target.closest('button, [type=submit], .login-btn, .submit');
            if (!btn) return;
            const cred = window.__webhubCaptureCredential();
            if (cred) {
              try {
                window.webkit.messageHandlers.autofill.postMessage({
                  type: 'saveCredential', host: cred.host,
                  username: cred.username, password: cred.password
                });
              } catch (err) {}
            }
          }, true);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        var inner = json
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        return inner
    }
}
