import CryptoKit
import Foundation
import LocalAuthentication
import SentinelCore
import UIKit

/// Collects the facts for Device Security. Read-only: every call here only reads, and anything iOS refuses is
/// passed on as "not readable" with the system's own reason.
enum DeviceSecurityProbe {
    static let jailbreakRoot = "/var/jb"

    static func collect() -> DeviceSecurityFacts {
        let info = Bundle.main.infoDictionary ?? [:]
        let ats = info["NSAppTransportSecurity"] as? [String: Any] ?? [:]
        let bundleURL = Bundle.main.bundleURL
        let rootVisible = FileManager.default.fileExists(atPath: jailbreakRoot)
        let bundlePath = normalizedBundlePath(bundleURL.path, rootVisible: rootVisible)
        let (files, directories) = bundleContents(bundleURL)
        let unleashed = bundlePath.hasPrefix(jailbreakRoot + "/")
        return DeviceSecurityFacts(
            systemName: UIDevice.current.systemName, systemVersion: UIDevice.current.systemVersion, model: DeviceInfo.modelIdentifier,
            passcode: passcode(), biometry: biometry(), dataProtection: dataProtection(),
            atsAllowsArbitraryLoads: (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false,
            atsExceptionDomains: ((ats["NSExceptionDomains"] as? [String: Any]).map { Array($0.keys) }) ?? [],
            atsAllowsLocalNetworking: (ats["NSAllowsLocalNetworking"] as? Bool) ?? false,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown", appVersion: DeviceInfo.appVersion,
            executableSHA256: executableHash(), rootlessPrefixVisible: rootVisible, bundlePath: bundlePath,
            dpkgStatus: unleashed ? read(jailbreakRoot + "/var/lib/dpkg/status") : nil,
            packageList: unleashed ? read(jailbreakRoot + "/var/lib/dpkg/info/\(DeviceSecurityEvaluator.packageID).list") : nil,
            bundleFiles: files, bundleDirectories: directories)
    }

    /// On Dopamine `/var/jb` is a symbolic link into /private/preboot; the bundle path the app sees may be the
    /// resolved one. Rewrite it to the `/var/jb/...` form dpkg records, when it lies under the resolved root.
    static func normalizedBundlePath(_ path: String, rootVisible: Bool) -> String {
        if path.hasPrefix("/private/var/jb/") { return String(path.dropFirst("/private".count)) }
        guard rootVisible, !path.hasPrefix(jailbreakRoot + "/") else { return path }
        let resolved = (jailbreakRoot as NSString).resolvingSymlinksInPath
        guard resolved != jailbreakRoot, path.hasPrefix(resolved + "/") else { return path }
        return jailbreakRoot + path.dropFirst(resolved.count)
    }

    private static func passcode() -> DeviceSecurityFacts.Passcode {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return .set }
        if let error = error, error.code == LAError.passcodeNotSet.rawValue { return .notSet }
        return .unknown(error.map { "LAError \($0.code): \($0.localizedDescription)" } ?? "no answer")
    }

    private static func biometry() -> DeviceSecurityFacts.Biometry {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let enrolled = usable || (error?.code != LAError.biometryNotEnrolled.rawValue)
        switch context.biometryType {
        case .none:
            if let error = error, error.code != LAError.biometryNotAvailable.rawValue, error.code != LAError.biometryNotEnrolled.rawValue {
                return .unknown("LAError \(error.code)")
            }
            return .none
        case .touchID: return .touchID(enrolled: enrolled)
        case .faceID: return .faceID(enrolled: enrolled)
        @unknown default:
            // Optic ID (Apple Vision Pro) or a newer type; reported by its raw value rather than guessed.
            return .unknown("biometry type \(context.biometryType.rawValue)")
        }
    }

    private static func dataProtection() -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let attributes = try? FileManager.default.attributesOfItem(atPath: support.path)
        return (attributes?[.protectionKey] as? FileProtectionType)?.rawValue
    }

    private static func executableHash() -> String? {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ path: String) -> Result<String, DeviceSecurityFacts.ReadFailure> {
        do {
            return .success(try String(contentsOfFile: path, encoding: .utf8))
        } catch {
            let ns = error as NSError
            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
            return .failure(.init("\(path): \(ns.localizedDescription)\(underlying)"))
        }
    }

    private static func bundleContents(_ root: URL) -> (Set<String>, Set<String>) {
        var files = Set<String>(), directories = Set<String>()
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return (files, directories)
        }
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { directories.insert(relative) } else { files.insert(relative) }
            if files.count > 5_000 { break }
        }
        return (files, directories)
    }
}
