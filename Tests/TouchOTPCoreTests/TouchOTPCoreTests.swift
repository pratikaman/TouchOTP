import XCTest
@testable import TouchOTPCore

final class TouchOTPCoreTests: XCTestCase {
    // RFC 6238 Appendix B: six timestamps, all three hash algorithms.
    func testRFC6238Vectors() throws {
        let times: [TimeInterval] = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000]
        let seeds = ["12345678901234567890", "12345678901234567890123456789012", "1234567890123456789012345678901234567890123456789012345678901234"]
        let expected = [
            ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"],
            ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"],
            ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"]
        ]
        for (i, algorithm) in OTPAlgorithm.allCases.enumerated() {
            let otp = try OTPSecret(issuer: "RFC fixture", username: "test", secret: Data(seeds[i].utf8), algorithm: algorithm, digits: 8)
            for (j, time) in times.enumerated() { XCTAssertEqual(try otp.code(at: Date(timeIntervalSince1970: time)), expected[i][j]) }
        }
    }
    func testRFC4226SixDigitVectors() throws {
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        let otp = try OTPSecret(issuer: "Fixture", username: "test", secret: Data("12345678901234567890".utf8))
        for (i, code) in expected.enumerated() { XCTAssertEqual(try otp.code(at: Date(timeIntervalSince1970: Double(i * 30))), code) }
    }
    func testInvalidTime() throws {
        let otp = try OTPSecret(issuer: "Test", username: "test", secret: Data([1]))
        XCTAssertThrowsError(try otp.code(at: Date(timeIntervalSince1970: -1)))
        XCTAssertThrowsError(try otp.code(at: Date(timeIntervalSince1970: .infinity)))
    }
    func testInvalidOTPParameters() {
        XCTAssertThrowsError(try OTPSecret(issuer: "Test", username: "test", secret: Data()))
        XCTAssertThrowsError(try OTPSecret(issuer: "Test", username: "test", secret: Data([1]), digits: 7))
        XCTAssertThrowsError(try OTPSecret(issuer: "Test", username: "test", secret: Data([1]), period: 0))
    }
    func testPromptControlCharactersRejected() {
        XCTAssertThrowsError(try OTPImporter.parse("otpauth://totp/Fake%0Aname?secret=MY"))
        XCTAssertThrowsError(try OTPSecret(issuer: "Test\u{202E}spoof", username: "test", secret: Data([1])))
    }
    func testBase32RFC4648() throws {
        let vectors = [("MY======", "f"), ("MZXQ====", "fo"), ("MZXW6===", "foo"), ("MZXW6YQ=", "foob"), ("MZXW6YTB", "fooba"), ("MZXW6YTBOI======", "foobar")]
        for (encoded, plain) in vectors { XCTAssertEqual(try Base32.decode(encoded), Data(plain.utf8)) }
        XCTAssertEqual(try Base32.decode("mzxw 6ytb oi"), Data("foobar".utf8))
    }
    func testBase32RejectsMalformed() {
        for value in ["", "A", "MY=====", "M0======", "MZ======", "MY======A", "MY=======", "MZXW6YTB!"] {
            XCTAssertThrowsError(try Base32.decode(value), value)
        }
    }
    func testStandardImport() throws {
        let result = try OTPImporter.parse("otpauth://totp/Example%3Aalice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA256&digits=8&period=60")
        XCTAssertEqual(result.accounts.count, 1)
        let account = result.accounts[0]
        XCTAssertEqual(account.issuer, "Example")
        XCTAssertEqual(account.username, "alice@example.com")
        XCTAssertEqual(account.algorithm, .sha256)
        XCTAssertEqual(account.digits, 8)
        XCTAssertEqual(account.period, 60)
    }
    func testImportRejectsUnsupportedAndDuplicateParameters() {
        for input in [
            "otpauth://hotp/Example?secret=JBSWY3DPEHPK3PXP&counter=1",
            "otpauth://totp/Example?secret=JBSWY3DPEHPK3PXP&secret=MY",
            "otpauth://totp/Example?secret=MY&algorithm=MD5",
            "otpauth://totp/Example?secret=MY&period=0",
            "otpauth://totp/Example?secret=MY&digits=5",
            "https://evil.example/otpauth?secret=MY",
            "otpauth-migration://offline?data=broken"
        ] { XCTAssertThrowsError(try OTPImporter.parse(input)) }
    }
    func testExactWebsiteMatchingAndPhishingCases() throws {
        let binding = Bindings(hosts: [try Bindings.canonicalHost(" https://accounts.google.com/ ")])
        XCTAssertTrue(binding.matches(url: URL(string: "https://accounts.google.com/signin?step=2")!))
        XCTAssertTrue(binding.matches(url: URL(string: "https://accounts.google.com:443/signin")!))
        for url in ["http://accounts.google.com", "https://accounts.google.com.evil.example", "https://evilaccounts.google.com", "https://google.com", "https://accounts.google.com@evil.example", "https://user@accounts.google.com", "https://accounts.google.com:8443", "https://accounts.google.com."] {
            XCTAssertFalse(binding.matches(url: URL(string: url)!), url)
        }
    }
    func testInvalidHostnameBindings() {
        for host in ["*.google.com", "google.com/path", "http://google.com", "google.com:8443", "google.com?x=y", "user@google.com", "google..com", "-google.com", "google.com.", "localhost", "gооgle.com"] {
            XCTAssertThrowsError(try Bindings.canonicalHost(host), host)
        }
    }
    func testBundleIDs() throws {
        XCTAssertEqual(try Bindings.validateBundleID(" com.example.App "), "com.example.App")
        for id in ["*", "com.example.*", "com..example", "com/example", "com.example\"", ".com.example"] {
            XCTAssertThrowsError(try Bindings.validateBundleID(id))
        }
    }

    // Construct synthetic migration wire fixtures; no real authenticator data enters the tests.
    private func varint(_ value: UInt64) -> Data {
        var value = value, output = Data()
        repeat {
            let byte = UInt8(value & 127); value >>= 7
            output.append(byte | (value > 0 ? 128 : 0))
        } while value > 0
        return output
    }
    private func number(_ tag: UInt64, _ value: UInt64) -> Data { varint(tag << 3) + varint(value) }
    private func blob(_ tag: UInt64, _ bytes: Data) -> Data { varint((tag << 3) | 2) + varint(UInt64(bytes.count)) + bytes }
    private func migration(size: UInt64 = 1, index: UInt64 = 0, batchID: UInt64 = 42, kind: UInt64 = 2, algorithm: UInt64 = 1, digits: UInt64 = 1, version: UInt64 = 1, extraAccountFields: Data = Data()) -> String {
        let parameters = blob(1, Data("12345678901234567890".utf8))
            + blob(2, Data("Example:alice@example.com".utf8)) + blob(3, Data("Example".utf8))
            + number(4, algorithm) + number(5, digits) + number(6, kind)
        let payload = blob(1, parameters + extraAccountFields) + number(2, version) + number(3, size) + number(4, index) + number(5, batchID)
        return migrationURL(payload)
    }
    private func migrationURL(_ data: Data) -> String {
        var url = URLComponents()
        url.scheme = "otpauth-migration"; url.host = "offline"
        url.queryItems = [URLQueryItem(name: "data", value: data.base64EncodedString())]
        return url.string!
    }
    func testGoogleExportImport() throws {
        let batch = try OTPImporter.parse(migration())
        XCTAssertEqual(batch.accounts[0].issuer, "Example")
        XCTAssertEqual(batch.accounts[0].username, "alice@example.com")
        XCTAssertEqual(try batch.accounts[0].code(at: Date(timeIntervalSince1970: 59)), "287082")
    }
    func testGoogleExportVersionTwo() throws {
        let old = try OTPImporter.parse(migration(version: 1))
        let current = try OTPImporter.parse(migration(version: 2))
        XCTAssertEqual(current.accounts, old.accounts)
        XCTAssertEqual(current.batchSize, 1)
        XCTAssertEqual(try current.accounts[0].code(at: Date(timeIntervalSince1970: 59)), "287082")
    }
    func testGoogleExportVersionTwoWithAdditionalMetadata() throws {
        let additionalFields = blob(8, Data("synthetic-account-id".utf8)) + number(20, 42)
        let batch = try OTPImporter.parse(migration(kind: 0, algorithm: 0, digits: 0, version: 2, extraAccountFields: additionalFields))
        XCTAssertEqual(batch.accounts[0].algorithm, .sha1)
        XCTAssertEqual(batch.accounts[0].digits, 6)
        XCTAssertEqual(try batch.accounts[0].code(at: Date(timeIntervalSince1970: 59)), "287082")
    }
    func testGoogleExportVersionTwoMultipleQRCodes() throws {
        var collector = BatchCollector()
        try collector.add(OTPImporter.parse(migration(size: 2, index: 1, version: 2)))
        XCTAssertFalse(collector.complete)
        try collector.add(OTPImporter.parse(migration(size: 2, index: 0, version: 2)))
        XCTAssertTrue(collector.complete)
        XCTAssertEqual(collector.accounts.count, 2)
    }
    func testGoogleExportVersionTwoRetainsAccountValidation() {
        XCTAssertThrowsError(try OTPImporter.parse(migration(kind: 1, version: 2))) { error in
            XCTAssertTrue(error.localizedDescription.contains("HOTP"))
        }
        XCTAssertThrowsError(try OTPImporter.parse(migration(algorithm: 4, version: 2))) { error in
            XCTAssertTrue(error.localizedDescription.contains("hash algorithm"))
        }
        XCTAssertThrowsError(try OTPImporter.parse(migration(size: 2, index: 2, version: 2))) { error in
            XCTAssertTrue(error.localizedDescription.contains("batch settings"))
        }
    }
    func testUnknownMigrationVersionsRemainRejected() {
        for version: UInt64 in [3, 255, UInt64.max] {
            XCTAssertThrowsError(try OTPImporter.parse(migration(version: version))) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsupported version"))
            }
        }
    }
    func testGoogleExportWithOmittedDefaultParameters() throws {
        // Public synthetic Example fixture, independently encoded by a migration decoder:
        // https://github.com/digitalduke/otpauth-migration-decoder
        // The optional algorithm and digit-count fields are omitted.
        let sample = "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTAC"
        let batch = try OTPImporter.parse(sample)
        XCTAssertEqual(batch.accounts.count, 1)
        XCTAssertEqual(batch.accounts[0].algorithm, .sha1)
        XCTAssertEqual(batch.accounts[0].digits, 6)
        XCTAssertEqual(batch.accounts[0].username, "alice@google.com")
        XCTAssertEqual(batch.accounts[0].secret, try Base32.decode("JBSWY3DPEHPK3PXP"))
    }
    func testGoogleExportWithExplicitUnspecifiedParameters() throws {
        let batch = try OTPImporter.parse(migration(kind: 0, algorithm: 0, digits: 0))
        XCTAssertEqual(batch.accounts[0].algorithm, .sha1)
        XCTAssertEqual(batch.accounts[0].digits, 6)
        XCTAssertEqual(try batch.accounts[0].code(at: Date(timeIntervalSince1970: 59)), "287082")
    }
    func testGoogleExportAlgorithms() throws {
        XCTAssertEqual(try OTPImporter.parse(migration(algorithm: 2, digits: 2)).accounts[0].algorithm, .sha256)
        XCTAssertEqual(try OTPImporter.parse(migration(algorithm: 3)).accounts[0].algorithm, .sha512)
        for input in [migration(kind: 1), migration(kind: 3), migration(algorithm: 4), migration(digits: 3), migration(size: 0), migration(size: 2, index: 2)] {
            XCTAssertThrowsError(try OTPImporter.parse(input))
        }
    }
    func testMultiQRExportOutOfOrderAndRepeatedScan() throws {
        var collector = BatchCollector()
        try collector.add(OTPImporter.parse(migration(size: 2, index: 1)))
        XCTAssertFalse(collector.complete)
        try collector.add(OTPImporter.parse(migration(size: 2, index: 1)))
        XCTAssertEqual(collector.received, 1)
        try collector.add(OTPImporter.parse(migration(size: 2, index: 0)))
        XCTAssertTrue(collector.complete)
        XCTAssertEqual(collector.accounts.count, 2)
    }
    func testMixedAndConflictingBatchesRejected() throws {
        var collector = BatchCollector()
        try collector.add(OTPImporter.parse(migration(size: 2, index: 0)))
        XCTAssertThrowsError(try collector.add(OTPImporter.parse(migration(size: 2, index: 1, batchID: 43))))
        XCTAssertThrowsError(try collector.add(OTPImporter.parse(migration(size: 2, index: 0, algorithm: 2))))
        XCTAssertFalse(collector.complete)
    }
    func testMalformedProtobufFailsWithoutCrash() {
        let fixtures = [Data([0]), Data([10, 255, 255, 255, 127]), Data([16] + Array(repeating: 255, count: 11)), Data([11]), Data([10, 1, 0]), Data([16, 1, 16, 1])]
        for data in fixtures { XCTAssertThrowsError(try OTPImporter.parse(migrationURL(data))) }
    }
    func testRandomMalformedInputNeverCrashes() {
        // Deterministic bounded fuzz coverage for protobuf lengths, tags, UTF-8 and varints.
        var state: UInt64 = 12345
        for length in 1...128 {
            var data = Data()
            for _ in 0..<length { state = state &* 6364136223846793005 &+ 1; data.append(UInt8(truncatingIfNeeded: state >> 32)) }
            _ = try? OTPImporter.parse(migrationURL(data))
        }
    }
    func testProtectedRecordRoundTripIncludesBindings() throws {
        let record = AccountRecord(issuer: "Test", username: "test", bindings: Bindings(hosts: ["example.com"]))
        let payload = ProtectedAccount(record: record, otp: try OTPSecret(issuer: "Test", username: "test", secret: Data([1])))
        let restored = try JSONDecoder().decode(ProtectedAccount.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(restored.record, record)
        var tampered = record; tampered.bindings.hosts = ["evil.example"]
        XCTAssertNotEqual(restored.record, tampered)
    }
}
