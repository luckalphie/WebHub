# WebHub

[English](README.md)

把常用的 Web 应用装进 macOS 桌面的应用中心。每个站点有自己的 Dock 图标和独立窗口（带标签页），而**所有站点共用同一份** WebKit 数据仓库 —— 登录一次，处处生效。

Swift + WebKit 实现。打包产物面向 **Apple Silicon**，最低系统要求 macOS 14。

这是独立项目，与 Apple、Google 以及你自行配置的站点均无关联。MIT 许可仅覆盖本项目代码与自制资源；站点名称、图标与商标归各自所有者。

## 功能

- **应用中心** —— 站点磁贴网格。填入名称和网址即可添加，favicon 自动抓取，也可以手动替换。
- **真实 Dock 图标** —— 每个站点生成独立 `.app` 和唯一 bundle 标识，因此在 Dock、启动台、应用切换器里都像一个原生应用。
- **独立窗口** —— 每个站点在自己的窗口里打开，有标签页、前进 / 后退 / 刷新 / 主页按钮和可编辑地址栏。下次启动恢复上次的标签。
- **共享登录态** —— 整个进程只有一个 `WKWebsiteDataStore`，cookie、`localStorage`、`IndexedDB`、Service Worker 全是**同一份数据**，不是定时同步的副本。
- **密码自动填充** —— 凭据存在 macOS 钥匙串，在 document start 用原生 setter 加合成事件注入，React 和 Vue 的表单都能识别。
- **按站点退出** —— 关掉某个站点的窗口（⌘Q 或红叉）只结束该站点、只移除它自己的 Dock 图标。退出应用中心才会全部退出。
- **外链交给系统浏览器** —— 点击指向站点根域之外的链接，不在标签页里打开，而是交给默认浏览器；同根域的链接（含 SSO 跨子域跳转）留在站内。自动重定向一律不拦，登录流程不受影响。

## 架构

WebHub 刻意采用**单宿主进程**，与 Chrome 跑 web app 的形态一致。

```
WebHub.app（唯一真正干活的进程）
├── 应用中心窗口
├── 站点窗口 A ─┐
├── 站点窗口 B  ├── 所有 WebKit 视图都在这里
└── 站点窗口 C ─┘
        ▲
        │ CFMessagePort：open / activate / close
        │
站点 shim 进程（"Slack.app"、"GitHub.app" …）
    — 每站点一个，不建窗口、不加载 WebKit，只占 Dock 位
```

原因就是共享登录态。`WKWebsiteDataStore` 按宿主 bundle 标识分目录：两个不同 bundle 标识的进程必然拿到两个不同的数据目录，没有任何配置能改变这一点。多进程方案只能用「拷贝 cookie」去**逼近**共享，而把所有站点放进同一个进程，就是**真的**共享。

于是每个站点的 `.app` 是一个 shim —— 等价于 Chrome 的 `app_mode_loader`。它把激活策略设为 `regular` 占住 Dock 位，发消息请宿主开窗，然后常驻直到被宿主结束。窗口归宿主所有；窗口一关，宿主就让对应的 shim 退出。

`Sources/WebHubIPC` 只放消息契约，所以 shim 永远不会链接宿主的 AppKit / WebKit 代码。

## 构建与运行

需要 macOS 14 以上和 Swift 6 以上。

| 命令 | 作用 |
| --- | --- |
| `sh scripts/build-app.sh` | 产出 `dist/WebHub.app` |
| `sh scripts/run.sh` | 从源码构建并运行 |
| `open Package.swift` | 用 Xcode 打开工程 |

`sh scripts/build-app.sh` 是受支持的运行方式。直接 `swift run` 出来的是没有 bundle 标识的裸可执行文件，而 WebKit 在没有 bundle 时行为不可靠 —— 窗口尺寸、cookie、shim 的拉起路径都假定自己跑在真正的 `.app` 里。

用 `WEBHUB_VERSION=1.2.0` 可以改写包里的版本号。

## 安装

打包产物是 ad-hoc 签名、**未经公证**。系统可能拒绝打开下载来的副本。尝试打开后，若你信任来源，到**系统设置 → 隐私与安全性 → 仍要打开**即可，不需要关闭系统安全机制。

## 数据位置

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/WebHub/apps.json` | 站点列表：名称、网址、配色 |
| `~/Library/Application Support/WebHub/sessions.json` | 各站点打开的标签 |
| `~/Library/Application Support/WebHub/icons/` | 缓存的 favicon |
| `~/Library/Application Support/WebHub/runners/` | 运行时生成的各站点 `.app` |
| `~/Library/WebKit/cn.webhub.launcher/` | 共享数据仓库 —— 登录态就在这里 |
| 钥匙串项 `cn.webhub.credentials` | 保存的用户名密码，按可注册域名一条 |

`apps.json` 和 `sessions.json` 还会备份一份到 WebKit 数据目录里，主文件丢失时自动恢复。

WebHub 不含遥测和统计。唯一的网络活动是加载你配置的站点、以及抓取它们的 favicon。

## 现状与限制

- 开发与验证环境是 Apple Silicon + macOS 27。声明 macOS 14 只是部署下限，不代表每个受支持的版本都实测过。
- 单个站点卡死会拖累整个应用 —— 这是单宿主的代价，没有按站点的崩溃隔离。
- 登录态无法与 Safari 共享：`~/Library/Containers/com.apple.Safari` 受 TCC 保护，`HttpOnly` 会话 cookie 从外部读不到，且 Safari 退出时会把整份数据重写一遍。
- shim 是真实的 `.app`，所以宿主重启后，站点只有在对应 Dock 图标还开着时才会恢复。
- `Resources/WebHub.icns` 是直接入库的二进制文件，`sh tools/make-icon.sh` 会用 `tools/makeicon.swift` 里的绘制代码重新生成它。
