import XCTest
import ApplicationServices
@testable import TouchOTP

@MainActor
final class AccessibilityFocusTests: XCTestCase {
    // Distinct inert AX handles. All AX calls below go through the fixture.
    private let root = AXUIElementCreateApplication(91001)
    private let field = AXUIElementCreateApplication(91002)
    private let window = AXUIElementCreateApplication(91003)
    private let pid: pid_t = 91001

    private func fixture() -> AccessibilityAccess {
        AccessibilityAccess(read: { node, key in
            if CFEqual(node, self.root), key == kAXFocusedUIElementAttribute { return self.field }
            if CFEqual(node, self.root), key == kAXFocusedWindowAttribute { return self.window }
            if CFEqual(node, self.field), key == kAXRoleAttribute { return kAXTextFieldRole as CFString }
            return nil
        }, write: { _, _, _ in .attributeUnsupported }, owner: { _ in self.pid },
           frontmostPID: { self.pid }, pause: {})
    }

    func testElectronFieldAppearsAfterAccessibilityActivation() async throws {
        var enabled = false
        var waits = 0
        var access = fixture()
        let read = access.read
        access.write = { node, key, value in
            XCTAssertTrue(CFEqual(node, self.root))
            XCTAssertEqual(key, "AXManualAccessibility")
            XCTAssertTrue(CFEqual(value, kCFBooleanTrue))
            enabled = true
            return .success
        }
        access.read = { node, key in enabled && waits >= 2 ? read(node, key) : nil }
        access.pause = { waits += 1 }
        let focus = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: true, access: access)
        XCTAssertTrue(enabled)
        XCTAssertTrue(CFEqual(focus.element, field))
        XCTAssertEqual(waits, 2)
    }

    func testOrdinaryNativeFieldDoesNotNeedActivationOrWait() async throws {
        var access = fixture()
        access.write = { _, _, _ in XCTFail("Do not toggle non-Electron apps"); return .failure }
        access.pause = { XCTFail("Already available field should not wait") }
        let focus = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: false, access: access)
        XCTAssertTrue(CFEqual(focus.element, field))
    }

    func testAlreadyEnabledElectronDoesNotReceiveAnotherActivation() async throws {
        var access = fixture()
        let read = access.read
        access.read = { node, key in
            if CFEqual(node, self.root), key == "AXManualAccessibility" { return kCFBooleanTrue }
            return read(node, key)
        }
        access.write = { _, _, _ in XCTFail("Repeated activation can notify/rebuild the app UI"); return .success }
        _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: true, access: access)
    }

    func testAuthenticationRecheckNeverReactivatesAccessibility() async throws {
        var access = fixture()
        access.write = { _, _, _ in XCTFail("Revalidation must only read"); return .success }
        _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: true,
                                                       activateAccessibility: false, access: access)
    }

    func testElectronWaitsForWebAreaToResolveToTextField() async throws {
        var waits = 0
        var access = fixture()
        let read = access.read
        access.read = { node, key in
            if CFEqual(node, self.field), key == kAXRoleAttribute, waits < 2 { return "AXWebArea" as CFString }
            return read(node, key)
        }
        access.pause = { waits += 1 }
        _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: true, access: access)
        XCTAssertEqual(waits, 2)
    }

    func testFocusChangeDuringAttributeReadCancels() async {
        var changed = false
        var access = fixture()
        let read = access.read
        access.read = { node, key in changed = true; return read(node, key) }
        access.frontmostPID = { changed ? 99999 : self.pid }
        do {
            _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: false, access: access)
            XCTFail("Focus changed during the read")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Focus changed")) }
    }

    func testForeignProcessWindowIsRejected() async {
        var access = fixture()
        access.owner = { CFEqual($0, self.window) ? 99999 : self.pid }
        do {
            _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: false, access: access)
            XCTFail("A window owned by another process must not be accepted")
        } catch {}
    }

    func testFocusedFieldsWindowWorksWhenAppWindowAttributeIsMissing() async throws {
        var access = fixture()
        let read = access.read
        access.read = { node, key in
            if CFEqual(node, self.root), key == kAXFocusedWindowAttribute { return nil }
            if CFEqual(node, self.field), key == kAXWindowAttribute { return self.window }
            return read(node, key)
        }
        let focus = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: false, access: access)
        XCTAssertTrue(CFEqual(focus.window, window))
    }

    func testSwitchingAppsWhileTreeLoadsCancels() async {
        var changed = false
        var access = fixture()
        let read = access.read
        access.read = { node, key in changed ? read(node, key) : nil }
        access.frontmostPID = { changed ? 99999 : self.pid }
        access.pause = { changed = true }
        do {
            _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: true, access: access)
            XCTFail("A background app must never become the fill target")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Focus changed")) }
    }

    func testForeignProcessFieldIsRejected() async {
        var access = fixture()
        access.owner = { _ in 99999 }
        do {
            _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: false, access: access)
            XCTFail("A field owned by another process must not be accepted")
        } catch {}
    }

    func testUnavailableFieldStopsAfterBoundedRetries() async {
        var waits = 0
        var access = fixture()
        access.read = { _, _ in nil }
        access.pause = { waits += 1 }
        do {
            _ = try await AccessibilityFocusReader.capture(root: root, pid: pid, electron: true, access: access)
            XCTFail("Must fail when no field is exposed")
        } catch {
            XCTAssertGreaterThan(waits, 0)
            XCTAssertLessThanOrEqual(waits, 15)
            XCTAssertTrue(error.localizedDescription.contains("Show code"))
        }
    }
}
