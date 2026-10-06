import Foundation

// Only the latest attempt's control-flow facts are kept locally. This type has
// no fields for codes, secrets, account names, URLs, UI text, or input contents.
@MainActor
enum FillDiagnostics {
    enum Stage: String, Codable {
        case capture, matchAccount, chooseAccount, authenticate, revalidate, insert, verify
    }
    enum Outcome: String, Codable { case running, completed, failed, cancelled }
    struct Attempt: Codable {
        let version: String
        let started: Date
        var stage: Stage = .capture
        var outcome: Outcome = .running
        var electron: Bool?
        var accessibilityAlreadyEnabled: Bool?
        var accessibilityEnableResult: Int32?
        var sameApp: Bool?
        var sameURL: Bool?
        var sameWindow: Bool?
        var sameField: Bool?
    }
    private(set) static var attempt: Attempt?

    static func begin() {
        attempt = Attempt(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", started: Date())
    }
    static func stage(_ stage: Stage) { attempt?.stage = stage }
    static func accessibility(electron: Bool, enabled: Bool?, result: Int32?) {
        attempt?.electron = electron
        attempt?.accessibilityAlreadyEnabled = enabled
        attempt?.accessibilityEnableResult = result
    }
    static func comparison(app: Bool, url: Bool, window: Bool, field: Bool) {
        attempt?.sameApp = app; attempt?.sameURL = url
        attempt?.sameWindow = window; attempt?.sameField = field
    }
    static func finish(_ outcome: Outcome) {
        attempt?.outcome = outcome
        guard let attempt else { return }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TouchOTP")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("last-fill-diagnostic.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(attempt).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Diagnostics must never interrupt filling. */ }
    }
}
