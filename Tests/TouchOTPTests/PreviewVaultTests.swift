import XCTest
import TouchOTPCore
@testable import TouchOTP

@MainActor
final class PreviewVaultTests: XCTestCase {
    func testPreviewAccountsCannotReadOrWriteProtectedStorage() async throws {
        let record = AccountRecord(issuer: "Preview", username: "sample@example.com")
        let vault = Vault(previewAccounts: [record])
        XCTAssertEqual(vault.accounts, [record])
        do {
            _ = try await vault.unlock(record, reason: "Preview test")
            XCTFail("Preview records must never request a stored secret")
        } catch { XCTAssertEqual(error.localizedDescription, "Preview accounts have no stored secrets.") }
        do {
            try await vault.update(record, bindings: Bindings(hosts: ["example.com"]))
            XCTFail("Preview records must never update real accounts")
        } catch { XCTAssertEqual(error.localizedDescription, "Preview accounts cannot be changed.") }
        XCTAssertEqual(vault.accounts, [record])
    }
}
