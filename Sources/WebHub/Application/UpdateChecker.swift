import AppKit
import Sparkle

final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
