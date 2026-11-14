import Foundation

/// The parts of an X.509 certificate Exposure Check reports: validity period, subject common name and DNS names.
/// Parsing is strictly bounded; anything unexpected returns nil rather than guessing.
public struct X509Summary: Equatable {
    public var notBefore: Date
    public var notAfter: Date
    public var commonName: String?
    public var dnsNames: [String]

    public init(notBefore: Date, notAfter: Date, commonName: String?, dnsNames: [String]) {
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.commonName = commonName
        self.dnsNames = dnsNames
    }

    /// RFC 6125-style matching: exact names, or a single left-most wildcard label (`*.example.com`).
    /// The common name is used only when the certificate lists no DNS names.
    public func matches(host rawHost: String) -> Bool {
        let host = AddressClassifier.normalizedHost(rawHost)
        let names = dnsNames.isEmpty ? (commonName.map { [$0] } ?? []) : dnsNames
        return names.contains { X509Summary.nameMatches(pattern: $0.lowercased(), host: host) }
    }

    static func nameMatches(pattern: String, host: String) -> Bool {
        if pattern == host { return true }
        guard pattern.hasPrefix("*."), AddressClassifier.classify(host) == nil else { return false }
        let suffix = String(pattern.dropFirst(1)) // ".example.com"
        guard suffix.split(separator: ".").count >= 2, host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }

    // MARK: DER

    private struct Node {
        let tag: UInt8
        let start: Int // first content byte
        let end: Int   // one past the last content byte
    }

    private static func node(_ b: [UInt8], at offset: Int, limit: Int) -> Node? {
        guard offset + 2 <= limit else { return nil }
        let tag = b[offset]
        var length = Int(b[offset + 1])
        var start = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count >= 1, count <= 3, start + count <= limit else { return nil }
            length = 0
            for index in 0..<count { length = (length << 8) | Int(b[start + index]) }
            start += count
        }
        guard start + length <= limit else { return nil }
        return Node(tag: tag, start: start, end: start + length)
    }

    private static func children(_ b: [UInt8], of parent: Node) -> [Node]? {
        var result: [Node] = []
        var offset = parent.start
        while offset < parent.end {
            guard let child = node(b, at: offset, limit: parent.end), result.count < 64 else { return nil }
            result.append(child)
            offset = child.end
        }
        return result
    }

    private static func time(_ b: [UInt8], _ n: Node) -> Date? {
        let text = String(decoding: b[n.start..<n.end], as: UTF8.self)
        guard text.hasSuffix("Z") else { return nil }
        let digits = Array(text.dropLast())
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? { from + count <= digits.count ? Int(String(digits[from..<(from + count)])) : nil }
        var year: Int
        var index: Int
        switch n.tag {
        case 0x17:
            guard digits.count == 12, let yy = number(0, 2) else { return nil }
            year = yy >= 50 ? 1900 + yy : 2000 + yy // RFC 5280
            index = 2
        case 0x18:
            guard digits.count == 14, let yyyy = number(0, 4) else { return nil }
            year = yyyy
            index = 4
        default:
            return nil
        }
        guard let month = number(index, 2), let day = number(index + 2, 2), let hour = number(index + 4, 2),
              let minute = number(index + 6, 2), let second = number(index + 8, 2) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]
    private static let subjectAltNameOID: [UInt8] = [0x55, 0x1d, 0x11]

    public static func parse(der b: [UInt8]) -> X509Summary? {
        guard let certificate = node(b, at: 0, limit: b.count), certificate.tag == 0x30,
              let parts = children(b, of: certificate), let tbsNode = parts.first, tbsNode.tag == 0x30,
              var tbs = children(b, of: tbsNode) else { return nil }
        if tbs.first?.tag == 0xa0 { tbs.removeFirst() } // explicit version
        // serial, signature, issuer, validity, subject, subjectPublicKeyInfo, then optional [1] [2] [3]
        guard tbs.count >= 6, tbs[3].tag == 0x30, let validity = children(b, of: tbs[3]), validity.count == 2,
              let notBefore = time(b, validity[0]), let notAfter = time(b, validity[1]) else { return nil }

        var commonName: String?
        if tbs[4].tag == 0x30, let rdns = children(b, of: tbs[4]) {
            for rdn in rdns {
                guard let attributes = children(b, of: rdn) else { continue }
                for attribute in attributes {
                    guard let pair = children(b, of: attribute), pair.count == 2, pair[0].tag == 0x06,
                          Array(b[pair[0].start..<pair[0].end]) == commonNameOID else { continue }
                    commonName = String(decoding: b[pair[1].start..<pair[1].end], as: UTF8.self)
                }
            }
        }

        var dnsNames: [String] = []
        if let extensionsWrapper = tbs.dropFirst(6).first(where: { $0.tag == 0xa3 }),
           let wrapped = children(b, of: extensionsWrapper), let sequence = wrapped.first,
           let extensions = children(b, of: sequence) {
            for item in extensions {
                guard let fields = children(b, of: item), fields.count >= 2, fields[0].tag == 0x06,
                      Array(b[fields[0].start..<fields[0].end]) == subjectAltNameOID,
                      let octets = fields.last, octets.tag == 0x04,
                      let names = node(b, at: octets.start, limit: octets.end), names.tag == 0x30,
                      let generalNames = children(b, of: names) else { continue }
                for name in generalNames where name.tag == 0x82 && dnsNames.count < 100 {
                    dnsNames.append(String(decoding: b[name.start..<name.end], as: UTF8.self))
                }
            }
        }
        return X509Summary(notBefore: notBefore, notAfter: notAfter, commonName: commonName, dnsNames: dnsNames)
    }
}
