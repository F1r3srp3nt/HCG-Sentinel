import Foundation
import SentinelCore

/// State for the Security Intelligence features added in 0.1.0~beta3: device security checks, imported diagnostic
/// reports (for example from HCG System Tester), the network diagnostic history and the Capability Center's
/// self-tests. Everything runs on the user's action; nothing starts by itself.
final class IntelligenceModel: ObservableObject {
    enum SelfTestState: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    @Published private(set) var deviceSecurity: DeviceSecurityReport?
    @Published private(set) var deviceSecurityRunning = false
    @Published private(set) var importedReports: [ImportedReportStore.Entry] = []
    @Published var importMessage: String?
    @Published private(set) var history: [NetworkHistoryEntry] = []
    @Published private(set) var selfTests: [CapabilitySelfTest: SelfTestState] = [:]

    private let registry: CapabilityRegistry
    private let log: ActivityLog
    private let reportStore: ImportedReportStore
    private let historyStore: NetworkHistoryStore
    private let connection: ConnectionMonitor
    private var pingSession: PingSession?

    init(registry: CapabilityRegistry, log: ActivityLog, support: URL, connection: ConnectionMonitor) {
        self.registry = registry
        self.log = log
        self.connection = connection
        reportStore = ImportedReportStore(directory: support.appendingPathComponent("ImportedReports", isDirectory: true))
        historyStore = NetworkHistoryStore(url: support.appendingPathComponent("NetworkHistory/history.json"))
        importedReports = reportStore.list()
        history = historyStore.list()
    }

    // MARK: Device security

