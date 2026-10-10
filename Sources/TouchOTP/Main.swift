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

extension Notification.Name {
    /// Posted when the menu bar popover asks the manager window to open its import sheet.
    static let touchOTPImportRequested = Notification.Name("local.touchotp.importRequested")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let vault = CommandLine.arguments.contains("--render-preview")
        ? Vault(previewAccounts: CommandLine.arguments.contains("--preview-empty") ? [] : PreviewSupport.accounts)
        : Vault()
    private lazy var codeModel = CodeListModel(vault: vault)
    private let shortcut = GlobalShortcut()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var window: NSWindow?
    private var chooser: NSPanel?
    private var touchIDHost: NSWindow?
    private var busy = false
    private var shortcutAvailable = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--keychain-probe") {
            print(KeychainProbe.report())
            NSApp.terminate(nil)
            return
        }
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
            let codes = CommandLine.arguments.contains("--preview-codes")
            let root: AnyView
            if codes {
                // Unlocked preview uses published RFC-style seeds, never protected storage.
                let model = CommandLine.arguments.contains("--preview-locked")
                    ? CodeListModel(vault: vault)
                    : CodeListModel(vault: vault, previewUnlocked: PreviewSupport.protectedAccounts)
                root = AnyView(CodeListView(vault: vault, model: model).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-review") {
                root = AnyView(ImportView(vault: vault, previewCollector: PreviewSupport.importCollector).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-complete") {
                root = AnyView(ImportView(vault: vault, previewImported: true).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-import") {
                root = AnyView(ImportView(vault: vault).preferredColorScheme(appearance))
            } else if CommandLine.arguments.contains("--preview-setup") {
                root = AnyView(SetupView(vault: vault, shortcutAvailable: true).preferredColorScheme(appearance))
            } else {
                root = AnyView(ManagerView(vault: vault, shortcutAvailable: true).preferredColorScheme(appearance))
            }
            let view = NSHostingView(rootView: root)
            let size: NSSize
            if codes {
                let fitting = view.fittingSize
                size = fitting.height > 0 ? fitting : NSSize(width: 340, height: 480)
            } else {
                size = CommandLine.arguments.contains("--preview-compact") ? NSSize(width: 780, height: 570) : NSSize(width: 900, height: 650)
            }
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
        statusItem.button?.toolTip = "TouchOTP · Click for codes · ⌃⌥⌘O to fill"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let codes = NSMenuItem(title: "Show codes…", action: #selector(showCodes), keyEquivalent: "")
        codes.target = self; menu.addItem(codes)
        let fill = NSMenuItem(title: "Fill current field     ⌃⌥⌘O", action: #selector(fillCurrent), keyEquivalent: "")
        fill.target = self; menu.addItem(fill)
        let manage = NSMenuItem(title: "Manage accounts…", action: #selector(showManager), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TouchOTP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        shortcut.action = { [weak self] in self?.fillCurrent() }
        shortcutAvailable = shortcut.register()
        showManager()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager(); return true
    }

    // MARK: Menu bar

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // The classic menu does not activate TouchOTP, so "Fill current field" still targets the front app.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc func showCodes() {
        if popover?.isShown != true { togglePopover() }
    }

    private func togglePopover() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = CodeListView(vault: vault, model: codeModel, manage: { [weak self] in
            self?.showManager()
            self?.popover?.performClose(nil)
        }, importAccounts: { [weak self] in
            self?.showManager()
            self?.popover?.performClose(nil)
            NotificationCenter.default.post(name: .touchOTPImportRequested, object: nil)
        }, quit: { NSApp.terminate(nil) })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        codeModel.touchIDHost = { [weak self] in self?.showTouchIDHost() }
        codeModel.touchIDEnded = { [weak self] in self?.hideTouchIDHost() }
        return popover
    }

    /// Touch ID for the popover is presented against this transparent strip along the popover's bottom edge.
    /// Left to itself, macOS attaches the prompt as a sheet to whichever window is key: inside the popover it
    /// can draw blank, and with the manager window open it lands there, hidden. Given this window instead,
    /// macOS shows its standalone Touch ID dialog, which runs in a separate system agent. That dialog only
    /// arms the sensor once it has focus, and since macOS 14 an active app must yield activation before
    /// another app can take it; without the yield, the dialog stays gray and ignores fingers.
    private func showTouchIDHost() -> NSWindow? {
        guard let anchor = popover?.contentViewController?.view.window, anchor.isVisible else { return nil }
        let host = touchIDHost ?? {
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            touchIDHost = window
            return window
        }()
        host.level = anchor.level
        host.setFrame(NSRect(x: anchor.frame.minX, y: anchor.frame.minY - 2, width: anchor.frame.width, height: 2), display: false)
        host.orderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.LocalAuthentication.UIAgent")
        }
        return host
    }

    private func hideTouchIDHost() {
        guard let host = touchIDHost, host.isVisible else { return }
        host.orderOut(nil)
        // Take focus back from the Touch ID agent so the popover's buttons respond right away.
        if popover?.isShown == true { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Keep the popover up while a Touch ID sheet is attached to it; a dismissed popover drops the codes.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !codeModel.busy && popover.contentViewController?.view.window?.attachedSheet == nil
    }

    func popoverDidClose(_ notification: Notification) {
        codeModel.lock()
        // Return focus to the app the user came from when nothing else of ours is open.
        if window?.isVisible != true, chooser == nil { NSApp.hide(nil) }
    }

    @objc func showManager() {
        if window == nil {
            let controller = NSHostingController(rootView: ManagerView(vault: vault, shortcutAvailable: shortcutAvailable))
            let created = NSWindow(contentViewController: controller)
            created.title = "TouchOTP"
            created.setContentSize(NSSize(width: 900, height: 650))
            created.contentMinSize = NSSize(width: 780, height: 570)
            created.titlebarAppearsTransparent = true
            created.backgroundColor = NSColor(TouchStyle.background)
            created.toolbarStyle = .unified
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Autofill

    @objc func fillCurrent() {
        guard !busy else { return }
        busy = true
        FillDiagnostics.begin()
        Task {
            do {
                guard !vault.needsMigration else { throw OTPError(Vault.migrationMessage) }
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
                if !Vault.isCancellation(error) { present(error) }
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
            Text("Choose an account").font(TouchStyle.title(15)).foregroundStyle(TouchStyle.ink)
            Text("Confirm with Touch ID next.").font(.caption).foregroundStyle(TouchStyle.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(accounts) { account in
                        Button { select(account) } label: {
                            HStack(spacing: 10) {
                                AccountSymbol(issuer: account.issuer, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.issuer).font(.system(size: 13, weight: .semibold)).foregroundStyle(TouchStyle.ink)
                                    Text(account.username).font(.caption).foregroundStyle(TouchStyle.muted).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(TouchStyle.faint)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(TouchStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TouchStyle.border))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button("Cancel", action: cancel).buttonStyle(.warmSecondary)
        }.padding(20).frame(width: 350, height: 230).background(TouchStyle.background)
    }
}
