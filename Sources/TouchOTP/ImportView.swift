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
                Image(systemName: "qrcode.viewfinder").font(.system(size: 16, weight: .semibold)).foregroundStyle(TouchStyle.onHoney)
                    .frame(width: 32, height: 32).background(TouchStyle.honey, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("Import accounts").font(TouchStyle.title(20)).foregroundStyle(TouchStyle.ink)
                Spacer()
                if !imported { Button("Cancel") { dismiss() }.buttonStyle(.warmSecondary).disabled(busy).keyboardShortcut(.cancelAction) }
            }.padding(24)
            HStack(spacing: 16) {
                stepLabel("Scan", number: 1)
                stepConnector(after: 1)
                stepLabel("Review", number: 2)
                stepConnector(after: 2)
                stepLabel("Ready", number: 3)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 20)
            Rectangle().fill(TouchStyle.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if imported { completion }
                    else if collector.complete { review }
                    else { scan }
                    if let message { InlineNotice(text: message) }
                    if let error = scanner.error, !collector.complete { InlineNotice(text: error) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 340, maxHeight: 450)
            HStack {
                if !imported && collector.received > 0 {
                    Button("Start over") { reset() }.buttonStyle(.warmSecondary).disabled(busy)
                } else {
                    Label("Only on this Mac", systemImage: "lock").font(.caption).foregroundStyle(TouchStyle.muted)
                }
                Spacer()
                if imported {
                    Button(added > 0 ? "Set up autofill" : "View accounts") { finish() }
                        .buttonStyle(.warm(.primary, large: true)).keyboardShortcut(.defaultAction)
                } else if collector.complete {
                    if busy { ProgressView().controlSize(.small) }
                    Button(incomingCount == 0 ? "Done" : "Import \(incomingCount) \(incomingCount == 1 ? "account" : "accounts")") {
                        if incomingCount == 0 { finish() } else { commit() }
                    }.buttonStyle(.warm(.primary, large: true)).disabled(busy).keyboardShortcut(.defaultAction)
                } else {
                    Text("Scan all QR codes to continue").font(.caption).foregroundStyle(TouchStyle.muted)
                }
            }.padding(.horizontal, 24).padding(.vertical, 14)
                .background(TouchStyle.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(TouchStyle.border).frame(height: 1) }
        }.frame(width: 590).background(TouchStyle.background).tint(TouchStyle.honeyText)
            .interactiveDismissDisabled(busy)
            .onDisappear { scanner.stop(); collector = BatchCollector(); uri = "" }
    }

    private func stepLabel(_ title: String, number: Int) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(number <= step ? TouchStyle.honey : TouchStyle.well)
                if number < step { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(TouchStyle.onHoney) }
                else { Text("\(number)").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(number == step ? TouchStyle.onHoney : TouchStyle.muted) }
            }.frame(width: 21, height: 21)
            Text(title).font(.system(size: 12, weight: number == step ? .semibold : .medium))
                .foregroundStyle(number <= step ? TouchStyle.ink : TouchStyle.muted)
        }
    }

    private func stepConnector(after number: Int) -> some View {
        Capsule().fill(number < step ? TouchStyle.honey : TouchStyle.border).frame(width: 28, height: 2)
    }

    private var scan: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start in Google Authenticator").font(TouchStyle.title(15)).foregroundStyle(TouchStyle.ink)
                Text("On your phone, choose Transfer accounts → Export accounts, then select the accounts to bring over.")
                    .font(.callout).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TouchStyle.well)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(TouchStyle.faint.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: camera ? [] : [5, 5]))
                if camera {
                    CameraPreview(session: scanner.session).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .task { await scanner.start { text in ingest(text) } }
                        .onDisappear { scanner.stop() }
                    VStack {
                        Spacer()
                        Text("Hold your phone’s QR code up to the camera")
                            .font(.caption).padding(8).foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule()).padding(12)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 36, weight: .light)).foregroundStyle(TouchStyle.honeyText)
                        Button { scanner.error = nil; camera = true } label: { Label("Start camera", systemImage: "camera") }
                            .buttonStyle(.warm(.primary, large: true))
                        Text("Point your phone’s export QR at the camera").font(.caption).foregroundStyle(TouchStyle.muted)
                    }
                }
            }.frame(height: 200)
            if collector.received > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("\(collector.received) of \(collector.expected) QR codes scanned").font(.callout.weight(.semibold)).foregroundStyle(TouchStyle.ink)
                        Spacer()
                        Text("Show the next QR code").font(.caption).foregroundStyle(TouchStyle.muted)
                    }
                    ProgressView(value: Double(collector.received), total: Double(collector.expected))
                }
            }
            HStack {
                Button(action: chooseImage) { Label("Choose QR image…", systemImage: "photo") }.buttonStyle(.warmSecondary)
                Spacer()
                if camera { Button("Stop camera") { camera = false; scanner.stop() }.buttonStyle(.warmSecondary) }
            }
            DisclosureGroup("Use a setup link instead") {
                HStack {
                    SecureField("otpauth://…", text: $uri).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Authenticator setup link")
                    Button("Read") { ingest(uri); uri = "" }.buttonStyle(.warmSecondary).disabled(uri.isEmpty)
                }.padding(.top, 8)
            }.font(.callout).foregroundStyle(TouchStyle.ink)
            Text("Your phone keeps working. QR codes are processed locally and aren’t saved.")
                .font(.caption).foregroundStyle(TouchStyle.muted)
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(collector.accounts.count) \(collector.accounts.count == 1 ? "account" : "accounts") found")
                    .font(TouchStyle.title(21)).foregroundStyle(TouchStyle.ink)
                Text(incomingCount == 0 ? "These accounts are already in TouchOTP."
                     : vault.accounts.isEmpty ? "Review your accounts before adding them to this Mac."
                     : "Review your accounts. Touch ID confirms adding them to your protected vault.")
                    .font(.callout).foregroundStyle(TouchStyle.muted)
            }
            GroupSurface {
                ForEach(Array(collector.accounts.enumerated()), id: \.offset) { index, account in
                    let existing = vault.accounts.contains { $0.issuer == account.issuer && $0.username == account.username }
                    HStack(spacing: 12) {
                        AccountSymbol(issuer: account.issuer)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.issuer).font(.callout.weight(.semibold)).foregroundStyle(TouchStyle.ink)
                            Text(account.username).font(.caption).foregroundStyle(TouchStyle.muted).lineLimit(1)
                        }
                        Spacer()
                        if existing { Text("Already added").font(.caption).foregroundStyle(TouchStyle.muted) }
                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(TouchStyle.sage) }
                    }.padding(12)
                    if index < collector.accounts.count - 1 { Rectangle().fill(TouchStyle.border).frame(height: 1).padding(.leading, 58) }
                }
            }
            Text("Next, choose the websites and apps where each account can autofill.")
                .font(.caption).foregroundStyle(TouchStyle.muted)
        }
    }

    private var completion: some View {
        VStack(alignment: .center, spacing: 18) {
            Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(TouchStyle.onHoney)
                .frame(width: 64, height: 64).background(TouchStyle.honey, in: Circle())
                .shadow(color: TouchStyle.honey.opacity(0.35), radius: 12, y: 5)
            VStack(spacing: 8) {
                Text(added == 1 ? "Account added" : "\(added) accounts added").font(TouchStyle.title(23)).foregroundStyle(TouchStyle.ink)
                Text("Choose a website or Mac app for each account\nto start filling codes with Touch ID.")
                    .font(.callout).foregroundStyle(TouchStyle.muted).multilineTextAlignment(.center)
            }
            if skipped > 0 { Text("\(skipped) existing \(skipped == 1 ? "account was" : "accounts were") skipped.").font(.caption).foregroundStyle(TouchStyle.muted) }
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.click").foregroundStyle(TouchStyle.honeyText)
                Text("Link a destination, then use").font(.caption).foregroundStyle(TouchStyle.muted)
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
            } catch {
                message = Vault.isCancellation(error)
                    ? "Touch ID is needed to add accounts to your protected vault. Try Import again when you are ready."
                    : "Import failed: " + error.localizedDescription
            }
            busy = false
        }
    }
    private func finish() {
        dismiss()
        onComplete(firstAccount)
    }
}
