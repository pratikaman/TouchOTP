import SwiftUI
import TouchOTPCore

enum PreviewSupport {
    static var importCollector: BatchCollector {
        var collector = BatchCollector()
        // Public RFC-style fixture used only by the offscreen preview renderer.
        if let batch = try? OTPImporter.parse("otpauth://totp/Linear:alex%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Linear") {
            try? collector.add(batch)
        }
        return collector
    }
    static var accounts: [AccountRecord] {
        [
            AccountRecord(issuer: "OpenVPN", username: "alex@example.com", bindings: Bindings(bundleIDs: ["org.openvpn.client.app"])),
            AccountRecord(issuer: "GitHub", username: "alex-morgan", bindings: Bindings(hosts: ["github.com"])),
            AccountRecord(issuer: "Google", username: "alex@example.com", bindings: Bindings(hosts: ["accounts.google.com"])),
            AccountRecord(issuer: "AWS", username: "alex · personal", bindings: Bindings())
        ]
    }
}
