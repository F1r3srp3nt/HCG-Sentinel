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
            implementation: .interfaceOnly("The contract is defined in docs/SECURITY_LAB_SERVER.md, but HCG Server has no assessment API yet and cannot pair with an iPhone, so every assessment runs on this device."),
            verificationMethod: "Requires an HCG Server that implements the Security Lab contract and reports the module as supported.",
            limits: "Pairing a server never enables anything by itself; each module needs the server's own capability report and an explicit scope.")
    ]

    public static func initialEnvironment(for id: CapabilityID) -> EnvironmentSupport {
        switch id {
        case .connectionDiagnostics, .captureFileInspection, .requestComposer, .networkAssessment,
             .secretScanning, .exposureCheck, .authDefenseLab:
            return .supported
        case .serverAssessments:
            return .unknown("No HCG Server with a Security Lab interface is paired.")
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
