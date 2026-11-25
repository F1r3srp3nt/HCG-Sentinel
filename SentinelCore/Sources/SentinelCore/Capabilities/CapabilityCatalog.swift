import Foundation

public enum CapabilityCatalog {
    public static let all: [CapabilityDescriptor] = [
        CapabilityDescriptor(
            id: .connectionDiagnostics, title: "Connection diagnostics",
            summary: "Shows this app's own network path: interface types, addresses and constraints.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Open Network Inspector; it is confirmed when iOS delivers a network path update.",
            limits: "Describes Sentinel's own connectivity only. It does not observe other apps."),
        CapabilityDescriptor(
            id: .captureFileInspection, title: "Capture file inspection",
            summary: "Imports pcap and pcapng files and decodes link, IP and transport headers.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Import a capture file; it is confirmed when a file parses successfully.",
            limits: "Reads files captured elsewhere. It is not live capture and does not decrypt TLS."),
        CapabilityDescriptor(
            id: .bluetoothDiscovery, title: "Bluetooth LE discovery",
            summary: "Lists nearby Bluetooth LE advertisers using Core Bluetooth.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Start a scan; it is confirmed when the first advertisement is received.",
            limits: "Sees advertisements only. iOS hides hardware addresses, and connections between other devices are not visible."),
        CapabilityDescriptor(
            id: .requestComposer, title: "Test request composer",
            summary: "Builds and sends HTTP requests from Sentinel to your selected HCG test endpoint.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Send a request; it is confirmed when the endpoint returns an HTTP response.",
            limits: "Only modifies requests Sentinel itself creates. It does not intercept other apps or decrypt HTTPS."),
        CapabilityDescriptor(
            id: .networkAssessment, title: "Check My Network",
            summary: "Bounded DNS, HTTPS, captive-portal and proxy checks of the current connection, with evidence for every finding.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Run Check My Network; it is confirmed when a run completes with at least one network test answered.",
            limits: "Tests this device's own path only. It cannot see other devices, inspect the router, or prove a network is safe."),
        CapabilityDescriptor(
            id: .radioNodeLink, title: "Radio node link",
            summary: "Connects to an external analysis node over the authenticated Sentinel Node Protocol v2.",
            tier: .externalNode, implementation: .included,
            verificationMethod: "Connect with the node's pairing key; confirmed when the authenticated capability handshake completes.",
            limits: "The iPhone itself provides no general RF reception, transmission or baseband access."),
        CapabilityDescriptor(
            id: .radioSpectrum, title: "Spectrum from node hardware",
            summary: "Displays spectrum frames streamed by a node with real radio hardware.",
            tier: .externalNode, implementation: .included,
            verificationMethod: "Stream from a node that reports hardware; confirmed by the first valid non-simulated frame.",
            limits: "Receive-side analysis only. Protocol version 1 defines no transmit operation."),
        CapabilityDescriptor(
            id: .nearbyWifiDiscovery, title: "Nearby Wi-Fi discovery",
            summary: "Lists nearby Wi-Fi networks scanned by a node that offers the wifi_scan feature.",
            tier: .externalNode, implementation: .included,
            verificationMethod: "Request a scan from an authenticated, non-simulated node that offers wifi_scan; confirmed by a valid result.",
            limits: "iOS does not let ordinary apps scan for nearby networks. Sentinel shows only what the node reports; no monitor mode, injection or radio control."),
        CapabilityDescriptor(
            id: .macDebugProxy, title: "Mac debugging proxy",
            summary: "Future adapter for an authorised debugging proxy running on a Mac.",
            tier: .externalNode,
            implementation: .interfaceOnly("The adapter interface is defined, but no Mac companion exists yet, so nothing can be intercepted."),
            verificationMethod: "Requires the Mac companion described in docs/MAC_PROXY_ADAPTER.md.",
            limits: "Separate from capture-file inspection and from any filtering. Nothing is installed or trusted automatically."),
        CapabilityDescriptor(
            id: .helperLink, title: "Privileged helper link",
            summary: "Authenticated connection to an optional helper installed separately on a compatible device.",
            tier: .privilegedHelper, implementation: .included,
            verificationMethod: "Pair and probe the helper; confirmed only by an authenticated session that answers a capability report.",
            limits: "Sentinel ships no helper binary. Helper deployment is unverified, and a package manager or sideloading proves nothing."),
        CapabilityDescriptor(
            id: .deviceWideCapture, title: "Device-wide capture",
            summary: "Future packet capture performed by the privileged helper.",
            tier: .privilegedHelper,
            implementation: .interfaceOnly("The helper operations are specified and validated, but no helper backend has been built or tested."),
            verificationMethod: "Requires a deployed helper, described in docs/HELPER_INTERFACE.md.",
            limits: "Sentinel cannot capture other apps' traffic today and does not claim to."),
        CapabilityDescriptor(
            id: .trafficFiltering, title: "Own-device traffic filtering",
            summary: "Sends block/allow rules to a privileged helper that reports it can apply them.",
            tier: .privilegedHelper, implementation: .included,
            verificationMethod: "Requires an authenticated helper whose capability report lists setFilterRules; confirmed when it accepts a rule set.",
            limits: "Sentinel only sends validated rules. Filtering itself is done by the helper; no helper has been built, so this stays unavailable until one is."),
        CapabilityDescriptor(
            id: .secretScanning, title: "Secret Scanner",
            summary: "Looks for likely exposed credentials in folders and archives you select, on this device.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Scan a folder or archive; it is confirmed when a scan completes with at least one text file read.",
            limits: "Pattern matching cannot prove a credential is active, and Sentinel never tests found credentials. Nothing is uploaded."),
        CapabilityDescriptor(
            id: .exposureCheck, title: "Exposure Check",
            summary: "Checks HTTP/HTTPS services you own or may test: reachability, TLS, HTTPS redirect, headers and version banners.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Run a check; it is confirmed when a target you entered returns an HTTP response.",
            limits: "Only the URLs you enter, with plain GET requests. No exploits, credential guessing or scanning for other hosts; banners and headers are observations only."),
        CapabilityDescriptor(
            id: .authDefenseLab, title: "Authentication Defense Lab",
            summary: "Measures lockout, rate limiting, error messages and event logging of Sentinel's bundled local login service.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Run the lab assessment; it is confirmed when the bundled lab answers a login attempt.",
            limits: "Restricted to the bundled lab and its synthetic accounts. Real services cannot be targeted from this module."),
        CapabilityDescriptor(
            id: .serverAssessments, title: "Assessments on a paired HCG Server",
            summary: "Running heavier Security Lab assessments on an HCG Server you have paired and authorised.",
            tier: .externalNode,
            implementation: .interfaceOnly("The contract is defined in docs/SECURITY_LAB_SERVER.md. Sentinel can pair with HCG Server through Device Link (Connected Devices), but HCG Server has no Security Lab assessment API yet, so every assessment runs on this device."),
            verificationMethod: "Requires an HCG Server that implements the Security Lab contract and reports the module as supported.",
            limits: "Pairing a server never enables anything by itself; each module needs the server's own capability report and an explicit scope."),
        CapabilityDescriptor(
            id: .satelliteAccess, title: "Satellite access",
            summary: "Feasibility question only: whether Sentinel could show anything about the iPhone's satellite features.",
            tier: .feasibility,
            implementation: .notIncluded("Not implemented. iOS offers apps no public interface to the satellite radio or its state, so there is nothing Sentinel can read or verify today."),
            verificationMethod: "Needs a documented, public Apple API or an external receiver with its own verified interface.",
            limits: "Sentinel shows no satellite status, positions or link data, and does not claim to."),
        CapabilityDescriptor(
            id: .radioModification, title: "Cellular radio settings and baseband",
            summary: "Feasibility question only: reading or changing how the phone's cellular, Wi-Fi or Bluetooth radios behave.",
            tier: .feasibility,
            implementation: .notIncluded("Not implemented and not planned for the app. iOS gives apps no control over the cellular, Wi-Fi or Bluetooth radios, and a jailbreak helper does not add a supported, safe way to change radio behaviour."),
            verificationMethod: "Would need concrete, legal, documented support on specific hardware before any design work.",
            limits: "Sentinel never transmits, jams, injects or changes radio settings."),
        CapabilityDescriptor(
            id: .watchScanning, title: "Apple Watch scanning",
            summary: "Feasibility question only: running scans on, or from, an Apple Watch.",
            tier: .feasibility,
            implementation: .notIncluded("Not implemented. Sentinel has no watchOS app, and watchOS limits Bluetooth and networking for apps; whether any useful, honest scan is possible has not been established."),
            verificationMethod: "Needs a watchOS prototype on real hardware that shows which APIs actually deliver data.",
            limits: "No scan data comes from an Apple Watch today."),
        CapabilityDescriptor(
            id: .wifiConnectionInfo, title: "Wi-Fi connection details",
            summary: "The current connection: interface, IPv4 address and subnet, IPv6, gateway, path changes. SSID only if iOS provides it.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Open Wi-Fi or run the self-test; confirmed when iOS reports an interface address and a network path.",
            limits: "Nearby networks cannot be listed by iOS apps. The SSID needs an entitlement and location permission this build does not have; DNS server addresses are not available to apps."),
        CapabilityDescriptor(
            id: .icmpPing, title: "Ping (ICMP Echo)",
            summary: "Real ICMP Echo from this iPhone to an address you enter, with loss and latency; a labelled TCP connect test as an alternative.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Run a ping or the loopback self-test; confirmed when an ICMP Echo Reply arrives.",
            limits: "One probe at a time, at least 1 s apart, at most 100. A TCP connect test is never called a ping. No sweeps of addresses you did not enter."),
        CapabilityDescriptor(
            id: .localDiscovery, title: "Local network discovery",
            summary: "Bonjour service browsing, and a sweep of a private range you confirm you are authorised to test.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Browse Bonjour or sweep your range; confirmed when a service is resolved or an address answers.",
            limits: "Private ranges on a network the iPhone is on, at most 254 addresses, after confirmation. No response is reported as no response, never as absence."),
        CapabilityDescriptor(
            id: .deviceSecurity, title: "Device security checks",
            summary: "Read-only checks of this iPhone: passcode and biometrics, system version, Sentinel's own package and files, and the jailbreak environment.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Run the checks; confirmed when they complete and at least one check returns a result.",
            limits: "Reads what iOS lets an app read. Nothing is changed, installed or disabled; checks that cannot be read say so."),
        CapabilityDescriptor(
            id: .reportImport, title: "Import diagnostic reports",
            summary: "Opens hcg.diagnostic-report/1 files you choose, for example HCG System Tester's connection-security findings.",
            tier: .onDevice, implementation: .included,
            verificationMethod: "Import a report file; confirmed when a valid, redacted report is read.",
            limits: "Reports are data: every field is shown as text, nothing in them is opened or run. Sentinel does not contact the app that made them."),
        CapabilityDescriptor(
            id: .deviceLinkPairing, title: "HCG Server pairing (Device Link)",
            summary: "Pairs with an HCG Server you run, over HCG Device Link, to share redacted reports.",
            tier: .externalNode, implementation: .included,
            verificationMethod: "Pair from Connected Devices; confirmed when the server accepts the pairing.",
            limits: "Needs your HCG Server. No remote execution: the server receives only reports you choose to share."),
        CapabilityDescriptor(
            id: .serverHealth, title: "HCG Server health",
            summary: "Read-only view of the paired server's availability, version, TLS and hosted services.",
            tier: .externalNode, implementation: .included,
            verificationMethod: "Open HCG Server health while paired; confirmed when the server answers its diagnostics request.",
            limits: "Shows what the server reports about itself. Sentinel does not administer the server.")
    ]

