import Foundation
import CryptoKit

public struct OTPError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum OTPAlgorithm: String, Codable, CaseIterable {
    case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
}

public struct OTPSecret: Codable, Equatable {
    public var issuer: String
    public var username: String
    public var secret: Data
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int

    public init(issuer: String, username: String, secret: Data, algorithm: OTPAlgorithm = .sha1,
                digits: Int = 6, period: Int = 30) throws {
        guard !secret.isEmpty, secret.count <= 1024 else { throw OTPError("The secret is empty or too large.") }
        guard [6, 8].contains(digits), (1...3600).contains(period) else {
            throw OTPError("Only 6- or 8-digit time-based codes with periods from 1 to 3600 seconds are supported.")
        }
        let labels = issuer + username
        guard !labels.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
            throw OTPError("An account label contains unsupported control characters.")
        }
        self.issuer = issuer.isEmpty ? "Unnamed account" : String(issuer.prefix(200))
        self.username = String(username.prefix(300))
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    public func code(at date: Date = Date()) throws -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max),
              period > 0, [6, 8].contains(digits), !secret.isEmpty else { throw OTPError("Invalid code parameters or system time.") }
        var counter = UInt64(seconds / Double(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let digest: [UInt8]
        switch algorithm {
        case .sha1: digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(digest.last! & 0x0f)
        let number = (UInt32(digest[offset] & 0x7f) << 24) | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        return String(format: "%0*u", digits, number % (digits == 6 ? 1_000_000 : 100_000_000))
    }

    public func remaining(at date: Date = Date()) -> TimeInterval {
        Double(period) - date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period))
    }
}

public enum Base32 {
    public static func decode(_ source: String) throws -> Data {
        let normalized = source.uppercased().filter { !$0.isWhitespace }
        let body = normalized.prefix(while: { $0 != "=" })
        let tail = normalized.dropFirst(body.count)
        guard !body.isEmpty, tail.allSatisfy({ $0 == "=" }), [0, 2, 4, 5, 7].contains(body.count % 8),
              tail.isEmpty || (normalized.count % 8 == 0 && tail.count < 8) else {
            throw OTPError("The setup key is not valid Base32.")
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var buffer: UInt32 = 0, bits = 0
        var data = Data()
        for byte in body.utf8 {
            guard let value = alphabet.firstIndex(of: byte) else { throw OTPError("The setup key contains an invalid Base32 character.") }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8((buffer >> bits) & 255))
                buffer &= (1 << bits) - 1
            }
        }
        guard buffer == 0 else { throw OTPError("The setup key has invalid trailing bits.") }
        return data
    }
}

public struct Bindings: Codable, Equatable {
    public var hosts: [String]
    public var bundleIDs: [String]
    public init(hosts: [String] = [], bundleIDs: [String] = []) { self.hosts = hosts; self.bundleIDs = bundleIDs }

    public static func canonicalHost(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains("*"), text.utf8.allSatisfy({ $0 < 128 }),
              let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let host = url.host, host.contains("."), !host.hasSuffix("."),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), host.count <= 253 else {
            throw OTPError("Enter an exact website hostname, such as accounts.google.com. Wildcards, paths and non-HTTPS sites are not supported.")
        }
        return host
    }

    public func matches(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    public static func validateBundleID(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), !text.contains(".."),
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46].contains($0) }) else {
            throw OTPError("Choose a Mac application or enter its bundle identifier.")
        }
        return text
    }
}

public struct AccountRecord: Identifiable, Codable, Equatable {
    public var id: UUID
    public var issuer: String
    public var username: String
    public var bindings: Bindings
    public init(id: UUID = UUID(), issuer: String, username: String, bindings: Bindings = Bindings()) {
        self.id = id; self.issuer = issuer; self.username = username; self.bindings = bindings
    }
}

// Bindings are authenticated along with the seed, so editing the metadata file cannot redirect a code.
public struct ProtectedAccount: Codable, Equatable {
    public var record: AccountRecord
    public var otp: OTPSecret
    public init(record: AccountRecord, otp: OTPSecret) { self.record = record; self.otp = otp }
}

/// Every account's seed and bindings, protected together by one biometric right so a single
/// Touch ID can show all codes. Versions before 0.3.0 stored one `ProtectedAccount` per right.
public struct ProtectedVault: Codable, Equatable {
    public var accounts: [ProtectedAccount]
    public init(accounts: [ProtectedAccount] = []) { self.accounts = accounts }
    public var records: [AccountRecord] { accounts.map(\.record) }
}
