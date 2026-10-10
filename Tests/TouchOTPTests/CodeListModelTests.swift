import XCTest
import TouchOTPCore
@testable import TouchOTP

@MainActor
final class CodeListModelTests: XCTestCase {
    private let record = AccountRecord(issuer: "Fixture", username: "test", bindings: Bindings(hosts: ["example.com"]))
    private func fixture() throws -> ProtectedAccount {
        // RFC 4226 reference seed; the expected code is the published vector.
        ProtectedAccount(record: record, otp: try OTPSecret(issuer: "Fixture", username: "test", secret: Data("12345678901234567890".utf8)))
    }

    func testUnlockedPayloadsProduceCodesAndLockDiscardsThem() throws {
        let model = CodeListModel(vault: Vault(previewAccounts: [record]), previewUnlocked: [try fixture()])
        XCTAssertTrue(model.isUnlocked)
        XCTAssertNotNil(model.unlockedUntil)
        let payload = try XCTUnwrap(model.payload(for: record))
        XCTAssertEqual(try payload.otp.code(at: Date(timeIntervalSince1970: 59)), "287082")
        model.lock()
        XCTAssertFalse(model.isUnlocked)
        XCTAssertNil(model.payload(for: record))
        XCTAssertNil(model.unlockedUntil)
    }

    func testPayloadFollowsTheAccountIdentityNotItsBindings() throws {
        let model = CodeListModel(vault: Vault(previewAccounts: [record]), previewUnlocked: [try fixture()])
        var edited = record
        edited.bindings.hosts = ["other.example"]
        XCTAssertNotNil(model.payload(for: edited), "Changing destinations in the manager must not hide an already unlocked code")
        XCTAssertNil(model.payload(for: AccountRecord(issuer: "Fixture", username: "test")), "A different account never borrows a code")
    }

    func testRevealOnPreviewVaultStaysLockedAndReportsWhy() async {
        let model = CodeListModel(vault: Vault(previewAccounts: PreviewSupport.accounts))
        await model.reveal()
        XCTAssertFalse(model.isUnlocked)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.message, "Preview accounts have no stored secrets.")
    }

    func testPreviewSeedsCoverEverySampleAccount() {
        XCTAssertEqual(PreviewSupport.protectedAccounts.map(\.record), PreviewSupport.accounts)
    }
}
