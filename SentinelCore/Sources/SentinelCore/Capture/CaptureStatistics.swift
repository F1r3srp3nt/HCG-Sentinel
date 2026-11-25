import Foundation

/// Statistics over an imported capture file: counts, sizes, protocol mix, conversations and a timeline.
/// Computed from headers Sentinel already decoded; payloads are never read for this, and nothing is sent anywhere.
public struct CaptureStatistics: Equatable {
    public struct Count: Equatable {
        public var name: String
        public var packets: Int
        public var bytes: Int
    }

    public struct Conversation: Equatable {
        /// Endpoint labels: addresses as in the file, or pseudonyms ("host-1") in a privacy-preserving report.
        public var a: String
        public var b: String
        public var protocolName: String
        public var packets: Int
        public var bytes: Int
    }

    public struct Bucket: Equatable {
        public var start: Date
        public var packets: Int
        public var bytes: Int
    }

    public static let maxBuckets = 60
    public static let maxConversations = 20

    public var packetCount: Int
    public var capturedBytes: Int
    public var originalBytes: Int
    /// Packets stored shorter than they were on the wire (snap length).
    public var truncatedPackets: Int
    public var packetsWithoutTimestamp: Int
    public var first: Date?
    public var last: Date?
    public var protocols: [Count]
    public var services: [Count]
    public var conversations: [Conversation]
    public var timeline: [Bucket]
    public var bucketSeconds: TimeInterval
    public var distinctEndpoints: Int

    public var duration: TimeInterval? {
        guard let first = first, let last = last else { return nil }
        return last.timeIntervalSince(first)
    }

    /// Average packets per second over the file's time span, when it has one.
    public var packetsPerSecond: Double? {
        guard let duration = duration, duration > 0 else { return nil }
        return Double(packetCount) / duration
    }

    /// - Parameter pseudonymize: replace every address with a stable label (`host-1`, `host-2`, …) in order of
    ///   first appearance, for reports that may be shared.
    public static func compute(_ capture: ParsedCapture, pseudonymize: Bool = false) -> CaptureStatistics {
        var names: [String: String] = [:]
        func label(_ address: String?) -> String {
            guard let address = address else { return "—" }
            guard pseudonymize else { return address }
            if let existing = names[address] { return existing }
            let next = "host-\(names.count + 1)"
            names[address] = next
            return next
        }

        var protocols: [String: (Int, Int)] = [:]
        var services: [String: (Int, Int)] = [:]
        var conversations: [String: Conversation] = [:]
        var endpoints = Set<String>()
        var captured = 0, original = 0, truncated = 0, noTime = 0
        for packet in capture.packets {
            captured += packet.capturedLength
            original += packet.originalLength
            if packet.capturedLength < packet.originalLength { truncated += 1 }
            if packet.timestamp == nil { noTime += 1 }
            let s = packet.summary
            protocols[s.protocolName, default: (0, 0)].0 += 1
            protocols[s.protocolName, default: (0, 0)].1 += packet.originalLength
            if let hint = s.serviceHint {
                services[hint, default: (0, 0)].0 += 1
                services[hint, default: (0, 0)].1 += packet.originalLength
            }
            if let src = s.source { endpoints.insert(src) }
            if let dst = s.destination { endpoints.insert(dst) }
            if s.source != nil || s.destination != nil {
                let a = label(s.source), b = label(s.destination)
                let (x, y) = a <= b ? (a, b) : (b, a)
                let key = "\(x)|\(y)|\(s.protocolName)"
                var c = conversations[key] ?? Conversation(a: x, b: y, protocolName: s.protocolName, packets: 0, bytes: 0)
                c.packets += 1
                c.bytes += packet.originalLength
                conversations[key] = c
            }
        }

        let stamps = capture.packets.compactMap { $0.timestamp }
        let first = stamps.min(), last = stamps.max()
        var buckets: [Bucket] = []
        var width: TimeInterval = 0
        if let first = first, let last = last {
            let span = max(last.timeIntervalSince(first), 0.001)
            width = niceWidth(span / Double(maxBuckets))
            let count = min(maxBuckets, Int((span / width).rounded(.down)) + 1)
            buckets = (0..<count).map { Bucket(start: first.addingTimeInterval(Double($0) * width), packets: 0, bytes: 0) }
            for packet in capture.packets {
                guard let t = packet.timestamp else { continue }
                let index = min(count - 1, Int(t.timeIntervalSince(first) / width))
                buckets[index].packets += 1
                buckets[index].bytes += packet.originalLength
            }
        }

        func sorted(_ d: [String: (Int, Int)]) -> [Count] {
            d.map { Count(name: $0.key, packets: $0.value.0, bytes: $0.value.1) }
                .sorted { $0.packets != $1.packets ? $0.packets > $1.packets : $0.name < $1.name }
        }
        let topConversations = conversations.values
            .sorted { $0.packets != $1.packets ? $0.packets > $1.packets : ($0.a, $0.b, $0.protocolName) < ($1.a, $1.b, $1.protocolName) }
        return CaptureStatistics(packetCount: capture.packets.count, capturedBytes: captured, originalBytes: original,
                                 truncatedPackets: truncated, packetsWithoutTimestamp: noTime, first: first, last: last,
                                 protocols: sorted(protocols), services: sorted(services),
                                 conversations: Array(topConversations.prefix(maxConversations)),
                                 timeline: buckets, bucketSeconds: width, distinctEndpoints: endpoints.count)
    }

