import Foundation

// MARK: - dpkg

/// The parts of a dpkg status database entry Sentinel uses.
public struct DpkgPackage: Equatable {
    public var name: String
    public var version: String?
    public var architecture: String?
    public var status: String?
    public var depends: String?

    /// dpkg's "want ok state": only "install ok installed" means the package is fully installed and configured.
    public var isInstalled: Bool { status == "install ok installed" }
}

public enum DpkgStatusParser {
    /// Parses a dpkg `status` file (RFC 822-style paragraphs). Continuation lines are ignored; only the fields above
    /// are kept. Unreadable or empty input gives an empty list, never a guess.
    public static func parse(_ text: String) -> [DpkgPackage] {
        var packages: [DpkgPackage] = []
        for paragraph in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in paragraph.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let name = fields["package"], !name.isEmpty else { continue }
            packages.append(DpkgPackage(name: name, version: fields["version"], architecture: fields["architecture"],
                                        status: fields["status"], depends: fields["depends"]))
        }
        return packages
    }

    /// Paths from a dpkg `info/<package>.list` file.
    public static func listedPaths(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
    }
}

/// Compares the files dpkg says a package installed inside an app bundle with the files actually in that bundle.
public struct BundleFileComparison: Equatable {
    /// Files dpkg installed that are no longer there.
    public var missing: [String]
    /// Files in the bundle that dpkg did not install (added afterwards).
    public var unexpected: [String]
    public var listedFileCount: Int

    public var isIntact: Bool { missing.isEmpty && unexpected.isEmpty }

    /// - Parameters:
    ///   - listed: absolute paths from the package's `.list` file (directories included, as dpkg records them).
    ///   - bundlePath: the installed bundle's absolute path, as dpkg records it (e.g. `/var/jb/Applications/X.app`).
    ///   - presentFiles: files found in the bundle, relative to it (e.g. `Info.plist`, `Base.lproj/Main.strings`).
    ///   - isDirectory: whether a listed path is a directory (directories are not compared).
    public static func compare(listed: [String], bundlePath: String, presentFiles: Set<String>,
                               isDirectory: (String) -> Bool) -> BundleFileComparison {
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        let listedFiles = Set(listed.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.filter { !$0.isEmpty && !isDirectory($0) })
        // iOS writes these into an installed bundle itself; they are not a change to the package.
        let systemManaged: (String) -> Bool = { $0.hasPrefix("_CodeSignature/") || $0 == "embedded.mobileprovision" || $0.hasPrefix("SC_Info/") }
        let missing = listedFiles.subtracting(presentFiles).sorted()
        let unexpected = presentFiles.subtracting(listedFiles).filter { !systemManaged($0) }.sorted()
        return BundleFileComparison(missing: missing, unexpected: unexpected, listedFileCount: listedFiles.count)
    }
}

// MARK: - Checks

public struct DeviceSecurityCheck: Equatable, Identifiable {
    public enum Outcome: String, Equatable {
        case pass = "Pass"
        case warning = "Warning"
        case fail = "Needs attention"
        case info = "Information"
        case unavailable = "Not readable"
    }

    public var id: String
    public var title: String
    public var outcome: Outcome
    /// What was observed, in plain words.
    public var detail: String
    /// How it was observed (API or file), so the result can be checked.
    public var evidence: String
    public var remediation: String?

    public init(id: String, title: String, outcome: Outcome, detail: String, evidence: String, remediation: String? = nil) {
        self.id = id
        self.title = title
        self.outcome = outcome
        self.detail = detail
        self.evidence = evidence
        self.remediation = remediation
    }
}

/// Everything the platform layer observed. `nil` means "could not be read", which becomes an explicit
/// "Not readable" result, never a pass.
public struct DeviceSecurityFacts: Equatable {
    public enum Passcode: Equatable { case set, notSet, unknown(String) }
    public enum Biometry: Equatable { case none, touchID(enrolled: Bool), faceID(enrolled: Bool), opticID(enrolled: Bool), unknown(String) }

