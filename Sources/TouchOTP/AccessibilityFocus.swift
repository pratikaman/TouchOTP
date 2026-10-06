import AppKit
import ApplicationServices
import TouchOTPCore

struct AccessibilityFocus {
    let element: AXUIElement
    let window: AXUIElement
}

// Injectable AX operations allow focus transitions to be tested without another
// app's UI, Accessibility permission, biometric prompts, or real account data.
@MainActor
struct AccessibilityAccess {
    var read: (AXUIElement, String) -> CFTypeRef? = TargetReader.attribute
    var write: (AXUIElement, String, CFTypeRef) -> AXError = {
        AXUIElementSetAttributeValue($0, $1 as CFString, $2)
    }
    var owner: (AXUIElement) -> pid_t? = { element in
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
}

@MainActor
enum AccessibilityFocusReader {
    static func isTextEntryRole(_ role: String) -> Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    static func capture(root: AXUIElement, pid: pid_t, electron: Bool, activateAccessibility: Bool = true,
                        access: AccessibilityAccess) async throws -> AccessibilityFocus {
        func checkFocus() throws {
            try Task.checkCancellation()
            guard access.frontmostPID() == pid else {
                throw OTPError("Focus changed while reading the code field. Nothing was filled. Focus the field and try again.")
            }
        }
        try checkFocus()
        if electron && activateAccessibility {
            // Electron's documented opt-in for third-party assistive applications.
            // Do not turn it off afterwards: another assistive app may need it too.
            // Re-setting it emits another accessibility-support-changed event.
            let enabled = access.read(root, "AXManualAccessibility") as? Bool
            let result = enabled == true ? nil : access.write(root, "AXManualAccessibility", kCFBooleanTrue).rawValue
            FillDiagnostics.accessibility(electron: true, enabled: enabled, result: result)
        }
        let attempts = electron ? 12 : 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        for attempt in 0..<attempts {
            try checkFocus()
            if let element = TargetReader.axElement(access.read(root, kAXFocusedUIElementAttribute)),
               access.owner(element) == pid,
               let window = TargetReader.axElement(access.read(element, kAXWindowAttribute))
                    ?? TargetReader.axElement(access.read(root, kAXFocusedWindowAttribute)),
               access.owner(window) == pid {
                let role = access.read(element, kAXRoleAttribute) as? String ?? ""
                try checkFocus()
                // Electron can briefly expose only its web area while building the
                // tree. A real non-text target is returned for normal validation.
                if !electron || isTextEntryRole(role) || attempt == attempts - 1 || ContinuousClock.now >= deadline {
                    return AccessibilityFocus(element: element, window: window)
                }
            }
            if attempt == attempts - 1 || ContinuousClock.now >= deadline { break }
            try await access.pause()
        }
        try checkFocus()
        throw OTPError("The app has not exposed its code field yet. Click the empty Authenticator Code field and press ⌃⌥⌘O again. If it still fails, use Show code with Touch ID in TouchOTP for manual entry.")
    }
}
