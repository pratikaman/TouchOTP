import Foundation

public struct ImportBatch {
    public var accounts: [OTPSecret]
    public var batchID: UInt64?
    public var batchSize: Int
    public var batchIndex: Int
}

public enum OTPImporter {
    public static func parse(_ text: String) throws -> ImportBatch {
        guard text.utf8.count <= 256_000, let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OTPError("That QR code is not an authenticator export.")
        }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw OTPError("The authenticator link has duplicate or missing parameters.") }
            query[item.name] = value
        }
        if url.scheme == "otpauth" {
            guard url.host == "totp", let raw = query["secret"] else { throw OTPError("Only time-based authenticator codes (TOTP) are supported. Counter-based HOTP codes cannot be imported.") }
            let label = String(url.path.dropFirst())
            let pieces = label.split(separator: ":", maxSplits: 1).map(String.init)
            let issuer = query["issuer"] ?? (pieces.count == 2 ? pieces[0] : label)
            let username = pieces.count == 2 ? pieces[1] : label
            guard let algorithm = OTPAlgorithm(rawValue: (query["algorithm"] ?? "SHA1").uppercased()),
                  let digits = Int(query["digits"] ?? "6"), let period = Int(query["period"] ?? "30") else {
                throw OTPError("This account uses unsupported code parameters.")
            }
            let account = try OTPSecret(issuer: issuer, username: username, secret: Base32.decode(raw), algorithm: algorithm, digits: digits, period: period)
            return ImportBatch(accounts: [account], batchID: nil, batchSize: 1, batchIndex: 0)
        }
        guard url.scheme == "otpauth-migration", url.host == "offline", let encoded = query["data"],
              let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw OTPError("Use a Google Authenticator export QR or an otpauth setup QR.")
        }
        let payload = try Proto.fields(data)
        let version = try Proto.integer(payload, 2, default: 1)
        let size = try Proto.integer(payload, 3, default: 1)
        let index = try Proto.integer(payload, 4, default: 0)
        // Accept the v2 envelope seen in current Google Authenticator exports.
        // Account fields still pass the checks below; additive protobuf metadata is skipped.
        guard version <= 2 else { throw OTPError("This Google Authenticator export uses an unsupported version (\(version)).") }
        guard (1...100).contains(size), index < size else {
            throw OTPError("The Google Authenticator export has invalid QR batch settings (size \(size), index \(index)).")
        }
        let rawAccounts = payload.filter { $0.tag == 1 }
        guard !rawAccounts.isEmpty, rawAccounts.count <= 100 else { throw OTPError("The export contains no accounts or too many accounts.") }
        let accounts = try rawAccounts.map { field -> OTPSecret in
            guard let blob = field.bytes else { throw OTPError("Invalid exported account.") }
            let fields = try Proto.fields(blob)
            guard let secret = try Proto.bytes(fields, 1) else { throw OTPError("An exported account has no secret.") }
            let label = try Proto.string(fields, 2)
            let issuer = try Proto.string(fields, 3)
            let algorithm: OTPAlgorithm
            // Optional migration settings also use UNSPECIFIED to mean the default.
            // Reference: Aegis GoogleAuthInfo.parseExportUri (beemdevelopment/Aegis).
            let rawAlgorithm = try Proto.integer(fields, 4, default: 0)
            switch rawAlgorithm {
            case 0, 1: algorithm = .sha1
            case 2: algorithm = .sha256
            case 3: algorithm = .sha512
            default: throw OTPError("An exported account has an unsupported hash algorithm (\(rawAlgorithm)).")
            }
            let digits: Int
            let rawDigits = try Proto.integer(fields, 5, default: 0)
            switch rawDigits {
            case 0, 1: digits = 6
            case 2: digits = 8
            default: throw OTPError("An exported account has an unsupported code length setting (\(rawDigits)).")
            }
            switch try Proto.integer(fields, 6, default: 0) {
            case 0, 2: break
            case 1: throw OTPError("This export includes a counter-based HOTP account. Export only time-based accounts.")
            default: throw OTPError("An exported account uses an unsupported authenticator type.")
            }
            let prefix = issuer + ":"
            let username = !issuer.isEmpty && label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
            return try OTPSecret(issuer: issuer, username: username, secret: secret, algorithm: algorithm, digits: digits)
        }
        let batchID = try Proto.integer(payload, 5, default: 0)
        return ImportBatch(accounts: accounts, batchID: batchID, batchSize: Int(size), batchIndex: Int(index))
    }
}

