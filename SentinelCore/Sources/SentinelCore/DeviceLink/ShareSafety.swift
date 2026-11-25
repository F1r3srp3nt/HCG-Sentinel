import Foundation

// Sharing a report with a paired device (HCG Device Link) is always the
// user's explicit, one-off decision:
//
//   1. the report is built once and redacted in two passes (Sentinel's rules
//      with the sharing rules below, then the shared `hcg.redaction/1` rules),
//      counting what each rule removed;
//   2. the encoded bytes are checked strictly for anything that still looks
//      like a credential or sensitive host information (`SensitiveContentCheck`);
//   3. the review screen shows exactly those bytes, their size and SHA-256;
//   4. only after the user confirms are the same bytes sent (`ReportShareService`).
//
// Nothing here sends anything, and nothing remembers a decision.

/// Who the report says it is from. `deviceName` is a neutral model name
/// ("iPhone"), never the user's personal device name.
public struct ShareOrigin: Equatable, Sendable {
    public var installationId: String
    public var deviceName: String
    public var appVersion: String

    public init(installationId: String, deviceName: String, appVersion: String) {
        self.installationId = installationId
        self.deviceName = deviceName
        self.appVersion = appVersion
    }
}

/// How many replacements one redaction rule made while a report was built.
public struct RedactionCount: Equatable, Sendable {
    public var rule: String
    public var count: Int

    public init(rule: String, count: Int) {
        self.rule = rule
        self.count = count
    }
}

/// The redaction used for every string of a shared report. Pass 1 is
/// Sentinel's `Redactor` plus the sharing rules (home folders, user names,
/// personal device names, host names, serial numbers, tokens); pass 2 is the
/// shared `hcg.redaction/1` strict rules (credentials, private keys, e-mail,
/// IP and MAC addresses). Every replacement is counted per rule.
public final class ShareRedaction {
    public struct Context: Equatable, Sendable {
        /// Names that may appear (the server's display name).
        public var allowedNames: [String]
        /// Exact strings that must never appear: this device's personal name,
        /// the server's network address, the signed-in account's e-mail.
        public var sensitiveNames: [String]

        public init(allowedNames: [String] = [], sensitiveNames: [String] = []) {
            self.allowedNames = allowedNames
            self.sensitiveNames = sensitiveNames
        }
    }

    public enum Rule: String, CaseIterable, Sendable {
        case sentinelCredentials = "Credentials (Sentinel rules)"
        case sharedCredentials = "Credentials (hcg.redaction/1)"
        case privateKeys = "Private keys"
        case tokens = "API keys and tokens"
        case emails = "E-mail addresses"
        case ipAddresses = "IP addresses"
        case macAddresses = "MAC addresses"
        case knownNames = "This device's name and the server's address"
        case homePaths = "Home folder paths (user names)"
        case userNames = "User names"
        case deviceNames = "Personal device names"
        case hostNames = "Host names"
        case serialNumbers = "Serial numbers and device identifiers"
    }

    public let context: Context
    public private(set) var counts: [Rule: Int] = [:]

