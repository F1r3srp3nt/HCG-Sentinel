import Foundation
import Network
import NetworkExtension
import Security
import SentinelCore

/// Supplies Check My Network with real information about this device's connection. Nothing here guesses:
/// anything iOS does not provide is reported as unavailable, with the reason.
final class PlatformNetworkProbe: NSObject, NetworkAssessmentProbe, URLSessionTaskDelegate {
    private let monitorQueue = DispatchQueue(label: "sentinel.assessment.path")
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    /// Certificate summaries per task, written and read on `delegateQueue` only.
    private var certificates: [Int: [String]] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    // MARK: Connection

    func connectionFacts(completion: @escaping (ConnectionFacts?) -> Void) {
        let monitor = NWPathMonitor()
        var delivered = false
        monitor.pathUpdateHandler = { [weak monitor] path in
            guard !delivered else { return }
            delivered = true
            let facts = PlatformNetworkProbe.facts(from: path)
            monitor?.pathUpdateHandler = nil
            monitor?.cancel()
            DispatchQueue.main.async { completion(facts) }
        }
        monitor.start(queue: monitorQueue)
        // Keep the monitor alive until it has delivered its first update (the engine bounds the wait).
        monitorQueue.asyncAfter(deadline: .now() + 6) { withExtendedLifetime(monitor) {} }
    }

    private static func facts(from path: NWPath) -> ConnectionFacts {
        var types: [String] = []
        if path.usesInterfaceType(.wifi) { types.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { types.append("Cellular") }
        if path.usesInterfaceType(.wiredEthernet) { types.append("Wired") }
        if path.usesInterfaceType(.other) { types.append("Other") }
        let status: String
        switch path.status {
        case .satisfied: status = "Online"
        case .unsatisfied: status = "No network connection"
        case .requiresConnection: status = "Connection must be activated"
        @unknown default: status = "Unknown"
        }
        let gateways: [String] = path.gateways.map { endpoint in
            if case .hostPort(let host, _) = endpoint { return "\(host)" }
            return "\(endpoint)"
        }
        return ConnectionFacts(isOnline: path.status == .satisfied, statusDescription: status, interfaceTypes: types,
                               isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                               supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6,
                               supportsDNS: path.supportsDNS, gateways: gateways)
    }

    // MARK: Wi-Fi identity

    func wifiFacts(completion: @escaping (WiFiFacts) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
                guard let network = network else {
                    completion(WiFiFacts(unavailableReason: "iOS did not provide the joined network’s name, BSSID or security type. It only does so for apps that have Apple’s Access Wi-Fi Information entitlement and location permission. Sentinel has neither, so these values are unavailable rather than guessed."))
                    return
                }
                var security: WiFiSecurity?
                if #available(iOS 15.0, *) {
                    switch network.securityType {
                    case .open: security = .open
                    case .WEP: security = .wep
                    case .personal: security = .personal
                    case .enterprise: security = .enterprise
                    case .unknown: security = .unknown
                    @unknown default: security = .unknown
                    }
                }
                completion(WiFiFacts(ssid: network.ssid.isEmpty ? nil : network.ssid,
                                     bssid: network.bssid.isEmpty ? nil : network.bssid,
                                     security: security))
            }
        }
    }

    // MARK: Proxy and tunnels

    func proxyFacts(completion: @escaping (ProxyFacts) -> Void) {
        guard let unmanaged = CFNetworkCopySystemProxySettings(),
              let settings = unmanaged.takeRetainedValue() as? [String: Any] else {
            completion(ProxyFacts(unavailableReason: "The system returned no proxy settings."))
            return
        }
        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue == true }
        func proxy(_ enable: String, _ hostKey: String, _ portKey: String) -> String? {
            guard enabled(enable), let host = settings[hostKey] as? String, !host.isEmpty else { return nil }
            if let port = settings[portKey] as? NSNumber { return "\(host):\(port)" }
            return host
        }
        let pac = enabled("ProxyAutoConfigEnable") ? (settings["ProxyAutoConfigURLString"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]
        let scoped: [String] = (settings["__SCOPED__"] as? [String: Any]).map { Array($0.keys) } ?? []
        let tunnels = scoped.filter { name in tunnelPrefixes.contains { name.hasPrefix($0) } }.sorted()
        completion(ProxyFacts(httpProxy: proxy("HTTPEnable", "HTTPProxy", "HTTPPort"),
                              httpsProxy: proxy("HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
                              pacURL: pac, autoDiscovery: enabled("ProxyAutoDiscoveryEnable"),
                              tunnelInterfaces: tunnels))
    }

    // MARK: DNS

    private final class CancelFlag: AssessmentCancellable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    func resolve(host: String, timeout: TimeInterval, completion: @escaping (ResolveOutcome) -> Void) -> AssessmentCancellable? {
        let flag = CancelFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            let outcome: ResolveOutcome
            if status == 0 {
                var addresses: [String] = []
                var cursor = result
                while let info = cursor {
                    if let address = info.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(address, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let text = String(cString: buffer)
                            if !addresses.contains(text) { addresses.append(text) }
                        }
                    }
                    cursor = info.pointee.ai_next
                }
                freeaddrinfo(result)
                outcome = addresses.isEmpty ? .failed("The resolver returned no addresses.") : .addresses(addresses)
            } else if status == EAI_NONAME {
                outcome = .notFound
            } else {
                outcome = .failed(String(cString: gai_strerror(status)))
            }
            DispatchQueue.main.async {
                if !flag.isCancelled { completion(outcome) }
            }
        }
        return flag
    }

    // MARK: HTTP(S)

    private final class TaskHandle: AssessmentCancellable {
        let task: URLSessionTask
        init(_ task: URLSessionTask) { self.task = task }
        func cancel() { task.cancel() }
    }

    func fetch(url: URL, timeout: TimeInterval, completion: @escaping (FetchOutcome) -> Void) -> AssessmentCancellable? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        var taskID = -1
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            // Runs on delegateQueue, the same queue that recorded the certificates.
            let chain = self?.certificates.removeValue(forKey: taskID) ?? []
            let outcome: FetchOutcome
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled { return } // The assessment cancelled it.
                outcome = FetchErrorClassifier.classify(code: error.code, message: error.localizedDescription, certificates: chain)
            } else if let http = response as? HTTPURLResponse {
                let body = data.map { String(decoding: $0.prefix(512), as: UTF8.self) } ?? ""
                outcome = .response(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"),
                                    bodyPrefix: body, certificates: chain)
            } else {
                outcome = .connectivityFailure(code: 0, message: "No HTTP response was received.")
            }
            DispatchQueue.main.async { completion(outcome) }
        }
        taskID = task.taskIdentifier
        task.resume()
        return TaskHandle(task)
    }

    /// Redirects are reported, never followed: following one could hide a captive portal or interception.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// Records the presented certificate chain as evidence, then lets the system evaluate trust as usual.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            certificates[task.taskIdentifier] = PlatformNetworkProbe.summaries(of: trust)
        }
        completionHandler(.performDefaultHandling, nil)
    }

    private static func summaries(of trust: SecTrust) -> [String] {
        var chain: [SecCertificate] = []
        if #available(iOS 15.0, *) {
            chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        } else {
            for index in 0..<SecTrustGetCertificateCount(trust) {
                if let certificate = SecTrustGetCertificateAtIndex(trust, index) { chain.append(certificate) }
            }
        }
        return chain.prefix(4).compactMap { SecCertificateCopySubjectSummary($0) as String? }
    }
}
