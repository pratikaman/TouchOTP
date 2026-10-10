import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State private var accessibility = AXIsProcessTrusted()
    @State private var testing = false
    @State private var message: String?
    @State private var testSucceeded = false
    @State private var confirmReset = false
    let shortcutAvailable: Bool

    private var canReset: Bool { !vault.accounts.isEmpty || vault.needsMigration }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Autofill setup").font(TouchStyle.title(22)).foregroundStyle(TouchStyle.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.warmSecondary).keyboardShortcut(.cancelAction).disabled(testing)
            }
            GroupSurface {
                HStack(spacing: 12) {
                    setupGlyph("hand.point.up.left.fill")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(TouchStyle.ink)
                        Text(accessibility ? "TouchOTP can fill the field you select." : "Allow TouchOTP to insert codes into other apps.")
                            .font(.caption).foregroundStyle(TouchStyle.muted)
                    }
                    Spacer()
                    if accessibility {
                        Label("On", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(TouchStyle.sage)
                            .accessibilityLabel("Enabled")
                    }
                    else { Button("Enable…", action: Self.openAccessibility).buttonStyle(.warmPrimary) }
                }.padding(16)
                Rectangle().fill(TouchStyle.border).frame(height: 1).padding(.leading, 62)
                HStack(spacing: 12) {
                    setupGlyph("touchid")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Touch ID").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(TouchStyle.ink)
                        Text("Confirm your fingerprint and protected storage.").font(.caption).foregroundStyle(TouchStyle.muted)
                    }
                    Spacer()
                    Button(testing ? "Checking…" : "Test Touch ID") { test() }.buttonStyle(.warmSecondary).disabled(testing)
                }.padding(16)
            }
            if let message { InlineNotice(text: message, success: testSucceeded) }
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("To fill a code").font(TouchStyle.title(15)).foregroundStyle(TouchStyle.ink); Spacer(); ShortcutKeys() }
                InstructionRow(number: 1, title: "Click the code field", detail: "Select an empty verification-code box in a linked website or app.")
                InstructionRow(number: 2, title: "Press Control + Option + Command + O", detail: "Keep the website or app in front while you use Touch ID.")
                InstructionRow(number: 3, title: "Confirm with your fingerprint", detail: "TouchOTP fills the matching code. You control when to submit.")
            }
            if !shortcutAvailable { InlineNotice(text: "Another app is using the shortcut. Choose Fill current field from TouchOTP’s menu bar instead.") }
            Text("For Safari or Chrome, macOS may also ask to let TouchOTP read the active tab. Allow this in Privacy & Security → Automation.")
                .font(.caption).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(TouchStyle.border).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Start over").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(TouchStyle.ink)
                    Text("Removes every account and its protected codes from this Mac. Needed after your enrolled fingerprints change, because the vault can no longer be read.")
                        .font(.caption).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(role: .destructive) { confirmReset = true } label: { Text("Remove all accounts…").foregroundStyle(TouchStyle.coral) }
                    .buttonStyle(.warmSecondary).disabled(testing || !canReset)
            }
            Rectangle().fill(TouchStyle.border).frame(height: 1)
            HStack {
                Label("Codes stay on this Mac", systemImage: "lock").font(.caption).foregroundStyle(TouchStyle.muted)
                Spacer()
                Text("TouchOTP \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(TouchStyle.faint)
            }
        }.padding(26).frame(width: 510).background(TouchStyle.background).tint(TouchStyle.honeyText)
            .interactiveDismissDisabled(testing)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in accessibility = AXIsProcessTrusted() }
            .confirmationDialog("Remove all accounts from TouchOTP?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Remove all with Touch ID", role: .destructive, action: reset)
            } message: {
                Text("Google Authenticator keeps its copies. Import the accounts again from your phone afterwards.")
            }
    }

    private func setupGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(TouchStyle.honeyText)
            .frame(width: 34, height: 34).background(TouchStyle.selection, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
    private func reset() {
        testing = true; message = nil
        Task {
            do { try await vault.removeAllAccounts(); message = "All accounts were removed."; testSucceeded = true }
            catch where !Vault.isCancellation(error) { message = error.localizedDescription; testSucceeded = false }
            catch {}
            testing = false
        }
    }
}
