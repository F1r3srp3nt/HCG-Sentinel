import Foundation
import Network
import SentinelCore

/// Status words shared by the network tools and the dashboard.
enum ToolStatus: Equatable {
    case idle, running, completed, permissionRequired, unsupported, failed

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Scanning"
        case .completed: return "Completed"
        case .permissionRequired: return "Permission required"
        case .unsupported: return "Unsupported"
        case .failed: return "Failed"
        }
    }

    var tone: Tone {
        switch self {
        case .idle: return .off
        case .running: return .ready
        case .completed: return .info
        case .permissionRequired: return .warning
        case .unsupported: return .off
        case .failed: return .danger
        }
    }
}

// MARK: - Ping

final class PingModel: ObservableObject {
    struct Run: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let configuration: PingConfiguration
        let startedAt: Date
        var resolved: [ProbeAddress] = []
        var target: ProbeAddress?
        var results: [PingProbeResult] = []
        var failure: String?
        var finishedAt: Date?
        var cancelled = false

        var statistics: PingStatistics { PingStatistics(results: results) }
    }

    /// Completed runs kept for this session only (never stored), newest first.
    static let historyLimit = 20

    @Published var input = ""
    @Published var useTCP = false
    @Published var tcpPort = "443"
    @Published var count = 10
    @Published var interval: TimeInterval = 1
    @Published var timeout: TimeInterval = 2
    @Published private(set) var current: Run?
    @Published private(set) var history: [Run] = []
    @Published private(set) var inputError: String?

    private var session: PingSession?
    private let log: ActivityLog

    init(log: ActivityLog) {
        self.log = log
    }

    var isRunning: Bool { session != nil }

    var status: ToolStatus {
        if isRunning { return .running }
        guard let run = current else { return .idle }
        if run.failure != nil && run.results.isEmpty { return .failed }
        return .completed
    }

    func start() {
        guard !isRunning else { return }
        let host: String
        switch PingTargetInput.validate(input) {
        case .success(let value): host = value
        case .failure(let failure): inputError = failure.message; return
        }
        var method = PingConfiguration.Method.icmpEcho
        if useTCP {
            guard let port = Int(tcpPort.trimmingCharacters(in: .whitespaces)), PingConfiguration.portRange.contains(port) else {
                inputError = "Enter a TCP port from 1 to 65535."
                return
            }
            method = .tcpConnect(port: port)
        }
        inputError = nil
        let configuration = PingConfiguration(count: count, interval: interval, timeout: timeout, method: method)
        let session = PingSession(host: host, configuration: configuration)
        self.session = session
        current = Run(host: host, configuration: configuration, startedAt: Date())
        log.record(.network, "\(configuration.method.title) to \(host) started (\(configuration.count) probes)")
        session.start { [weak self] event in self?.handle(event, from: session) }
    }

    func stop() {
        session?.cancel()
    }

    func clearHistory() {
        history.removeAll()
    }

    private func handle(_ event: PingSession.Event, from session: PingSession) {
        guard session === self.session, var run = current else { return }
        switch event {
        case .resolved(let all, let target):
            run.resolved = all
            run.target = target
        case .probe(let result):
            run.results.append(result)
        case .failed(let failure):
            run.failure = failure.message
        case .finished(let cancelled):
            run.finishedAt = Date()
            run.cancelled = cancelled
            self.session = nil
            history.insert(run, at: 0)
            if history.count > PingModel.historyLimit { history.removeLast(history.count - PingModel.historyLimit) }
            let stats = run.statistics
            log.record(.network, run.failure.map { "Ping to \(run.host) failed: \($0)" }
                       ?? "Ping to \(run.host) \(cancelled ? "stopped" : "finished"): \(stats.received)/\(stats.sent) answered",
                       severity: run.failure == nil ? .info : .warning)
        }
        current = run
    }
}

// MARK: - Local network: Bonjour

struct BonjourService: Identifiable, Equatable {
    let name: String
    let type: String
    let domain: String
    var hostName: String?
    var addresses: [String] = []
    var resolveError: String?
    var firstSeen: Date
    var lastSeen: Date
    var id: String { "\(type)|\(domain)|\(name)" }
}