    public var systemName: String
    public var systemVersion: String
    public var model: String
    public var passcode: Passcode
    public var biometry: Biometry
    /// Data protection class of Sentinel's own Application Support folder, as iOS reports it.
    public var dataProtection: String?
    /// App Transport Security exceptions declared in Sentinel's Info.plist.
    public var atsAllowsArbitraryLoads: Bool
    public var atsExceptionDomains: [String]
    public var atsAllowsLocalNetworking: Bool
    public var bundleIdentifier: String
    public var appVersion: String
    /// SHA-256 of the app's main executable, computed on the device.
    public var executableSHA256: String?
    /// Whether `/var/jb` (the rootless jailbreak prefix) is visible to the app. Nil when the check itself failed.
    public var rootlessPrefixVisible: Bool?
    /// The app's own path, e.g. `/var/jb/Applications/HCGSentinelModern.app` or a `/var/containers/...` path.
    public var bundlePath: String
    /// dpkg's status database as read by the app, or the reason it could not be read.
    public var dpkgStatus: Result<String, ReadFailure>?
    /// dpkg's file list for Sentinel's package, or the reason it could not be read.
    public var packageList: Result<String, ReadFailure>?
    /// Files in the app bundle, relative to it.
    public var bundleFiles: Set<String>
    public var bundleDirectories: Set<String>

    public struct ReadFailure: Error, Equatable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    public init(systemName: String, systemVersion: String, model: String, passcode: Passcode, biometry: Biometry,
                dataProtection: String?, atsAllowsArbitraryLoads: Bool, atsExceptionDomains: [String], atsAllowsLocalNetworking: Bool,
                bundleIdentifier: String, appVersion: String, executableSHA256: String?, rootlessPrefixVisible: Bool?, bundlePath: String,
                dpkgStatus: Result<String, ReadFailure>?, packageList: Result<String, ReadFailure>?,
                bundleFiles: Set<String>, bundleDirectories: Set<String>) {
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.model = model
        self.passcode = passcode
        self.biometry = biometry
        self.dataProtection = dataProtection
        self.atsAllowsArbitraryLoads = atsAllowsArbitraryLoads
        self.atsExceptionDomains = atsExceptionDomains
        self.atsAllowsLocalNetworking = atsAllowsLocalNetworking
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.executableSHA256 = executableSHA256
        self.rootlessPrefixVisible = rootlessPrefixVisible
        self.bundlePath = bundlePath
        self.dpkgStatus = dpkgStatus
        self.packageList = packageList
        self.bundleFiles = bundleFiles
        self.bundleDirectories = bundleDirectories
    }
}

public struct DeviceSecurityReport: Equatable {
    public var generatedAt: Date
    public var checks: [DeviceSecurityCheck]
    /// "Standard" (App Store-style install) or "Unleashed" (installed by a package manager on a jailbroken device).
    public var edition: String

    public var counts: [DeviceSecurityCheck.Outcome: Int] {
        Dictionary(grouping: checks, by: { $0.outcome }).mapValues { $0.count }
    }

    /// Plain text for export. Contains no serial numbers, identifiers for vendor, account data or file contents.
    public func text() -> String {
        var lines = ["HCG Sentinel Unleashed — Device security report", "Generated: \(ISO8601DateFormatter().string(from: generatedAt))",
                     "Edition: \(edition)", ""]
        for check in checks {
            lines.append("[\(check.outcome.rawValue)] \(check.title)")
            lines.append("  \(check.detail)")
            lines.append("  Evidence: \(check.evidence)")
            if let fix = check.remediation { lines.append("  What to do: \(fix)") }
        }
        lines.append("")
        lines.append("Limits: read-only checks of what iOS lets an app read. Nothing was changed. A check that could not be read is reported as such, never as a pass.")
        return lines.joined(separator: "\n")
    }
}

public enum DeviceSecurityEvaluator {
    public static let packageID = "com.hakmicapitalgroup.hcgsentinel"

