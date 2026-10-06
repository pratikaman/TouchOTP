import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TouchOTPCore

struct ImportView: View {
    @ObservedObject var vault: Vault
    var onComplete: (UUID?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()
    @State private var camera = false
    @State private var uri = ""
    @State private var collector = BatchCollector()
    @State private var message: String?
    @State private var busy = false
    @State private var imported = false
    @State private var added = 0
    @State private var skipped = 0
    @State private var firstAccount: UUID?

    init(vault: Vault, previewCollector: BatchCollector? = nil, previewImported: Bool = false,
         onComplete: @escaping (UUID?) -> Void = { _ in }) {
        self.vault = vault; self.onComplete = onComplete
        _collector = State(initialValue: previewCollector ?? BatchCollector())
        _imported = State(initialValue: previewImported)
        _added = State(initialValue: previewImported ? 1 : 0)
    }

    private var step: Int { imported ? 3 : collector.complete ? 2 : 1 }
    private var incomingCount: Int {
        Set(collector.accounts.filter { incoming in
            !vault.accounts.contains { $0.issuer == incoming.issuer && $0.username == incoming.username }
        }.map { [$0.issuer, $0.username] }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "qrcode.viewfinder").font(.title2).foregroundStyle(Color.accentColor)
                Text("Import accounts").font(.system(size: 20, weight: .semibold))
                Spacer()
                if !imported { Button("Cancel") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction) }
            }.padding(24)
            HStack(spacing: 16) {
                stepLabel("Scan", number: 1)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stepLabel("Review", number: 2)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stepLabel("Ready", number: 3)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if imported { completion }
                    else if collector.complete { review }
                    else { scan }
                    if let message { InlineNotice(text: message) }
                    if let error = scanner.error, !collector.complete { InlineNotice(text: error) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 340, maxHeight: 450)
            Divider()
            HStack {
                if !imported && collector.received > 0 {
                    Button("Start over") { reset() }.disabled(busy)
                } else {
                    Label("Only on this Mac", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if imported {
                    Button(added > 0 ? "Set up autofill" : "View accounts") { finish() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else if collector.complete {
                    if busy { ProgressView().controlSize(.small) }
                    Button(incomingCount == 0 ? "Done" : "Import \(incomingCount) \(incomingCount == 1 ? "account" : "accounts")") {
                        if incomingCount == 0 { finish() } else { commit() }
                    }.buttonStyle(.borderedProminent).disabled(busy).keyboardShortcut(.defaultAction)
                } else {
                    Text("Scan all QR codes to continue").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 590).background(TouchStyle.background)
            .interactiveDismissDisabled(busy)
            .onDisappear { scanner.stop(); collector = BatchCollector(); uri = "" }
    }

    private func stepLabel(_ title: String, number: Int) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(number <= step ? Color.accentColor : Color.secondary.opacity(0.15))
                if number < step { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.system(size: 10, weight: .semibold)).foregroundStyle(number == step ? .white : .secondary) }
            }.frame(width: 20, height: 20)
            Text(title).font(.system(size: 12, weight: number == step ? .semibold : .regular))
                .foregroundStyle(number <= step ? Color.primary : .secondary)
        }
    }

    private var scan: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start in Google Authenticator").font(.headline)
                Text("On your phone, choose Transfer accounts → Export accounts, then select the accounts to bring over.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.035))
                if camera {
                    CameraPreview(session: scanner.session).clipShape(RoundedRectangle(cornerRadius: 12))
                        .task { await scanner.start { text in ingest(text) } }
                        .onDisappear { scanner.stop() }
                    VStack {
                        Spacer()
                        Text("Hold your phone’s QR code up to the camera")
                            .font(.caption).padding(8).foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule()).padding(12)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                        Button { scanner.error = nil; camera = true } label: { Label("Start camera", systemImage: "camera") }
                            .controlSize(.large)
                        Text("Point your phone’s export QR at the camera").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(height: 200)
            if collector.received > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("\(collector.received) of \(collector.expected) QR codes scanned").font(.callout.weight(.medium))
                        Spacer()
                        Text("Show the next QR code").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(collector.received), total: Double(collector.expected))
                }
            }
            HStack {
                Button(action: chooseImage) { Label("Choose QR image…", systemImage: "photo") }
                Spacer()
                if camera { Button("Stop camera") { camera = false; scanner.stop() } }
            }
            DisclosureGroup("Use a setup link instead") {
                HStack {
                    SecureField("otpauth://…", text: $uri).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Authenticator setup link")
                    Button("Read") { ingest(uri); uri = "" }.disabled(uri.isEmpty)
                }.padding(.top, 8)
            }.font(.callout)
            Text("Your phone keeps working. QR codes are processed locally and aren’t saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(collector.accounts.count) \(collector.accounts.count == 1 ? "account" : "accounts") found")
                    .font(.system(size: 21, weight: .semibold))
                Text(incomingCount == 0 ? "These accounts are already in TouchOTP." : "Review your accounts before adding them to this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            GroupSurface {
                ForEach(Array(collector.accounts.enumerated()), id: \.offset) { index, account in
                    let existing = vault.accounts.contains { $0.issuer == account.issuer && $0.username == account.username }
                    HStack(spacing: 12) {
                        AccountSymbol(issuer: account.issuer)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.issuer).font(.callout.weight(.medium))
                            Text(account.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if existing { Text("Already added").font(.caption).foregroundStyle(.secondary) }
                        else { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }.padding(12)
                    if index < collector.accounts.count - 1 { Divider().padding(.leading, 58) }
                }
            }
            Text("Next, choose the websites and apps where each account can autofill.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var completion: some View {
        VStack(alignment: .center, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 46, weight: .light)).foregroundStyle(.green)
            VStack(spacing: 8) {
                Text(added == 1 ? "Account added" : "\(added) accounts added").font(.system(size: 23, weight: .semibold))
                Text("Choose a website or Mac app for each account\nto start filling codes with Touch ID.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if skipped > 0 { Text("\(skipped) existing \(skipped == 1 ? "account was" : "accounts were") skipped.").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.click").foregroundStyle(.secondary)
                Text("Link a destination, then use").font(.caption).foregroundStyle(.secondary)
                ShortcutKeys()
            }.padding(.top, 12)
        }.padding(.vertical, 35).frame(maxWidth: .infinity)
    }

    private func ingest(_ text: String) {
        guard !collector.complete, !busy else { return }
        do {
            try collector.add(OTPImporter.parse(text))
            message = nil
            if collector.complete { scanner.stop(); camera = false }
        } catch { message = "QR read, but the account data could not be imported: " + error.localizedDescription }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.prompt = "Read QR codes"
        guard panel.runModal() == .OK else { return }
        do { for url in panel.urls { for text in try QRImageReader.read(url) { ingest(text) } } }
        catch { message = error.localizedDescription }
    }
    private func reset() {
        scanner.stop(); camera = false; scanner.error = nil
        collector = BatchCollector(); message = nil; uri = ""
    }
    private func commit() {
        busy = true; message = nil
        let existing = Set(vault.accounts.map(\.id))
        Task {
            do {
                let result = try await vault.importAccounts(collector.accounts)
                added = result.added; skipped = result.skipped
                firstAccount = vault.accounts.first { !existing.contains($0.id) }?.id
                imported = true; collector = BatchCollector(); uri = ""
            } catch { message = "Import failed: " + error.localizedDescription }
            busy = false
        }
    }
    private func finish() {
        dismiss()
        onComplete(firstAccount)
    }
}
