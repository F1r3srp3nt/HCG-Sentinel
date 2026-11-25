import XCTest
@testable import SentinelCore

final class PingTests: XCTestCase {
    private let token: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

    func testEchoRequestLayoutAndChecksum() {
        let packet = ICMPEcho.request(family: .ipv4, identifier: 0x1234, sequence: 7, token: token)
        XCTAssertEqual(packet.count, ICMPEcho.headerSize + ICMPEcho.payloadSize)
        XCTAssertEqual(packet[0], 8, "Echo Request")
        XCTAssertEqual(Array(packet[4...7]), [0x12, 0x34, 0x00, 0x07])
        XCTAssertEqual(Array(packet[8..<16]), token)
        XCTAssertEqual(ICMPEcho.checksum(packet), 0, "a packet with a correct checksum sums to zero")
        let v6 = ICMPEcho.request(family: .ipv6, identifier: 1, sequence: 1, token: token)
        XCTAssertEqual(v6[0], 128)
        XCTAssertEqual(Array(v6[2...3]), [0, 0], "the kernel fills in the ICMPv6 checksum")
    }

    func testChecksumKnownValue() {
        // RFC 1071 example words 0x0001 0xf203 0xf4f5 0xf6f7 sum to 0xddf2; the checksum is its complement.
        XCTAssertEqual(ICMPEcho.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]), ~UInt16(0xddf2))
    }

    private func reply(sequence: UInt16, token: [UInt8], type: UInt8 = 0) -> [UInt8] {
        var packet = ICMPEcho.request(family: .ipv4, identifier: 99, sequence: sequence, token: token)
        packet[0] = type
        return packet
    }

    func testReplyMatchingWithAndWithoutIPHeader() {
        let bare = reply(sequence: 3, token: token)
        XCTAssertEqual(ICMPEcho.matchReply(bare, family: .ipv4, token: token), 3, "Linux: no IP header")
        let ipHeader: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        XCTAssertEqual(ICMPEcho.matchReply(ipHeader + bare, family: .ipv4, token: token), 3, "Darwin: 20-byte IPv4 header first")
        XCTAssertNil(ICMPEcho.matchReply(reply(sequence: 3, token: [9, 9, 9, 9, 9, 9, 9, 9]), family: .ipv4, token: token), "another session's reply")
        XCTAssertNil(ICMPEcho.matchReply(reply(sequence: 3, token: token, type: 8), family: .ipv4, token: token), "our own request echoed back is not a reply")
        XCTAssertNil(ICMPEcho.matchReply(Array(bare.prefix(10)), family: .ipv4, token: token), "truncated")
        var v6 = ICMPEcho.request(family: .ipv6, identifier: 1, sequence: 12, token: token)
        v6[0] = 129
        XCTAssertEqual(ICMPEcho.matchReply(v6, family: .ipv6, token: token), 12)
    }

    func testConfigurationIsBounded() {
        let wild = PingConfiguration(count: 100_000, interval: 0.01, timeout: 0, method: .tcpConnect(port: 70_000))
        XCTAssertEqual(wild.count, 100)
        XCTAssertEqual(wild.interval, 1, "no sub-second intervals, no flood mode")
        XCTAssertEqual(wild.timeout, 1)
        XCTAssertEqual(wild.method, .tcpConnect(port: 65_535))
        XCTAssertEqual(PingConfiguration().count, 10)
        XCTAssertTrue(PingConfiguration.Method.tcpConnect(port: 443).title.contains("not ICMP"))
    }

    func testStatistics() {
        let at = Date()
        let results = [PingProbeResult(sequence: 1, outcome: .reply(milliseconds: 10), at: at),
                       PingProbeResult(sequence: 2, outcome: .timeout, at: at),
                       PingProbeResult(sequence: 3, outcome: .reply(milliseconds: 30), at: at),
                       PingProbeResult(sequence: 4, outcome: .error("No route to host"), at: at)]
        let stats = PingStatistics(results: results)
        XCTAssertEqual(stats.sent, 4)
        XCTAssertEqual(stats.received, 2)
        XCTAssertEqual(stats.lost, 2)
        XCTAssertEqual(stats.lossPercent, 50)
        XCTAssertEqual(stats.minimum, 10)
        XCTAssertEqual(stats.maximum, 30)
        XCTAssertEqual(stats.average, 20)
        XCTAssertNil(PingStatistics().lossPercent)
    }

    func testTargetInput() {
        XCTAssertEqual(try PingTargetInput.validate("  192.168.1.1 ").get(), "192.168.1.1")
        XCTAssertEqual(try PingTargetInput.validate("[fe80::1]").get(), "fe80::1")
        for bad in ["", "   ", "http://example.com", "example.com/path", "a b"] {
            XCTAssertThrowsError(try PingTargetInput.validate(bad).get(), bad)
        }
    }

    /// A prober that answers from a script, for the session's sequencing and cancellation.
    final class ScriptedProber: PingProber {
        var outcomes: [PingProbeOutcome]
        var resolveError: ResolveFailure?
        var prepareError: PingStartFailure?
        var probes = 0
        var finished = false
        init(_ outcomes: [PingProbeOutcome]) { self.outcomes = outcomes }
        func resolve(_ host: String) throws -> [ProbeAddress] {
            if let error = resolveError { throw error }
            return [ProbeAddress(numeric: "127.0.0.1")!]
        }
        func prepare(method: PingConfiguration.Method, address: ProbeAddress) throws {
            if let error = prepareError { throw error }
        }
        func probe(sequence: UInt16, timeout: TimeInterval) -> PingProbeOutcome {
            probes += 1
            return outcomes.isEmpty ? .timeout : outcomes.removeFirst()
        }
        func finish() { finished = true }
    }

    private func run(_ session: PingSession, cancelAfter: Int? = nil) -> [PingSession.Event] {
        var events: [PingSession.Event] = []
        var probeCount = 0
        let done = expectation(description: "finished")
        session.start { event in
            events.append(event)
            if case .probe = event {
                probeCount += 1
                if probeCount == cancelAfter { session.cancel() }
            }
            if case .finished = event { done.fulfill() }
        }
        wait(for: [done], timeout: 30)
        return events
    }

    func testSessionRunsCountProbesAndFinishes() {
        let prober = ScriptedProber([.reply(milliseconds: 1), .timeout, .reply(milliseconds: 2)])
        let session = PingSession(host: "127.0.0.1", configuration: PingConfiguration(count: 3, interval: 1, timeout: 1),
                                  prober: prober, callbackQueue: DispatchQueue(label: "cb"))
        let events = run(session)
        let probes = events.compactMap { event -> PingProbeResult? in if case .probe(let r) = event { return r }; return nil }
        XCTAssertEqual(probes.map { $0.sequence }, [1, 2, 3])
        XCTAssertEqual(events.last, .finished(cancelled: false))
        XCTAssertTrue(prober.finished, "the socket is closed at the end")
    }

    func testCancelStopsBeforeTheNextProbe() {
        let prober = ScriptedProber([])
        let session = PingSession(host: "127.0.0.1", configuration: PingConfiguration(count: 50, interval: 5, timeout: 1),
                                  prober: prober, callbackQueue: DispatchQueue(label: "cb"))
        let start = Date()
        let events = run(session, cancelAfter: 1)
        XCTAssertEqual(events.last, .finished(cancelled: true))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "cancel wakes the interval wait")
        XCTAssertLessThanOrEqual(prober.probes, 2)
    }

    func testDNSFailureIsReportedAsSuch() {
        let prober = ScriptedProber([])
        prober.resolveError = .notFound("no-such-host.invalid")
        let session = PingSession(host: "no-such-host.invalid", configuration: PingConfiguration(count: 3),
                                  prober: prober, callbackQueue: DispatchQueue(label: "cb"))
        let events = run(session)
        XCTAssertEqual(events.first, .failed(.resolve(.notFound("no-such-host.invalid"))))
        XCTAssertEqual(prober.probes, 0)
        XCTAssertTrue(PingStartFailure.resolve(.notFound("x")).message.hasPrefix("DNS"))
    }

    func testICMPUnavailableSuggestsTheLabelledTCPTest() {
        let prober = ScriptedProber([])
        prober.prepareError = .icmpUnavailable("Not permitted by the system (EACCES)")
        let events = run(PingSession(host: "127.0.0.1", configuration: PingConfiguration(count: 3), prober: prober,
                                     callbackQueue: DispatchQueue(label: "cb")))
        XCTAssertTrue(events.contains(.failed(.icmpUnavailable("Not permitted by the system (EACCES)"))))
        XCTAssertTrue(PingStartFailure.icmpUnavailable("x").message.contains("not a ping"))
    }

    // MARK: Real sockets on this machine (loopback only)

    func testRealICMPEchoToLoopback() throws {
        let prober = SocketPingProber()
        let address = try XCTUnwrap(ProbeAddress(numeric: "127.0.0.1"))
        do {
            try prober.prepare(method: .icmpEcho, address: address)
        } catch {
            throw XCTSkip("This machine does not allow unprivileged ICMP sockets: \(error)")
        }
        defer { prober.finish() }
        guard case .reply(let ms) = prober.probe(sequence: 1, timeout: 2) else {
            return XCTFail("no echo reply from 127.0.0.1")
        }
        XCTAssertLessThan(ms, 2000)
    }

    func testRealTCPConnectAcceptedAndRefused() throws {
        let server = LoopbackHTTPServer { _ in LabHTTPResponse.json(200, [:]) }
        let url = try server.start()
        defer { server.stop() }
        let address = try XCTUnwrap(ProbeAddress(numeric: "127.0.0.1"))
        let port = UInt16(try XCTUnwrap(url.port))
        guard case .connected = ProbeSockets.tcpConnect(address, port: port, timeout: 2) else { return XCTFail("listener not reached") }
        server.stop()
        Thread.sleep(forTimeInterval: 0.5)
        let closed = ProbeSockets.tcpConnect(address, port: port, timeout: 2)
        XCTAssertTrue(closed.hostResponded, "a closed loopback port refuses: \(closed)")
        if case .refused = closed {} else { XCTFail("expected refused, got \(closed)") }
    }

    func testRealResolverReportsNotFound() {
        XCTAssertThrowsError(try ProbeSockets.resolve("sentinel-no-such-host.invalid")) { error in
            guard let failure = error as? ResolveFailure else { return XCTFail("\(error)") }
            switch failure {
            case .notFound, .failed: break // .failed when the runner has no DNS at all
            case .invalidInput: XCTFail("a name is not invalid input")
            }
        }
        XCTAssertEqual(try ProbeSockets.resolve("127.0.0.1").first?.text, "127.0.0.1")
    }
}

