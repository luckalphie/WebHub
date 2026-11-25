import AppKit
import SwiftUI

private final class SettingsModel: ObservableObject {
    @Published var busy = false
    var saveSettings: ([String: Any]) -> Void = { _ in }
    var dismissSettings: () -> Void = {}
    var cancelSettings: () -> Void = {}
    var previewIconSize: (CGFloat) -> Void = { _ in }
    var resizeSettings: () -> Void = {}
}

final class SettingsController: NSObject, NSWindowDelegate {
    private let model = SettingsModel()
    private let parentWindow: () -> NSWindow?
    private let onRefresh: () -> Void
    private let onPreviewIconSize: (CGFloat) -> Void
    private var window: NSPanel?
    private var changingStandaloneApps = false

    init(parentWindow: @escaping () -> NSWindow?, onRefresh: @escaping () -> Void, onPreviewIconSize: @escaping (CGFloat) -> Void) {
        self.parentWindow = parentWindow
        self.onRefresh = onRefresh
        self.onPreviewIconSize = onPreviewIconSize
        super.init()
        model.saveSettings = { [weak self] in self?.save($0) }
        model.dismissSettings = { [weak self] in self?.dismiss() }
        model.cancelSettings = { [weak self] in self?.cancel() }
        model.previewIconSize = { [weak self] in self?.onPreviewIconSize($0) }
        model.resizeSettings = { [weak self] in self?.resizeWindow() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = WebHubLanguage.text("Settings")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        window = panel
        let settingsView = NSHostingView(rootView: SettingsView(model: model))
        settingsView.sizingOptions = [.intrinsicContentSize]
        settingsView.setContentHuggingPriority(.required, for: .vertical)
        panel.contentView = settingsView
        resizeWindow()
        centerOnParent()
        panel.makeKeyAndOrderFront(nil)

        // 等 SwiftUI 的按钮事件返回后再进入 AppKit 模态循环，避免重入阻塞后续按钮事件。
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.window === panel else { return }
            NSApp.runModal(for: panel)
            panel.orderOut(nil)
            self.window = nil
        }
    }

    func dismiss() {
        guard let window, !model.busy, NSApp.modalWindow === window else { return }
        NSApp.stopModal()
    }

    func cancel() {
        guard let window, !model.busy, NSApp.modalWindow === window else { return }
        onPreviewIconSize(AppCenterIconSize.preference)
        NSApp.stopModal()
    }

