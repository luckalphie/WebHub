import WebKit

enum VideoFullscreenGesture {
    static let userScript = WKUserScript(source: """
    window.addEventListener('dblclick', event => {
      if (!event.isTrusted || event.button !== 0 || event.ctrlKey || event.metaKey
          || event.altKey || event.shiftKey) return;

      const video = event.composedPath().find(element => element instanceof HTMLVideoElement);
      if (!video) return;
      const fullscreen = document.fullscreenElement;
      const nativeFullscreen = video.webkitDisplayingFullscreen;

      // 等网页自己的事件处理完成，避免跟播放器的双击行为重复切换。
      setTimeout(() => {
        if (event.defaultPrevented || !video.isConnected || fullscreen !== document.fullscreenElement
            || nativeFullscreen !== video.webkitDisplayingFullscreen) return;

        if (fullscreen) {
          document.exitFullscreen().catch(() => {});
        } else if (nativeFullscreen) {
          video.webkitExitFullscreen();
        } else if (document.fullscreenEnabled && navigator.userActivation?.isActive !== false) {
          video.requestFullscreen().catch(() => {});
        }
      }, 0);
    });
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: false,
         in: WKContentWorld.world(name: "WebHub Video Fullscreen"))
}
