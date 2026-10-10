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
    // Stored once so the preview vault and the unlocked code list agree on account identities.
    static let accounts: [AccountRecord] = [
        AccountRecord(issuer: "OpenVPN", username: "alex@example.com", bindings: Bindings(bundleIDs: ["org.openvpn.client.app"])),
        AccountRecord(issuer: "GitHub", username: "alex-morgan", bindings: Bindings(hosts: ["github.com"])),
        AccountRecord(issuer: "Google", username: "alex@example.com", bindings: Bindings(hosts: ["accounts.google.com"])),
        AccountRecord(issuer: "AWS", username: "alex · personal", bindings: Bindings())
    ]
    /// Synthetic seeds derived from the sample names, for the unlocked code-list preview only.
    static var protectedAccounts: [ProtectedAccount] {
        accounts.compactMap { record in
            (try? OTPSecret(issuer: record.issuer, username: record.username, secret: Data((record.issuer + " preview seed").utf8)))
                .map { ProtectedAccount(record: record, otp: $0) }
        }
    }
}
