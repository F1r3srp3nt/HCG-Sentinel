import AuthenticationServices
import Foundation
import SentinelCore
import UIKit

/// Connected devices (HCG Device Link) for Sentinel: sign in with HCG Connect,
/// pair this installation with an HCG Server, see the paired devices and share
/// redacted reports with one of them.
///
/// Nothing contacts a server unless "Remote connections" is on in Settings and
/// the user acted. HCG Server authorizes every request with HCG Connect and
/// ERP App Access; this model never decides access itself and never enables
/// anything on another device.
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

    let identity: InstallationIdentity?
    let identityProblem: String?
    var deviceName: String { UIDevice.current.name }
    var appVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }

    private let secrets: LinkSecretStore
    private let recordFile: PairingRecordFile
    private let auth: HCGConnectAuth
    private let session: HCGConnectSession
    private let log: ActivityLog
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
                                  signer: id.signer, transport: PinnedSessionTransport(fingerprint: r.serverFingerprint), tokens: session)
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
            stopSync()
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
        let c = DeviceLinkClient(configuration: DeviceLinkConfiguration(baseURL: base, serverFingerprint: invitation.fingerprint, installationId: id.installationId),
                                 signer: id.signer, transport: PinnedSessionTransport(fingerprint: invitation.fingerprint), tokens: session)
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
                log.record(.devices, "Pairing requested with \(invitation.hostName); waiting for approval on the server")
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
                    link = .ended(e.description)
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
                    _ = await c.resendPending()
                    lastSync = Date()
                    link = .connected
                    failures = 0
                    try? await Task.sleep(nanoseconds: UInt64(DeviceLinkProtocol.inboxInterval * 1_000_000_000))
                } catch let e as DeviceLinkError {
                    if e.endsLink {
                        link = .ended(e.description)
                        if e.code == "device_revoked" || e.code == "unknown_installation" {
                            var n = record; n?.status = .removed
                            saveRecord(n)
                        }
                        if e.code == "hcg_session_ended" { signIn = .ended(e.description) }
                        log.record(.devices, "Connected devices stopped: \(e.code)", severity: .warning)
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

    // MARK: sharing

    /// Installations that can receive reports (never this one).
    var recipients: [LinkInstallation] {
        guard let d = devices else { return [] }
        return d.installations.filter { $0.installationId != d.selfInstallationId && $0.supports(LinkCapabilityID.reportReceive) }
    }

    func share(_ report: DiagnosticReport, to recipient: LinkInstallation) async -> String {
        guard remoteAllowed() else { return "Turn on Remote connections in Settings first." }
        guard let c = client else { return "This device is not paired with an HCG Server." }
        do {
            let r = try await c.share(report, to: recipient.installationId)
            outbox = (try? await c.outbox()) ?? outbox
            log.record(.devices, "Report shared with \(recipient.name) (\(r.recipientState))")
            return r.recipientState == "online"
                ? "Shared with \(recipient.name)."
                : "Queued for \(recipient.name). It is offline and will receive the report when it next connects (until \(Formatters.preciseTime.string(from: r.expiresAt)))."
        } catch let e as DeviceLinkError where e.isRetryable {
            return "HCG Server could not be reached. The report will be sent with the same ID when the connection returns. (\(e.description))"
        } catch {
            return "Not shared: \(describe(error))"
        }
    }

    func sharingIdentity() -> (installationId: String, deviceName: String, appVersion: String)? {
        identity.map { ($0.installationId, deviceName, appVersion) }
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
