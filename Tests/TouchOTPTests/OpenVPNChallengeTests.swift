import XCTest
import ApplicationServices
@testable import TouchOTP

@MainActor
final class OpenVPNChallengeTests: XCTestCase {
    private let field = AXUIElementCreateApplication(92001)
    private let group = AXUIElementCreateApplication(92002)
    private let title = AXUIElementCreateApplication(92003)
    private let prompt = AXUIElementCreateApplication(92004)
    private let otherField = AXUIElementCreateApplication(92005)

    private func reader(titleText: String = "Multi-factor authentication", promptText: String = "Enter Authenticator Code",
                        extraInput: Bool = false, rootRole: String = kAXGroupRole) -> (AXUIElement, String) -> CFTypeRef? {
        { node, key in
            if CFEqual(node, self.field), key == kAXParentAttribute { return self.group }
            if CFEqual(node, self.group) {
                if key == kAXRoleAttribute { return rootRole as CFString }
                if key == kAXChildrenAttribute {
                    return (extraInput ? [self.title, self.prompt, self.field, self.otherField] : [self.title, self.prompt, self.field]) as CFArray
                }
            }
            if CFEqual(node, self.field) || CFEqual(node, self.otherField) {
                if key == kAXRoleAttribute { return kAXTextFieldRole as CFString }
                if key == kAXValueAttribute { XCTFail("Do not read inputs to identify the dialog") }
            }
            if CFEqual(node, self.title) || CFEqual(node, self.prompt) {
                if key == kAXRoleAttribute { return kAXStaticTextRole as CFString }
                if key == kAXValueAttribute { return (CFEqual(node, self.title) ? titleText : promptText) as CFString }
            }
            return nil
        }
    }

    func testRecognizesOpenVPNAuthenticatorDialog() {
        XCTAssertTrue(OpenVPNChallenge.containsCodeField(field, bundleID: "org.openvpn.client.app", read: reader()))
    }
    func testRejectsPasswordPromptOtherAppsAndAmbiguousDialogs() {
        XCTAssertFalse(OpenVPNChallenge.containsCodeField(field, bundleID: "org.openvpn.client.app", read: reader(promptText: "Enter Password")))
        XCTAssertFalse(OpenVPNChallenge.containsCodeField(field, bundleID: "org.openvpn.client.app", read: reader(titleText: "Sign in")))
        XCTAssertFalse(OpenVPNChallenge.containsCodeField(field, bundleID: "com.example.app", read: reader()))
        XCTAssertFalse(OpenVPNChallenge.containsCodeField(field, bundleID: "org.openvpn.client.app", read: reader(extraInput: true)))
        XCTAssertFalse(OpenVPNChallenge.containsCodeField(field, bundleID: "org.openvpn.client.app", read: reader(rootRole: "AXWebArea")))
    }
    func testMaskedFieldMustBeVerifiablyEmpty() {
        XCTAssertTrue(OpenVPNChallenge.isEmpty(value: "", characterCount: nil))
        XCTAssertTrue(OpenVPNChallenge.isEmpty(value: nil, characterCount: 0))
        XCTAssertFalse(OpenVPNChallenge.isEmpty(value: nil, characterCount: nil))
        XCTAssertFalse(OpenVPNChallenge.isEmpty(value: nil, characterCount: 1))
        XCTAssertFalse(OpenVPNChallenge.isEmpty(value: "", characterCount: 1))
        XCTAssertFalse(OpenVPNChallenge.isEmpty(value: "•••", characterCount: 0))
    }
}
