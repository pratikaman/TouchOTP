import Foundation
import LocalAuthentication
import TouchOTPCore

/// On-disk index: public metadata plus the identifier of the single protected right. No seeds.
/// `legacy` lists pre-0.3.0 records that still wait to be moved into the vault.
struct VaultIndex: Codable, Equatable {
    var vaultID: String?
    var accounts: [AccountRecord]
    var legacy: [LegacyIndexEntry]?
}

/// Index entry written by versions before 0.3.0, when every account had its own protected right.
struct LegacyIndexEntry: Codable, Equatable {
    var id: UUID
    var secretID: String
    var issuer: String
    var username: String
    var bindings: Bindings
    var record: AccountRecord { AccountRecord(id: id, issuer: issuer, username: username, bindings: bindings) }
    var rightIdentifier: String { "account-" + secretID }
}

struct MigrationProgress: Equatable {
    var moved: Int
    var total: Int
    /// The shared authentication was refused, so Touch ID asks once for each remaining account.
    var perAccount: Bool
}

@MainActor
final class Vault: ObservableObject {
    @Published private(set) var accounts: [AccountRecord] = []
    @Published private(set) var legacyAccounts: [AccountRecord] = []
    @Published private(set) var migration: MigrationProgress?
    @Published var loadError: String?
    private let file: URL
    private let previewMode: Bool
    private let store = LARightStore.shared
    private var vaultID: String?
    private var legacy: [LegacyIndexEntry] = [] { didSet { legacyAccounts = legacy.map(\.record) } }
    private var mutating = false

    /// Accounts saved by an earlier version still sit in per-account rights and must be moved first.
    var needsMigration: Bool { !legacy.isEmpty }

