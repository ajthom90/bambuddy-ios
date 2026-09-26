import SwiftUI

/// Loads a value asynchronously and tracks loading/error state.
/// Views hold one per request: `@State private var loader = Loader<[Archive]>()`.
@MainActor
@Observable
final class Loader<Value> {
    var value: Value?
    var error: String?
    var isLoading = false

    func load(_ work: () async throws -> Value) async {
        isLoading = true
        defer { isLoading = false }
        do {
            value = try await work()
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Standard container for a loader: spinner on first load, error with retry, then content.
struct LoadingContent<Value, Content: View>: View {
    let loader: Loader<Value>
    var retry: (() async -> Void)?
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        if let value = loader.value {
            content(value)
        } else if let error = loader.error {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let retry { Button("Try Again") { Task { await retry() } }.buttonStyle(.bordered) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Runs an action and presents any error as an alert. Attach with `.actionErrorAlert(runner)`.
@MainActor
@Observable
final class ActionRunner {
    var errorMessage: String?
    var isRunning = false
    var successMessage: String?

    func run(_ success: String? = nil, _ work: () async throws -> Void) async {
        isRunning = true
        defer { isRunning = false }
        do {
            try await work()
            if let success { successMessage = success }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    func actionAlerts(_ runner: ActionRunner) -> some View {
        modifier(ActionAlertModifier(runner: runner))
    }
}

private struct ActionAlertModifier: ViewModifier {
    @Bindable var runner: ActionRunner
    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: Binding(get: { runner.errorMessage != nil }, set: { if !$0 { runner.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(runner.errorMessage ?? "") }
            .overlay(alignment: .bottom) {
                if let msg = runner.successMessage {
                    Toast(message: msg, systemImage: "checkmark.circle.fill")
                        .task { try? await Task.sleep(for: .seconds(2)); runner.successMessage = nil }
                        .padding(.bottom, 24)
                }
            }
            .animation(.snappy, value: runner.successMessage)
    }
}

struct Toast: View {
    let message: String
    var systemImage: String = "info.circle.fill"
    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A small colored capsule for statuses and tags.
struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}

/// A filament color swatch (handles transparent / empty slots).
struct ColorSwatch: View {
    let hex: String?
    var size: CGFloat = 22
    var body: some View {
        Circle()
            .fill(Color(hex: hex) ?? .clear)
            .overlay { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
            .overlay {
                if Color(hex: hex) == nil {
                    Image(systemName: "questionmark").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
    }
}

/// Label/value row used across detail screens.
struct InfoRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    init(_ label: String, _ value: String?, systemImage: String? = nil) {
        self.label = label
        self.value = (value?.isEmpty ?? true) ? "—" : value!
        self.systemImage = systemImage
    }
    var body: some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        } label: {
            if let systemImage { Label(label, systemImage: systemImage) } else { Text(label) }
        }
    }
}

extension View {
    /// Confirmation dialog helper for destructive actions.
    func confirm(_ title: String, isPresented: Binding<Bool>, message: String? = nil, action: String = "Delete", role: ButtonRole? = .destructive, perform: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(action, role: role, action: perform)
        } message: {
            if let message { Text(message) }
        }
    }
}

/// A read-only placeholder for sections that are not yet available natively.
struct OpenInWebView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    let title: String
    let webPath: String
    var systemImage: String = "safari"
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("This section is available in the Bambuddy web interface.")
        } actions: {
            if let base = session.serverURL {
                Button("Open in Browser") { openURL(base.appending(path: webPath)) }.buttonStyle(.borderedProminent)
            }
        }
    }
}
