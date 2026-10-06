import Foundation
import TouchOTPCore

struct DestinationDraft: Equatable {
    var hosts: [String]
    var apps: [String]

    init(_ bindings: Bindings) {
        hosts = bindings.hosts
        apps = bindings.bundleIDs
    }

    var bindings: Bindings { Bindings(hosts: hosts.sorted(), bundleIDs: apps.sorted()) }

    mutating func addWebsite(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if trimmed.contains("://") {
            guard var url = URLComponents(string: trimmed), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil else {
                throw OTPError("Use an HTTPS website address, such as https://accounts.google.com.")
            }
            // Keep only the explicit host after validating the scheme, port and
            // credentials. Login URLs may contain paths or temporary query data.
            url.path = ""; url.query = nil; url.fragment = nil
            host = try Bindings.canonicalHost(url.string ?? "")
        } else {
            host = try Bindings.canonicalHost(trimmed)
        }
        guard !hosts.contains(host) else { throw OTPError("This website is already linked.") }
        hosts.append(host)
    }

    mutating func addApp(_ id: String) throws {
        let id = try Bindings.validateBundleID(id)
        guard !apps.contains(id) else { throw OTPError("This app is already linked.") }
        apps.append(id)
    }
}