    static var defaultIndexFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TouchOTP/accounts.json")
    }

    convenience init(previewAccounts: [AccountRecord]? = nil) {
        self.init(indexFile: Self.defaultIndexFile, previewAccounts: previewAccounts)
    }

    init(indexFile: URL, previewAccounts: [AccountRecord]? = nil) {
        previewMode = previewAccounts != nil
        file = indexFile
        if let previewAccounts { accounts = previewAccounts; return }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            if let index = try? JSONDecoder().decode(VaultIndex.self, from: data) {
                accounts = index.accounts
                vaultID = index.vaultID
                legacy = index.legacy ?? []
            } else {
                legacy = try JSONDecoder().decode([LegacyIndexEntry].self, from: data)
            }
            legacyAccounts = legacy.map(\.record) // Property observers do not run during init.
        } catch { loadError = "Could not read the account index. Import and changes are disabled to protect the existing vault. \(error.localizedDescription)" }
    }

    private func beginMutation(allowLegacy: Bool = false) throws {
        guard !previewMode else { throw OTPError("Preview accounts cannot be changed.") }
        guard !mutating else { throw OTPError("Another account change is still in progress. Please try again when it finishes.") }
        guard loadError == nil else { throw OTPError(loadError!) }
        guard allowLegacy || !needsMigration else { throw OTPError(Self.migrationMessage) }
        mutating = true
    }

    static let migrationMessage = "Move your accounts to the new TouchOTP vault first. Open Manage accounts to continue."

    static func checkBiometry() throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), context.biometryType == .touchID else {
            throw OTPError("Touch ID is unavailable. Enroll a fingerprint in System Settings → Touch ID & Password, then try again.")
        }
    }

    /// True when the user dismissed a Touch ID prompt rather than hitting a real failure.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == LAError.errorDomain
            && [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue].contains(nsError.code)
    }

    private func rightIdentifier(_ id: String) -> String { "vault-" + id }

    private func persist(records: [AccountRecord], vaultID: String?, legacy: [LegacyIndexEntry]) throws {
        guard loadError == nil else { throw OTPError(loadError!) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let index = VaultIndex(vaultID: vaultID, accounts: records, legacy: legacy.isEmpty ? nil : legacy)
        let data = try JSONEncoder().encode(index)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        accounts = records
        self.vaultID = vaultID
        self.legacy = legacy
    }

    /// Saves the vault under a fresh right, points the index at it, then removes the previous right.
    /// An empty vault removes the right entirely so nothing protected lingers in the keychain.
    private func commit(_ vault: ProtectedVault, legacy: [LegacyIndexEntry] = []) async throws {
        let previous = vaultID
        if vault.accounts.isEmpty {
            try persist(records: [], vaultID: nil, legacy: legacy)
        } else {
            try Self.checkBiometry()
            let identifier = UUID().uuidString
            _ = try await store.saveRight(LARight(requirement: .biometryCurrentSet), identifier: rightIdentifier(identifier),
                                          secret: JSONEncoder().encode(vault))
            do { try persist(records: vault.records, vaultID: identifier, legacy: legacy) }
            catch {
                try? await store.removeRight(forIdentifier: rightIdentifier(identifier))
                throw error
            }
        }
        if let previous { try? await store.removeRight(forIdentifier: rightIdentifier(previous)) }
    }

    private static func sameRecords(_ lhs: [AccountRecord], _ rhs: [AccountRecord]) -> Bool {
        lhs.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func readVault(_ vaultID: String, reason: String) async throws -> ProtectedVault {
        try Self.checkBiometry()
        let right = try await store.right(forIdentifier: rightIdentifier(vaultID))
        do {
            try await right.authorize(localizedReason: reason)
            let data = try await right.secret.rawData
            await right.deauthorize()
            let vault = try JSONDecoder().decode(ProtectedVault.self, from: data)
            guard Self.sameRecords(vault.records, accounts) else {
                throw OTPError("The account index does not match the protected vault. Filling has been stopped.")
            }
            return vault
        } catch {
            await right.deauthorize()
            throw error
        }
    }

    /// One Touch ID prompt decrypts every seed. The protected copy of the metadata must match the index.
    func unlockAll(reason: String) async throws -> ProtectedVault {
        guard !previewMode else { throw OTPError("Preview accounts have no stored secrets.") }
        guard !needsMigration else { throw OTPError(Self.migrationMessage) }
        guard let vaultID else { throw OTPError("No accounts have been imported yet.") }
        return try await readVault(vaultID, reason: reason)
    }

    func unlock(_ record: AccountRecord, reason: String) async throws -> ProtectedAccount {
        let vault = try await unlockAll(reason: reason)
        guard let payload = vault.accounts.first(where: { $0.record == record }) else {
            throw OTPError("The account index does not match its protected record. Filling has been stopped.")
        }
        return payload
    }

    /// The first import needs no Touch ID; later imports decrypt the vault to add to it.
    func importAccounts(_ incoming: [OTPSecret]) async throws -> (added: Int, skipped: Int) {
        try beginMutation()
        defer { mutating = false }
        var vault: ProtectedVault
        if vaultID == nil { vault = ProtectedVault() }
        else { vault = try await unlockAll(reason: "Add accounts to TouchOTP") }
        var added = 0, skipped = 0
        for otp in incoming {
            if vault.accounts.contains(where: { $0.record.issuer == otp.issuer && $0.record.username == otp.username }) {
                skipped += 1; continue
            }
            vault.accounts.append(ProtectedAccount(record: AccountRecord(issuer: otp.issuer, username: otp.username), otp: otp))
            added += 1
        }
        guard added > 0 else { return (0, skipped) }
        try await commit(vault)
        return (added, skipped)
    }

    func update(_ record: AccountRecord, bindings: Bindings) async throws {
        try beginMutation()
        defer { mutating = false }
        guard accounts.contains(record) else { throw OTPError("This account changed. Select it again before editing.") }
        var vault = try await unlockAll(reason: "Change where \(record.issuer) codes can be filled")
        guard let index = vault.accounts.firstIndex(where: { $0.record == record }) else {
            throw OTPError("The account index does not match its protected record. Nothing was changed.")
        }
        vault.accounts[index].record.bindings = bindings
        try await commit(vault)
    }

    func remove(_ record: AccountRecord) async throws {
        try beginMutation()
        defer { mutating = false }
        guard accounts.contains(record) else { throw OTPError("This account changed. Select it again before removing.") }
        var vault = try await unlockAll(reason: "Remove \(record.issuer) from TouchOTP")
        vault.accounts.removeAll { $0.record == record }
        try await commit(vault)
    }

    // MARK: Migration from per-account rights (versions before 0.3.0)

    /// Moves legacy records into the single vault. One biometric evaluation is shared across every legacy
    /// Secure Enclave key; if the system refuses that, the remaining records fall back to `LARight.authorize`,
    /// one prompt each. Whatever was read is committed even when a later step fails, so stopping keeps progress.
    func migrateLegacyAccounts() async throws {
        try beginMutation(allowLegacy: true)
        defer { mutating = false; migration = nil }
        guard needsMigration else { return }
        try Self.checkBiometry()
        let total = legacy.count
        let noun = total == 1 ? "account" : "accounts"
        migration = MigrationProgress(moved: 0, total: total, perAccount: false)

        let context = LAContext()
        defer { context.invalidate() }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                             localizedReason: "\(vaultID == nil ? "Move" : "Continue moving") \(total) \(noun) to the new TouchOTP vault")

        // A partial vault from an earlier, interrupted run is appended to rather than replaced.
        var existing: [ProtectedAccount] = []
        if let vaultID {
            if let data = try? LegacyKeychain.secret(forRightIdentifier: rightIdentifier(vaultID), context: context),
               let vault = try? JSONDecoder().decode(ProtectedVault.self, from: data), Self.sameRecords(vault.records, accounts) {
                existing = vault.accounts
            } else {
                existing = try await readVault(vaultID, reason: "Continue moving accounts to the new TouchOTP vault").accounts
            }
        }

        var movedEntries: [LegacyIndexEntry] = []
        var movedPayloads: [ProtectedAccount] = []
        var remaining = legacy
        var failure: Error?
        while let entry = remaining.first {
            let payload: ProtectedAccount
            if migration?.perAccount == false,
               let fast = try? Self.decodeLegacy(LegacyKeychain.secret(forRightIdentifier: entry.rightIdentifier, context: context), entry) {
                payload = fast
            } else {
                migration?.perAccount = true
                do { payload = try await readLegacyRight(entry, position: movedEntries.count + 1, total: total) }
                catch { failure = error; break }
            }
            movedEntries.append(entry)
            movedPayloads.append(payload)
            remaining.removeFirst()
            migration?.moved = movedEntries.count
        }
        if !movedEntries.isEmpty {
            try await commit(ProtectedVault(accounts: existing + movedPayloads), legacy: remaining)
            for entry in movedEntries { try? await store.removeRight(forIdentifier: entry.rightIdentifier) }
        }
        if let failure { throw failure }
    }

    private func readLegacyRight(_ entry: LegacyIndexEntry, position: Int, total: Int) async throws -> ProtectedAccount {
        let right = try await store.right(forIdentifier: entry.rightIdentifier)
        do {
            try await right.authorize(localizedReason: "Move \(entry.issuer) to the new TouchOTP vault (\(position) of \(total))")
            let data = try await right.secret.rawData
            await right.deauthorize()
            return try Self.decodeLegacy(data, entry)
        } catch {
            await right.deauthorize()
            throw error
        }
    }

    private static func decodeLegacy(_ data: Data, _ entry: LegacyIndexEntry) throws -> ProtectedAccount {
        let payload = try JSONDecoder().decode(ProtectedAccount.self, from: data)
        guard payload.record == entry.record else {
            throw OTPError("The account index does not match the protected record for \(entry.issuer). Nothing was moved.")
        }
        return payload
    }

    /// Deletes every account without reading the vault. This is the recovery path after the enrolled
    /// fingerprints change, when `.biometryCurrentSet` makes the existing records unreadable.
    func removeAllAccounts() async throws {
        try beginMutation(allowLegacy: true)
        defer { mutating = false }
        let confirmation = LARight(requirement: .biometry)
        try await confirmation.authorize(localizedReason: "Remove all accounts from TouchOTP")
        await confirmation.deauthorize()
        if let vaultID { try? await store.removeRight(forIdentifier: rightIdentifier(vaultID)) }
        for entry in legacy { try? await store.removeRight(forIdentifier: entry.rightIdentifier) }
        try persist(records: [], vaultID: nil, legacy: [])
    }

    /// Exercises this app's storage identity using a disposable fixture, never a real account.
    static func storageCheck() async -> String {
        let identifier = "storage-check-" + UUID().uuidString
        do {
            try checkBiometry()
            let right = LARight(requirement: .biometryCurrentSet)
            let stored = try await LARightStore.shared.saveRight(right, identifier: identifier, secret: Data("TouchOTP test fixture".utf8))
            let loaded = try await LARightStore.shared.right(forIdentifier: identifier)
            guard loaded.state != .authorized, stored.state != .authorized else { throw OTPError("Unexpected authorization state.") }
            var unauthorizedReadSucceeded = false
            do { _ = try await loaded.secret.rawData; unauthorizedReadSucceeded = true } catch { }
            guard !unauthorizedReadSucceeded else { throw OTPError("An unauthorized read unexpectedly succeeded.") }
            try await LARightStore.shared.removeRight(forIdentifier: identifier)
            return "PASS: biometric-protected fixture saved; unauthorized secret read rejected; fixture removed. Touch ID interaction still requires a manual test."
        } catch {
            try? await LARightStore.shared.removeRight(forIdentifier: identifier)
            return "FAIL: \(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)]"
        }
    }

    static func biometricCheck() async throws {
        try checkBiometry()
        let identifier = "biometric-check-" + UUID().uuidString
        let fixture = Data("TouchOTP biometric test".utf8)
        do {
            let right = try await LARightStore.shared.saveRight(LARight(requirement: .biometryCurrentSet), identifier: identifier, secret: fixture)
            do {
                try await right.authorize(localizedReason: "Test Touch ID for TouchOTP using a temporary test account")
                let actual = try await right.secret.rawData
                await right.deauthorize()
                guard actual == fixture else { throw OTPError("The storage test did not return the expected fixture.") }
            } catch { await right.deauthorize(); throw error }
            try await LARightStore.shared.removeRight(forIdentifier: identifier)
        } catch {
            try? await LARightStore.shared.removeRight(forIdentifier: identifier)
            throw error
        }
    }
}
