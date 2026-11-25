import Foundation

/// A device a report can be sent to, exactly as the pinned HCG Server lists it
/// (`devices()`): name, app and the installation's key fingerprint.
public struct ShareDestination: Equatable, Sendable, Identifiable {
    public var installationId: String
    public var name: String
    public var app: String
    public var appVersion: String
    public var platform: String
    /// Lowercase hex SHA-256 of the installation's public key, as reported by the server.
    public var keyFingerprint: String
    public var authority: String?
    /// The server that reported it (display name and pinned key fingerprint).
    public var serverName: String
    public var serverFingerprint: String

    public var id: String { installationId }

    public var appLabel: String {
        switch app {
        case "hcg.terminal": return "HCG Terminal"
        case "hcg.sentinel": return "HCG Sentinel"
        case "hcg.nexus": return "HCG Nexus"
        default: return app
        }
    }

    public var displayFingerprint: String { LinkCrypto.displayFingerprint(keyFingerprint) }

    init(_ i: LinkInstallation, host: LinkHost) {
        installationId = i.installationId.lowercased()
        name = i.name
        app = i.app
        appVersion = i.appVersion
        platform = i.platform
        keyFingerprint = ShareDestinationCheck.normalized(i.keyFingerprint)
        authority = i.authority
        serverName = host.name
        serverFingerprint = ShareDestinationCheck.normalized(host.fingerprint)
    }
}

/// Which installations may receive a report, and the re-check right before sending.
public enum ShareDestinationCheck {
    public enum Refusal: Error, Equatable, Sendable {
        /// The device list did not come from the server pinned at pairing.
        case differentServer
        case notListed
        case revoked
        case selfInstallation
        case cannotReceive
        case noKey
        /// The destination's key is not the one the user saw.
        case keyChanged(shown: String, now: String)

        public var message: String {
            switch self {
            case .differentServer: return "The device list did not come from the HCG Server this device paired with (its key does not match the pinned key)."
            case .notListed: return "The destination is no longer an approved device on this HCG Server."
            case .revoked: return "The destination was removed from this HCG Server."
            case .selfInstallation: return "A report cannot be sent to this device itself."
            case .cannotReceive: return "The destination does not accept reports (report.receive)."
            case .noKey: return "The server reported no key fingerprint for the destination."
            case .keyChanged(let shown, let now):
                return "The destination's key changed since you selected it (shown \(LinkCrypto.displayFingerprint(shown)), now \(LinkCrypto.displayFingerprint(now))). Nothing was sent. Check the device, then start again."
            }
        }
    }

    static func normalized(_ hex: String) -> String { String(hex.lowercased().filter { $0.isHexDigit }) }

    /// Why an installation cannot receive reports (nil: it can).
    static func refusal(_ i: LinkInstallation, in devices: LinkDevices, pinnedServerFingerprint: String) -> Refusal? {
        if normalized(devices.host.fingerprint) != normalized(pinnedServerFingerprint) || normalized(pinnedServerFingerprint).isEmpty { return .differentServer }
        if i.installationId.lowercased() == devices.selfInstallationId.lowercased() { return .selfInstallation }
        if i.state == .revoked || i.revokedAt != nil { return .revoked }
        if normalized(i.keyFingerprint).count != 64 { return .noKey }
        if !i.supports(LinkCapabilityID.reportReceive) { return .cannotReceive }
        return nil
    }

    /// Approved, non-revoked installations of the pinned server that accept reports (never this one).
    public static func eligible(_ devices: LinkDevices, pinnedServerFingerprint: String) -> [ShareDestination] {
        devices.installations.filter { refusal($0, in: devices, pinnedServerFingerprint: pinnedServerFingerprint) == nil }
            .map { ShareDestination($0, host: devices.host) }
    }

    /// Re-checks a selected destination against a fresh device list.
    public static func verify(_ selected: ShareDestination, against devices: LinkDevices, pinnedServerFingerprint: String) -> Result<ShareDestination, Refusal> {
        guard normalized(devices.host.fingerprint) == normalized(pinnedServerFingerprint),
              normalized(selected.serverFingerprint) == normalized(pinnedServerFingerprint) else { return .failure(.differentServer) }
        guard let i = devices.installations.first(where: { $0.installationId.lowercased() == selected.installationId.lowercased() }) else {
            return .failure(.notListed)
        }
        if let r = refusal(i, in: devices, pinnedServerFingerprint: pinnedServerFingerprint) { return .failure(r) }
        let now = normalized(i.keyFingerprint)
        guard now == normalized(selected.keyFingerprint) else { return .failure(.keyChanged(shown: selected.keyFingerprint, now: now)) }
        return .success(ShareDestination(i, host: devices.host))
    }
}

