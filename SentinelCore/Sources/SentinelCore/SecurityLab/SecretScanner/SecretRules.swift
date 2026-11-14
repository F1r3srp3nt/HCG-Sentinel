import Foundation

/// The four families of checks the scanner reports on.
public enum SecretCategory: String, Codable, CaseIterable {
    case privateKey
    case apiCredential
    case embeddedCredential
    case highEntropy

    public var checkTitle: String {
        switch self {
        case .privateKey: return "Private-key blocks"
        case .apiCredential: return "Recognised API credential formats"
        case .embeddedCredential: return "Credentials in configuration and URLs"
        case .highEntropy: return "High-entropy values near credential names"
        }
    }
}

public struct SecretRule {
    public let id: String
    public let title: String
    public let category: SecretCategory
    public let pattern: NSRegularExpression
    /// Capture group holding the secret value.
    public let group: Int
    public let severity: FindingSeverity
    public let confidence: FindingConfidence
    /// Characters at the start of a match that identify the format and are not secret (e.g. "ghp_").
    public let visiblePrefix: Int
    public let explanation: String
    public let remediation: String
}

/// A match before redaction. Lives only in memory during a scan; the value never reaches a report.
public struct SecretMatch: Equatable {
    public let ruleID: String
    public let line: Int
    public let column: Int
    public let value: String
    public let range: NSRange
}

public enum SecretRules {
    static func rule(_ id: String, _ title: String, _ category: SecretCategory, _ pattern: String, group: Int = 1,
                     severity: FindingSeverity, confidence: FindingConfidence, prefix: Int = 0,
                     explanation: String, remediation: String) -> SecretRule {
        // Patterns are constants covered by tests; a failure here is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern)
        return SecretRule(id: id, title: title, category: category, pattern: regex, group: group, severity: severity,
                          confidence: confidence, visiblePrefix: prefix, explanation: explanation, remediation: remediation)
    }

    static let rotate = "Revoke or rotate this credential with its issuer, remove it from the files and their history, and load it from a secrets store or environment at run time."

