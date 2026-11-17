import AppKit

/// 保存进程身份，避免辅助进程退出后 PID 被其他应用复用。
struct RunnerProcess {
    private let application: NSRunningApplication
    private let pid: pid_t
    private let launchDate: Date
    private let bundleURL: URL
    private let bundleID: String

    init?(pid: pid_t, appID: String) {
        guard pid > 1, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        self.init(application: app, appID: appID)
    }

    init?(application: NSRunningApplication, appID: String) {
        let pid = application.processIdentifier
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier, !application.isTerminated,
              let launchDate = application.launchDate, let url = application.bundleURL?.resolvingSymlinksInPath(),
              let bundleID = application.bundleIdentifier else { return nil }
        let embedded = RunnerPackager.embeddedHelperURL?.resolvingSymlinksInPath()
        let standaloneDir = AppStore.shared.runnerDir.resolvingSymlinksInPath()
        let isEmbedded = url == embedded && bundleID == "cn.webhub.runner.template"
        let isStandalone = url.deletingLastPathComponent() == standaloneDir && RunnerPackager.appID(in: url) == appID && bundleID == "cn.webhub.runner.\(appID)"
        guard isEmbedded || isStandalone else { return nil }
        self.application = application
        self.pid = pid
        self.launchDate = launchDate
        self.bundleURL = url
        self.bundleID = bundleID
    }

    @discardableResult
    func requestTermination() -> Bool {
        // 不对 0、-1 或进程组发送信号；PID、启动时间及包身份都必须仍然匹配。
        guard pid > 1, !application.isTerminated, application.processIdentifier == pid,
              let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated,
              current.launchDate == launchDate, current.bundleIdentifier == bundleID,
              current.bundleURL?.resolvingSymlinksInPath() == bundleURL else { return false }
        return kill(pid, SIGTERM) == 0
    }
}