/// One line of the local share history. It holds no report content: only the
/// title and type, the payload's SHA-256 and size, the destination and the outcome.
public struct ShareAuditEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable { case send, withdraw }
    public enum Outcome: String, Codable, Sendable {
        case sent, withdrawn, failed
        case cancelledBeforeSend = "cancelled-before-send"

        public var label: String {
            switch self {
            case .sent: return "Sent"
            case .withdrawn: return "Withdrawn"
            case .failed: return "Failed"
            case .cancelledBeforeSend: return "Cancelled before sending"
            }
        }
    }

    public var id: String
    public var time: Date
    public var action: Action
    public var outcome: Outcome
    public var destinationName: String?
    public var destinationInstallationId: String?
    public var destinationFingerprint: String?
    public var reportTitle: String
    public var reportKind: String
    public var payloadSha256: String
    public var payloadSize: Int
    public var messageId: String?
    /// Why (error code or reason). Never report content.
    public var detail: String?
}

/// The share history, kept on this device (Application Support) as JSON,
/// newest first, bounded. Entries are only appended.
public final class ShareAuditLog: @unchecked Sendable {
    public static let maxEntries = 500

    private let url: URL
    private let now: () -> Date
    private let lock = NSLock()

    public init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    public func entries() -> [ShareAuditEntry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    @discardableResult
    public func record(_ action: ShareAuditEntry.Action, _ outcome: ShareAuditEntry.Outcome, title: String, kind: String, sha256: String, size: Int,
                       destination: ShareDestination?, messageId: String? = nil, detail: String? = nil) -> ShareAuditEntry {
        let entry = ShareAuditEntry(id: UUID().uuidString.lowercased(), time: now(), action: action, outcome: outcome,
                                    destinationName: destination?.name, destinationInstallationId: destination?.installationId,
                                    destinationFingerprint: destination?.keyFingerprint, reportTitle: title, reportKind: kind,
                                    payloadSha256: sha256, payloadSize: size, messageId: messageId?.lowercased(), detail: detail)
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all.insert(entry, at: 0)
        if all.count > Self.maxEntries { all.removeLast(all.count - Self.maxEntries) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder().encode(all) { try? data.write(to: url, options: .atomic) }
        return entry
    }

    /// The `sent` entry for a message, if this device recorded one.
    public func sentEntry(messageId: String) -> ShareAuditEntry? {
        entries().first { $0.messageId == messageId.lowercased() && $0.action == .send && $0.outcome == .sent }
    }

    private func load() -> [ShareAuditEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? LinkJSON.decoder().decode([ShareAuditEntry].self, from: data)) ?? []
    }

    static func encoder() -> JSONEncoder {
        let e = LinkJSON.encoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// Sends a reviewed payload, withdraws it while it is still queued, and records
/// every outcome in the share history. It is only ever called because the user
/// pressed a button; it never retries or resends by itself.
public struct ReportShareService: Sendable {
    public enum SendResult: Equatable, Sendable {
        case sent(messageId: String, recipientState: String, expiresAt: Date)
        /// Refused locally before anything was sent (blocked content, changed payload, destination check).
        case refused(String)
        /// The server refused or could not be reached; `error` when it came from Device Link.
        case failed(String, DeviceLinkError?)
    }

    public enum WithdrawResult: Equatable, Sendable {
        case withdrawn
        /// The recipient already downloaded it (`already_delivered`).
        case alreadyDelivered
        case failed(String, DeviceLinkError?)
    }

    public let client: DeviceLinkClient
    public let pinnedServerFingerprint: String
    public let audit: ShareAuditLog

    public init(client: DeviceLinkClient, pinnedServerFingerprint: String, audit: ShareAuditLog) {
        self.client = client
        self.pinnedServerFingerprint = pinnedServerFingerprint
        self.audit = audit
    }

    /// The user closed the review without sending. No network call.
    public static func cancel(_ payload: SharePayload, destination: ShareDestination?, audit: ShareAuditLog) {
        audit.record(.send, .cancelledBeforeSend, title: payload.title, kind: payload.kind, sha256: payload.sha256, size: payload.size,
                     destination: destination, detail: payload.isSendable ? nil : "Blocked by the strict check")
    }

    /// Sends exactly `payload.report` (the previewed bytes) after re-checking the
    /// destination against a fresh device list from the pinned server.
    public func send(_ payload: SharePayload, to destination: ShareDestination, messageId: String = LinkCrypto.uuid()) async -> SendResult {
        func refuse(_ why: String) -> SendResult {
            audit.record(.send, .failed, title: payload.title, kind: payload.kind, sha256: payload.sha256, size: payload.size,
                         destination: destination, detail: "Not sent: " + why)
            return .refused(why)
        }
        guard payload.isSendable else { return refuse("the strict check found sensitive content (" + payload.blockers.joined(separator: "; ") + ").") }
        guard payload.isIntact else { return refuse("the report changed after it was previewed.") }

        let fresh: LinkDevices
        do { fresh = try await client.devices() } catch {
            return failed(payload, destination, messageId: nil, error, prefix: "The destination could not be re-checked, so nothing was sent")
        }
        switch ShareDestinationCheck.verify(destination, against: fresh, pinnedServerFingerprint: pinnedServerFingerprint) {
        case .failure(let r): return refuse(r.message)
        case .success: break
        }

        do {
            let receipt = try await client.share(payload.report, to: destination.installationId, messageId: messageId)
            audit.record(.send, .sent, title: payload.title, kind: payload.kind, sha256: payload.sha256, size: payload.size,
                         destination: destination, messageId: receipt.messageId, detail: "Recipient " + receipt.recipientState)
            return .sent(messageId: receipt.messageId, recipientState: receipt.recipientState, expiresAt: receipt.expiresAt)
        } catch let e as DeviceLinkError where e.isRetryable {
            // The server may have stored it before the connection dropped: look once.
            if let h = try? await client.outbox().first(where: { $0.messageId.lowercased() == messageId.lowercased() }) {
                audit.record(.send, .sent, title: payload.title, kind: payload.kind, sha256: payload.sha256, size: payload.size,
                             destination: destination, messageId: h.messageId, detail: "Confirmed from the outbox (\(h.status))")
                return .sent(messageId: h.messageId, recipientState: h.status, expiresAt: h.expiresAt)
            }
            return failed(payload, destination, messageId: messageId, e,
                          prefix: "Not confirmed by HCG Server. Nothing is resent automatically; you can review and send again")
        } catch {
            return failed(payload, destination, messageId: messageId, error, prefix: "Not sent")
        }
    }

    private func failed(_ payload: SharePayload, _ destination: ShareDestination, messageId: String?, _ error: Error, prefix: String) -> SendResult {
        let e = error as? DeviceLinkError
        let why = e.map { "\($0.description) (\($0.code))" } ?? "\(error)"
        audit.record(.send, .failed, title: payload.title, kind: payload.kind, sha256: payload.sha256, size: payload.size,
                     destination: destination, messageId: messageId, detail: e?.code ?? "error")
        return .failed("\(prefix): \(why)", e)
    }

    /// Withdraws a sent report while the recipient has not downloaded it.
    /// `header` (from the outbox) describes it when this device has no `sent` entry for it.
    public func withdraw(messageId: String, header: LinkMessageHeader? = nil) async -> WithdrawResult {
        let sent = audit.sentEntry(messageId: messageId)
        func log(_ outcome: ShareAuditEntry.Outcome, _ detail: String?) {
            var destination: ShareDestination?
            if let s = sent, let id = s.destinationInstallationId {
                destination = ShareDestination(installationId: id, name: s.destinationName ?? "", app: "", appVersion: "", platform: "",
                                               keyFingerprint: s.destinationFingerprint ?? "", authority: nil, serverName: "", serverFingerprint: "")
            } else if let h = header {
                destination = ShareDestination(installationId: h.to.installationId, name: h.to.name, app: h.to.app, appVersion: "", platform: "",
                                               keyFingerprint: "", authority: nil, serverName: "", serverFingerprint: "")
            }
            audit.record(.withdraw, outcome, title: sent?.reportTitle ?? header?.title ?? "Report", kind: sent?.reportKind ?? header?.type ?? "",
                         sha256: sent?.payloadSha256 ?? "", size: sent?.payloadSize ?? header?.size ?? 0, destination: destination,
                         messageId: messageId, detail: detail)
        }
        do {
            let h = try await client.withdraw(messageId: messageId)
            guard h.status == "withdrawn" else {
                log(.failed, "Server answered status \(h.status)")
                return .failed("HCG Server answered with status \"\(h.status)\" instead of withdrawn.", nil)
            }
            log(.withdrawn, nil)
            return .withdrawn
        } catch let e as DeviceLinkError where e.code == "already_delivered" {
            log(.failed, "already_delivered")
            return .alreadyDelivered
        } catch {
            let e = error as? DeviceLinkError
            log(.failed, e?.code ?? "error")
            return .failed(e?.description ?? "\(error)", e)
        }
    }
}

extension ShareDestination {
    init(installationId: String, name: String, app: String, appVersion: String, platform: String, keyFingerprint: String,
         authority: String?, serverName: String, serverFingerprint: String) {
        self.installationId = installationId.lowercased()
        self.name = name
        self.app = app
        self.appVersion = appVersion
        self.platform = platform
        self.keyFingerprint = keyFingerprint
        self.authority = authority
        self.serverName = serverName
        self.serverFingerprint = serverFingerprint
    }
}