    public static func evaluate(_ f: DeviceSecurityFacts, now: Date = Date()) -> DeviceSecurityReport {
        var checks: [DeviceSecurityCheck] = []

        switch f.passcode {
        case .set:
            checks.append(.init(id: "passcode", title: "Device passcode", outcome: .pass, detail: "A passcode is set, so iOS encrypts protected data when the iPhone is locked.",
                                evidence: "LocalAuthentication: device-owner authentication is available"))
        case .notSet:
            checks.append(.init(id: "passcode", title: "Device passcode", outcome: .fail,
                                detail: "No passcode is set. Without one, iOS data protection does not protect files when the iPhone is locked, and anyone holding it can open it.",
                                evidence: "LocalAuthentication: passcode not set", remediation: "Settings › Face ID & Passcode (or Touch ID & Passcode) › Turn Passcode On."))
        case .unknown(let reason):
            checks.append(.init(id: "passcode", title: "Device passcode", outcome: .unavailable, detail: "iOS did not say whether a passcode is set.", evidence: reason))
        }

        switch f.biometry {
        case .none:
            checks.append(.init(id: "biometry", title: "Biometric unlock", outcome: .info, detail: "No Face ID or Touch ID is available or set up.", evidence: "LocalAuthentication biometryType: none"))
        case .touchID(let enrolled), .faceID(let enrolled), .opticID(let enrolled):
            let name: String
            switch f.biometry { case .touchID: name = "Touch ID"; case .faceID: name = "Face ID"; default: name = "Optic ID" }
            checks.append(.init(id: "biometry", title: "Biometric unlock", outcome: .info,
                                detail: enrolled ? "\(name) is set up." : "\(name) is available but not set up.", evidence: "LocalAuthentication biometryType"))
        case .unknown(let reason):
            checks.append(.init(id: "biometry", title: "Biometric unlock", outcome: .unavailable, detail: "Not determined.", evidence: reason))
        }

        checks.append(.init(id: "system", title: "System version", outcome: .info,
                            detail: "\(f.systemName) \(f.systemVersion) on \(f.model). Sentinel does not look up whether a newer version exists; check Settings › General › Software Update.",
                            evidence: "UIDevice and the kernel model identifier"))

        if let protection = f.dataProtection {
            let strong = protection.contains("Complete")
            checks.append(.init(id: "data-protection", title: "Sentinel's data protection", outcome: strong ? .pass : .info,
                                detail: "Sentinel's stored files use the iOS protection class \(protection).",
                                evidence: "FileManager file protection attribute of Application Support"))
        } else {
            checks.append(.init(id: "data-protection", title: "Sentinel's data protection", outcome: .unavailable,
                                detail: "iOS reported no protection class for Sentinel's data folder (for example on an unsandboxed install or in the Simulator).",
                                evidence: "FileManager file protection attribute: absent"))
        }

        var ats: [String] = []
        if f.atsAllowsArbitraryLoads { ats.append("arbitrary plain-HTTP loads are allowed") }
        if f.atsAllowsLocalNetworking { ats.append("plain HTTP to local network addresses is allowed (for your own test endpoints and nodes)") }
        if !f.atsExceptionDomains.isEmpty { ats.append("exceptions for \(f.atsExceptionDomains.sorted().joined(separator: ", "))") }
        checks.append(.init(id: "ats", title: "Sentinel's transport security", outcome: f.atsAllowsArbitraryLoads ? .warning : .pass,
                            detail: ats.isEmpty ? "All connections require HTTPS." : "HTTPS is required except: \(ats.joined(separator: "; ")).",
                            evidence: "NSAppTransportSecurity in Sentinel's Info.plist"))

        let unleashed = f.bundlePath.hasPrefix("/var/jb/") || f.bundlePath.hasPrefix("/private/var/jb/")
        switch f.rootlessPrefixVisible {
        case true?:
            checks.append(.init(id: "jailbreak", title: "Device environment", outcome: .info,
                                detail: "The rootless jailbreak prefix /var/jb is visible to Sentinel\(unleashed ? ", and Sentinel itself is installed there" : ""). A jailbroken iPhone runs code iOS did not approve; protections such as code signing and the sandbox are weakened for anything the jailbreak allows.",
                                evidence: "FileManager: /var/jb exists; app path \(unleashed ? "under /var/jb" : "not under /var/jb")",
                                remediation: "Install only packages you trust, from repositories you trust. Sentinel needs no extra privileges."))
        case false?:
            checks.append(.init(id: "jailbreak", title: "Device environment", outcome: .info,
                                detail: "No rootless jailbreak prefix is visible to Sentinel. That is expected for a standard install; a sandboxed app cannot prove a device is not jailbroken.",
                                evidence: "FileManager: /var/jb not visible"))
        case nil:
            checks.append(.init(id: "jailbreak", title: "Device environment", outcome: .unavailable, detail: "Could not be determined.", evidence: "FileManager error"))
        }

        checks.append(contentsOf: packageChecks(f, unleashed: unleashed))
        return DeviceSecurityReport(generatedAt: now, checks: checks, edition: unleashed ? "Unleashed (package-manager install)" : "Standard")
    }

