import Foundation

/// Removes credentials before anything is logged or shown in activity history.
public struct Redactor {
    public static let placeholder = "[REDACTED]"
    public static let standard = Redactor()

    private static let sensitiveNameParts = ["authorization", "cookie", "token", "secret", "password", "passwd",
                                             "pwd", "api-key", "apikey", "api_key", "session", "credential",
                                             "signature", "x-auth", "private"]
    private static let sensitiveExactNames: Set<String> = ["key", "auth", "sig", "code", "pin", "otp"]

    public init() {}

    public func isSensitiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if Redactor.sensitiveExactNames.contains(lower) { return true }
        return Redactor.sensitiveNameParts.contains { lower.contains($0) }
    }

    public func headerValue(name: String, value: String) -> String {
        isSensitiveName(name) ? Redactor.placeholder : text(value)
    }

    /// Redacts user-info and sensitive query values of a URL string.
    public func url(_ string: String) -> String {
        guard var components = URLComponents(string: string) else { return text(string) }
        if components.user != nil || components.password != nil {
            components.user = Redactor.placeholder
            components.password = nil
        }
        if let items = components.queryItems {
            components.queryItems = items.map {
                URLQueryItem(name: $0.name, value: isSensitiveName($0.name) && $0.value != nil ? Redactor.placeholder : $0.value)
            }
        }
        let rendered = components.string ?? string
        return rendered.replacingOccurrences(of: "%5BREDACTED%5D", with: Redactor.placeholder)
    }

    /// Redacts credentials embedded in free text, JSON or form bodies.
    public func text(_ input: String) -> String {
        var output = input
        for (pattern, template) in Redactor.rules {
            output = pattern.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output),
                                                      withTemplate: template)
        }
        return output
    }

    private static let rules: [(NSRegularExpression, String)] = {
        let names = "[A-Za-z0-9_.\\-]*(?:authorization|cookie|token|secret|password|passwd|pwd|api[-_]?key|session|credential|signature)[A-Za-z0-9_.\\-]*"
        let specs: [(String, String)] = [
            // Authorization schemes followed by a credential.
            ("(?i)\\b(bearer|basic|digest|negotiate)\\s+[A-Za-z0-9+/=._~\\-]{4,}", "$1 [REDACTED]"),
            // "name": "value" in JSON.
            ("(?i)(\"\(names)\"\\s*:\\s*)\"(?:[^\"\\\\]|\\\\.)*\"", "$1\"[REDACTED]\""),
            // "name": 12345 / true in JSON.
            ("(?i)(\"\(names)\"\\s*:\\s*)[^\"\\s,}\\]]+", "$1\"[REDACTED]\""),
            // name=value in query strings, form bodies and header-like text.
            ("(?i)\\b(\(names))=([^&\\s;,\"]+)", "$1=[REDACTED]"),
            // Header lines such as "Cookie: a=b".
            ("(?im)^(\\s*\(names)\\s*:\\s*)(?!\\s*\\[REDACTED\\]).+$", "$1[REDACTED]"),
            // user:password@host in URLs.
            ("(?i)([a-z][a-z0-9+.\\-]*://)[^/@\\s:]+:[^/@\\s]+@", "$1[REDACTED]@")
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()
}
