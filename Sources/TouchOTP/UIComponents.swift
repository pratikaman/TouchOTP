import SwiftUI
import AppKit
import TouchOTPCore

enum TouchStyle {
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let border = Color.primary.opacity(0.08)
}

struct AccountSymbol: View {
    let issuer: String
    var size: CGFloat = 34
    private var symbol: String {
        let name = issuer.lowercased()
        if name.contains("vpn") { return "network" }
        if name.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if name.contains("google") || name.contains("mail") { return "envelope" }
        if name.contains("amazon") || name.contains("aws") { return "cloud" }
        return "key.horizontal"
    }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

struct ShortcutKeys: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["⌃", "⌥", "⌘", "O"], id: \.self) { key in
                Text(key).font(.system(size: 12, weight: .medium))
                    .frame(width: 23, height: 23)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08)))
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
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(success ? Color.green : Color.orange)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background((success ? Color.green : Color.orange).opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct GroupSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TouchStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TouchStyle.border))
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
            Text("\(number)").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 24, height: 24)
                .background(.primary.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
