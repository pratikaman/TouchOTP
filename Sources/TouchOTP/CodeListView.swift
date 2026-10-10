import SwiftUI
import AppKit
import TouchOTPCore

/// Holds the decrypted vault for the menu bar code list. Seeds live here only while the popover
/// is open and for at most `visibleFor` seconds; `lock()` discards them.
@MainActor
final class CodeListModel: ObservableObject {
    static let visibleFor: TimeInterval = 90
    @Published private(set) var unlocked: [ProtectedAccount]?
    @Published private(set) var unlockedUntil: Date?
    @Published private(set) var busy = false
    @Published var message: String?
    private let vault: Vault
    private var relock: Task<Void, Never>?

    init(vault: Vault, previewUnlocked: [ProtectedAccount]? = nil) {
        self.vault = vault
        if let previewUnlocked {
            unlocked = previewUnlocked
            unlockedUntil = Date().addingTimeInterval(Self.visibleFor)
        }
    }

    var isUnlocked: Bool { unlocked != nil }

    func payload(for record: AccountRecord) -> ProtectedAccount? {
        unlocked?.first { $0.record.id == record.id }
    }

    /// One Touch ID prompt reveals every code. A dismissed prompt leaves the list locked without a message.
    func reveal() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let vault = try await vault.unlockAll(reason: "Show your verification codes")
            unlocked = vault.accounts
            unlockedUntil = Date().addingTimeInterval(Self.visibleFor)
            relock?.cancel()
            relock = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.visibleFor))
                guard !Task.isCancelled else { return }
                self?.lock()
            }
        } catch {
            if !Vault.isCancellation(error) { message = error.localizedDescription }
        }
    }

    func lock() {
        relock?.cancel(); relock = nil
        unlocked = nil; unlockedUntil = nil
    }
}

/// Content of the menu bar popover: every account with its live code once the vault is unlocked.
struct CodeListView: View {
    @ObservedObject var vault: Vault
    @ObservedObject var model: CodeListModel
    var manage: () -> Void = {}
    var importAccounts: () -> Void = {}
    var quit: () -> Void = {}

    private static let rowHeight: CGFloat = 54
    private var accounts: [AccountRecord] {
        vault.accounts.sorted { $0.issuer.localizedStandardCompare($1.issuer) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "touchid").font(.system(size: 13, weight: .semibold)).foregroundStyle(TouchStyle.onHoney)
                    .frame(width: 24, height: 24).background(TouchStyle.honey, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("TouchOTP").font(TouchStyle.title(14)).foregroundStyle(TouchStyle.ink)
                Spacer()
                if model.isUnlocked {
                    Button { model.lock() } label: { Label("Hide codes", systemImage: "eye.slash") }.buttonStyle(.warmQuiet)
                }
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            content
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Text("Fill a code").font(.caption).foregroundStyle(TouchStyle.muted).fixedSize()
                    ShortcutKeys()
                }
                Spacer()
                Button("Manage…") { manage() }.buttonStyle(.warmSecondary)
                Button { quit() } label: { Image(systemName: "power").font(.system(size: 12, weight: .semibold)).foregroundStyle(TouchStyle.muted) }
                    .buttonStyle(.plain).help("Quit TouchOTP").accessibilityLabel("Quit TouchOTP")
            }.padding(.horizontal, 16).padding(.vertical, 11)
                .background(TouchStyle.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(TouchStyle.border).frame(height: 1) }
        }
        .frame(width: 340)
        .background(TouchStyle.background)
        .tint(TouchStyle.honeyText)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !model.busy { model.lock() }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = vault.loadError {
            InlineNotice(text: error).padding(14)
        } else if vault.needsMigration {
            MigrationPanel(vault: vault, compact: true, openManager: manage).padding(14)
        } else if accounts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill").font(.system(size: 20)).foregroundStyle(TouchStyle.honeyText)
                    .frame(width: 46, height: 46).background(TouchStyle.selection, in: Circle())
                Text("No accounts yet").font(TouchStyle.title(15)).foregroundStyle(TouchStyle.ink)
                Text("Import your authenticator accounts to see their codes here.")
                    .font(.caption).foregroundStyle(TouchStyle.muted).multilineTextAlignment(.center)
                Button { importAccounts() } label: { Label("Import accounts", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.warm(.primary, large: true)).padding(.top, 4)
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 24).frame(maxWidth: .infinity)
        } else {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        ForEach(accounts) { record in
                            CodeRow(record: record, payload: model.payload(for: record), date: context.date)
                                .frame(height: Self.rowHeight)
                            if record.id != accounts.last?.id { Rectangle().fill(TouchStyle.border).frame(height: 1).padding(.leading, 56).padding(.trailing, 12) }
                        }
                    }
                }
            }.frame(height: min(CGFloat(accounts.count) * Self.rowHeight, Self.rowHeight * 6))
                .background(TouchStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TouchStyle.border))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
            VStack(spacing: 8) {
                if model.isUnlocked, let until = model.unlockedUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label("Codes hide in \(max(0, Int(ceil(until.timeIntervalSince(context.date)))))s or when this closes", systemImage: "lock")
                            .font(.caption).monospacedDigit().foregroundStyle(TouchStyle.muted)
                    }
                } else if !model.isUnlocked {
                    Button { Task { await model.reveal() } } label: {
                        Label(model.busy ? "Waiting for Touch ID…" : "Show codes with Touch ID", systemImage: "touchid")
                    }.buttonStyle(.warm(.primary, large: true, fill: true)).disabled(model.busy)
                }
                if let message = model.message { InlineNotice(text: message) }
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)
        }
    }
}

