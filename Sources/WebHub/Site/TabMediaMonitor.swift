import WebKit

/// 记录出现过媒体的网页 frame，用播放器状态校正 WebKit 的整页播放状态。
final class TabMediaMonitor: NSObject, WKScriptMessageHandler {
    private static let handlerName = "mediaActivity"
    private static let world = WKContentWorld.world(name: "WebHub Media Activity")
    private var mediaFrames: [String: WKFrameInfo] = [:]

    func install(in controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.observerScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: Self.world))
    }

    func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        mediaFrames.removeAll()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let id = message.body as? String else { return }
        mediaFrames[id] = message.frameInfo
    }

    @MainActor func hasActiveMedia(in webView: WKWebView) async -> Bool {
        var inspectedPlayer = false
        for (id, frame) in mediaFrames {
            let result = try? await webView.callAsyncJavaScript(
                "return globalThis.webHubMediaActivity?.(documentID) ?? null",
                arguments: ["documentID": id], in: frame, contentWorld: Self.world)
            guard let active = result as? Bool else {
                // iframe 已移除或跳到其他文档，旧状态不再影响卸载。
                mediaFrames.removeValue(forKey: id)
                continue
            }
            if active { return true }
            inspectedPlayer = true
        }
        if inspectedPlayer { return false }
        // 没观测到 HTML 播放器时仍以 WebKit 状态为准，例如 Web Audio 不一定有媒体元素。
        return await webView.requestMediaPlaybackState() == .playing
    }

    private static let observerScript = """
    (() => {
      const id = Array.from(crypto.getRandomValues(new Uint32Array(4))).join('-');
      const players = new Set();
      const events = ['play', 'enterpictureinpicture', 'webkitpresentationmodechanged'];
      let registered = false;
      function remember(event) {
        const player = event.target;
        if (!(player instanceof HTMLMediaElement)) return;
        players.add(player);
        if (registered) return;
        registered = true;
        window.webkit.messageHandlers.mediaActivity.postMessage(id);
      }
      for (const name of events) document.addEventListener(name, remember, true);
      globalThis.webHubMediaActivity = documentID => {
        if (documentID !== id) return null;
        for (const player of players) {
          if ((!player.paused && !player.ended) || document.pictureInPictureElement === player
              || player.webkitPresentationMode === 'picture-in-picture') return true;
          if (!player.isConnected) players.delete(player);
        }
        return false;
      };
    })();
    """
}
