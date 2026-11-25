import AuthenticationServices
import Foundation
import SentinelCore
import UIKit

/// Connected devices (HCG Device Link) for Sentinel: sign in with HCG Connect,
/// pair this installation with an HCG Server, see the paired devices and share
/// redacted reports with one of them.
///
/// Sharing is always one explicit decision per report: the review screen shows
/// the exact redacted payload (size, SHA-256, what was removed), the strict
/// check result and the destination's key as reported by the pinned server;
/// only "Send" transmits, after a fresh re-check of the destination. Nothing is
/// sent automatically or resent later, no choice is remembered, and every
/// outcome goes into the local share history.
///
/// Nothing contacts a server unless "Remote connections" is on in Settings and
/// the user acted. HCG Server authorizes every request with HCG Connect and
/// ERP App Access; this model never decides access itself and never enables
/// anything on another device.
///
/// Local development pairing: only when the invitation says the server is in
/// local development mode does Sentinel pair without HCG Connect (empty token
/// provider). The pairing record keeps that mode, and every screen that shows
/// such a connection says "LOCAL DEVELOPMENT — not an HCG account".
@MainActor
final class ConnectedDevicesModel: ObservableObject {
    enum SignIn: Equatable {
        case notConfigured(String)
        case signedOut
        case signedIn(email: String?)
        case ended(String)
    }

    enum Link: Equatable {
        case notPaired
        case pairing(PairingRecord)
        case connected
        case offline(reason: String, retryIn: TimeInterval)
        case ended(String)
        case paused(String)
    }

    @Published private(set) var signIn: SignIn = .signedOut
    @Published private(set) var link: Link = .notPaired
    @Published private(set) var record: PairingRecord?
    @Published private(set) var devices: LinkDevices?
    @Published private(set) var outbox: [LinkMessageHeader] = []
    @Published private(set) var approvals: LinkApprovals?
    @Published private(set) var lastSync: Date?
    @Published var message: String?
    @Published private(set) var busy = false
    /// HCG Server health (read-only diagnostics); only what the server returned.
    @Published private(set) var health: ServerHealthState = .notConnected("Open this screen while connected to read the server's health.")
    /// The local share history (newest first). No report content.
    @Published private(set) var shareHistory: [ShareAuditEntry] = []

    /// The current pairing was made in local development mode (no HCG account).
    var isLocalDevelopment: Bool { record?.isLocalDevelopment ?? false }

