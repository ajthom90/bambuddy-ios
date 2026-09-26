# Architecture

SwiftUI, iOS 26+, Swift 6 strict concurrency, no third-party dependencies.

```
Bambuddy/
  App/            entry point, RootView (connection phases), MainView (tabs/sidebar), AppSection
  Core/API/       APIClient (URLSession), APICoders, JSONValue
  Core/Models/    Codable models shared across features
  Core/Services/  AppSession, LiveUpdates (WebSocket), PrinterStore, Keychain
  Core/UI/        RemoteImage, MJPEG camera, Loader/ActionRunner, formatting, shared views
  Features/<X>/   one folder per top-level section; `<X>RootView` is its entry point
```

## Conventions

- **Environment**: `AppSession`, `PrinterStore`, and `LiveUpdates` are injected with
  `.environment(...)`. Read them with `@Environment(AppSession.self) private var session`.
- **HTTP**: `session.client` is an `APIClient`. Paths are relative to `/api/v1`:
  - `try await client.get("archives/", query: ["limit": 50])` → decodes `T`
  - `try await client.send(.post, "queue/", body: payload)` → decodes `T`
  - `try await client.call(.delete, "archives/\(id)")` → ignores body
  - `client.upload(...)` for multipart, `client.download(...)` to a temp file
  - Query values: `.string`, `.int`, `.double`, `.bool`, `.list`, or literals; `nil` is skipped.
- **Models**: Swift properties are camelCase; the decoder converts from snake_case.
  Make everything optional unless the OpenAPI schema lists it as required. Note that
  `foo_2fa` decodes as `foo2Fa`. For loosely-typed payloads use `JSONValue` (keys are
  kept verbatim, i.e. snake_case).
- **Loading/errors**: `@State private var loader = Loader<[T]>()` + `LoadingContent`;
  mutations via `@State private var runner = ActionRunner()` + `.actionAlerts(runner)`.
- **Images**: `RemoteImage(path: "/api/v1/archives/1/thumbnail")` attaches the bearer token.
- **Live refresh**: `.task(id: live.revision("archive_created", "archive_updated")) { … }`
  reloads when the server pushes matching WebSocket events.
- **Permissions**: gate actions with `session.can("archives:delete_own")`; with auth
  disabled everything is allowed. The full list is in `docs/api/permissions.txt`.
- **Layout**: must work on iPhone and iPad. Use `NavigationStack` inside each root view;
  prefer `List`/`Form` and adaptive grids; use `.searchable`, `.refreshable`, swipe actions,
  context menus and sheets for native feel.