// Strict, bounded protobuf wire decoder for Google's migration payload. Unknown fields are skipped.
private enum Proto {
    struct Field { var tag: UInt64; var integer: UInt64?; var bytes: Data? }
    static func fields(_ data: Data) throws -> [Field] {
        let bytes = Array(data)
        var offset = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<10 {
                guard offset < bytes.count else { throw OTPError("Truncated export QR.") }
                let byte = bytes[offset]; offset += 1
                guard i < 9 || byte <= 1 else { throw OTPError("Invalid export integer.") }
                result |= UInt64(byte & 0x7f) << (7 * i)
                if byte & 0x80 == 0 { return result }
            }
            throw OTPError("Invalid export integer.")
        }
        var fields: [Field] = []
        while offset < bytes.count {
            guard fields.count < 1000 else { throw OTPError("Export QR is too complex.") }
            let key = try varint(), tag = key >> 3, wire = key & 7
            guard tag > 0 else { throw OTPError("Invalid export field.") }
            if wire == 0 { fields.append(Field(tag: tag, integer: try varint())) }
            else if wire == 2 {
                let count = try varint()
                guard count <= UInt64(bytes.count - offset) else { throw OTPError("Truncated export QR.") }
                fields.append(Field(tag: tag, bytes: Data(bytes[offset..<offset + Int(count)])))
                offset += Int(count)
            } else if wire == 1 || wire == 5 {
                let count = wire == 1 ? 8 : 4
                guard count <= bytes.count - offset else { throw OTPError("Truncated export QR.") }
                offset += count
            } else { throw OTPError("Unsupported export encoding.") }
        }
        return fields
    }
    static func unique(_ fields: [Field], _ tag: UInt64) throws -> Field? {
        let found = fields.filter { $0.tag == tag }
        guard found.count <= 1 else { throw OTPError("Duplicate export field.") }
        return found.first
    }
    static func integer(_ fields: [Field], _ tag: UInt64, default fallback: UInt64) throws -> UInt64 {
        guard let field = try unique(fields, tag) else { return fallback }
        guard let value = field.integer else { throw OTPError("Invalid export field type.") }
        return value
    }
    static func bytes(_ fields: [Field], _ tag: UInt64) throws -> Data? {
        guard let field = try unique(fields, tag) else { return nil }
        guard let value = field.bytes else { throw OTPError("Invalid export field type.") }
        return value
    }
    static func string(_ fields: [Field], _ tag: UInt64) throws -> String {
        guard let data = try bytes(fields, tag) else { return "" }
        guard let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw OTPError("Invalid export label.")
        }
        return text
    }
}

public struct BatchCollector {
    private var batches: [Int: ImportBatch] = [:]
    public init() {}
    public var received: Int { batches.count }
    public var expected: Int { batches.values.first?.batchSize ?? 0 }
    public var complete: Bool { expected > 0 && received == expected }
    public var accounts: [OTPSecret] { batches.keys.sorted().flatMap { batches[$0]!.accounts } }
    public mutating func add(_ batch: ImportBatch) throws {
        if let first = batches.values.first {
            guard first.batchID == batch.batchID, first.batchSize == batch.batchSize else {
                throw OTPError("This QR belongs to a different export. Cancel and start a new import.")
            }
        }
        if let previous = batches[batch.batchIndex] {
            guard previous.accounts == batch.accounts else { throw OTPError("Conflicting QR codes in the same export.") }
            return
        }
        batches[batch.batchIndex] = batch
    }
}