final class LocalDiscoveryTests: XCTestCase {
    private let home = LocalInterfaceNetwork(interface: "en0", address: IPv4("192.168.1.23")!, network: IPv4Network("192.168.1.0/24")!)

    func testIPv4Parsing() {
        XCTAssertEqual(IPv4("10.0.0.1")?.value, 0x0a00_0001)
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "a.b.c.d", "1.2.3.-4"] { XCTAssertNil(IPv4(bad), bad) }
        XCTAssertEqual(IPv4(0xc0a8_0101).description, "192.168.1.1")
    }

    func testNetworks() throws {
        let net = try XCTUnwrap(IPv4Network("192.168.1.77/24"))
        XCTAssertEqual(net.description, "192.168.1.0/24")
        XCTAssertEqual(net.hosts.count, 254)
        XCTAssertEqual(net.hosts.first?.description, "192.168.1.1")
        XCTAssertEqual(net.hosts.last?.description, "192.168.1.254")
        XCTAssertEqual(net.broadcast.description, "192.168.1.255")
        XCTAssertEqual(IPv4Network("192.168.1.7")?.hosts.map { $0.description }, ["192.168.1.7"])
        XCTAssertEqual(IPv4Network(address: IPv4("10.1.2.3")!, netmask: IPv4("255.255.0.0")!)?.description, "10.1.0.0/16")
        XCTAssertNil(IPv4Network(address: IPv4("10.1.2.3")!, netmask: IPv4("255.0.255.0")!), "non-contiguous mask")
        XCTAssertNil(IPv4Network("10.0.0.0/33"))
        XCTAssertNil(IPv4Network("10.0.0.0/2x"))
        XCTAssertTrue(IPv4Network("192.168.0.0/16")!.contains(net))
        XCTAssertFalse(net.contains(IPv4Network("192.168.0.0/16")!))
    }

    func testPrivateRanges() {
        for ok in ["10.9.8.7", "172.16.0.1", "172.31.255.254", "192.168.0.1", "169.254.3.4"] { XCTAssertTrue(IPv4(ok)!.isPrivateOrLinkLocal, ok) }
        for no in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "192.169.0.1", "127.0.0.1"] { XCTAssertFalse(IPv4(no)!.isPrivateOrLinkLocal, no) }
    }

    func testScopeRules() {
        func refusal(_ text: String, confirmed: Bool = true, networks: [LocalInterfaceNetwork]? = nil) -> DiscoveryScope.Refusal? {
            if case .failure(let r) = DiscoveryScope.make(text, localNetworks: networks ?? [home], confirmedAuthorization: confirmed) { return r }
            return nil
        }
        XCTAssertEqual(refusal("8.8.8.0/24"), .notPrivate("8.8.8.0/24"))
        XCTAssertEqual(refusal("192.168.0.0/16"), .tooLarge("192.168.0.0/16"))
        XCTAssertEqual(refusal("10.0.0.0/24"), .outsideLocalNetworks("10.0.0.0/24"))
        XCTAssertEqual(refusal("192.168.1.0/24", confirmed: false), .notConfirmed)
        XCTAssertEqual(refusal("192.168.1.0/24", networks: []), .outsideLocalNetworks("192.168.1.0/24"))
        XCTAssertEqual(refusal("not an address"), .invalid("not an address"))
        guard case .success(let scope) = DiscoveryScope.make("192.168.1.0/24", localNetworks: [home], confirmedAuthorization: true) else {
            return XCTFail("a confirmed /24 on the home network is allowed")
        }
        XCTAssertEqual(scope.hosts.count, 253, "the iPhone's own address is not probed")
        XCTAssertFalse(scope.hosts.contains(home.address))
        XCTAssertEqual(scope.excludesOwnAddress, home.address)
        guard case .success(let one) = DiscoveryScope.make("192.168.1.40", localNetworks: [home], confirmedAuthorization: true) else {
            return XCTFail("a single address is a valid scope")
        }
        XCTAssertEqual(one.hosts.map { $0.description }, ["192.168.1.40"])
    }

    func testSuggestedRange() {
        XCTAssertEqual(DiscoveryScope.suggestedRange(for: home)?.description, "192.168.1.0/24")
        let big = LocalInterfaceNetwork(interface: "en0", address: IPv4("10.20.30.40")!, network: IPv4Network("10.0.0.0/8")!)
        XCTAssertEqual(DiscoveryScope.suggestedRange(for: big)?.description, "10.20.30.0/24", "never more than a /24")
        let cgnat = LocalInterfaceNetwork(interface: "pdp_ip0", address: IPv4("100.70.1.2")!, network: IPv4Network("100.64.0.0/10")!)
        XCTAssertNil(DiscoveryScope.suggestedRange(for: cgnat), "carrier networks are not the user's")
    }

    final class FakeHostProber: HostProber {
        var echoes: Set<String> = []
        var refusals: [String: Int] = [:]
        private let lock = NSLock()
        private(set) var calls: [String] = []
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0

        private func track(_ text: String, _ body: () -> HostResponse?) -> HostResponse? {
            lock.lock(); calls.append(text); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
            defer { lock.lock(); inFlight -= 1; lock.unlock() }
            return body()
        }
        func echo(_ address: IPv4, timeout: TimeInterval) -> HostResponse? {
            track("echo \(address)") { echoes.contains(address.description) ? .icmpEchoReply(milliseconds: 3) : nil }
        }
        func connect(_ address: IPv4, port: Int, timeout: TimeInterval) -> HostResponse? {
            track("tcp \(address):\(port)") { refusals[address.description] == port ? .tcpRefused(port: port, milliseconds: 4) : nil }
        }
        func reverseName(_ address: IPv4) -> String? { address.description == "192.168.1.1" ? "router.lan" : nil }
    }

    func testSweepReportsVerifiedResponsesAndNoResponseHonestly() throws {
        guard case .success(let scope) = DiscoveryScope.make("192.168.1.0/28", localNetworks: [home], confirmedAuthorization: true) else {
            return XCTFail("scope")
        }
        let prober = FakeHostProber()
        prober.echoes = ["192.168.1.1"]
        prober.refusals = ["192.168.1.5": 443]
        var limits = LocalSweep.Limits()
        limits.concurrency = 50
        let sweep = LocalSweep(scope: scope, limits: limits, prober: prober, callbackQueue: DispatchQueue(label: "cb"))
        XCTAssertEqual(sweep.limits.concurrency, LocalSweep.maxConcurrency, "concurrency is capped")
        var hosts: [DiscoveredHost] = []
        let done = expectation(description: "done")
        sweep.start { event in
            if case .host(let h) = event { hosts.append(h) }
            if case .finished(let cancelled) = event { XCTAssertFalse(cancelled); done.fulfill() }
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(hosts.count, 14)
        let router = try XCTUnwrap(hosts.first { $0.address.description == "192.168.1.1" })
        XCTAssertEqual(router.status, .responded(.icmpEchoReply(milliseconds: 3)))
        XCTAssertEqual(router.reverseName, "router.lan")
        let five = try XCTUnwrap(hosts.first { $0.address.description == "192.168.1.5" })
        XCTAssertEqual(five.status, .responded(.tcpRefused(port: 443, milliseconds: 4)))
        XCTAssertEqual(hosts.filter { $0.responded }.count, 2)
        XCTAssertFalse(prober.calls.contains("tcp 192.168.1.1:80"), "no TCP probes once ICMP answered")
        XCTAssertFalse(prober.calls.contains("tcp 192.168.1.5:22"), "stops at the first answer")
        XCTAssertFalse(prober.calls.contains { $0.contains("192.168.1.0") || $0.contains("192.168.1.15") }, "no network or broadcast address")
        XCTAssertLessThanOrEqual(prober.maxInFlight, LocalSweep.maxConcurrency)
        XCTAssertTrue(prober.calls.allSatisfy { $0.contains("192.168.1.") }, "nothing outside the scope")
    }

    func testCancelledSweepStopsProbing() {
        guard case .success(let scope) = DiscoveryScope.make("192.168.1.0/24", localNetworks: [home], confirmedAuthorization: true) else {
            return XCTFail("scope")
        }
        let prober = FakeHostProber()
        let sweep = LocalSweep(scope: scope, prober: prober, callbackQueue: DispatchQueue(label: "cb"))
        let done = expectation(description: "done")
        sweep.start { event in if case .finished(let cancelled) = event { XCTAssertTrue(cancelled); done.fulfill() } }
        sweep.cancel()
        wait(for: [done], timeout: 30)
        XCTAssertLessThan(prober.calls.count, scope.hosts.count * 5, "cancel prevents the rest of the sweep")
    }
}
