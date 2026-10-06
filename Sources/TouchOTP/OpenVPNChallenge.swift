import Foundation
import ApplicationServices

@MainActor
enum OpenVPNChallenge {
    // OpenVPN Connect 3.6 labels its masked challenge input "Password Input".
    // Accept it only inside a small MFA dialog that explicitly asks for a code,
    // with the focused element as its sole text input. Never inspect input values.
    static func containsCodeField(_ element: AXUIElement, bundleID: String,
                                  read: @MainActor (AXUIElement, String) -> CFTypeRef? = TargetReader.attribute) -> Bool {
        guard bundleID == "org.openvpn.client.app" else { return false }
        var ancestor = TargetReader.axElement(read(element, kAXParentAttribute))
        for _ in 0..<12 {
            guard let node = ancestor else { break }
            let role = read(node, kAXRoleAttribute) as? String ?? ""
            // Do not infer an OTP context from the whole app or underlying page.
            if [kAXWindowRole, kAXApplicationRole, "AXWebArea"].contains(role) { break }
            if matchesDialog(node, field: element, read: read) { return true }
            ancestor = TargetReader.axElement(read(node, kAXParentAttribute))
        }
        return false
    }

    private static func matchesDialog(_ root: AXUIElement, field: AXUIElement,
                                      read: @MainActor (AXUIElement, String) -> CFTypeRef?) -> Bool {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [AXUIElement] = []
        var title = false, prompt = false, focusedField = false
        var inputCount = 0
        while !queue.isEmpty {
            let (node, depth) = queue.removeLast()
            if seen.contains(where: { CFEqual($0, node) }) { continue }
            guard seen.count < 160, depth <= 8 else { return false }
            seen.append(node)
            let role = read(node, kAXRoleAttribute) as? String ?? ""
            if AccessibilityFocusReader.isTextEntryRole(role) {
                inputCount += 1
                if CFEqual(node, field) { focusedField = true }
                if inputCount > 1 { return false }
                continue
            } else if role == kAXStaticTextRole {
                let text = (read(node, kAXValueAttribute) as? String ?? read(node, kAXTitleAttribute) as? String ?? "")
                    .lowercased().replacingOccurrences(of: "‑", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                title = title || text == "multi-factor authentication" || text == "multi factor authentication"
                prompt = prompt || ["authenticator code", "verification code", "one-time code", "one time code"].contains(where: text.contains)
            }
            if let children = read(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return title && prompt && focusedField && inputCount == 1
    }

    static func isEmpty(value: String?, characterCount: Int?) -> Bool {
        // A missing/redacted value alone is never evidence that a field is empty.
        if let value { return value.isEmpty && (characterCount == nil || characterCount == 0) }
        return characterCount == 0
    }
}
