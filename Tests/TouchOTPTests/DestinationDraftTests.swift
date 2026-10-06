import XCTest
import TouchOTPCore
@testable import TouchOTP

final class DestinationDraftTests: XCTestCase {
    func testFullLoginURLKeepsOnlyExactHostname() throws {
        var draft = DestinationDraft(Bindings())
        try draft.addWebsite(" https://Accounts.Example.com/login?session=not-stored#otp ")
        XCTAssertEqual(draft.bindings.hosts, ["accounts.example.com"])
    }
    func testUnsafeAddressesCannotBeAdded() {
        for input in ["http://example.com", "https://user:pass@example.com/login", "https://example.com:8443/login", "*.example.com", "example.com/path", "javascript:example.com", "https://example.com.evil./login"] {
            var draft = DestinationDraft(Bindings())
            XCTAssertThrowsError(try draft.addWebsite(input), input)
            XCTAssertTrue(draft.hosts.isEmpty)
        }
    }
    func testDuplicateWebsiteAndAppLeaveDraftUnchanged() throws {
        let original = Bindings(hosts: ["github.com"], bundleIDs: ["org.openvpn.client.app"])
        var draft = DestinationDraft(original)
        XCTAssertThrowsError(try draft.addWebsite("https://github.com/login"))
        XCTAssertThrowsError(try draft.addApp("org.openvpn.client.app"))
        XCTAssertEqual(draft.bindings, original)
    }
    func testDraftDoesNotMutateSavedBindings() throws {
        let saved = Bindings(hosts: ["github.com"])
        var draft = DestinationDraft(saved)
        try draft.addApp("org.openvpn.client.app")
        draft.hosts.removeAll()
        XCTAssertEqual(saved.hosts, ["github.com"])
        XCTAssertTrue(saved.bundleIDs.isEmpty)
        XCTAssertEqual(draft.bindings, Bindings(bundleIDs: ["org.openvpn.client.app"]))
    }
}