    /// Format-specific rules, checked before the generic ones.
    public static let specific: [SecretRule] = [
        rule("aws-access-key-id", "AWS access key ID", .apiCredential, "\\b((?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16})\\b",
             severity: .medium, confidence: .high, prefix: 4,
             explanation: "An AWS access key ID identifies an IAM credential. Its secret key is often stored nearby.",
             remediation: "Check the AWS console for this key; deactivate it if it is in use and was exposed, and use IAM roles or a secrets store instead."),
        rule("aws-secret-access-key", "AWS secret access key", .apiCredential,
             "(?i)aws.{0,20}?(?:secret|sk).{0,20}?[\"'=:\\s]+([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])",
             severity: .high, confidence: .medium,
             explanation: "A 40-character value assigned to an AWS secret key name. Together with an access key ID it grants API access.",
             remediation: rotate),
        rule("github-token", "GitHub token", .apiCredential, "\\b((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36})\\b",
             severity: .high, confidence: .high, prefix: 4,
             explanation: "This has the format of a GitHub personal access, OAuth, user, server or refresh token.",
             remediation: rotate),
        rule("github-fine-grained-token", "GitHub fine-grained token", .apiCredential, "\\b(github_pat_[A-Za-z0-9_]{82})\\b",
             severity: .high, confidence: .high, prefix: 11, explanation: "This has the format of a GitHub fine-grained personal access token.",
             remediation: rotate),
        rule("gitlab-token", "GitLab personal access token", .apiCredential, "\\b(glpat-[A-Za-z0-9_\\-]{20})(?![A-Za-z0-9_\\-])",
             severity: .high, confidence: .high, prefix: 6, explanation: "This has the format of a GitLab personal access token.",
             remediation: rotate),
        rule("slack-token", "Slack token", .apiCredential, "\\b(xox[abprs]-[A-Za-z0-9-]{10,72})\\b",
             severity: .high, confidence: .high, prefix: 5, explanation: "This has the format of a Slack bot, user or app token.",
             remediation: rotate),
        rule("slack-webhook", "Slack incoming webhook", .apiCredential,
             "(https://hooks\\.slack\\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]{20,})",
             severity: .medium, confidence: .high, prefix: 32,
             explanation: "Anyone with an incoming-webhook URL can post messages to the Slack channel it belongs to.",
             remediation: "Regenerate the webhook in Slack and keep the URL out of source files."),
        rule("stripe-live-key", "Stripe live secret key", .apiCredential, "\\b((?:sk|rk)_live_[A-Za-z0-9]{20,99})\\b",
             severity: .critical, confidence: .high, prefix: 8,
             explanation: "This has the format of a Stripe live-mode secret or restricted key, which can act on real payments.",
             remediation: rotate),
        rule("stripe-test-key", "Stripe test secret key", .apiCredential, "\\b(sk_test_[A-Za-z0-9]{20,99})\\b",
             severity: .low, confidence: .high, prefix: 8,
             explanation: "This has the format of a Stripe test-mode key. Test keys cannot move real money but still expose your test account.",
             remediation: "Rotate the test key if the files are shared, and load it from the environment."),
        rule("google-api-key", "Google API key", .apiCredential, "\\b(AIza[0-9A-Za-z_\\-]{35})(?![0-9A-Za-z_\\-])",
             severity: .medium, confidence: .high, prefix: 4,
             explanation: "This has the format of a Google API key. Its impact depends on the APIs and restrictions configured for it.",
             remediation: "Restrict or regenerate the key in Google Cloud console and keep it out of source files."),
        rule("openai-key", "OpenAI API key", .apiCredential,
             "\\b(sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\\-]{16,}T3BlbkFJ[A-Za-z0-9_\\-]{16,})(?![A-Za-z0-9_\\-])",
             severity: .high, confidence: .high, prefix: 3, explanation: "This has the format of an OpenAI API key.",
             remediation: rotate),
        rule("anthropic-key", "Anthropic API key", .apiCredential, "\\b(sk-ant-(?:api|admin)\\d{2}-[A-Za-z0-9_\\-]{80,})(?![A-Za-z0-9_\\-])",
             severity: .high, confidence: .high, prefix: 7, explanation: "This has the format of an Anthropic API key.",
             remediation: rotate),
        rule("sendgrid-key", "SendGrid API key", .apiCredential, "\\b(SG\\.[A-Za-z0-9_\\-]{22}\\.[A-Za-z0-9_\\-]{43})(?![A-Za-z0-9_\\-])",
             severity: .high, confidence: .high, prefix: 3, explanation: "This has the format of a SendGrid API key.", remediation: rotate),
        rule("npm-token", "npm access token", .apiCredential, "\\b(npm_[A-Za-z0-9]{36})\\b",
             severity: .high, confidence: .high, prefix: 4, explanation: "This has the format of an npm access token, which can publish packages.",
             remediation: rotate),
        rule("twilio-api-key", "Twilio API key SID", .apiCredential, "\\b(SK[0-9a-f]{32})\\b",
             severity: .medium, confidence: .medium, prefix: 2,
             explanation: "This has the format of a Twilio API key SID. The matching secret is often stored nearby.",
             remediation: "Check the key in the Twilio console and rotate it if it was exposed."),
        rule("json-web-token", "JSON Web Token", .apiCredential,
             "\\b(eyJ[A-Za-z0-9_\\-]{8,}\\.eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,})(?![A-Za-z0-9_\\-])",
             severity: .medium, confidence: .medium, prefix: 3,
             explanation: "A signed JSON Web Token. It may be expired or for a test system; Sentinel does not decode or test it.",
             remediation: "If it is a long-lived or production token, revoke it and stop committing tokens."),
        rule("url-credentials", "Password embedded in a URL", .embeddedCredential,
             "\\b[a-zA-Z][a-zA-Z0-9+.\\-]{1,20}://[^/\\s:@'\"<>]{1,64}:([^/\\s@'\"<>]{1,128})@[A-Za-z0-9.\\-\\[\\]]+",
             severity: .high, confidence: .medium,
             explanation: "A connection URL contains a user name and password. Anyone who can read the file can use them.",
             remediation: "Move the password out of the URL into a secrets store or environment variable, and change it if the file was shared.")
    ]