    /// Platform, hardware, permissions, screen and self-test for each capability.
    public static func profile(for id: CapabilityID) -> CapabilityProfile {
        let phone = "iPhone and iPad, iOS 15.0+ (also the iOS 14.7 legacy build)"
        let none = "None beyond the iPhone"
        switch id {
        case .connectionDiagnostics:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["None"], section: .network, selfTest: .readConnection)
        case .wifiConnectionInfo:
            return CapabilityProfile(platforms: phone, hardware: "Wi-Fi", permissions: ["None for addresses", "SSID: Access Wi-Fi Information entitlement + location (not in this build)"],
                                     section: .wifi, selfTest: .readConnection)
        case .captureFileInspection:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["Files you choose in the document picker"], section: .captureInspector, selfTest: .syntheticCapture)
        case .bluetoothDiscovery:
            return CapabilityProfile(platforms: phone, hardware: "Bluetooth LE radio (not in the Simulator)", permissions: ["Bluetooth (asked at the first scan)", "Sentinel › Scanning"], section: .bluetooth)
        case .requestComposer:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["Sentinel › Remote connections", "A test endpoint you add", "Local network (for local endpoints)"], section: .requests)
        case .networkAssessment:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["None (contacts example.com, captive.apple.com, www.apple.com when you start it)"], section: .networkCheck)
        case .icmpPing:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["Local network (for local addresses)"], section: .ping, selfTest: .loopbackPing)
        case .localDiscovery:
            return CapabilityProfile(platforms: phone, hardware: "Wi-Fi or Ethernet on a private network", permissions: ["Local network", "Your confirmation for a sweep"], section: .localNetwork)
        case .deviceSecurity:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["None"], section: .deviceSecurity, selfTest: .deviceSecurityChecks)
        case .reportImport:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["Files you choose"], section: .reports)
        case .secretScanning:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["Folders or archives you choose"], section: .secretScanner, selfTest: .syntheticSecretScan)
        case .exposureCheck:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["Sentinel › Remote connections", "Targets you enter and confirm"], section: .exposureCheck)
        case .authDefenseLab:
            return CapabilityProfile(platforms: phone, hardware: none, permissions: ["None (bundled loopback lab)"], section: .authLab)
        case .radioNodeLink:
            return CapabilityProfile(platforms: phone, hardware: "External radio analysis node (for example from HCG Signal Contractor) with its pairing key", permissions: ["Sentinel › Remote connections", "Local network"], section: .radio)
        case .radioSpectrum:
            return CapabilityProfile(platforms: phone, hardware: "Receive-capable radio hardware on the node", permissions: ["Sentinel › Remote connections"], section: .radio)
        case .nearbyWifiDiscovery:
            return CapabilityProfile(platforms: phone, hardware: "A node with a Wi-Fi radio that offers wifi_scan", permissions: ["Sentinel › Remote connections", "Sentinel › Scanning"], section: .radio)
        case .macDebugProxy:
            return CapabilityProfile(platforms: "Needs a Mac companion that does not exist yet", hardware: "A Mac", permissions: [], section: .externalNodes)
        case .serverAssessments:
            return CapabilityProfile(platforms: phone, hardware: "An HCG Server with a Security Lab API (not yet built)", permissions: ["Pairing", "Per-module scope"], section: .devices)
        case .deviceLinkPairing:
            return CapabilityProfile(platforms: phone, hardware: "Your HCG Server", permissions: ["Sentinel › Remote connections", "Local network (for a server on your network)"], section: .devices)
        case .serverHealth:
            return CapabilityProfile(platforms: phone, hardware: "Your paired HCG Server", permissions: ["Pairing"], section: .serverHealth)
        case .helperLink:
            return CapabilityProfile(platforms: "Jailbroken iPhone with a separately installed helper (Unleashed only)", hardware: none,
                                     permissions: ["Sentinel › Remote connections", "Helper pairing key"], section: .settings, partial: true)
        case .trafficFiltering:
            return CapabilityProfile(platforms: "Jailbroken iPhone with a helper that reports setFilterRules (Unleashed only)", hardware: none,
                                     permissions: ["Sentinel › Remote connections", "Helper pairing key"], section: .settings, partial: true)
        case .deviceWideCapture:
            return CapabilityProfile(platforms: "Jailbroken iPhone with a helper (Unleashed only); no helper exists", hardware: none, permissions: [], section: nil)
        case .satelliteAccess, .radioModification, .watchScanning:
            return CapabilityProfile(platforms: "None today", hardware: "See the research note", permissions: [], section: nil)
        }
    }

    public static func initialEnvironment(for id: CapabilityID) -> EnvironmentSupport {
        switch id {
        case .connectionDiagnostics, .captureFileInspection, .requestComposer, .networkAssessment,
             .secretScanning, .exposureCheck, .authDefenseLab, .wifiConnectionInfo, .icmpPing, .localDiscovery,
             .deviceSecurity, .reportImport:
            return .supported
        case .deviceLinkPairing, .serverHealth:
            return .unknown("No HCG Server is paired.")
        case .serverAssessments:
            return .unknown("No HCG Server with a Security Lab interface is paired.")
        case .satelliteAccess, .radioModification, .watchScanning:
            return .unsupported("Feasibility research only. Nothing is implemented, so nothing can run or be verified.")
        case .nearbyWifiDiscovery:
            return .unknown("Needs an authenticated node that offers Wi-Fi scanning. iOS itself provides no scanning API to ordinary apps.")
        case .bluetoothDiscovery:
            return .unknown("Bluetooth permission and radio state are checked when you start a scan.")
        case .radioNodeLink, .radioSpectrum:
            return .unknown("No node has completed a handshake. Radio Lab stays disconnected until one does.")
        case .macDebugProxy:
            return .unknown("No Mac companion is available.")
        case .trafficFiltering:
            return .unknown("No helper has reported that it can apply filter rules.")
        case .helperLink, .deviceWideCapture:
            return .unknown("No helper has authenticated. Whether this device can run one is not known.")
        }
    }
}