    let identity: InstallationIdentity?
    let identityProblem: String?
    var deviceName: String { UIDevice.current.name }
    var appVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }

    private let secrets: LinkSecretStore
    private let recordFile: PairingRecordFile
    private let auth: HCGConnectAuth
    private let session: HCGConnectSession
    private let log: ActivityLog
    let shareAudit: ShareAuditLog
    private var client: DeviceLinkClient?
    private var syncTask: Task<Void, Never>?
    private var webSession: ASWebAuthenticationSession?
    private lazy var anchor = PresentationAnchor()
    let remoteAllowed: () -> Bool

    /// Built by AppModel (not main-actor isolated), so it only stores values; work starts in `restore()`.
    nonisolated init(log: ActivityLog, support: URL, remoteAllowed: @escaping () -> Bool) {
        self.log = log
        self.remoteAllowed = remoteAllowed
        let secrets = KeychainSecretStore(service: "com.hcg.sentinel.devicelink")
        self.secrets = secrets
        let file = PairingRecordFile(url: support.appendingPathComponent("DeviceLink/pairing.json"))
        recordFile = file
        let audit = ShareAuditLog(url: support.appendingPathComponent("DeviceLink/share-audit.json"))
        shareAudit = audit
        _shareHistory = Published(initialValue: audit.entries())
        let info = Bundle.main.infoDictionary ?? [:]
        let cfg = HCGConnectConfiguration(contractVersion: SentinelLinkIdentity.contract,
                                          clientId: (info["HCGConnectClientID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                          redirectUri: (info["HCGConnectRedirectURI"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        let auth = HCGConnectAuth(configuration: cfg, expectedContract: SentinelLinkIdentity.contract)
        self.auth = auth
        session = HCGConnectSession(auth: auth, store: SecretTokenStore(store: secrets))
        do {
            identity = try InstallationIdentity.loadOrCreate(store: secrets)
            identityProblem = nil
        } catch {
            identity = nil
            identityProblem = "This device's key could not be created or read from the Keychain (\(error.localizedDescription))."
        }
        _record = Published(initialValue: file.load())
        if let problem = cfg.problem(expectedContract: SentinelLinkIdentity.contract) {
            _signIn = Published(initialValue: .notConfigured(problem))
        }
    }

    /// Called once from the app's start (AppModel is not main-actor isolated).
    nonisolated func start() {
        Task { @MainActor in await self.restore() }
    }

    private func restore() async {
        if case .notConfigured = signIn {} else {
            let t = await session.current
            signIn = t.map { .signedIn(email: $0.email) } ?? .signedOut
        }
        switch record?.status {
        case .pending?: link = .pairing(record!)
        case .approved?: link = .connected
        default: link = .notPaired
        }
        rebuildClient()
    }

    private func rebuildClient() {
        guard let r = record, let base = r.baseURL, let id = identity else { client = nil; return }
        client = DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: base, serverFingerprint: r.serverFingerprint, installationId: id.installationId),
                                  signer: id.signer, transport: PinnedSessionTransport(fingerprint: r.serverFingerprint),
                                  tokens: SentinelLinkAuthority.tokens(for: r, hcgConnect: session))
    }

    private func saveRecord(_ r: PairingRecord?) {
        record = r
        try? recordFile.save(r)
        rebuildClient()
    }

    // MARK: HCG Connect

    func startSignIn() {
        switch signIn {
        case .signedOut, .ended: beginWeb()
        case .notConfigured(let why): message = why
        case .signedIn: break
        }
    }

    private func beginWeb() {
        let attempt: SignInAttempt
        do { attempt = try auth.begin() } catch {
            message = "\(error)"
            return
        }
        let scheme = URL(string: attempt.redirectUri)?.scheme
        let web = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: scheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.webSession = nil
                guard let url = url, error == nil else {
                    self.message = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? nil : "Sign-in did not complete."
                    return
                }
                do {
                    let tokens = try await self.auth.complete(attempt, callback: url)
                    try await self.session.signedIn(tokens)
                    self.signIn = .signedIn(email: tokens.email)
                    self.log.record(.devices, "Signed in to HCG Connect")
                } catch {
                    self.message = "\(error)"
                }
            }
        }
        web.presentationContextProvider = anchor
        web.prefersEphemeralWebBrowserSession = false
        webSession = web
        if !web.start() { message = "The sign-in window could not be opened." }
    }

    /// Local sign-out (HCG Connect has no revocation endpoint). HCG Server stops
    /// accepting the session once HCG reports it ended.
    func signOut() {
        Task {
            await session.signOut()
            signIn = .signedOut
            // A local-development pairing never used the HCG Connect session.
            if !isLocalDevelopment { stopSync() }
        }
    }

    // MARK: pairing

    func pair(code: String) {
        guard remoteAllowed() else { message = "Turn on Remote connections in Settings first."; return }
        guard let id = identity else { message = identityProblem; return }
        let invitation: Invitation
        do { invitation = try Invitation.parse(code) } catch {
            message = "\(error)"
            return
        }
        guard let base = invitation.baseURL else { message = "The invitation has no usable server address."; return }
        // HCG Connect unless the invitation itself says local development.
        let c = DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: base, serverFingerprint: invitation.fingerprint, installationId: id.installationId),
                                 signer: id.signer, transport: PinnedSessionTransport(fingerprint: invitation.fingerprint),
                                 tokens: SentinelLinkAuthority.tokens(for: invitation, hcgConnect: session))
        let info = SentinelLinkIdentity.installationInfo(identity: id, name: deviceName, platform: "iOS \(UIDevice.current.systemVersion)",
                                                         appVersion: appVersion, deviceId: UIDevice.current.identifierForVendor?.uuidString.lowercased())
        busy = true
        Task {
            defer { busy = false }
            do {
                let st = try await c.pair(invitation: invitation, info: info)
                let r = PairingRecord(invitation: invitation, requestId: st.requestId, status: .pending)
                saveRecord(r)
                link = .pairing(r)
                log.record(.devices, "Pairing requested with \(invitation.hostName)"
                           + (invitation.isLocalDevelopment ? " (\(SentinelLinkAuthority.localDevelopmentLabel))" : "")
                           + "; waiting for approval on the server")
                pollPairing()
            } catch {
                message = describe(error)
            }
        }
    }

    private func pollPairing() {
        syncTask?.cancel()
        syncTask = Task {
            while !Task.isCancelled, let r = record, r.status == .pending, let c = client {
                do {
                    let st = try await c.pairingStatus(requestId: r.requestId)
                    switch st.status {
                    case "approved":
                        var n = r; n.status = .approved; n.updatedAt = Date()
                        saveRecord(n)
                        link = .connected
                        log.record(.devices, "\(r.serverName) approved this device")
                        startSync()
                        return
                    case "rejected", "expired", "superseded":
                        var n = r; n.status = st.status == "rejected" ? .rejected : .expired
                        saveRecord(n)
                        link = .ended(st.status == "rejected" ? "The server owner rejected this pairing request." : "The pairing request expired. Use a new invitation.")
                        return
                    default: break
                    }
                } catch let e as DeviceLinkError where !e.isRetryable {
                    if e.endsLink { linkEnded(e) } else { link = .ended(e.description) }
                    return
                } catch {}
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: sync (foreground only)

    func appeared() {
        switch link {
        case .pairing: pollPairing()
        case .connected, .offline, .paused: startSync()
        default: break
        }
    }

    func disappeared() { stopSync() }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    func startSync() {
        guard record?.status == .approved else { return }
        guard remoteAllowed() else {
            link = .paused("Remote connections are off in Settings, so Sentinel does not contact HCG Server.")
            return
        }
        stopSync()
        syncTask = Task {
            var failures = 0
            let policy = ReconnectPolicy()
            while !Task.isCancelled {
                guard let c = client, remoteAllowed() else { link = .paused("Remote connections are off in Settings."); return }
                do {
                    _ = try await c.heartbeat(capabilities: SentinelLinkIdentity.capabilities())
                    devices = try await c.devices()
                    outbox = try await c.outbox()
                    approvals = try await c.approvals()
                    // Shares are never resent in the background: a failed send is
                    // reported to the user, who may review and send again.
                    lastSync = Date()
                    link = .connected
                    failures = 0
                    try? await Task.sleep(nanoseconds: UInt64(DeviceLinkProtocol.inboxInterval * 1_000_000_000))
                } catch let e as DeviceLinkError {
                    if e.endsLink {
                        linkEnded(e)
                        return
                    }
                    failures += 1
                    let wait = e.isRetryable ? policy.delay(afterFailures: failures, retryAfter: e.retryAfter) : 60
                    link = .offline(reason: e.description, retryIn: wait)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    /// The server ended the link (never retried). `authority_changed` means the
    /// server switched between HCG Connect and local development pairing: the
    /// pairing is over and the user pairs again with a new invitation.
    private func linkEnded(_ e: DeviceLinkError) {
        stopSync()
        link = .ended(SentinelLinkAuthority.endedMessage(e))
        if SentinelLinkAuthority.needsNewPairing(e) {
            var n = record; n?.status = .removed
            saveRecord(n)
        }
        if e.code == "hcg_session_ended" { signIn = .ended(e.description) }
        health = .notConnected(SentinelLinkAuthority.endedMessage(e))
        log.record(.devices, "Connected devices stopped: \(e.code)", severity: .warning)
    }

    // MARK: HCG Server health (read only)

    /// Reads `link/diagnostics` once. Shows the real error when it fails and
    /// never fills in values the server did not send.
    func loadHealth() {
        guard let r = record, r.status == .approved else {
            health = .notConnected(record?.status == .pending ? "Not connected: the server owner has not approved this device yet."
                                                              : "Not connected: this device is not paired with an HCG Server.")
            return
        }
        guard remoteAllowed() else {
            health = .notConnected("Not connected: Remote connections are off in Settings, so Sentinel does not contact HCG Server.")
            return
        }
        guard let c = client else { health = .notConnected("Not connected: \(identityProblem ?? "no usable server address.")"); return }
        if case .loading = health { return }
        health = .loading
        Task {
            do {
                let d = try await c.diagnostics()
                health = .loaded(d, fetchedAt: Date())
            } catch let e as DeviceLinkError where e.endsLink {
                linkEnded(e)
                health = .failed(SentinelLinkAuthority.endedMessage(e))
            } catch {
                health = .failed(describe(error))
            }
        }
    }

    // MARK: sharing (explicit, reviewed, one report at a time)

    /// Devices that may receive a report: approved, non-revoked installations
    /// of the pinned server that accept reports (never this one).
    var shareDestinations: [ShareDestination] {
        guard let d = devices, let r = record else { return [] }
        return ShareDestinationCheck.eligible(d, pinnedServerFingerprint: r.serverFingerprint)
    }

    /// What a shared report may and may not name: the server's display name is
    /// allowed; this device's personal name, the server's address and the
    /// signed-in e-mail never appear.
    func shareContext() -> ShareRedaction.Context {
        var sensitive = [UIDevice.current.name]
        if let r = record {
            sensitive.append(r.serverAddress)
            if let host = r.baseURL?.host { sensitive.append(host) }
        }
        if case .signedIn(let email?) = signIn { sensitive.append(email) }
        return ShareRedaction.Context(allowedNames: record.map { [$0.serverName] } ?? [], sensitiveNames: sensitive)
    }

    /// Who a shared report says it is from: a neutral model name, never the personal device name.
    func shareOrigin() -> ShareOrigin? {
        identity.map { ShareOrigin(installationId: $0.installationId, deviceName: SentinelReportSharing.neutralDeviceName(model: UIDevice.current.model),
                                   appVersion: appVersion) }
    }

    /// Builds, redacts, encodes and checks the report once. Sends nothing.
    func prepareShare(_ build: (ShareOrigin, ShareRedaction) -> DiagnosticReport) -> SharePayload? {
        guard let origin = shareOrigin() else { return nil }
        return SharePayload.prepare(context: shareContext()) { build(origin, $0) }
    }

    private func shareService() -> ReportShareService? {
        guard let c = client, let r = record else { return nil }
        return ReportShareService(client: c, pinnedServerFingerprint: r.serverFingerprint, audit: shareAudit)
    }

    /// The user confirmed on the review screen: re-check the destination and send exactly `payload`.
    func send(_ payload: SharePayload, to destination: ShareDestination, messageId: String) async -> ReportShareService.SendResult {
        guard remoteAllowed() else { return .refused("Remote connections are off in Settings, so nothing was sent.") }
        guard record?.status == .approved, let service = shareService() else { return .refused("This device is not paired with an HCG Server.") }
        let result = await service.send(payload, to: destination, messageId: messageId)
        shareHistory = shareAudit.entries()
        switch result {
        case .sent(_, let state, _):
            log.record(.devices, "Report shared with \(destination.name) after review (\(state))")
            outbox = (try? await service.client.outbox()) ?? outbox
        case .refused(let why):
            log.record(.devices, "Report not shared: \(why)", severity: .warning)
        case .failed(_, let e):
            if let e = e, e.endsLink { linkEnded(e) }
        }
        return result
    }

    /// The user closed the review without sending. No network call.
    func cancelShare(_ payload: SharePayload, destination: ShareDestination?) {
        ReportShareService.cancel(payload, destination: destination, audit: shareAudit)
        shareHistory = shareAudit.entries()
    }

    /// Withdraws a sent report while the recipient has not downloaded it.
    func withdraw(messageId: String) async -> String {
        guard remoteAllowed() else { return "Remote connections are off in Settings." }
        guard let service = shareService() else { return "This device is not paired with an HCG Server." }
        let header = outbox.first { $0.messageId.lowercased() == messageId.lowercased() }
        let result = await service.withdraw(messageId: messageId, header: header)
        shareHistory = shareAudit.entries()
        outbox = (try? await service.client.outbox()) ?? outbox
        let name = header?.to.name ?? "the recipient"
        switch result {
        case .withdrawn:
            log.record(.devices, "Shared report withdrawn before \(name) downloaded it")
            return "Withdrawn. \(name) had not downloaded it; HCG Server deleted its copy."
        case .alreadyDelivered:
            return "Not withdrawn: \(name) already downloaded this report, so it can no longer be recalled."
        case .failed(let why, let e):
            if let e = e, e.endsLink { linkEnded(e) }
            return "Not withdrawn: \(why)"
        }
    }

    // MARK: removal

    /// Removes this installation from the server (needs only the device key), then forgets the pairing.
    func removeFromServer() {
        busy = true
        Task {
            defer { busy = false }
            if let c = client, remoteAllowed() {
                do { try await c.unregister() } catch { message = "The server could not be told (\(describe(error))). The pairing was forgotten on this device; the owner can also remove it on the server." }
            }
            forgetLocally()
        }
    }

    func forgetLocally() {
        stopSync()
        saveRecord(nil)
        devices = nil
        outbox = []
        approvals = nil
        health = .notConnected("Not connected: this device is not paired with an HCG Server.")
        link = .notPaired
        InstallationIdentity.reset(store: secrets)
        log.record(.devices, "Pairing forgotten on this device")
    }

    private func describe(_ error: Error) -> String {
        (error as? DeviceLinkError)?.description ?? (error as? HCGConnectError)?.description ?? "\(error)"
    }
}

/// Window anchor for the HCG Connect sign-in sheet.
final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first ?? ASPresentationAnchor()
    }
}