    public init(context: Context = Context()) {
        var c = context
        c.allowedNames = context.allowedNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Generic model names ("iPhone", what iOS 16+ reports as the device name) are not personal.
        let generic = ["iphone", "ipad", "ipod touch", "mac", "ios device"]
        c.sensitiveNames = context.sensitiveNames.filter { $0.trimmingCharacters(in: .whitespaces).count >= 3 }
            .filter { !generic.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            .filter { s in !c.allowedNames.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
        self.context = c
    }

    /// Non-zero counts, in a fixed order.
    public var summary: [RedactionCount] {
        Rule.allCases.compactMap { r in counts[r].flatMap { $0 > 0 ? RedactionCount(rule: r.rawValue, count: $0) : nil } }
    }

    public func callAsFunction(_ s: String) -> String { redact(s) }

    public func redact(_ input: String) -> String {
        let (protected, tokens) = Self.protect(input, names: context.allowedNames)
        var s = protected
        // Exact strings first, before other rules change them.
        for name in context.sensitiveNames {
            s = apply(NSRegularExpression.literal(name), "[REDACTED NAME]", .knownNames, s)
        }
        // Pass 1a: Sentinel's credential rules.
        let sentinel = Redactor.standard.textCounting(s)
        s = sentinel.text
        add(.sentinelCredentials, sentinel.replacements)
        // Pass 2 runs before the host rules so e-mail addresses are masked whole.
        s = sharedPass(s)
        // Pass 1b: sharing rules.
        for (rule, re, template) in ShareRules.redactions { s = apply(re, template, rule, s) }
        // The shared rules again (idempotent; DiagnosticReport.make applies them too).
        s = sharedPass(s)
        return Self.restore(s, tokens)
    }

    /// `hcg.redaction/1` (strict), counted by the placeholders it adds.
    private func sharedPass(_ s: String) -> String {
        let out = ReportRedactor.strict.redact(s)
        guard out != s else { return out }
        for (placeholder, rule) in [("[REDACTED PRIVATE KEY]", Rule.privateKeys), ("[REDACTED EMAIL]", .emails), ("[REDACTED MAC]", .macAddresses),
                                    ("[REDACTED IP]", .ipAddresses), ("[REDACTED]", .sharedCredentials)] {
            add(rule, max(0, out.occurrences(of: placeholder) - s.occurrences(of: placeholder)))
        }
        return out
    }

    private func apply(_ re: NSRegularExpression?, _ template: String, _ rule: Rule, _ s: String) -> String {
        guard let re = re else { return s }
        let r = Redactor.replaceCounting(re, template, in: s)
        add(rule, r.replacements)
        return r.text
    }

    private func add(_ rule: Rule, _ n: Int) {
        if n > 0 { counts[rule, default: 0] += n }
    }

    // Allowed names are swapped for private-use markers while the rules run.
    static func protect(_ s: String, names: [String]) -> (String, [String: String]) {
        var out = s
        var tokens: [String: String] = [:]
        for (i, name) in names.sorted(by: { $0.count > $1.count }).enumerated() where out.range(of: name) != nil {
            let token = "\u{E000}\(i)\u{E001}"
            tokens[token] = name
            out = out.replacingOccurrences(of: name, with: token)
        }
        return (out, tokens)
    }

    static func restore(_ s: String, _ tokens: [String: String]) -> String {
        tokens.reduce(s) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}

/// Detectors shared by the redaction pass and the strict check.
enum ShareRules {
    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    // Host names: URL hosts, and dotted names ending in a common or local top-level domain.
    static let tlds = "local|lan|home|internal|intranet|corp|localdomain|test|example|invalid|com|net|org|io|dev|app|cloud|co|us|uk|de|fr|nl|eu|ca|au|ch|at|se|no|dk|es|it|jp|info|biz|me|tech|ai|xyz|edu|gov"
    static let urlHost = re(#"(?i)\b([a-z][a-z0-9+.-]*://)((?>(?:(?:[^/\s@"\[]|\[[^\]/@"]*\])*@)?))(?!localhost\b)(?!\[REDACTED)([^/\s:?#\[\]@"\\]+|\[[0-9a-f:.]+\])"#)
    static let urlUser = re(#"(?i)\b([a-z][a-z0-9+.-]*://)(?!\[REDACTED)[^/\s:@"\[\]]+((?::(?:[^/\s@"\[]|\[[^\]/@"]*\])*)?@)"#)
    static let dottedHost = re(#"(?i)(?<![\w.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:\#(tlds))(?![\w-])"#)
    static let homePath = re(#"(?i)(/Users/|/home/|/var/mobile/Containers/Data/Application/|/private/var/mobile/|[a-z]:\\+Users\\+)(?!\[REDACTED)(?!Shared\b)([^/\\\s"']+)"#)
    static let tildeUser = re(#"(?i)(?<![\w/])~([a-z_][a-z0-9_.-]*)(?=/)"#)
    static let userName = re(#"(?i)\b(user(?:[ _-]?name)?|login|account[ _-]?name|owner)(\s*[:=]\s*)("?)(?!\[REDACTED)([A-Za-z0-9._@-]{2,})"#)
    static let signedInAs = re(#"(?i)\b((?:logged|signed) in as\s+)("?)(?!\[REDACTED)([A-Za-z0-9._@-]{2,})"#)
    static let possessiveDevice = re(#"\b\p{Lu}[\p{L}\p{M}.-]*['’]s\s+(?:iPhone|iPad|iPod(?:\stouch)?|MacBook(?:\s(?:Pro|Air))?|Mac(?:\s(?:mini|Studio|Pro))?|iMac|Apple\sWatch|Apple\sTV|Watch|Computer|PC|Laptop|Desktop|Phone|Pixel|Galaxy|Android)\b"#)
    static let labelledSerial = re(#"(?i)\b(serial(?:[ _-]?(?:number|no\.?))?|s/n|udid|imei|meid|ecid)(\s*[:=#]?\s*)(?!\[REDACTED)(?!(?:number|no)\b)([A-Za-z0-9-]{6,})"#)
    static let udid = re(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#)
    static let appleSerial = re(#"\b(?=(?:[A-Z]*[0-9]){2})(?=(?:[0-9]*[A-Z]){3})[A-Z0-9]{10,12}\b"#)
    static let providerToken = re(#"\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sk_(?:live|test)_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{20,}|hcg_[A-Za-z0-9_-]{20,})"#)
    static let longToken = re(#"(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*[A-Z])(?=[A-Za-z0-9+/_-]*[a-z])(?=[A-Za-z0-9+/_-]*[0-9])[A-Za-z0-9+/_-]{32,}={0,2}(?![A-Za-z0-9+/_-])"#)
    static let keyValueSecret = re(#"(?i)"?\b(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|cookie|session[_-]?id|private[_-]?key)"?\s*[:=]\s*"?(?![^"\s&,;]*\[REDACTED)(?!(?:bearer|basic|digest|negotiate)\b)[^"\s&,;]{3,}"#)
    static let privateKeyBlock = re(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#)
    static let email = re(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    static let mac = re(#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#)
    static let ipv4 = re(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    static let ipv6 = re(#"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b"#)

    /// The sharing rules of pass 1, in order.
    static let redactions: [(ShareRedaction.Rule, NSRegularExpression, String)] = [
        (.tokens, providerToken, "[REDACTED TOKEN]"),
        (.tokens, longToken, "[REDACTED TOKEN]"),
        (.homePaths, homePath, "$1[REDACTED USER]"),
        (.homePaths, tildeUser, "~[REDACTED USER]"),
        (.userNames, userName, "$1$2$3[REDACTED USER]"),
        (.userNames, signedInAs, "$1$2[REDACTED USER]"),
        (.userNames, urlUser, "$1[REDACTED USER]$2"),
        (.deviceNames, possessiveDevice, "[REDACTED DEVICE NAME]"),
        (.hostNames, urlHost, "$1$2[REDACTED HOST]"),
        (.hostNames, dottedHost, "[REDACTED HOST]"),
        (.serialNumbers, labelledSerial, "$1$2[REDACTED SERIAL]"),
        (.serialNumbers, udid, "[REDACTED SERIAL]"),
        (.serialNumbers, appleSerial, "[REDACTED SERIAL]"),
    ]
}

/// The strict check run on the final, encoded payload before it is shown.
/// Anything it finds blocks sending; the reasons are shown to the user.
public enum SensitiveContentCheck {
    public struct Finding: Equatable, Sendable {
        public var category: String
        public var count: Int

        public var reason: String { "\(category) (\(count) occurrence\(count == 1 ? "" : "s"))" }
    }

    static let detectors: [(String, NSRegularExpression)] = [
        ("Private key", ShareRules.privateKeyBlock),
        ("Credential or token value", ShareRules.keyValueSecret),
        ("API key or access token", ShareRules.providerToken),
        ("Long token-like string", ShareRules.longToken),
        ("E-mail address", ShareRules.email),
        ("IP address", ShareRules.ipv4),
        ("IP address", ShareRules.ipv6),
        ("MAC address", ShareRules.mac),
        ("Home folder path or user name", ShareRules.homePath),
        ("Home folder path or user name", ShareRules.tildeUser),
        ("Home folder path or user name", ShareRules.userName),
        ("Home folder path or user name", ShareRules.signedInAs),
        ("Home folder path or user name", ShareRules.urlUser),
        ("Personal device name", ShareRules.possessiveDevice),
        ("Host name", ShareRules.urlHost),
        ("Host name", ShareRules.dottedHost),
        ("Serial number or device identifier", ShareRules.labelledSerial),
        ("Serial number or device identifier", ShareRules.udid),
        ("Serial number or device identifier", ShareRules.appleSerial),
    ]

    /// Findings in `bytes` (the exact payload). The JSON text is checked, and
    /// so is every decoded string in it (escapes resolved).
    public static func findings(in bytes: Data, context: ShareRedaction.Context) -> [Finding] {
        var texts = [String(decoding: bytes, as: UTF8.self)]
        if let object = try? JSONSerialization.jsonObject(with: bytes) { texts += strings(in: object) }
        var counts: [String: Int] = [:]
        var order: [String] = []
        func found(_ category: String, _ n: Int) {
            guard n > 0 else { return }
            if counts[category] == nil { order.append(category) }
            counts[category] = max(counts[category] ?? 0, n)
        }
        let allowed = context.allowedNames
        for (category, re) in detectors {
            // Each text alone; the largest count per category wins (the same value is in the JSON text and the decoded string).
            let n = texts.map { t -> Int in
                let (p, _) = ShareRedaction.protect(t, names: allowed)
                return re.numberOfMatches(in: p, range: NSRange(p.startIndex..., in: p))
            }.max() ?? 0
            found(category, n)
        }
        for name in ShareRedaction(context: context).context.sensitiveNames {
            let n = texts.map { $0.occurrences(of: name, caseInsensitive: true) }.max() ?? 0
            found("This device's name, the server's address or the account e-mail", n)
        }
        return order.map { Finding(category: $0, count: counts[$0] ?? 0) }
    }

    static func strings(in object: Any) -> [String] {
        switch object {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(strings)
        case let d as [String: Any]: return d.keys.sorted() + d.keys.sorted().flatMap { strings(in: d[$0]!) }
        default: return []
        }
    }
}

/// One report, encoded once: what the review screen shows and exactly what is sent.
public struct SharePayload: Equatable, Sendable {
    public let report: DiagnosticReport
    /// The exact bytes of the report as sent (inside the Device Link envelope).
    public let bytes: Data
    /// Lowercase hex SHA-256 of `bytes`.
    public let sha256: String
    /// What the redaction removed, per rule.
    public let redactions: [RedactionCount]
    /// Why sending is blocked (empty: the strict check passed).
    public let blockers: [String]

    public var size: Int { bytes.count }
    /// The exact payload as text (UTF-8 JSON), for the preview.
    public var text: String { String(decoding: bytes, as: UTF8.self) }
    public var title: String { report.title }
    public var kind: String { report.kind }
    public var isSendable: Bool { blockers.isEmpty }

    /// True while `report` still encodes to exactly the previewed bytes.
    public var isIntact: Bool {
        guard let again = try? report.encoded() else { return false }
        return again == bytes && LinkCrypto.sha256Hex(again) == sha256
    }

    /// Builds the report once with a fresh `ShareRedaction`, encodes it and
    /// runs the strict check. Sends nothing.
    public static func prepare(context: ShareRedaction.Context, build: (ShareRedaction) -> DiagnosticReport) -> SharePayload {
        let redaction = ShareRedaction(context: context)
        let report = build(redaction)
        return SharePayload(report: report, redactions: redaction.summary, context: redaction.context)
    }

    init(report: DiagnosticReport, redactions: [RedactionCount], context: ShareRedaction.Context) {
        self.report = report
        self.redactions = redactions
        do {
            let data = try report.encoded()
            bytes = data
            sha256 = LinkCrypto.sha256Hex(data)
            blockers = ReportValidator.problems(report, encoded: data).map { "HCG Server would refuse it: \($0)" }
                + SensitiveContentCheck.findings(in: data, context: context).map { "Still contains: \($0.reason)" }
        } catch {
            bytes = Data()
            sha256 = LinkCrypto.sha256Hex(Data())
            blockers = ["The report could not be encoded (\(error))."]
        }
    }
}

extension NSRegularExpression {
    static func literal(_ s: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: s), options: [.caseInsensitive])
    }
}

extension String {
    func occurrences(of needle: String, caseInsensitive: Bool = false) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var range = startIndex..<endIndex
        while let r = self.range(of: needle, options: caseInsensitive ? [.caseInsensitive] : [], range: range) {
            n += 1
            range = r.upperBound..<endIndex
        }
        return n
    }
}
