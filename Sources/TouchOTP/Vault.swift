import Foundation
import LocalAuthentication
import TouchOTPCore

@MainActor
final class Vault: ObservableObject {
    @Published private(set) var accounts: [AccountRecord] = []
    @Published var loadError: String?
    private let file: URL
    private let store = LARightStore.shared
    private var mutating = false

    private func beginMutation() throws {
        guard !mutating else { throw OTPError("Another account change is still in progress. Please try again when it finishes.") }
        guard loadError == nil else { throw OTPError(loadError!) }
        mutating = true
    }

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TouchOTP/accounts.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                accounts = try JSONDecoder().decode([AccountRecord].self, from: Data(contentsOf: file))
            }
        } catch { loadError = "Could not read the account index. Import and changes are disabled to protect the existing vault. \(error.localizedDescription)" }
    }

    static func checkBiometry() throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), context.biometryType == .touchID else {
            throw OTPError("Touch ID is unavailable. Enroll a fingerprint in System Settings → Touch ID & Password, then try again.")
        }
    }

    private func persist(_ records: [AccountRecord]) throws {
        guard loadError == nil else { throw OTPError(loadError!) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        accounts = records
    }

    private func save(_ payload: ProtectedAccount) async throws {
        try Self.checkBiometry()
        let right = LARight(requirement: .biometryCurrentSet)
        _ = try await store.saveRight(right, identifier: "account-" + payload.record.secretID,
                                      secret: JSONEncoder().encode(payload))
    }

    func unlock(_ record: AccountRecord, reason: String) async throws -> ProtectedAccount {
        try Self.checkBiometry()
        let right = try await store.right(forIdentifier: "account-" + record.secretID)
        do {
            try await right.authorize(localizedReason: reason)
            let data = try await right.secret.rawData
            await right.deauthorize()
            let payload = try JSONDecoder().decode(ProtectedAccount.self, from: data)
            guard payload.record == record else { throw OTPError("The account index does not match its protected record. Filling has been stopped.") }
            return payload
        } catch {
            await right.deauthorize()
            throw error
        }
    }

    func importAccounts(_ incoming: [OTPSecret]) async throws -> (added: Int, skipped: Int) {
        try beginMutation()
        defer { mutating = false }
        var updated = accounts
        var saved: [AccountRecord] = []
        var skipped = 0
        do {
            for otp in incoming {
                if updated.contains(where: { $0.issuer == otp.issuer && $0.username == otp.username }) {
                    skipped += 1; continue
                }
                let record = AccountRecord(issuer: otp.issuer, username: otp.username)
                try await save(ProtectedAccount(record: record, otp: otp))
                saved.append(record); updated.append(record)
            }
            try persist(updated)
            return (saved.count, skipped)
        } catch {
            for record in saved { try? await store.removeRight(forIdentifier: "account-" + record.secretID) }
            throw error
        }
    }

    func update(_ record: AccountRecord, bindings: Bindings) async throws {
        try beginMutation()
        defer { mutating = false }
        guard accounts.contains(record) else { throw OTPError("This account changed. Select it again before editing.") }
        var payload = try await unlock(record, reason: "Change where \(record.issuer) codes can be filled")
        payload.record.bindings = bindings
        payload.record.secretID = UUID().uuidString
        try await save(payload)
        do { try persist(accounts.map { $0.id == record.id ? payload.record : $0 }) }
        catch {
            try? await store.removeRight(forIdentifier: "account-" + payload.record.secretID)
            throw error
        }
        try? await store.removeRight(forIdentifier: "account-" + record.secretID)
    }

    func remove(_ record: AccountRecord) async throws {
        try beginMutation()
        defer { mutating = false }
        guard accounts.contains(record) else { throw OTPError("This account changed. Select it again before removing.") }
        // A new biometric right also permits removal after the original fingerprint set changed.
        let deletion = LARight(requirement: .biometry)
        try await deletion.authorize(localizedReason: "Remove \(record.issuer) from TouchOTP")
        await deletion.deauthorize()
        // Remove the protected secret first. On an index-write failure the stale entry remains visible,
        // but its secret has already been removed; a retry reports that instead of losing other accounts.
        try await store.removeRight(forIdentifier: "account-" + record.secretID)
        try persist(accounts.filter { $0.id != record.id })
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
