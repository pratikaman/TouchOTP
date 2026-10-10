import XCTest
import TouchOTPCore
@testable import TouchOTP

// Every case uses a throwaway index file and stops before any protected-storage call, so no
// Touch ID prompt, keychain access, or real account data is involved.
@MainActor
final class VaultIndexTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("accounts.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TouchOTPVaultIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLegacyIndexRequiresMigrationBeforeAnyUnlockOrChange() async throws {
        let id = UUID()
        let legacy = """
        [{"id":"\(id.uuidString)","secretID":"legacy-right","issuer":"Example","username":"alice@example.com","bindings":{"hosts":["example.com"],"bundleIDs":[]}}]
        """
        try legacy.write(to: file, atomically: true, encoding: .utf8)
        let vault = Vault(indexFile: file)
        XCTAssertNil(vault.loadError)
        XCTAssertTrue(vault.needsMigration)
        XCTAssertTrue(vault.accounts.isEmpty, "Legacy accounts stay out of the live list until they are moved")
        XCTAssertEqual(vault.legacyAccounts, [AccountRecord(id: id, issuer: "Example", username: "alice@example.com", bindings: Bindings(hosts: ["example.com"]))])
        do {
            _ = try await vault.unlockAll(reason: "test")
            XCTFail("Legacy records must not be unlocked through the vault path")
        } catch { XCTAssertEqual(error.localizedDescription, Vault.migrationMessage) }
        do {
            _ = try await vault.importAccounts([try OTPSecret(issuer: "New", username: "new", secret: Data([1]))])
            XCTFail("Imports must wait until the legacy records are moved")
        } catch { XCTAssertEqual(error.localizedDescription, Vault.migrationMessage) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), legacy, "A refused change leaves the index untouched")
    }

    func testPartiallyMigratedIndexKeepsMovedAndPendingAccountsApart() async throws {
        let moved = AccountRecord(issuer: "Moved", username: "done@example.com")
        let pending = LegacyIndexEntry(id: UUID(), secretID: "old-right", issuer: "Pending", username: "later@example.com", bindings: Bindings(hosts: ["pending.example"]))
        try JSONEncoder().encode(VaultIndex(vaultID: "partial", accounts: [moved], legacy: [pending])).write(to: file)
        let vault = Vault(indexFile: file)
        XCTAssertNil(vault.loadError)
        XCTAssertTrue(vault.needsMigration)
        XCTAssertEqual(vault.accounts, [moved])
        XCTAssertEqual(vault.legacyAccounts, [pending.record])
        XCTAssertNil(vault.migration)
        do {
            _ = try await vault.unlockAll(reason: "test")
            XCTFail("A partially migrated vault stays locked until every legacy record is moved")
        } catch { XCTAssertEqual(error.localizedDescription, Vault.migrationMessage) }
        let restored = try JSONDecoder().decode(VaultIndex.self, from: Data(contentsOf: file))
        XCTAssertEqual(restored.legacy, [pending])
    }

    func testLegacyRightIdentifierUsesTheOriginalNaming() {
        let entry = LegacyIndexEntry(id: UUID(), secretID: "ABC", issuer: "X", username: "y", bindings: Bindings())
        XCTAssertEqual(entry.rightIdentifier, "account-ABC")
        XCTAssertEqual(LegacyKeychain.namePrefix + entry.rightIdentifier, "com.apple.LocalAuthentication:Authorization:account-ABC")
    }

    func testCurrentIndexLoadsAccountsWithoutMigration() throws {
        let record = AccountRecord(issuer: "GitHub", username: "octo", bindings: Bindings(hosts: ["github.com"]))
        try JSONEncoder().encode(VaultIndex(vaultID: "vault-identifier", accounts: [record])).write(to: file)
        let vault = Vault(indexFile: file)
        XCTAssertNil(vault.loadError)
        XCTAssertFalse(vault.needsMigration)
        XCTAssertEqual(vault.accounts, [record])
    }

    func testEmptyLegacyIndexNeedsNoMigration() throws {
        try "[]".write(to: file, atomically: true, encoding: .utf8)
        let vault = Vault(indexFile: file)
        XCTAssertNil(vault.loadError)
        XCTAssertFalse(vault.needsMigration)
        XCTAssertTrue(vault.accounts.isEmpty)
    }

    func testMissingIndexHasNothingToUnlock() async {
        let vault = Vault(indexFile: file)
        XCTAssertNil(vault.loadError)
        XCTAssertTrue(vault.accounts.isEmpty)
        do {
            _ = try await vault.unlockAll(reason: "test")
            XCTFail("An empty vault has no protected right to read")
        } catch { XCTAssertEqual(error.localizedDescription, "No accounts have been imported yet.") }
    }

    func testUnreadableIndexDisablesChanges() async throws {
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        let vault = Vault(indexFile: file)
        let loadError = try XCTUnwrap(vault.loadError)
        XCTAssertTrue(loadError.contains("Could not read the account index"))
        do {
            _ = try await vault.importAccounts([try OTPSecret(issuer: "New", username: "new", secret: Data([1]))])
            XCTFail("Changes must be refused while the index is unreadable")
        } catch { XCTAssertEqual(error.localizedDescription, loadError) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }
}