    func owns(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    func disableStandaloneAppsIfNeeded() {
        guard !RunnerPackager.hasStandalonePreference else { return }
        disableStandaloneApps { _ in }
    }

    func save(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String, let enabled = body["enabled"] as? Bool,
              let appearanceValue = body["appearance"] as? String, let appearance = WebHubAppearance(rawValue: appearanceValue),
              let language = body["language"] as? String, ["system", "en", "zh-CN"].contains(language),
              let iconSize = (body["iconSize"] as? Double).map({ AppCenterIconSize.normalized(CGFloat($0)) }) else {
            model.busy = false
            return
        }

        let profile: NetworkProxyProfile?
        if kind == "system" {
            profile = nil
        } else {
            let username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredPassword = body["password"] as? String ?? ""
            guard !username.isEmpty || enteredPassword.isEmpty else {
                showValidationError("Enter a proxy username.")
                return
            }
            let previous = NetworkProxyStore.shared.profile
            let host = body["host"] as? String ?? ""
            let portText = body["port"] as? String ?? ""
            let canReusePassword = previous?.kind.rawValue == kind && previous?.host == host.trimmingCharacters(in: .whitespacesAndNewlines) && previous.map { String($0.port) } == portText && previous?.username == username
            let password = username.isEmpty ? nil : (enteredPassword.isEmpty && canReusePassword ? previous?.password : enteredPassword)
            guard username.isEmpty || !(password ?? "").isEmpty else {
                showValidationError("Enter a proxy password.")
                return
            }
            guard let type = NetworkProxyProfile.Kind(rawValue: kind),
                  let port = UInt16(portText),
                  let value = NetworkProxyProfile(name: "Global", kind: type, host: host, port: port, bypassDomains: body["bypass"] as? String ?? "", username: username, password: password) else {
                showValidationError("Enter a valid host and port from 1 to 65535.")
                return
            }
            profile = value
        }

        setStandaloneApps(enabled) { [weak self] success in
            guard let self else { return }
            guard success else {
                self.model.busy = false
                return
            }
            do {
                try NetworkProxyStore.shared.save(profile)
                SiteWindowManager.shared.refreshNetworkProxy()
                let languageChanged = (body["languageChanged"] as? Bool == true) && language != WebHubLanguage.languagePreference
                if body["appearanceChanged"] as? Bool == true { WebHubAppearance.select(appearance) }
                if languageChanged { UserDefaults.standard.set(language, forKey: "WebHub.language") }
                AppCenterIconSize.save(iconSize)
                self.onPreviewIconSize(iconSize)
                self.onRefresh()
                self.model.busy = false
                self.dismiss()
                if languageChanged {
                    let alert = NSAlert()
                    alert.messageText = WebHubLanguage.text("Language changed")
                    alert.informativeText = WebHubLanguage.text("Restart WebHub to apply the language change to all windows.")
                    alert.addButton(withTitle: WebHubLanguage.text("OK"))
                    alert.runModal()
                }
            } catch {
                self.showValidationError("Unable to save proxy settings.")
            }
        }
    }

    private func resizeWindow() {
        guard let window,
              let settingsView = window.contentView as? NSHostingView<SettingsView> else { return }
        let fallbackFrame = parentWindow()?.frame ?? window.frame
        let visible = window.screen?.visibleFrame ?? parentWindow()?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? fallbackFrame
        settingsView.layoutSubtreeIfNeeded()
        let fitted = settingsView.fittingSize
        let contentHeight = min(max(300, fitted.height), visible.height)
        var target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 460, height: contentHeight))
        guard abs(window.frame.height - target.height) > 1 else { return }
        target.origin.x = min(max(window.frame.midX - target.width / 2, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(window.frame.midY - target.height / 2, visible.minY), visible.maxY - target.height)
        window.setFrame(target, display: true, animate: window.isVisible)
    }

