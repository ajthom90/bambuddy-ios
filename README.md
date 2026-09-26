# Bambuddy for iOS & iPadOS

A native SwiftUI client for [Bambuddy](https://github.com/maziggy/bambuddy), the open-source,
self-hosted print archive and management server for Bambu Lab 3D printers.

> This is an independent, community-built companion app. It talks to your own Bambuddy
> server over its REST + WebSocket API; it is not affiliated with Bambu Lab or the
> Bambuddy project.

## Features

- **Printers** — live status over WebSocket, progress/ETA, temperatures, AMS & external spool,
  HMS errors, pause/resume/stop, speed, fans, lights, jog/home, AI detection options, drying
- **Live camera** — MJPEG streaming with snapshot fallback, full-screen view, camera wall
- **Server connection** — any http/https Bambuddy server, with local auth, 2FA (TOTP / email /
  backup codes) and OIDC single sign-on
- **iPhone & iPad** — tab bar on iPhone, sidebar on iPad, multi-window support

See [`docs/PLAN.md`](docs/PLAN.md) for feature parity with the web UI.

## Requirements

- iOS / iPadOS 26 or later
- Xcode 27+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Bambuddy server (API version **1.2.5.x**; the targeted OpenAPI snapshot is in
  [`docs/api/openapi.json`](docs/api/openapi.json))

## Building

```sh
xcodegen generate
open Bambuddy.xcodeproj
```

The `.xcodeproj` is generated from [`project.yml`](project.yml) and not committed. Set your
development team in Xcode to run on a device.

Run tests:

```sh
xcodebuild -project Bambuddy.xcodeproj -scheme Bambuddy \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License

MIT — see [LICENSE](LICENSE). Bambuddy itself is AGPL-3.0; this app contains no Bambuddy
source code and communicates with it only over its public HTTP API.