/// Common Bonjour service types and what they usually mean. The meaning is the service type's registered purpose,
/// not a claim about what the device is.
enum BonjourCatalog {
    static let types: [(type: String, meaning: String)] = [
        ("_http._tcp", "Web page (HTTP)"), ("_https._tcp", "Web page (HTTPS)"), ("_ssh._tcp", "SSH remote login"),
        ("_sftp-ssh._tcp", "SFTP file transfer"), ("_smb._tcp", "Windows/Samba file sharing"),
        ("_afpovertcp._tcp", "Apple file sharing (AFP)"), ("_ipp._tcp", "Printer (IPP)"), ("_ipps._tcp", "Printer (IPP over TLS)"),
        ("_printer._tcp", "Printer (LPD)"), ("_pdl-datastream._tcp", "Printer (raw)"), ("_airplay._tcp", "AirPlay receiver"),
        ("_raop._tcp", "AirPlay audio"), ("_googlecast._tcp", "Google Cast receiver"), ("_hap._tcp", "HomeKit accessory"),
        ("_matter._tcp", "Matter smart-home device"), ("_companion-link._tcp", "Apple device (Companion Link)"),
        ("_device-info._tcp", "Device information record"), ("_workstation._tcp", "Computer (workstation)"),
        ("_rfb._tcp", "Screen sharing (VNC)"), ("_mqtt._tcp", "MQTT message broker"), ("_spotify-connect._tcp", "Spotify Connect speaker"),
        ("_sleep-proxy._udp", "Bonjour Sleep Proxy"),
    ]

    static func meaning(of type: String) -> String {
        types.first { $0.type == type }?.meaning ?? "Service type \(type)"
    }
}

/// Resolves one Bonjour service to a host name and addresses (an mDNS query; nothing connects to the device).
private final class BonjourResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let completion: (String?, [String], String?) -> Void

    init(name: String, type: String, domain: String, completion: @escaping (String?, [String], String?) -> Void) {
        service = NetService(domain: domain, type: type, name: name)
        self.completion = completion
        super.init()
        service.delegate = self
    }

    func start() { service.resolve(withTimeout: 5) }
    func stop() { service.stop() }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var addresses: [String] = []
        for data in sender.addresses ?? [] {
            if let text = BonjourResolver.numericAddress(data), !addresses.contains(text) { addresses.append(text) }
        }
        completion(sender.hostName, addresses, nil)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        completion(nil, [], code == NetService.ErrorCode.timeoutError.rawValue ? "No answer to the resolve query within 5 s" : "Could not resolve (error \(code))")
    }

    private static func numericAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
    }
}

final class LocalNetworkModel: ObservableObject {
    enum BrowseState: Equatable {
        case idle
        case browsing(since: Date)
        case finished(at: Date)
        /// iOS refused local network access (the user declined the prompt, or turned it off in Settings).
        case permissionDenied(String)
        case failed(String)
    }

    /// Browsing stops by itself after this long.
    static let browseDuration: TimeInterval = 20

    @Published private(set) var browseState: BrowseState = .idle
    @Published private(set) var services: [BonjourService] = []

    @Published var rangeInput = ""
    @Published var authorizationConfirmed = false
    @Published private(set) var sweepScope: DiscoveryScope?
    @Published private(set) var sweepResults: [DiscoveredHost] = []
    @Published private(set) var sweepProgress: (done: Int, total: Int)?
    @Published private(set) var sweepRunning = false
    @Published private(set) var sweepMessage: String?
    @Published private(set) var sweepFinishedAt: Date?

    private var browsers: [NWBrowser] = []
    private var resolvers: [String: BonjourResolver] = [:]
    private var stopWork: DispatchWorkItem?
    private var sweep: LocalSweep?
    private let log: ActivityLog
    private let queue = DispatchQueue(label: "sentinel.bonjour")

    init(log: ActivityLog) {
        self.log = log
    }

    var isBrowsing: Bool { if case .browsing = browseState { return true }; return false }
    var isActive: Bool { isBrowsing || sweepRunning }

    var status: ToolStatus {
        if isActive { return .running }
        switch browseState {
        case .permissionDenied: return .permissionRequired
        case .failed: return .failed
        case .finished: return .completed
        default: return sweepFinishedAt == nil ? .idle : .completed
        }
    }

    // MARK: Bonjour