    private func centerOnParent() {
        guard let window, let parentFrame = parentWindow()?.frame else { return }
        let visible = parentWindow()?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parentFrame
        let originX = min(max(parentFrame.midX - window.frame.width / 2, visible.minX), visible.maxX - window.frame.width)
        let originY = min(max(parentFrame.midY - window.frame.height / 2, visible.minY), visible.maxY - window.frame.height)
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func showValidationError(_ message: String) {
        model.busy = false
        let alert = NSAlert()
        alert.messageText = WebHubLanguage.text(message)
        alert.runModal()
    }

    private func setStandaloneApps(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard !changingStandaloneApps else { completion(false); return }
        guard enabled != RunnerPackager.createsStandaloneApps else { completion(true); return }
        if !enabled {
            disableStandaloneApps(completion: completion)
        } else {
            RunnerPackager.createsStandaloneApps = true
            createStandaloneApps(AppStore.shared.apps)
            completion(true)
        }
    }

    private func createStandaloneApps(_ apps: [WebApp], index: Int = 0) {
        guard RunnerPackager.createsStandaloneApps, !changingStandaloneApps, index < apps.count else { return }
        guard let current = AppStore.shared.apps.first(where: { $0.id == apps[index].id }) else {
            createStandaloneApps(apps, index: index + 1)
            return
        }
        if RunnerPackager.ensureApp(for: current, iconPNG: nil) == nil {
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.format("Unable to create standalone app for %@", current.name)
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.createStandaloneApps(apps, index: index + 1)
        }
    }

    private func disableStandaloneApps(completion: @escaping (Bool) -> Void) {
        guard !changingStandaloneApps else { completion(false); return }
        let bundles: [URL]
        do {
            bundles = try RunnerPackager.standaloneBundles()
        } catch {
            RunnerPackager.createsStandaloneApps = true
            showStandaloneError(error)
            completion(false)
            return
        }
        let paths = Set(bundles.map { $0.resolvingSymlinksInPath().path })
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL else { return false }
            return paths.contains(url.resolvingSymlinksInPath().path) && !$0.isTerminated
        }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.text("Quit running standalone apps?")
            alert.informativeText = WebHubLanguage.text("Running site windows will close and their standalone apps will be removed. Site data will be kept.")
            alert.addButton(withTitle: WebHubLanguage.text("Quit and Remove"))
            alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                RunnerPackager.createsStandaloneApps = true
                completion(false)
                return
            }
        }
        changingStandaloneApps = true
        RunnerPackager.isChangingStandaloneApps = true
        for process in running {
            let runner = process.bundleURL.flatMap { RunnerPackager.appID(in: $0) }.flatMap { RunnerProcess(application: process, appID: $0) }
            if let url = process.bundleURL, let id = RunnerPackager.appID(in: url), SiteWindowManager.shared.openSiteIDs.contains(id) {
                SiteWindowManager.shared.close(id)
            }
            runner?.requestTermination()
        }
        finishDisablingStandaloneApps(bundles, running: running, deadline: Date().addingTimeInterval(5), completion: completion)
    }

    private func finishDisablingStandaloneApps(_ bundles: [URL], running: [NSRunningApplication], deadline: Date, completion: @escaping (Bool) -> Void) {
        if running.contains(where: { !$0.isTerminated }) {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.finishDisablingStandaloneApps(bundles, running: running, deadline: deadline, completion: completion)
                }
                return
            }
            changingStandaloneApps = false
            RunnerPackager.isChangingStandaloneApps = false
            RunnerPackager.createsStandaloneApps = true
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.text("Some standalone apps did not quit")
            alert.informativeText = WebHubLanguage.text("No standalone apps were removed. Close them and try again.")
            alert.runModal()
            completion(false)
            return
        }
        do {
            try RunnerPackager.deleteStandaloneBundles(bundles)
            RunnerPackager.createsStandaloneApps = false
        } catch {
            RunnerPackager.createsStandaloneApps = true
            showStandaloneError(error)
        }
        changingStandaloneApps = false
        RunnerPackager.isChangingStandaloneApps = false
        completion(!RunnerPackager.createsStandaloneApps)
    }

    private func showStandaloneError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = WebHubLanguage.text("Unable to remove standalone apps")
        alert.runModal()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var appearance = WebHubAppearance.preference.rawValue
    @State private var appearanceBaseline = WebHubAppearance.preference.rawValue
    @State private var language = WebHubLanguage.languagePreference
    @State private var languageBaseline = WebHubLanguage.languagePreference
    @State private var iconSize = AppCenterIconSize.preference
    @State private var standalone = RunnerPackager.createsStandaloneApps
    @State private var kind = NetworkProxyStore.shared.profile?.kind.rawValue ?? "system"
    @State private var host = NetworkProxyStore.shared.profile?.host ?? ""
    @State private var port = NetworkProxyStore.shared.profile.map { String($0.port) } ?? ""
    @State private var username = NetworkProxyStore.shared.profile?.username ?? ""
    @State private var password = ""
    @State private var bypass = NetworkProxyStore.shared.profile?.bypassDomains.joined(separator: ", ") ?? ""
    private let hasPassword = NetworkProxyStore.shared.profile?.password != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                settingsField("Appearance") {
                    SettingsPopup(title: "Appearance", selection: $appearance, options: [("System Default", "system"), ("Light Mode", "light"), ("Dark Mode", "dark")])
                }
                settingsField("Language") {
                    SettingsPopup(title: "Language", selection: $language, options: [("System Default", "system"), ("English", "en"), ("简体中文", "zh-CN")])
                }
                settingsField("App Center Icon Size") {
                    HStack(spacing: 12) {
                        Slider(value: $iconSize, in: AppCenterIconSize.minimum...AppCenterIconSize.maximum, step: AppCenterIconSize.step)
                            .accessibilityLabel(WebHubLanguage.text("App Center Icon Size"))
                        Text("\(Int(iconSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(WebHubLanguage.text("Create Standalone Apps"))
                        Spacer()
                        Toggle(WebHubLanguage.text("Create Standalone Apps"), isOn: $standalone)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Text(WebHubLanguage.text("Create launchable apps in ~/Applications/WebHub Apps. When off, sites still have Dock icons while open."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                settingsField("Network Proxy") {
                    SettingsPopup(title: "Network Proxy", selection: $kind, options: [("Use System Proxy", "system"), ("HTTP", "httpConnect"), ("SOCKS5", "socks5")]) { _ in
                        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                            model.resizeSettings()
                        }
                    }
                }
                if kind != "system" {
                    HStack(alignment: .top, spacing: 12) {
                        settingsField("Host") { TextField("127.0.0.1", text: $host).accessibilityLabel(WebHubLanguage.text("Host")) }
                        settingsField("Port") { TextField("", text: $port).accessibilityLabel(WebHubLanguage.text("Port")) }
                            .frame(width: 110)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        settingsField("Proxy Username") { TextField("", text: $username).accessibilityLabel(WebHubLanguage.text("Proxy Username")) }
                        settingsField("Proxy Password") {
                            SecureField("", text: $password, prompt: Text(hasPassword ? "********" : ""))
                                .accessibilityLabel(WebHubLanguage.text("Proxy Password"))
                        }
                    }
                    settingsField("Bypass Domains") { TextField("localhost, example.com", text: $bypass).accessibilityLabel(WebHubLanguage.text("Bypass Domains")) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button(WebHubLanguage.text("Cancel")) { model.cancelSettings() }.disabled(model.busy)
                Button(WebHubLanguage.text("Confirm")) {
                    model.busy = true
                    model.saveSettings(["enabled": standalone, "appearance": appearance, "appearanceChanged": appearance != appearanceBaseline, "language": language, "languageChanged": language != languageBaseline, "iconSize": Double(iconSize), "kind": kind, "host": host.trimmingCharacters(in: .whitespacesAndNewlines), "port": port, "username": username.trimmingCharacters(in: .whitespacesAndNewlines), "password": password, "bypass": bypass.trimmingCharacters(in: .whitespacesAndNewlines)])
                }.keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .controlSize(.large)
        .interactiveDismissDisabled(model.busy)
        .onChange(of: iconSize) { _, value in
            model.previewIconSize(AppCenterIconSize.normalized(value))
        }
        .onReceive(NotificationCenter.default.publisher(for: .webHubDisplayPreferencesChanged)) { _ in
            if appearance == appearanceBaseline {
                appearanceBaseline = WebHubAppearance.preference.rawValue
                appearance = appearanceBaseline
            }
            if language == languageBaseline {
                languageBaseline = WebHubLanguage.languagePreference
                language = languageBaseline
            }
            if iconSize == AppCenterIconSize.preference {
                iconSize = AppCenterIconSize.preference
            }
        }
    }

    private func settingsField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(WebHubLanguage.text(title)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPopup: NSViewRepresentable {
    let title: String
    @Binding var selection: String
    let options: [(String, String)]
    var onSelect: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .large
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        button.setAccessibilityLabel(WebHubLanguage.text(title))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.removeAllItems()
        for (label, value) in options {
            button.addItem(withTitle: WebHubLanguage.text(label))
            button.lastItem?.representedObject = value
        }
        if let index = options.firstIndex(where: { $0.1 == selection }) {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var parent: SettingsPopup
        init(_ parent: SettingsPopup) { self.parent = parent }

        @objc func selected(_ sender: NSPopUpButton) {
            if let value = sender.selectedItem?.representedObject as? String {
                parent.selection = value
                parent.onSelect(value)
            }
        }
    }
}