struct CodeRow: View {
    let record: AccountRecord
    let payload: ProtectedAccount?
    let date: Date
    private var code: String? { try? payload?.otp.code(at: date) }

    var body: some View {
        HStack(spacing: 12) {
            AccountSymbol(issuer: record.issuer, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.issuer).font(.system(size: 13, weight: .semibold)).foregroundStyle(TouchStyle.ink).lineLimit(1)
                Text(record.username).font(.system(size: 11)).foregroundStyle(TouchStyle.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let payload, let code {
                let remaining = payload.otp.remaining(at: date)
                let seconds = max(0, Int(ceil(remaining)))
                // The code never wraps; the name column truncates instead.
                HStack(spacing: 8) {
                    Text(CodeFormat.grouped(code))
                        .font(TouchStyle.code(21))
                        .foregroundStyle(remaining < 6 ? TouchStyle.coral : TouchStyle.ink)
                        .lineLimit(1).fixedSize()
                        .textSelection(.enabled)
                        .accessibilityLabel("Code for \(record.issuer): \(code)")
                    ZStack {
                        CountdownRing(fraction: remaining / Double(payload.otp.period), urgent: remaining < 6)
                        Text("\(seconds)").font(.system(size: 8.5, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(TouchStyle.muted)
                    }.frame(width: 22, height: 22).accessibilityLabel("\(seconds) seconds remaining")
                }.layoutPriority(1)
            } else {
                Text("••• •••").font(TouchStyle.code(21)).fixedSize()
                    .foregroundStyle(TouchStyle.faint).accessibilityLabel("Code hidden")
            }
        }.padding(.horizontal, 12)
    }
}

/// Shown instead of the account list until records from versions before 0.3.0 are moved into the vault.
/// The compact form (menu bar popover) only hands off to the manager window, so no Touch ID sheet ever
/// attaches to a transient popover.
struct MigrationPanel: View {
    @ObservedObject var vault: Vault
    var compact = false
    var openManager: () -> Void = {}
    @State private var busy = false
    @State private var message: String?
    @State private var paused = false
    @State private var confirmReset = false

    private var remaining: Int { vault.legacyAccounts.count }
    private var movedSoFar: Int { vault.accounts.count }
    private var noun: String { remaining == 1 ? "account" : "accounts" }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            Label("Move your accounts to the new vault", systemImage: "arrow.triangle.2.circlepath")
                .font(compact ? TouchStyle.title(14) : TouchStyle.title(20)).foregroundStyle(TouchStyle.ink)
            if compact {
                Text("\(remaining) \(noun) from the previous version \(remaining == 1 ? "needs" : "need") to be moved before codes can be shown. One Touch ID normally moves them all.")
                    .font(.caption).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
                Button { openManager() } label: {
                    Label("Open TouchOTP to move them", systemImage: "arrow.up.forward.app")
                }.buttonStyle(.warm(.primary, fill: true))
            } else {
                Text("TouchOTP now keeps every code in one protected record, so a single Touch ID can show all of them. \(remaining) \(noun) from the previous version still \(remaining == 1 ? "needs" : "need") to be moved. One Touch ID normally moves them all. If this Mac insists on a separate Touch ID per account, progress is saved whenever you stop, and nothing is removed until it has been moved.")
                    .font(.callout).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
                if let progress = vault.migration {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(progress.moved), total: Double(max(progress.total, 1)))
                        Text(progressText(progress)).font(.caption).foregroundStyle(TouchStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    GroupSurface {
                        ForEach(vault.legacyAccounts) { record in
                            HStack(spacing: 12) {
                                AccountSymbol(issuer: record.issuer)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.issuer).font(.callout.weight(.medium))
                                    Text(record.username).font(.caption).foregroundStyle(TouchStyle.muted).lineLimit(1)
                                }
                                Spacer()
                            }.padding(12)
                            if record.id != vault.legacyAccounts.last?.id { Rectangle().fill(TouchStyle.border).frame(height: 1).padding(.leading, 58) }
                        }
                    }
                    if movedSoFar > 0 {
                        Text("\(movedSoFar) \(movedSoFar == 1 ? "account is" : "accounts are") already in the new vault.")
                            .font(.caption).foregroundStyle(TouchStyle.muted)
                    }
                }
                Button(action: migrate) {
                    Label(busy ? "Moving…" : movedSoFar > 0 ? "Continue with Touch ID" : "Move \(remaining) \(noun) with Touch ID", systemImage: "touchid")
                }.buttonStyle(.warm(.primary, large: true)).disabled(busy)
                if let message {
                    InlineNotice(text: message)
                    if !paused { Button("Remove all accounts…", role: .destructive) { confirmReset = true }.disabled(busy) }
                }
            }
        }
        .confirmationDialog("Remove all accounts from TouchOTP?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Remove all with Touch ID", role: .destructive, action: reset)
        } message: {
            Text("Use this if your enrolled fingerprints changed and the old records can no longer be read. Import the accounts again from your phone afterwards.")
        }
    }

    private func progressText(_ progress: MigrationProgress) -> String {
        if progress.perAccount {
            return "Moving account \(min(progress.moved + 1, progress.total)) of \(progress.total). This Mac asks for Touch ID once per account; keep your finger on the sensor. You can stop at any time and continue later."
        }
        return progress.moved == 0 ? "Waiting for Touch ID…" : "Moved \(progress.moved) of \(progress.total)…"
    }

    private func migrate() {
        busy = true; message = nil; paused = false
        Task {
            do { try await vault.migrateLegacyAccounts() }
            catch where Vault.isCancellation(error) {
                if vault.needsMigration {
                    paused = true
                    message = vault.accounts.isEmpty
                        ? "Touch ID was cancelled. Nothing was moved yet."
                        : "Paused with \(vault.accounts.count) moved and \(vault.legacyAccounts.count) to go. Continue whenever you are ready."
                }
            } catch {
                message = "Could not move the accounts: \(error.localizedDescription) If your fingerprints changed since they were saved, remove all accounts and import them again."
            }
            busy = false
        }
    }

    private func reset() {
        busy = true; message = nil
        Task {
            do { try await vault.removeAllAccounts() }
            catch where !Vault.isCancellation(error) { message = error.localizedDescription }
            catch {}
            busy = false
        }
    }
}
