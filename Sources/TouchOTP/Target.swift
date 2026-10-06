import AppKit
import ApplicationServices
import Carbon
import TouchOTPCore

struct FillTarget {
    let app: NSRunningApplication
    let element: AXUIElement
    let window: AXUIElement
    let url: URL?
    let bundleID: String
    var description: String { url?.host ?? app.localizedName ?? bundleID }
    func matches(_ record: AccountRecord) -> Bool {
        if let url { return record.bindings.matches(url: url) }
        return record.bindings.bundleIDs.contains(bundleID)
    }
}

@MainActor
enum TargetReader {
    // Only these browsers may use their scripting API for authoritative active-tab URLs.
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera"]

    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func browserLike(_ app: NSRunningApplication) -> Bool {
        guard let location = app.bundleURL, let bundle = Bundle(url: location),
              let types = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        return types.contains { item in
            let schemes = item["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains("http") || schemes.contains("https")
        }
    }

    static func browserURL(bundleID: String, window: AXUIElement, app: NSRunningApplication) throws -> URL? {
        if safari.contains(bundleID) || chromium.contains(bundleID) {
            let command = safari.contains(bundleID) ? "URL of current tab of front window" : "URL of active tab of front window"
            // The identifier is selected exclusively from the static allowlists above.
            let source = "with timeout of 5 seconds\n tell application id \"\(bundleID)\" to get \(command)\nend timeout"
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source), let raw = script.executeAndReturnError(&error).stringValue, error == nil,
                  let url = URL(string: raw), url.scheme == "https", url.host != nil else {
                throw OTPError("Could not verify the active HTTPS website. Allow TouchOTP to control this browser in System Settings → Privacy & Security → Automation. Then focus the code field and try again.")
            }
            return url
        }
        if bundleID == "org.mozilla.firefox" || bundleID == "org.mozilla.firefoxdeveloperedition" || browserLike(app) {
            // Firefox exposes the document URL through Accessibility on some versions.
            guard let raw = attribute(window, kAXDocumentAttribute) as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host != nil else {
                throw OTPError("This browser does not expose a verifiable website URL. Use Show code in TouchOTP, or open the login in Safari or Chrome.")
            }
            return url
        }
        return nil
    }

    static func capture(activateAccessibility: Bool = true) async throws -> FillTarget {
        guard AXIsProcessTrusted() else {
            throw OTPError("Enable TouchOTP in System Settings → Privacy & Security → Accessibility so it can fill the focused code field.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier else { throw OTPError("Focus the verification-code field in the app or website first, then press ⌃⌥⌘O.") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let electron = app.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        let focus = try await AccessibilityFocusReader.capture(root: root, pid: app.processIdentifier,
                                                               electron: electron, activateAccessibility: activateAccessibility,
                                                               access: AccessibilityAccess())
        let element = focus.element, window = focus.window
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let maskedChallenge = subrole == kAXSecureTextFieldSubrole
            && OpenVPNChallenge.containsCodeField(element, bundleID: bundleID)
        guard AccessibilityFocusReader.isTextEntryRole(role), subrole != kAXSecureTextFieldSubrole || maskedChallenge else {
            throw OTPError("Focus the empty verification-code field first. A masked field can be filled only when TouchOTP can verify it is OpenVPN’s authenticator-code dialog. Otherwise use Show code with Touch ID for manual entry.")
        }
        let value = attribute(element, kAXValueAttribute) as? String
        let empty = maskedChallenge
            ? OpenVPNChallenge.isEmpty(value: value, characterCount: attribute(element, kAXNumberOfCharactersAttribute) as? Int)
            : value?.isEmpty == true
        guard (attribute(element, kAXEnabledAttribute) as? Bool) != false,
              empty else {
            throw OTPError("The verification-code field must be empty before filling.")
        }
        let url = try browserURL(bundleID: bundleID, window: window, app: app)
        if url != nil {
            // Exclude browser chrome (address/search bars) and refuse cross-origin embedded frames.
            // Accessibility does not consistently expose frame origins, so require the focused
            // web area's own URL to equal the active page URL.
            var ancestor: AXUIElement? = element
            var webURL: URL?
            for _ in 0..<40 {
                guard let node = ancestor else { break }
                if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" {
                    if let raw = attribute(node, "AXURL") as? URL { webURL = raw }
                    else if let raw = attribute(node, "AXURL") as? String { webURL = URL(string: raw) }
                    break
                }
                ancestor = axElement(attribute(node, kAXParentAttribute))
            }
            guard let webURL, webURL == url else {
                throw OTPError("Could not verify that this field belongs to the active page. Embedded login frames and browser address bars are not filled. Use Show code for this page.")
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw OTPError("Focus changed while reading the code field. Nothing was filled. Focus the field and try again.")
        }
        return FillTarget(app: app, element: element, window: window, url: url, bundleID: bundleID)
    }

    static func fill(_ code: String, target: FillTarget) async throws {
        // Never reactivate another app on the user's behalf: a focus change cancels the operation.
        // Allow the system biometric sheet a moment to dismiss; the target must remain frontmost.
        try await Task.sleep(nanoseconds: 250_000_000)
        FillDiagnostics.stage(.revalidate)
        let current = try await capture(activateAccessibility: false)
        let sameApp = current.app.processIdentifier == target.app.processIdentifier && current.bundleID == target.bundleID
        let sameURL = current.url == target.url
        let sameField = CFEqual(current.element, target.element)
        let sameWindow = CFEqual(current.window, target.window)
        FillDiagnostics.comparison(app: sameApp, url: sameURL, window: sameWindow, field: sameField)
        guard sameApp, sameURL, sameField, sameWindow else {
            throw OTPError("The app, page or focused field changed during authentication. Nothing was filled. Focus the field and try again.")
        }
        guard [6, 8].contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw OTPError("Invalid generated code.") }
        let root = AXUIElementCreateApplication(target.app.processIdentifier)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier,
              let focused = axElement(attribute(root, kAXFocusedUIElementAttribute)), CFEqual(focused, target.element) else {
            throw OTPError("Focus changed before insertion. Nothing was filled.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw OTPError("Could not create a text insertion event.") }
        let units = Array(code.utf16)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
        down.flags = []; up.flags = []
        FillDiagnostics.stage(.insert)
        // One text event minimizes partial fills. The target PID prevents delivery to another process.
        down.postToPid(target.app.processIdentifier)
        up.postToPid(target.app.processIdentifier)
        // No clipboard writes and no Return/Submit event.
        FillDiagnostics.stage(.verify)
        try await Task.sleep(nanoseconds: 200_000_000)
        if let value = attribute(target.element, kAXValueAttribute) as? String,
           value.count < code.count,
           let focused = axElement(attribute(root, kAXFocusedUIElementAttribute)), CFEqual(focused, target.element) {
            throw OTPError("This field did not accept the complete code. Clear any partial entry and use Show code in TouchOTP for manual entry.")
        }
    }
}

@MainActor
final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, pointer in
            guard let pointer else { return noErr }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action?() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                  Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        let identifier = EventHotKeyID(signature: 0x544F5450, id: 1)
        return RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(controlKey | optionKey | cmdKey), identifier,
                                  GetApplicationEventTarget(), 0, &reference) == noErr
    }
}