    func runDeviceSecurity(completion: ((Bool) -> Void)? = nil) {
        guard !deviceSecurityRunning else { return }
        deviceSecurityRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let facts = DeviceSecurityProbe.collect()
            let report = DeviceSecurityEvaluator.evaluate(facts)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.deviceSecurityRunning = false
                self.deviceSecurity = report
                let answered = report.checks.filter { $0.outcome != .unavailable }.count
                let attention = report.checks.filter { $0.outcome == .fail || $0.outcome == .warning }.count
                self.log.record(.system, "Device security checks finished: \(report.checks.count) checks, \(attention) needing attention",
                                severity: attention > 0 ? .warning : .info)
                let ok = answered > 0 && self.registry.recordVerified(.deviceSecurity, evidence: "\(answered) of \(report.checks.count) device checks returned a result (\(report.edition))")
                completion?(ok || answered > 0)
            }
        }
    }

    // MARK: Imported reports

    func importReport(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ReportValidator.maxBytes * 2, let data = try? Data(contentsOf: url) else {
            importMessage = "The file could not be read, or it is far larger than a diagnostic report."
            return
        }
        switch reportStore.add(data) {
        case .success(let entry):
            importedReports = reportStore.list()
            importMessage = "Imported “\(entry.report.title)” from \(entry.report.origin.app)."
            log.record(.system, "Imported diagnostic report from \(entry.report.origin.app) (\(entry.report.summary.findingCount) finding(s))")
            registry.recordVerified(.reportImport, evidence: "A valid hcg.diagnostic-report/1 from \(entry.report.origin.app) was imported")
        case .failure(let failure):
            importMessage = failure.message
            log.record(.system, "Report import refused: \(failure.message)", severity: .warning)
        }
    }

    func deleteImported(_ entry: ImportedReportStore.Entry) {
        reportStore.delete(entry.report.reportId)
        importedReports = reportStore.list()
    }

    // MARK: Network history

    func record(_ entry: NetworkHistoryEntry) {
        history = historyStore.add(entry)
    }

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    // MARK: Self-tests

    func run(_ test: CapabilitySelfTest) {
        guard selfTests[test] != .running else { return }
        selfTests[test] = .running
        switch test {
        case .readConnection: readConnection()
        case .loopbackPing: loopbackPing()
        case .syntheticCapture: syntheticCapture()
        case .syntheticSecretScan: syntheticSecretScan()
        case .deviceSecurityChecks:
            runDeviceSecurity { [weak self] ok in
                self?.finish(test, ok ? .passed("Device security checks completed.") : .failed("No check returned a result."))
            }
        }
    }

    private func finish(_ test: CapabilitySelfTest, _ state: SelfTestState) {
        selfTests[test] = state
        log.record(.system, "Capability self-test “\(test.title)”: \(state)", severity: { if case .failed = state { return .warning }; return .info }())
    }

    private func readConnection() {
        connection.refreshAddresses()
        let networks = ConnectionMonitor.ipv4Networks()
        guard let snapshot = connection.snapshot else {
            registry.recordFailure(.connectionDiagnostics, reason: "iOS has not reported a network path yet")
            finish(.readConnection, .failed("iOS has not reported a network path yet."))
            return
        }
        registry.recordVerified(.connectionDiagnostics, evidence: "iOS reported the path: \(snapshot.headline)")
        if let wifi = networks.first(where: { $0.interface.hasPrefix("en") }) {
            registry.recordVerified(.wifiConnectionInfo, evidence: "Read \(wifi.interface) IPv4 address and /\(wifi.network.prefix) subnet from the system")
            finish(.readConnection, .passed("Path: \(snapshot.headline). \(wifi.interface) has an IPv4 address on a /\(wifi.network.prefix) network."))
        } else {
            finish(.readConnection, .passed("Path: \(snapshot.headline). No Wi-Fi or wired IPv4 address right now, so Wi-Fi details stay unverified."))
        }
    }

    private func loopbackPing() {
        let session = PingSession(host: "127.0.0.1", configuration: PingConfiguration(count: 1, interval: 1, timeout: 2))
        pingSession = session
        var outcome: PingProbeOutcome?
        var failure: String?
        session.start { [weak self] event in
            guard let self = self else { return }
            switch event {
            case .probe(let result): outcome = result.outcome
            case .failed(let error): failure = error.message
            case .finished:
                self.pingSession = nil
                if case .reply(let ms)? = outcome {
                    let text = String(format: "ICMP Echo Reply from 127.0.0.1 (this iPhone's loopback) in %.2f ms", ms)
                    self.registry.recordVerified(.icmpPing, evidence: text)
                    self.finish(.loopbackPing, .passed(text + ". This proves ICMP works here, not that any other host is reachable."))
                } else {
                    let reason = failure ?? outcome.map { "\($0)" } ?? "no result"
                    self.registry.recordFailure(.icmpPing, reason: reason)
                    self.finish(.loopbackPing, .failed(reason))
                }
            default: break
            }
        }
    }

    private func syntheticCapture() {
        let base = Date()
        let records = (0..<3).map { index in
            SyntheticCapture.Record(timestamp: base.addingTimeInterval(Double(index) * 0.1),
                                    bytes: SyntheticCapture.ethernet(etherType: 0x0800, payload: SyntheticCapture.ipv4(
                                        source: [192, 0, 2, 1], destination: [192, 0, 2, 2], proto: 17,
                                        payload: SyntheticCapture.udp(sourcePort: 5353, destinationPort: 53))))
        }
        do {
            let parsed = try CaptureParser.parse(SyntheticCapture.pcapng(records))
            let stats = CaptureStatistics.compute(parsed)
            guard parsed.packets.count == 3, stats.protocols.first?.name == "UDP" else {
                finish(.syntheticCapture, .failed("The parser returned \(parsed.packets.count) packets instead of 3."))
                return
            }
            registry.recordVerified(.captureFileInspection, evidence: "Parsed and decoded a synthetic 3-packet pcapng generated on this device (no real traffic)")
            finish(.syntheticCapture, .passed("Generated and decoded a synthetic 3-packet pcapng (documentation addresses only). Import your own capture to inspect real traffic."))
        } catch {
            registry.recordFailure(.captureFileInspection, reason: "\(error)")
            finish(.syntheticCapture, .failed("\(error)"))
        }
    }

    private func syntheticSecretScan() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-selftest-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // A fake AWS-style key that exists nowhere: the scanner must find it and return it redacted.
            let fake = "AKIA" + "SNTLSELF" + "CHECK026"
            var outcome: SelfTestState = .failed("The test file could not be written.")
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               (try? Data("aws_access_key_id = \(fake)\n".utf8).write(to: folder.appendingPathComponent("config.ini"))) != nil {
                let configuration = SecretScanConfiguration(fingerprintKey: [UInt8](repeating: 0x5A, count: 32))
                let record = SecretScanner(configuration: configuration).scan([folder], control: AssessmentControl(timeout: 20))
                let leaked = record.findings.contains { finding in finding.evidence.contains { $0.contains(fake) } || (finding.location ?? "").contains(fake) }
                if leaked {
                    outcome = .failed("A finding contained the full test value: redaction did not work.")
                } else if record.findings.isEmpty {
                    outcome = .failed("The scanner did not report the test key.")
                } else {
                    outcome = .passed("Found the planted test key (\(record.findings.count) finding) and kept it redacted. The test file was deleted.")
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .passed = outcome {
                    self.registry.recordVerified(.secretScanning, evidence: "Self-test: a planted fake key was found and redacted")
                } else if case .failed(let reason) = outcome {
                    self.registry.recordFailure(.secretScanning, reason: reason)
                }
                self.finish(.syntheticSecretScan, outcome)
            }
        }
    }
}
