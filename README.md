# WebHub

[简体中文](README.zh-CN.md)

A native macOS shell that turns your frequently used web apps into a desktop application center. Each site gets its own Dock icon and its own browser window with tabs; every site shares **one** WebKit data store, so you sign in once and stay signed in everywhere.

Built with Swift and WebKit. Packaged builds target **Apple Silicon** with a minimum deployment target of macOS 14.

This is an independent project and is not affiliated with Apple, Google, or any of the sites you choose to load. The MIT license covers this project's code and original assets; site names, icons, and trademarks belong to their owners.

## Features

- **Application center** — a grid of site tiles. Choose a generated name icon or a website icon, either fetched automatically or from a custom image URL. Generated icons crop transparent padding and scale the artwork to fit.
- **Real Dock icons** — each open site has its own Dock icon. The optional global “Create Standalone Apps” setting also creates launchable apps in `~/Applications/WebHub Apps`; it is off by default.
- **Independent windows** — each site opens in its own window with tabs, live website favicons, a tab menu for opening the page in the default browser, back / forward / reload / home buttons, and a copyable, read-only address bar. Hovering a tab shows its full title and, for loaded background tabs, the remaining time before unloading.
- **Bookmarks** — save pages from a tab’s context menu in a per-site bookmarks bar; drag to reorder and right-click to manage them. Available page icons are saved with the bookmarks.
- **Languages** — English and Simplified Chinese, with system or menu selection.
- **Appearance** — follow the system appearance or choose light or dark mode from the menu.
- **Shared sign-in** — one `WKWebsiteDataStore` for the whole process, so cookies, `localStorage`, `IndexedDB`, and service workers are literally the same data across all sites. Not synchronized copies: the same file.
- **Password autofill** — credentials are saved in the macOS Keychain and injected at document start with native setters and composed events, so React and Vue forms pick them up.
- **Per-site quit** — quitting a site window (⌘Q or the red button) closes only that site and removes only its Dock icon. Quitting the application center quits everything.
- **Outbound links go to your browser** — clicking a link whose hostname differs from the site's own opens it in your default browser instead of spawning another tab. Subdomains count as outbound too: `a.example.com` → `b.example.com` leaves the app. Redirect wrappers such as `docs.qq.com/scenario/link.html?url=…` are unwrapped first, so the browser lands on the real destination. Automatic redirects are never intercepted, so sign-in flows keep working.
- **Copyable address bar** — select the URL and copy it with ⌘C (or Ctrl+C, for muscle memory from other platforms); right-click gives a "copy address" item.

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
shared WebHub Helper process ("WebHubHelper.app")
    — one helper bundle is reused by all sites
```

The reason is the shared sign-in. `WKWebsiteDataStore` is scoped to the host bundle identifier: two processes with different bundle identifiers get two different data directories, and no configuration changes that. Any multi-process design can only *approximate* sharing by copying cookies around. Running every site in one process makes it exact.

When standalone apps are disabled, WebHub creates one shared `WebHubHelper.app` under `~/Library/Application Support/WebHub/runtime-shims/`. The site ID is passed as a launch argument, the helper asks the host to open that site, and the helper exits when the site window closes. WebHub no longer creates a temporary `.app` for every site.

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
| `~/Library/Application Support/WebHub/apps.json` | Site list: name, URL, icon source, and accent color |
| `~/Library/Application Support/WebHub/apps/<site-id>/` | Icons, sessions, bookmarks, and runtime icons for that site |
| `~/Applications/WebHub Apps/` | Generated per-site `.app` bundles |
| `~/Library/Application Support/WebHub/runtime-shims/` | Internal Dock shims when standalone apps are disabled |
| `~/Library/WebKit/cn.webhub.launcher/` | The shared WebKit data store — this is where your sign-in state lives |
| Keychain item `cn.webhub.credentials` | Saved usernames and passwords, one per registrable domain |

`apps.json` and each site directory are backed up into the WebKit data directory. Legacy scattered files are migrated on upgrade and then removed.

Disabling standalone apps removes WebHub-generated app bundles from `~/Applications/WebHub Apps`. If any are running, WebHub asks before closing them and removing the bundles; site data is retained. On first launch after upgrading, the default-off setting applies the same cleanup.

WebHub contains no telemetry and no analytics. Its only network activity is loading the sites you configure and fetching their favicons.

## Status and limitations

- Developed and tested on Apple Silicon against macOS 27. The macOS 14 deployment target is not a claim that every supported release has been exercised.
- Site windows share one WebHub host process. A host crash or main-thread hang affects every site. WebKit uses separate content processes, but complete isolation between sites is not guaranteed.
- WebHub uses its own website data store and does not directly share Safari's cookies or sign-in state.
- WebHub attempts to restore a site's saved tabs when that site is reopened; exiting WebHub does not automatically reopen all site windows. Closing the last tab clears that site's saved session.
- Restored tabs load when selected. A tab left in the background for five minutes is unloaded and reloads when selected again; unsaved form input, page state, navigation history, media playback, and live connections may be lost.
- `Resources/WebHub.icns` is a checked-in binary; `sh tools/make-icon.sh` regenerates it from the drawing code in `tools/makeicon.swift`.