    static func packageChecks(_ f: DeviceSecurityFacts, unleashed: Bool) -> [DeviceSecurityCheck] {
        let hash = f.executableSHA256.map { "Executable SHA-256 \($0)" } ?? "Executable SHA-256 not computed"
        guard unleashed else {
            return [.init(id: "package", title: "Sentinel's package", outcome: .info,
                          detail: "Sentinel is not installed by a package manager here, so there is no dpkg record to compare. \(f.bundleIdentifier) \(f.appVersion).",
                          evidence: hash)]
        }
        var checks: [DeviceSecurityCheck] = []
        switch f.dpkgStatus {
        case .success(let text)?:
            let entry = DpkgStatusParser.parse(text).first { $0.name == packageID }
            if let entry = entry {
                checks.append(.init(id: "package", title: "Sentinel's package record", outcome: entry.isInstalled ? .pass : .warning,
                                    detail: "dpkg records \(packageID) \(entry.version ?? "(no version)") \(entry.architecture ?? ""), status \"\(entry.status ?? "missing")\"." +
                                        (entry.isInstalled ? "" : " The package is not fully installed; reinstall it from your package manager."),
                                    evidence: "dpkg status database"))
            } else {
                checks.append(.init(id: "package", title: "Sentinel's package record", outcome: .warning,
                                    detail: "Sentinel runs from /var/jb, but dpkg has no record of \(packageID). It may have been copied there by hand.",
                                    evidence: "dpkg status database: package not listed",
                                    remediation: "Install Sentinel from HCG Repo Candidate so its files are tracked."))
            }
        case .failure(let failure)?:
            checks.append(.init(id: "package", title: "Sentinel's package record", outcome: .unavailable,
                                detail: "Sentinel could not read dpkg's status database, so the package record could not be checked.", evidence: failure.reason))
        case nil:
            checks.append(.init(id: "package", title: "Sentinel's package record", outcome: .unavailable, detail: "Not attempted.", evidence: "—"))
        }
        switch f.packageList {
        case .success(let text)?:
            let comparison = BundleFileComparison.compare(listed: DpkgStatusParser.listedPaths(text), bundlePath: f.bundlePath,
                                                          presentFiles: f.bundleFiles, isDirectory: { f.bundleDirectories.contains($0) })
            if comparison.isIntact {
                checks.append(.init(id: "package-files", title: "Sentinel's installed files", outcome: .pass,
                                    detail: "All \(comparison.listedFileCount) files dpkg installed are present, and nothing else was added to the app. The package ships no checksums, so file contents are not compared; the executable's SHA-256 is shown for comparison with the build record.",
                                    evidence: "dpkg file list vs. the app bundle · \(hash)"))
            } else {
                var parts: [String] = []
                if !comparison.missing.isEmpty { parts.append("\(comparison.missing.count) missing: \(comparison.missing.prefix(5).joined(separator: ", "))") }
                if !comparison.unexpected.isEmpty { parts.append("\(comparison.unexpected.count) not from the package: \(comparison.unexpected.prefix(5).joined(separator: ", "))") }
                checks.append(.init(id: "package-files", title: "Sentinel's installed files", outcome: .fail,
                                    detail: "The app bundle differs from what dpkg installed: \(parts.joined(separator: "; ")).",
                                    evidence: "dpkg file list vs. the app bundle · \(hash)",
                                    remediation: "Reinstall HCG Sentinel Unleashed from HCG Repo Candidate. If files were added that you did not add, treat the device as untrusted."))
            }
        case .failure(let failure)?:
            checks.append(.init(id: "package-files", title: "Sentinel's installed files", outcome: .unavailable,
                                detail: "dpkg's file list for Sentinel could not be read.", evidence: "\(failure.reason) · \(hash)"))
        case nil:
            break
        }
        return checks
    }
}