    static let keywordNames = "[A-Za-z0-9_.\\-]*(?:password|passwd|pwd|secret|token|api[_\\-]?key|access[_\\-]?key|private[_\\-]?key|client[_\\-]?secret|auth[_\\-]?key|credentials?)[A-Za-z0-9_.\\-]*"

    /// Generic assignment rules. Their matches are filtered for placeholders before they count.
    public static let assignments: [SecretRule] = [
        rule("config-assignment-quoted", "Credential assigned in configuration", .embeddedCredential,
             "(?i)\\b\(keywordNames)[\"']?\\s*[:=]>?\\s*[\"']([^\"'\\s]{6,200})[\"']",
             severity: .medium, confidence: .medium,
             explanation: "A value is assigned to a name that suggests a password, token or key.",
             remediation: "If this is a real credential, change it, remove it from the files, and load it from a secrets store or environment at run time."),
        rule("config-assignment-plain", "Credential assigned in configuration", .embeddedCredential,
             "(?i)^\\s*(?:export\\s+)?\(keywordNames)\\s*[:=]\\s*([^\\s\"'#;]{6,200})\\s*$",
             severity: .medium, confidence: .medium,
             explanation: "A value is assigned to a name that suggests a password, token or key, as in .env, .ini or .properties files.",
             remediation: "If this is a real credential, change it, remove it from the files, and load it from a secrets store or environment at run time.")
    ]

    static let entropyContext = try! NSRegularExpression(pattern: "(?i)(key|secret|token|passw|auth|credential|private|signature|bearer|api)")
    static let entropyCandidates = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/=_\\-])([A-Za-z0-9+/_\\-]{24,}={0,2})(?![A-Za-z0-9+/=_\\-])")
    static let digestContext = try! NSRegularExpression(pattern: "(?i)(sha\\d*|md5|hash|checksum|integrity|digest|commit|uuid|guid|nonce|example)")

    public static let highEntropy = rule("high-entropy-value", "Random-looking value near a credential name", .highEntropy, "(x)",
                                         severity: .low, confidence: .low,
                                         explanation: "A long, random-looking value appears next to a name that suggests a secret. It may be a credential, or harmless data such as an identifier.",
                                         remediation: "Check what this value is. If it is a credential, rotate it and load it from a secrets store instead.")

    static let privateKeyHeader = try! NSRegularExpression(pattern: "-----BEGIN ((?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?)-----")

    public static let privateKey = rule("private-key-block", "Private key", .privateKey, "(x)",
                                        severity: .high, confidence: .high,
                                        explanation: "A PEM or OpenSSH private-key block. Whoever has it can impersonate its owner or decrypt what it protects.",
                                        remediation: "Treat the key as compromised: replace it, revoke any certificates or authorised-key entries for it, and keep keys out of source folders.")

    public static var all: [SecretRule] { specific + assignments + [highEntropy, privateKey] }

    public static func rule(id: String) -> SecretRule? { all.first { $0.id == id } }

    /// Values that are clearly not real credentials.
    public static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = ["${", "$(", "%(", "{{", "<", "process.env", "os.environ", "getenv", "env[", "env.", "secrets.",
                       "your", "example", "sample", "dummy", "placeholder", "changeme", "change_me", "redacted", "xxxx",
                       "****", "...", "todo", "fixme", "insert", "replace", "none", "null", "undefined", "password", "secret",
                       "token", "test1234", "12345", "abcdef"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        if lower == "true" || lower == "false" { return true }
        if Set(value).count <= 2 { return true }
        if value.allSatisfy({ $0.isNumber }) { return true }
        // Bare identifiers that look like variable references: settings.dbPassword, config[KEY]
        if value.contains(".") && value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) && !value.contains(where: { $0.isNumber }) {
            return true
        }
        return false
    }

    /// Shannon entropy in bits per character.
    public static func entropy(_ value: String) -> Double {
        let characters = Array(value)
        guard !characters.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in characters { counts[character, default: 0] += 1 }
        let total = Double(characters.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    /// Redacted form of a secret: format prefix (if any) and length only.
    public static func redact(_ value: String, visiblePrefix: Int) -> String {
        let count = value.count
        let prefix = visiblePrefix > 0 && count > visiblePrefix + 8 ? String(value.prefix(visiblePrefix)) : ""
        return "\(prefix)[REDACTED \(count) chars]"
    }
}