    /// Rounds a bucket width up to 1/2/5 × 10^n seconds so the timeline is readable.
    static func niceWidth(_ raw: TimeInterval) -> TimeInterval {
        guard raw > 0 else { return 0.001 }
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        for step in [1.0, 2.0, 5.0, 10.0] where raw <= step * base { return step * base }
        return 10 * base
    }
}

/// A capture report safe to share: format, counts, protocol mix, timeline and conversations with pseudonymized
/// endpoints. No addresses, ports beyond service names, payloads, host names, or the file name.
public enum CaptureReport {
    public static func text(_ capture: ParsedCapture, generatedAt: Date = Date()) -> String {
        let stats = CaptureStatistics.compute(capture, pseudonymize: true)
        let iso = ISO8601DateFormatter()
        var lines = [
            "HCG Sentinel Unleashed — Capture report (privacy-preserving)",
            "Generated: \(iso.string(from: generatedAt))",
            "Source: a capture file imported by the user. Not live capture; TLS is not decrypted.",
            "",
            "Format: \(capture.format.displayName); link types: \(capture.linkTypes.map { LinkType.name($0) }.joined(separator: ", "))",
            "Packets: \(stats.packetCount)\(capture.stoppedEarly ? " (parsing stopped early: limit reached or file damaged)" : "")",
            "Bytes on the wire: \(stats.originalBytes); stored: \(stats.capturedBytes); truncated packets: \(stats.truncatedPackets)",
            "Endpoints: \(stats.distinctEndpoints) (shown as host-N)",
        ]
        if let duration = stats.duration {
            lines.append(String(format: "Duration: %.3f s; average %.1f packets/s", duration, stats.packetsPerSecond ?? 0))
        }
        if stats.packetsWithoutTimestamp > 0 { lines.append("Packets without a timestamp: \(stats.packetsWithoutTimestamp)") }
        lines.append("")
        lines.append("Protocols:")
        lines += stats.protocols.map { "  \($0.name): \($0.packets) packets, \($0.bytes) bytes" }
        if !stats.services.isEmpty {
            lines.append("Services (guessed from well-known ports only):")
            lines += stats.services.map { "  \($0.name): \($0.packets) packets" }
        }
        if !stats.conversations.isEmpty {
            lines.append("Top conversations:")
            lines += stats.conversations.map { "  \($0.a) ↔ \($0.b) \($0.protocolName): \($0.packets) packets, \($0.bytes) bytes" }
        }
        if !stats.timeline.isEmpty {
            lines.append(String(format: "Timeline (%g s per bucket, packets): ", stats.bucketSeconds) + stats.timeline.map { "\($0.packets)" }.joined(separator: " "))
        }
        if !capture.warnings.isEmpty {
            lines.append("Parser warnings:")
            lines += capture.warnings.prefix(20).map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
