import SwiftUI
import AppKit

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accessibility = AXIsProcessTrusted()
    @State private var testing = false
    @State private var message: String?
    @State private var testSucceeded = false
    let shortcutAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Autofill setup").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(testing)
            }
            GroupSurface {
                HStack(spacing: 12) {
                    Image(systemName: "hand.point.up.left").font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility").font(.headline)
                        Text(accessibility ? "TouchOTP can fill the field you select." : "Allow TouchOTP to insert codes into other apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if accessibility { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Enabled") }
                    else { Button("Enable…", action: Self.openAccessibility).buttonStyle(.borderedProminent) }
                }.padding(16)
                Divider().padding(.leading, 58)
                HStack(spacing: 12) {
                    Image(systemName: "touchid").font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Touch ID").font(.headline)
                        Text("Confirm your fingerprint and protected storage.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(testing ? "Checking…" : "Test Touch ID") { test() }.disabled(testing)
                }.padding(16)
            }
            if let message { InlineNotice(text: message, success: testSucceeded) }
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("To fill a code").font(.headline); Spacer(); ShortcutKeys() }
                InstructionRow(number: 1, title: "Click the code field", detail: "Select an empty verification-code box in a linked website or app.")
                InstructionRow(number: 2, title: "Press Control + Option + Command + O", detail: "Keep the website or app in front while you use Touch ID.")
                InstructionRow(number: 3, title: "Confirm with your fingerprint", detail: "TouchOTP fills the matching code. You control when to submit.")
            }
            if !shortcutAvailable { InlineNotice(text: "Another app is using the shortcut. Choose Fill current field from TouchOTP’s menu bar instead.") }
            Text("For Safari or Chrome, macOS may also ask to let TouchOTP read the active tab. Allow this in Privacy & Security → Automation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Label("Codes stay on this Mac", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("TouchOTP \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(26).frame(width: 510).background(TouchStyle.background)
            .interactiveDismissDisabled(testing)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in accessibility = AXIsProcessTrusted() }
    }

    static func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func test() {
        testing = true; message = nil
        Task {
            do { try await Vault.biometricCheck(); message = "Touch ID is ready."; testSucceeded = true }
            catch { message = error.localizedDescription; testSucceeded = false }
            testing = false
        }
    }
}
