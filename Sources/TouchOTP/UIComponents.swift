import SwiftUI
import AppKit
import TouchOTPCore

/// Warm palette: linen paper, walnut ink, honey-brass accent. Every token adapts to dark mode,
/// where the paper becomes a warm charcoal rather than a neutral grey.
enum TouchStyle {
    static let background = Color(light: 0xFAF6F0, dark: 0x1D1916)
    static let sidebar = Color(light: 0xF3ECE2, dark: 0x181512)
    static let surface = Color(light: 0xFFFDF9, dark: 0x27211C)
    static let well = Color(light: 0xF1E8DC, dark: 0x302822)
    static let border = Color(light: 0xE8DDCE, dark: 0x3B312A)
    static let ink = Color(light: 0x2D241C, dark: 0xF3EBE1)
    static let muted = Color(light: 0x7B6C5E, dark: 0xA6978A)
    static let faint = Color(light: 0xB9AC9E, dark: 0x6E6157)
    /// Fill for primary actions; text on it uses `onHoney`.
    static let honey = Color(light: 0xF0A93E, dark: 0xF2B357)
    static let onHoney = Color(light: 0x2E1F0C, dark: 0x2A1C0A)
    /// Accent for text and glyphs on paper; darker than `honey` in light mode for contrast.
    static let honeyText = Color(light: 0xA45F0E, dark: 0xF2B357)
    static let selection = Color(light: 0xF8E2BC, dark: 0x463620)
    static let coral = Color(light: 0xD0543A, dark: 0xF07D61)
    static let sage = Color(light: 0x4C875A, dark: 0x82BE8D)

    static func code(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum CodeFormat {
    /// "123456" → "123 456" for readability; the inserted code is never grouped.
    static func grouped(_ value: String) -> String {
        let split = value.index(value.startIndex, offsetBy: value.count / 2)
        return String(value[..<split]) + " " + String(value[split...])
    }
}

/// A soft, tinted key tag carrying the issuer's initial. The tint comes from a stable FNV-1a hash of
/// the name (not `hashValue`, which changes per launch), so an account keeps its color.
struct AccountSymbol: View {
    let issuer: String
    var size: CGFloat = 34
    private static let tints: [(Color, Color)] = [
        (Color(light: 0xFCE1C8, dark: 0x4A3020), Color(light: 0x9E4F10, dark: 0xF7B27A)), // apricot
        (Color(light: 0xF9EAC0, dark: 0x45381A), Color(light: 0x82600A, dark: 0xEDC66A)), // honey
        (Color(light: 0xDDEAD6, dark: 0x26382A), Color(light: 0x3D6B44, dark: 0x9CCB9F)), // sage
        (Color(light: 0xF7DADA, dark: 0x45272A), Color(light: 0x9C3B46, dark: 0xEFA2A8)), // rose
        (Color(light: 0xE5DEF0, dark: 0x322B42), Color(light: 0x5C4887, dark: 0xBCAEE3)), // dusk
        (Color(light: 0xDAE6EE, dark: 0x233340), Color(light: 0x386282, dark: 0x9CC2DE))  // slate
    ]
    private var tint: (Color, Color) {
        let hash = issuer.lowercased().utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return Self.tints[Int((hash >> 33) % UInt64(Self.tints.count))]
    }
    private var initial: String? {
        issuer.trimmingCharacters(in: .whitespaces).first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.0)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(tint.1.opacity(0.12))
            if let initial {
                Text(initial).font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "key.horizontal.fill").font(.system(size: size * 0.4, weight: .semibold))
            }
        }
        .foregroundStyle(tint.1)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Primary actions are honey with dark text (white on honey fails contrast); secondary sit in a
/// recessed well; quiet ones are honey text only.
struct WarmButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var large = false
    var fill = false
    func makeBody(configuration: Configuration) -> some View {
        WarmButton(configuration: configuration, kind: kind, large: large, fill: fill)
    }
    private struct WarmButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let large: Bool
        let fill: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
            configuration.label
                .font(.system(size: large ? 13.5 : 12.5, weight: kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, kind == .quiet ? 2 : large ? 16 : 11)
                .padding(.vertical, kind == .quiet ? 2 : large ? 9 : 5)
                .frame(maxWidth: fill ? .infinity : nil)
                .foregroundStyle(kind == .primary ? TouchStyle.onHoney : kind == .quiet ? TouchStyle.honeyText : TouchStyle.ink)
                .background {
                    switch kind {
                    case .primary: shape.fill(TouchStyle.honey).overlay(shape.strokeBorder(.black.opacity(0.06)))
                    case .secondary: shape.fill(TouchStyle.well).overlay(shape.strokeBorder(TouchStyle.border))
                    case .quiet: EmptyView()
                    }
                }
                .contentShape(shape)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension ButtonStyle where Self == WarmButtonStyle {
    static var warmPrimary: WarmButtonStyle { WarmButtonStyle(kind: .primary) }
    static var warmSecondary: WarmButtonStyle { WarmButtonStyle(kind: .secondary) }
    static var warmQuiet: WarmButtonStyle { WarmButtonStyle(kind: .quiet) }
    static func warm(_ kind: WarmButtonStyle.Kind, large: Bool = false, fill: Bool = false) -> WarmButtonStyle {
        WarmButtonStyle(kind: kind, large: large, fill: fill)
    }
}

/// Countdown ring for a code's remaining validity; turns coral in the last few seconds.
struct CountdownRing: View {
    let fraction: Double
    var urgent = false
    var lineWidth: CGFloat = 2.5
    var body: some View {
        ZStack {
            Circle().stroke(TouchStyle.well, lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(urgent ? TouchStyle.coral : TouchStyle.honey, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct ShortcutKeys: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["⌃", "⌥", "⌘", "O"], id: \.self) { key in
                // Keycaps sit on a slightly darker lip so they read as physical keys.
                Text(key).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(TouchStyle.ink)
                    .frame(width: 23, height: 22)
                    .background(TouchStyle.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(TouchStyle.border))
                    .padding(.bottom, 2)
                    .background(TouchStyle.border, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Control Option Command O")
    }
}

struct InlineNotice: View {
    let text: String
    var success = false
    var body: some View {
        Label {
            Text(text).font(.callout).foregroundStyle(TouchStyle.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(success ? TouchStyle.sage : TouchStyle.coral)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background((success ? TouchStyle.sage : TouchStyle.coral).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct GroupSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TouchStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TouchStyle.border))
            .shadow(color: Color(light: 0x6B4A22, dark: 0x000000).opacity(0.06), radius: 6, y: 2)
    }
}

struct NativeAppPresentation {
    let name: String
    let icon: NSImage
    let installed: Bool
    init(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            icon = NSWorkspace.shared.icon(forFile: url.path)
            installed = true
        } else {
            name = bundleID
            icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
            installed = false
        }
    }
}

struct InstructionRow: View {
    let number: Int
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(TouchStyle.honeyText).frame(width: 24, height: 24)
                .background(TouchStyle.selection, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(TouchStyle.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(TouchStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
