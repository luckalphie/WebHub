# WebHub

[简体中文](README.zh-CN.md)

A native macOS shell that turns your frequently used web apps into a desktop application center. Each site gets its own Dock icon and its own browser window with tabs; every site shares **one** WebKit data store, so you sign in once and stay signed in everywhere.

Built with Swift and WebKit. Packaged builds target **Apple Silicon** with a minimum deployment target of macOS 14.

This is an independent project and is not affiliated with Apple, Google, or any of the sites you choose to load. The MIT license covers this project's code and original assets; site names, icons, and trademarks belong to their owners.

## Features

- **Application center** — a grid of site tiles. Add a site by entering a name and a URL; the favicon is fetched automatically and can be replaced.
- **Real Dock icons** — every configured site becomes its own `.app` with a unique bundle identifier, so it appears in the Dock, in Launchpad, and in the app switcher like a native application.
- **Independent windows** — each site opens in its own window with tabs, back / forward / reload / home buttons, and an editable address bar. The last session's tabs are restored on launch.
- **Shared sign-in** — one `WKWebsiteDataStore` for the whole process, so cookies, `localStorage`, `IndexedDB`, and service workers are literally the same data across all sites. Not synchronized copies: the same file.
- **Password autofill** — credentials are saved in the macOS Keychain and injected at document start with native setters and composed events, so React and Vue forms pick them up.
- **Per-site quit** — quitting a site window (⌘Q or the red button) closes only that site and removes only its Dock icon. Quitting the application center quits everything.
- **Outbound links go to your browser** — clicking a link that points outside the site's own registrable domain opens it in your default browser instead of spawning another tab, while links within the domain (including cross-subdomain SSO hops) stay inside. Automatic redirects are never intercepted, so sign-in flows keep working.

## Architecture

WebHub deliberately uses a **single host process**, the same shape Chrome uses for its web apps.

```
WebHub.app  (the only process doing real work)
├── application center window
├── site window A ─┐
├── site window B  ├── all WebKit views live here
└── site window C ─┘
        ▲
        │ CFMessagePort: open / activate / close
        │
site shim processes ("Slack.app", "GitHub.app", …)
    — one per site, no windows, no WebKit, Dock placeholder only
```

The reason is the shared sign-in. `WKWebsiteDataStore` is scoped to the host bundle identifier: two processes with different bundle identifiers get two different data directories, and no configuration changes that. Any multi-process design can only *approximate* sharing by copying cookies around. Running every site in one process makes it exact.

So each site's `.app` is a shim — the equivalent of Chrome's `app_mode_loader`. It sets `NSApplicationActivationPolicy.regular` to claim a Dock tile, sends the host a message asking it to open the window, and stays alive until the host terminates it. The host owns the window and tells the shim to exit when that window closes.

`Sources/WebHubIPC` holds the message contract and nothing else, so the shim never links the host's AppKit or WebKit code.

## Build and run

Requires macOS 14 or newer and Swift 6 or newer.

| Command | Result |
| --- | --- |
| `sh scripts/build-app.sh` | Build `dist/WebHub.app` |
| `sh scripts/run.sh` | Build and run from source |
| `open Package.swift` | Open the package in Xcode |

`sh scripts/build-app.sh` is the supported way to run WebHub. A plain `swift run` produces a bare executable with no bundle identifier, and WebKit behaves poorly without one — window sizing, cookies, and the shim launch path all assume a real `.app`.

Set `WEBHUB_VERSION=1.2.0` to stamp a different marketing version into the bundle.

## Install

Packaged builds are ad hoc signed and **not notarized**. macOS may refuse to open a downloaded copy. After attempting to open it, use **System Settings → Privacy & Security → Open Anyway** if you trust the source. There is no need to disable system security.

## Where data lives

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/WebHub/apps.json` | Site list: name, URL, accent color |
| `~/Library/Application Support/WebHub/sessions.json` | Open tabs per site |
| `~/Library/Application Support/WebHub/icons/` | Cached favicons |
| `~/Library/Application Support/WebHub/runners/` | Generated per-site `.app` bundles |
| `~/Library/WebKit/cn.webhub.launcher/` | The shared WebKit data store — this is where your sign-in state lives |
| Keychain item `cn.webhub.credentials` | Saved usernames and passwords, one per registrable domain |

`apps.json` and `sessions.json` are also backed up into the WebKit data directory, and are restored automatically if the primary file goes missing.

WebHub contains no telemetry and no analytics. Its only network activity is loading the sites you configure and fetching their favicons.

## Status and limitations

- Developed and tested on Apple Silicon against macOS 27. The macOS 14 deployment target is not a claim that every supported release has been exercised.
- One misbehaving site can hang the whole application — that is the cost of a single host process. There is no per-site crash isolation.
- Sign-in state cannot be shared with Safari. `~/Library/Containers/com.apple.Safari` is protected by TCC, the `HttpOnly` session cookie is unreadable from outside, and Safari rewrites its store wholesale on quit.
- The shim process is a real `.app`, so a site keeps its Dock tile through a host restart only if that tile is still open.
- `Resources/WebHub.icns` is a checked-in binary; `sh tools/make-icon.sh` regenerates it from the drawing code in `tools/makeicon.swift`.
