# Contributing

Thanks for taking a look. This is a small project, so a short issue or a focused pull request is the easiest way to get a change in.

## Requirements

- macOS 14 or newer
- Swift 6 or newer (`xcrun swift --version`)
- Xcode is optional — `open Package.swift` works, but every command below also runs from the terminal

## Layout

```
Sources/
├── WebHubIPC/     message contract shared by both executables (nothing else)
├── WebHub/        the host: application center + all site windows
└── WebHubRunner/  the site shim: claims a Dock tile, asks the host to open a window
scripts/
├── build-app.sh   assembles dist/WebHub.app and embeds the shim
└── run.sh         build and run from source
Resources/
└── WebHub.icns    checked-in app icon
tools/
└── makeicon.swift regenerates the icon from the accent palette
```

`WebHub` is the only target that links AppKit and WebKit. If you find yourself wanting to import WebKit from `WebHubRunner`, the logic almost certainly belongs in the host.

## Before opening a pull request

```sh
sh scripts/build-app.sh
```

That must succeed, and the packaged app must still open the application center and at least one site window. There is no automated test suite yet; the packaging script and the CI workflow are the safety net.

Keep the bundle identifier `cn.webhub.launcher`. It keys the WebKit data directory, so changing it silently signs every existing user out.

## Reporting a bug

Please include:

- macOS version and chip (`sw_vers`, `uname -m`)
- What you did, what happened, and what you expected
- Whether it reproduces in the packaged `dist/WebHub.app` or only under `swift run`

Crash reports live in `~/Library/Logs/DiagnosticReports/`. Attach the relevant `.ips` file if the app quit unexpectedly — it usually identifies the faulting frame directly.
