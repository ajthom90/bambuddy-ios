import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders QR codes locally with Core Image.
enum AdminQRCode {
    static func image(for text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// A QR code on a white card (so it scans in dark mode too).
struct AdminQRCodeView: View {
    let text: String
    var fallbackPNGBase64: String?
    var size: CGFloat = 220

    var body: some View {
        Group {
            if let image = AdminQRCode.image(for: text) ?? fallbackImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(12)
        .background(.white, in: .rect(cornerRadius: 12))
        .accessibilityLabel("QR code")
    }

    private var fallbackImage: UIImage? {
        guard let b64 = fallbackPNGBase64, let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
}

/// A one-time secret with copy and share actions.
struct AdminSecretField: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack {
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                ShareLink(item: value) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shown when a screen needs server-side sign-in, which is currently off.
struct AdminAuthDisabledView: View {
    var feature: String
    var body: some View {
        ContentUnavailableView {
            Label("Sign-In Is Off", systemImage: "person.badge.key")
        } description: {
            Text("\(feature) requires authentication to be enabled on the server. Turn it on from the web interface's user settings.")
        }
    }
}

/// Password policy enforced by the server; mirrored here to give early feedback.
enum AdminPasswordPolicy {
    static func problem(_ password: String) -> String? {
        if password.count < 8 { return "Use at least 8 characters." }
        if password.rangeOfCharacter(from: .uppercaseLetters) == nil { return "Add an uppercase letter." }
        if password.rangeOfCharacter(from: .lowercaseLetters) == nil { return "Add a lowercase letter." }
        if password.rangeOfCharacter(from: .decimalDigits) == nil { return "Add a digit." }
        if password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil { return "Add a symbol." }
        return nil
    }
}

extension AdminGroup {
    /// Accent for the built-in groups, neutral for custom ones.
    var badgeColor: Color {
        switch name {
        case "Administrators": .purple
        case "Operators": .blue
        case "Viewers": .green
        default: .secondary
        }
    }
}
