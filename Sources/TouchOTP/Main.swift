import AppKit
import SwiftUI
import LocalAuthentication
import TouchOTPCore

@main
struct TouchOTPMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vault = CommandLine.arguments.contains("--render-preview")
        ? Vault(previewAccounts: CommandLine.arguments.contains("--preview-empty") ? [] : PreviewSupport.accounts)
        : Vault()
    private let shortcut = GlobalShortcut()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var chooser: NSPanel?
    private var busy = false
    private var shortcutAvailable = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--storage-check") {
            Task {
                let result = await Vault.storageCheck()
                print(result)
                // Only the synthetic diagnostic result is written, never a secret or real account.
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("touchotp-storage-check.txt")
                try? result.write(to: destination, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if let argument = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > argument + 1 {
            let appearance: ColorScheme = CommandLine.arguments.contains("--preview-dark") ? .dark : .light
            let root: AnyView
            if CommandLine.arguments.contains("--preview-review") {
                root = AnyView(ImportView(vault: vault, previewCollector: PreviewSupport.importCollector).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-complete") {
                root = AnyView(ImportView(vault: vault, previewImported: true).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-import") {
                root = AnyView(ImportView(vault: vault).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-setup") {
                root = AnyView(SetupView(shortcutAvailable: true).preferredColorScheme(appearance))
            } else {
                root = AnyView(ManagerView(vault: vault, shortcutAvailable: true).preferredColorScheme(appearance))
            }
            let view = NSHostingView(rootView: root)
            let size = CommandLine.arguments.contains("--preview-compact") ? NSSize(width: 780, height: 570) : NSSize(width: 900, height: 650)
            let previewWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            previewWindow.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            previewWindow.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[argument + 1]))
                    }
                }
                withExtendedLifetime(previewWindow) { NSApp.terminate(nil) }
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "TouchOTP")
        statusItem.button?.toolTip = "TouchOTP · ⌃⌥⌘O to fill"
        let menu = NSMenu()
        let fill = NSMenuItem(title: "Fill current field     ⌃⌥⌘O", action: #selector(fillCurrent), keyEquivalent: "")
        fill.target = self; menu.addItem(fill)
        let manage = NSMenuItem(title: "Manage accounts…", action: #selector(showManager), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TouchOTP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        shortcut.action = { [weak self] in self?.fillCurrent() }
        shortcutAvailable = shortcut.register()
        showManager()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager(); return true
    }

    @objc func showManager() {
        if window == nil {
            let controller = NSHostingController(rootView: ManagerView(vault: vault, shortcutAvailable: shortcutAvailable))
            let created = NSWindow(contentViewController: controller)
            created.title = "TouchOTP"
            created.setContentSize(NSSize(width: 900, height: 650))
            created.contentMinSize = NSSize(width: 780, height: 570)
            created.titlebarAppearsTransparent = true
            created.toolbarStyle = .unified
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func fillCurrent() {
        guard !busy else { return }
        busy = true
        FillDiagnostics.begin()
        Task {
            do {
                let target = try await TargetReader.capture()
                FillDiagnostics.stage(.matchAccount)
                let matches = vault.accounts.filter(target.matches)
                guard !matches.isEmpty else {
                    let destination = target.url?.host ?? target.bundleID
                    throw OTPError("No account is linked to \(destination). Open Manage accounts, select your account, and add this exact \(target.url == nil ? "Mac app" : "website") destination.")
                }
                if matches.count == 1 { performFill(matches[0], target: target) }
                else { choose(matches, target: target) }
            } catch {
                FillDiagnostics.finish(.failed)
                busy = false
                present(error)
            }
        }
    }

    private func choose(_ accounts: [AccountRecord], target: FillTarget) {
        FillDiagnostics.stage(.chooseAccount)
        // Nonactivating panel preserves focus in the destination app.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 250),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Choose account for \(target.description)"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: AccountChooser(accounts: accounts, select: { [weak self] account in
            self?.chooser?.orderOut(nil); self?.chooser = nil
            self?.performFill(account, target: target)
        }, cancel: { [weak self] in
            FillDiagnostics.finish(.cancelled)
            self?.chooser?.orderOut(nil); self?.chooser = nil; self?.busy = false
        }))
        panel.center(); panel.orderFrontRegardless(); chooser = panel
    }

    private func performFill(_ account: AccountRecord, target: FillTarget) {
        statusItem.button?.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "Authenticating")
        Task {
            defer {
                busy = false
                statusItem.button?.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "TouchOTP")
            }
            do {
                FillDiagnostics.stage(.authenticate)
                let payload = try await vault.unlock(account, reason: "Fill \(account.issuer) (\(account.username)) on \(target.description)")
                guard target.matches(payload.record) else { throw OTPError("This account is not authorized for that destination.") }
                // Wait for a fresh code only when the current time step is almost over.
                let remaining = payload.otp.remaining()
                if remaining < min(3, Double(payload.otp.period) / 2) {
                    try await Task.sleep(nanoseconds: UInt64((remaining + 0.1) * 1_000_000_000))
                }
                try await TargetReader.fill(payload.otp.code(), target: target)
                FillDiagnostics.finish(.completed)
            } catch {
                FillDiagnostics.finish(.failed)
                let nsError = error as NSError
                if nsError.domain != LAError.errorDomain || ![LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue].contains(nsError.code) {
                    present(error)
                }
            }
        }
    }

    private func present(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "TouchOTP couldn’t fill this field"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Manage accounts")
        if alert.runModal() == .alertSecondButtonReturn { showManager() }
    }
}

struct AccountChooser: View {
    let accounts: [AccountRecord]
    let select: (AccountRecord) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an account").font(.headline)
            Text("Confirm with Touch ID next.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(accounts) { account in
                        Button { select(account) } label: {
                            HStack(spacing: 10) {
                                AccountSymbol(issuer: account.issuer, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.issuer).font(.system(size: 13, weight: .medium))
                                    Text(account.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                }
            }
            Button("Cancel", action: cancel)
        }.padding(20).frame(width: 350, height: 230)
    }
}
