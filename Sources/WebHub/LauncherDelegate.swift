import AppKit

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LauncherWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SharedStorage.warmUp()
        // 把旧目录中的站点包迁移到用户的应用程序目录。
        RunnerPackager.migrateLegacyBundles()

        // 单宿主：先起 IPC 端口，等各站点 shim 来「请我开窗」
        SiteWindowManager.shared.startIPCServer()

        // 把启动器 pid 写下来：站点进程会盯着它，父进程一没就自己退出
        let pidFile = AppStore.shared.rootDir.appendingPathComponent("launcher.pid")
        let pid = ProcessInfo.processInfo.processIdentifier
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)

        let wc = LauncherWindowController()
        controller = wc
        wc.show()

        // 站点窗口全关后把菜单还原，否则 Cmd+Q / 「退出 WebHub」会落在
        // 一个已经关了窗口的站点菜单上，毫无反应
        SiteWindowManager.shared.onAllSitesClosed = { [weak wc] in
            wc?.restoreMenu()
        }

        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // 把各站点包刷新到当前版本。
        //
        // 升级、换安装位置之后，站点应用目录里躺着的可能还是
        // 上一版的 shim，`WebHubHostPath` 也可能指向旧路径 —— 用户若直接从 Dock 点
        // 站点图标（不经过应用中心），就会用到过期的那份。这里逐个校正一遍。
        // ensureApp 有指纹幂等，没变化时几乎不花时间；串行 + 间隔是为了不卡住启动。
        refreshSiteBundles(AppStore.shared.apps)
    }

    private func refreshSiteBundles(_ apps: [WebApp], index: Int = 0) {
        guard index < apps.count else { return }
        _ = RunnerPackager.ensureApp(for: apps[index], iconPNG: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshSiteBundles(apps, index: index + 1)
        }
    }

    /// Chrome 式语义：
    /// - 关掉**某个站点**的窗口 → 只影响那一个（shim 退出、Dock 图标消失），
    ///   其他站点窗口和 WebHub 主进程都不受影响。
    /// - 关掉应用中心窗口 → 只是收起窗口，进程留在后台（点 Dock 图标能回来）。
    /// - 只有显式退出（应用中心里 Cmd+Q / 菜单「退出 WebHub」）才收掉全部。
    ///
    /// 所以这里永远返回 false：**绝不因为「最后一个窗口关了」就退出进程**。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.reveal()
        return true
    }

    /// 退出启动器时把站点进程一起收掉，避免 Dock 里留一堆孤儿图标。
    ///
    /// ⚠️ 不能用 `NSRunningApplication.terminate()`：那是发 Apple Event，
    /// 会被「隐私与安全性 → 自动化」权限拦截并静默失败（实测启动器原地不动）。
    /// 改用 SIGTERM，站点进程里有对应处理，会先存会话再退出。
    func applicationWillTerminate(_ notification: Notification) {
        // 先按登记过的 pid 收一遍 shim
        SiteWindowManager.shared.terminateAllShims()

        let runners = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier ?? "").hasPrefix("cn.webhub.runner.")
        }
        guard !runners.isEmpty else { return }

        for runner in runners { kill(runner.processIdentifier, SIGTERM) }

        // 给它们最多 1.5 秒优雅退出（保存标签会话），超时就强杀
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline && runners.contains(where: { isAlive($0) }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        for runner in runners where isAlive(runner) {
            kill(runner.processIdentifier, SIGKILL)
        }
    }

    /// 信号 0 不发送任何东西，只探测进程是否还在
    private func isAlive(_ app: NSRunningApplication) -> Bool {
        kill(app.processIdentifier, 0) == 0
    }
}