    func startBrowsing() {
        guard !isBrowsing else { return }
        services.removeAll()
        browseState = .browsing(since: Date())
        log.record(.network, "Bonjour browsing started (\(BonjourCatalog.types.count) service types, \(Int(LocalNetworkModel.browseDuration)) s)")
        for entry in BonjourCatalog.types {
            let parameters: NWParameters = entry.type.hasSuffix("._udp") ? .udp : .tcp
            let browser = NWBrowser(for: .bonjour(type: entry.type, domain: nil), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { self?.browserState(state) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                DispatchQueue.main.async { self?.received(results) }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
        let work = DispatchWorkItem { [weak self] in self?.stopBrowsing(reason: "finished") }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LocalNetworkModel.browseDuration, execute: work)
    }

    func stopBrowsing(reason: String = "stopped") {
        stopWork?.cancel()
        stopWork = nil
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.values.forEach { $0.stop() }
        resolvers.removeAll()
        if isBrowsing {
            browseState = .finished(at: Date())
            log.record(.network, "Bonjour browsing \(reason): \(services.count) service(s) found")
        }
    }

    private func browserState(_ state: NWBrowser.State) {
        guard isBrowsing else { return }
        switch state {
        case .failed(let error), .waiting(let error):
            if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
                stopBrowsing(reason: "refused")
                browseState = .permissionDenied("iOS did not allow Sentinel to use the local network. Allow it in iOS Settings › Sentinel › Local Network (or Settings › Privacy & Security › Local Network), then browse again.")
                log.record(.network, "Bonjour browsing refused: local network access is off", severity: .warning)
            } else if case .failed = state {
                stopBrowsing(reason: "failed")
                browseState = .failed("Browsing failed: \(error.localizedDescription)")
            }
        default:
            break
        }
    }

    private func received(_ results: Set<NWBrowser.Result>) {
        guard isBrowsing else { return }
        let now = Date()
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let key = "\(type)|\(domain)|\(name)"
            if let index = services.firstIndex(where: { $0.id == key }) {
                services[index].lastSeen = now
                continue
            }
            services.append(BonjourService(name: name, type: type, domain: domain, firstSeen: now, lastSeen: now))
            let resolver = BonjourResolver(name: name, type: type, domain: domain) { [weak self] host, addresses, error in
                DispatchQueue.main.async {
                    guard let self = self, let index = self.services.firstIndex(where: { $0.id == key }) else { return }
                    self.services[index].hostName = host
                    self.services[index].addresses = addresses
                    self.services[index].resolveError = error
                    self.resolvers[key] = nil
                }
            }
            resolvers[key] = resolver
            resolver.start()
        }
        services.sort { ($0.type, $0.name) < ($1.type, $1.name) }
    }

    // MARK: Sweep

    func suggestedRange(networks: [LocalInterfaceNetwork]) -> String? {
        networks.first { $0.interface.hasPrefix("en") }.flatMap(DiscoveryScope.suggestedRange(for:))?.description
            ?? networks.compactMap(DiscoveryScope.suggestedRange(for:)).first?.description
    }

    func startSweep(networks: [LocalInterfaceNetwork]) {
        guard !sweepRunning else { return }
        switch DiscoveryScope.make(rangeInput, localNetworks: networks, confirmedAuthorization: authorizationConfirmed) {
        case .failure(let refusal):
            sweepMessage = refusal.message
        case .success(let scope):
            sweepMessage = nil
            sweepScope = scope
            sweepResults = []
            sweepProgress = (0, scope.hosts.count)
            sweepRunning = true
            sweepFinishedAt = nil
            let sweep = LocalSweep(scope: scope)
            self.sweep = sweep
            log.record(.network, "Local sweep of \(scope.range) started (\(scope.hosts.count) addresses, authorisation confirmed by the user)")
            sweep.start { [weak self] event in self?.handle(event, from: sweep) }
        }
    }

    func stopSweep() {
        sweep?.cancel()
    }

    private func handle(_ event: LocalSweep.Event, from sweep: LocalSweep) {
        guard sweep === self.sweep else { return }
        switch event {
        case .host(let host):
            sweepResults.append(host)
            sweepResults.sort { $0.address < $1.address }
        case .progress(let done, let total):
            sweepProgress = (done, total)
        case .finished(let cancelled):
            sweepRunning = false
            sweepFinishedAt = Date()
            self.sweep = nil
            let answered = sweepResults.filter { $0.responded }.count
            sweepMessage = cancelled ? "Stopped. \(sweepResults.count) of \(sweepScope?.hosts.count ?? 0) addresses were probed." : nil
            log.record(.network, "Local sweep \(cancelled ? "stopped" : "finished"): \(answered) address(es) answered")
        }
    }

    func stopAll() {
        stopBrowsing()
        stopSweep()
    }
}
