import Foundation

/// 宿主进程与站点 shim 之间的约定。
///
/// 单独成一个 target：两侧都只依赖这里的常量，不会互相拖进对方的实现，
/// shim 因此能保持极小（不链接宿主的 AppKit / WebKit 代码）。
public enum WebHubIPC {

    /// 本地 message port 名。宿主监听，shim 连接。
    public static let portName = "cn.webhub.host"

    /// 消息 id（目前统一用 1，命令放在 JSON 的 cmd 字段里）
    public static let messageID: Int32 = 1

    /// shim 的 Info.plist 里记录的宿主 App 路径，宿主没起时用它拉起
    public static let hostPathKey = "WebHubHostPath"

    public enum Command: String {
        /// 请宿主打开本站点窗口
        case open
        /// 窗口已在，把它提到前面
        case activate
        /// 本 shim 要退出了（例如 Dock 右键「退出」）：
        /// 请宿主关掉本站点窗口，别让窗口变成没有 Dock 图标的孤儿
        case close
    }
}
