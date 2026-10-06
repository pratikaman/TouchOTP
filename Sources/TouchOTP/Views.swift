import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TouchOTPCore

struct ManagerView: View {
    @ObservedObject var vault: Vault
    @State private var selected: UUID?
    @State private var importing = false
    @State private var accessibility = AXIsProcessTrusted()
    @State private var message: String?
    @State private var testing = false
    let shortcutAvailable: Bool

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Label("TouchOTP", systemImage: "touchid").font(.system(size: 23, weight: .semibold)).padding(22)
                List(vault.accounts, selection: $selected) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.issuer).font(.headline)
                        Text(account.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 5).tag(account.id)
                }
                Button { importing = true } label: { Label("Import accounts", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(20).disabled(vault.loadError != nil)
            }.navigationSplitViewColumnWidth(min: 225, ideal: 245)
        } detail: {
            if let account = vault.accounts.first(where: { $0.id == selected }) {
                AccountDetail(vault: vault, record: account).id(account.secretID)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "touchid").font(.system(size: 50)).foregroundStyle(.tint)
                    Text("Your codes. One touch away.").font(.system(size: 28, weight: .semibold))
                    Text("Import your authenticator accounts, then choose which websites and Mac apps each account can fill.")
                        .font(.title3).foregroundStyle(.secondary)
                    Divider()
                    Label("Focus an empty verification-code field", systemImage: "1.circle")
                    Label("Press Control + Option + Command + O", systemImage: "2.circle")
                    Label("Use Touch ID to insert the matching code", systemImage: "3.circle")
                    Text("Runs locally. Codes stay off the clipboard. Each fill requires Touch ID.").font(.callout).foregroundStyle(.secondary)
                    if !accessibility {
                        Button("Enable Accessibility…") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }.buttonStyle(.borderedProminent)
                    } else { Label("Accessibility enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button(testing ? "Waiting for Touch ID…" : "Test Touch ID…") {
                        testing = true; message = nil
                        Task {
                            do { try await Vault.biometricCheck(); message = "Touch ID and protected storage are working." }
                            catch { message = error.localizedDescription }
                            testing = false
                        }
                    }.disabled(testing)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if !shortcutAvailable { Text("The shortcut is already used by another app. Use Fill current field from the menu bar.").foregroundStyle(.orange) }
                    if let error = vault.loadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Text("Safari, Chrome, Edge, Brave, Arc and Vivaldi use their active-tab URL. Native apps use the app you link. Embedded login frames and some custom or split code fields may need manual entry.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(36).frame(maxWidth: 660, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 850, minHeight: 610)
        .sheet(isPresented: $importing) { ImportView(vault: vault) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in accessibility = AXIsProcessTrusted() }
    }
}

struct AccountDetail: View {
    @ObservedObject var vault: Vault
    let record: AccountRecord
    @State private var hosts = ""
    @State private var apps = ""
    @State private var busy = false
    @State private var message: String?
    @State private var code: String?
    @State private var expires: Date?
    @State private var deleting = false
    @State private var revealGeneration = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(record.issuer).font(.largeTitle.bold())
                Text(record.username).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Websites").font(.headline)
                    Text("Exact login hostnames, separated by commas. For example: accounts.google.com, github.com").font(.caption).foregroundStyle(.secondary)
                    TextField("accounts.example.com", text: $hosts).textFieldStyle(.roundedBorder)
                    Text("Use the hostname visible when the site asks for your code. An issuer name does not automatically authorize a website.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mac apps").font(.headline)
                    TextField("App bundle identifiers, separated by commas", text: $apps).textFieldStyle(.roundedBorder)
                    Button("Choose application…") { chooseApp() }
                    Text("Only link an app you trust to receive this account’s codes. Browser accounts must use website hostnames.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Save destinations with Touch ID") { save() }.buttonStyle(.borderedProminent).disabled(busy)
                Divider()
                if let code, let expires {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(code).font(.system(size: 36, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        Text("Valid until \(expires.formatted(date: .omitted, time: .standard)). Hidden automatically.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { reveal() } label: { Label("Show code with Touch ID", systemImage: "touchid") }.disabled(busy)
                    Spacer()
                    Button("Remove account…", role: .destructive) { deleting = true }.disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Adding or removing a fingerprint makes these protected secrets unavailable. Keep Google Authenticator as your backup; you can reimport after removing the old entry.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }
        .onAppear { hosts = record.bindings.hosts.joined(separator: ", "); apps = record.bindings.bundleIDs.joined(separator: ", ") }
        .onDisappear { code = nil; revealGeneration = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in code = nil }
        .confirmationDialog("Remove this account from TouchOTP? Google Authenticator is unaffected.", isPresented: $deleting) {
            Button("Remove with Touch ID", role: .destructive) {
                busy = true
                Task {
                    do { try await vault.remove(record) } catch { message = error.localizedDescription }
                    busy = false
                }
            }
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        if TargetReader.safari.contains(id) || TargetReader.chromium.contains(id) ||
            (bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []).contains(where: {
                ($0["CFBundleURLSchemes"] as? [String] ?? []).contains("https")
            }) {
            message = "For a browser, add the login website under Websites instead."; return
        }
        var current = apps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !current.contains(id) { current.append(id) }
        apps = current.joined(separator: ", ")
    }
    func save() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                let hostList = try hosts.split(separator: ",").map { try Bindings.canonicalHost(String($0)) }
                let appList = try apps.split(separator: ",").map { try Bindings.validateBundleID(String($0)) }
                try await vault.update(record, bindings: Bindings(hosts: Array(Set(hostList)).sorted(), bundleIDs: Array(Set(appList)).sorted()))
                message = "Destinations saved."
            } catch { message = error.localizedDescription }
        }
    }
    func reveal() {
        busy = true; message = nil; code = nil
        let generation = UUID(); revealGeneration = generation
        Task {
            do {
                let payload = try await vault.unlock(record, reason: "Show the verification code for \(record.issuer)")
                guard revealGeneration == generation else { busy = false; return }
                let now = Date()
                code = try payload.otp.code(at: now)
                expires = now.addingTimeInterval(payload.otp.remaining(at: now))
                busy = false
                try await Task.sleep(nanoseconds: UInt64(payload.otp.remaining(at: now) * 1_000_000_000))
                if revealGeneration == generation { code = nil }
            } catch { message = error.localizedDescription; busy = false }
        }
    }
}

