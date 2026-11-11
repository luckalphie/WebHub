# WebHub

[English](README.md)

把常用的 Web 应用装进 macOS 桌面的应用中心。每个站点有自己的 Dock 图标和独立窗口（带标签页），而**所有站点共用同一份** WebKit 数据仓库 —— 登录一次，处处生效。

Swift + WebKit 实现。打包产物面向 **Apple Silicon**，最低系统要求 macOS 14。

这是独立项目，与 Apple、Google 以及你自行配置的站点均无关联。MIT 许可仅覆盖本项目代码与自制资源；站点名称、图标与商标归各自所有者。

## 功能

- **应用中心** —— 站点磁贴网格。可选择生成名称图标，或使用网页图标；网页图标支持自动抓取和自定义图片 URL。合成图标会裁掉透明留白并放大主体。
- **真实 Dock 图标** —— 打开的站点各有自己的 Dock 图标。全局开启「创建独立 App」后，还会在 `~/Applications/WebHub Apps` 中创建可直接启动的应用；默认关闭。
- **独立窗口** —— 每个站点在自己的窗口里打开，标签页显示随网页更新的 favicon，右键可用默认浏览器打开页面；悬停标签可查看完整标题和已加载后台标签的卸载倒计时。窗口还提供前进 / 后退 / 刷新 / 主页按钮和可复制的只读地址栏。
- **收藏栏** —— 通过标签页右键收藏页面，在各站点的收藏栏里拖动排序、右键管理；获取到的网页图标会随收藏保存。
- **语言** —— 支持英文和简体中文，可跟随系统或在菜单中选择。
- **外观** —— 可跟随系统，或在菜单中选择浅色、深色模式。
- **共享登录态** —— 整个进程只有一个 `WKWebsiteDataStore`，cookie、`localStorage`、`IndexedDB`、Service Worker 全是**同一份数据**，不是定时同步的副本。
- **密码自动填充** —— 凭据存在 macOS 钥匙串，在 document start 用原生 setter 加合成事件注入，React 和 Vue 的表单都能识别。
- **按站点退出** —— 关掉某个站点的窗口（⌘Q 或红叉）只结束该站点、只移除它自己的 Dock 图标。退出应用中心才会全部退出。
- **外链交给系统浏览器** —— 点击主机名与站点不同的链接，不在标签页里打开，而是交给默认浏览器。子域也算出站（`a.example.com` → `b.example.com` 同样出去）；`docs.qq.com/scenario/link.html?url=…` 这类中转包装会先解出真实地址，浏览器不会停在包装页上。自动重定向一律不拦，登录流程不受影响。
- **地址栏可复制** —— 选中网址后 ⌘C 复制，也兼容 Ctrl+C；右键菜单里有「复制地址」。

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
共用 WebHub Helper 进程（"WebHubHelper.app"）
    — 所有站点复用同一个 Helper，不建窗口、不加载 WebKit
```

原因就是共享登录态。`WKWebsiteDataStore` 按宿主 bundle 标识分目录：两个不同 bundle 标识的进程必然拿到两个不同的数据目录，没有任何配置能改变这一点。多进程方案只能用「拷贝 cookie」去**逼近**共享，而把所有站点放进同一个进程，就是**真的**共享。

关闭「创建独立 App」时，WebHub 只生成一个共用的 `WebHubHelper.app`，放在 `~/Library/Application Support/WebHub/runtime-shims/`。每次打开站点时通过启动参数把站点 ID 交给 Helper，再由它请求宿主开窗；窗口关闭后 Helper 进程退出。不会再按站点生成临时 `.app`。

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
| `~/Library/Application Support/WebHub/apps.json` | 站点列表：名称、网址、图标来源、配色 |
| `~/Library/Application Support/WebHub/apps/<站点 ID>/` | 该站点的图标、会话、收藏和运行时图标 |
| `~/Applications/WebHub Apps/` | 运行时生成的各站点 `.app` |
| `~/Library/Application Support/WebHub/runtime-shims/` | 未开启独立 App 时使用的内部 Dock shim |
| `~/Library/WebKit/cn.webhub.launcher/` | 共享数据仓库 —— 登录态就在这里 |
| 钥匙串项 `cn.webhub.credentials` | 保存的用户名密码，按可注册域名一条 |

`apps.json`、各站点目录及其会话和收藏会备份到 WebKit 数据目录。升级时旧版分散文件会自动迁移并清理。

关闭「创建独立 App」会删除 `~/Applications/WebHub Apps` 中由 WebHub 创建的应用包；如有应用正在运行，会先询问是否关闭并删除。站点数据会保留。升级后首次启动时，默认关闭也会执行相同清理。

WebHub 不含遥测和统计。唯一的网络活动是加载你配置的站点、以及抓取它们的 favicon。

## 现状与限制

- 开发与验证环境是 Apple Silicon + macOS 27。声明 macOS 14 只是部署下限，不代表每个受支持的版本都实测过。
- 站点窗口共享同一个 WebHub 宿主进程，宿主崩溃或主线程卡死会影响所有站点。WebKit 使用独立内容进程，但不能保证每个站点都完全隔离。
- WebHub 使用独立于 Safari 的网站数据仓库，不直接共享 Safari 的 Cookie 和登录态。
- 重新打开站点时，WebHub 会尝试恢复该站点保存的标签页；退出 WebHub 后不会自动重新打开全部站点窗口。关闭最后一个标签页会清空该站点保存的会话。
- 恢复的标签页在选中时加载。后台标签页闲置五分钟后会卸载，再次选中时重新加载；未保存的表单、页面状态、前进后退历史、媒体播放和实时连接可能丢失。
- `Resources/WebHub.icns` 是直接入库的二进制文件，`sh tools/make-icon.sh` 会用 `tools/makeicon.swift` 里的绘制代码重新生成它。