struct ImportView: View {
    @ObservedObject var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()
    @State private var camera = false
    @State private var uri = ""
    @State private var collector = BatchCollector()
    @State private var message: String?
    @State private var busy = false
    @State private var imported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import your authenticator accounts").font(.title2.bold())
            Text("On your phone, open Google Authenticator → Transfer accounts → Export accounts. Select the accounts and show each export QR to this Mac’s camera.")
                .foregroundStyle(.secondary)
            Text("QR codes contain your secret keys. Scan them here locally; do not send them in chat. Your phone keeps working after import.").font(.callout)
            if camera && !collector.complete {
                CameraPreview(session: scanner.session).frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 10))
                    .task { await scanner.start { text in ingest(text) } }
                    .onDisappear { scanner.stop() }
            }
            if let error = scanner.error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button(camera ? "Stop camera" : "Scan with camera") { camera.toggle(); if !camera { scanner.stop() } }
                    .disabled(busy || collector.complete)
                Button("Choose QR image…") { chooseImage() }.disabled(busy || collector.complete)
            }
            DisclosureGroup("Or enter an authenticator setup link") {
                HStack {
                    SecureField("otpauth://… or otpauth-migration://…", text: $uri).textFieldStyle(.roundedBorder)
                    Button("Read") { ingest(uri); uri = "" }.disabled(uri.isEmpty || busy || collector.complete)
                }.padding(.top, 8)
            }
            if collector.received > 0 {
                Text("\(collector.received) of \(collector.expected) QR codes scanned · \(collector.accounts.count) accounts").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(collector.accounts.enumerated()), id: \.offset) { _, account in
                            Text("\(account.issuer) — \(account.username)").font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
            if let message { Text(message).font(.callout).foregroundStyle(imported ? .green : .orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(imported ? "Done" : "Cancel") { dismiss() }.disabled(busy)
                if !imported {
                    Button("Import \(collector.accounts.count) accounts") { commit() }
                        .buttonStyle(.borderedProminent).disabled(!collector.complete || busy)
                }
                if busy { ProgressView().controlSize(.small) }
            }
        }.padding(28).frame(width: 580)
        .interactiveDismissDisabled(busy)
        .onDisappear { scanner.stop(); collector = BatchCollector(); uri = "" }
    }
    func ingest(_ text: String) {
        guard !collector.complete, !busy else { return }
        do {
            try collector.add(OTPImporter.parse(text))
            message = nil
            if collector.complete { scanner.stop(); camera = false }
        } catch { message = "QR read, but the account data could not be imported: " + error.localizedDescription }
    }
    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do { for url in panel.urls { for text in try QRImageReader.read(url) { ingest(text) } } }
        catch { message = error.localizedDescription }
    }
    func commit() {
        busy = true
        Task {
            do {
                let result = try await vault.importAccounts(collector.accounts)
                message = "Imported \(result.added) accounts. Skipped \(result.skipped) existing accounts. Select each account to set its allowed websites or apps."
                imported = true
                collector = BatchCollector(); uri = ""
            } catch { message = "Import failed: \(error.localizedDescription)" }
            busy = false
        }
    }
}
