import Foundation

/// Turns raw observations into findings. Pure and deterministic: the same observations always give the same
/// findings. Connectivity failures are reported as connectivity problems, never as threats, and nothing here
/// ever concludes that a network is safe.
public enum AssessmentAnalyzer {
    public static func findings(from o: AssessmentObservations, defaultTime: Date) -> [AssessmentFinding] {
        var result: [AssessmentFinding] = []
        func time(_ step: AssessmentStep) -> Date { o.completedAt[step] ?? defaultTime }
        func add(_ step: AssessmentStep, _ suffix: String, _ kind: AssessmentFinding.Kind, _ title: String,
                 evidence: [String], limitations: String, remediation: String? = nil) {
            result.append(AssessmentFinding(id: step.rawValue + "." + suffix, step: step, kind: kind, title: title,
                                            evidence: evidence, observedAt: time(step), limitations: limitations,
                                            remediation: remediation))
        }
        func notChecked(_ step: AssessmentStep) -> Bool {
            if let reason = o.skipped[step] {
                add(step, "skipped", .notChecked, "\(step.title): not checked", evidence: [reason],
                    limitations: "No conclusion can be drawn about this part of the network.",
                    remediation: "Run the check again when connected.")
                return true
            }
            if o.timedOut.contains(step) {
                add(step, "timeout", .connectivityProblem, "\(step.title): no answer within \(Int(step.timeout)) seconds",
                    evidence: ["The step did not complete within its time limit."],
                    limitations: "A timeout is a connectivity symptom (slow, congested or filtered network). It is not evidence of an attack.",
                    remediation: "Move closer to the access point or try again later.")
                return true
            }
            return false
        }

        // Connection
        if !notChecked(.connection) {
            if let c = o.connection {
                var evidence = ["Status: \(c.statusDescription)",
                                "Interfaces: \(c.interfaceTypes.isEmpty ? "none reported" : c.interfaceTypes.joined(separator: ", "))",
                                "IPv4: \(yesNo(c.supportsIPv4)) · IPv6: \(yesNo(c.supportsIPv6)) · DNS: \(yesNo(c.supportsDNS))",
                                "Metered: \(yesNo(c.isExpensive)) · Low Data Mode: \(yesNo(c.isConstrained))"]
                evidence.append(c.gateways.isEmpty ? "Gateway: not reported by the system" : "Gateway: \(c.gateways.joined(separator: ", "))")
                let limits = "Describes this device's own network path as reported by iOS. It does not list other devices on the network."
                if !c.isOnline {
                    add(.connection, "offline", .connectivityProblem, "No network connection", evidence: evidence,
                        limitations: limits, remediation: "Join a Wi-Fi network and run the check again. Network tests were skipped.")
                } else if !c.usesWiFi {
                    add(.connection, "notwifi", .notice, "Not connected over Wi-Fi", evidence: evidence,
                        limitations: limits + " The network tests below describe the current path (\(c.interfaceTypes.joined(separator: ", "))), not a Wi-Fi network.",
                        remediation: "To assess a Wi-Fi network, join it and run the check again.")
                } else {
                    add(.connection, "online", .observation, "Connected over Wi-Fi", evidence: evidence, limitations: limits)
                }
            } else {
                add(.connection, "unavailable", .unavailable, "Connection state unavailable",
                    evidence: ["The system did not report a network path."],
                    limitations: "Without the path, network tests were not run.")
            }
        }

        // Wi-Fi details
        if !notChecked(.wifiDetails), let w = o.wifi {
            let limits = "iOS only reveals the joined network's name and security type to apps with Apple's Access Wi-Fi Information entitlement and location permission. Sentinel cannot see other networks or the router's configuration."
            if let reason = w.unavailableReason, w.ssid == nil {
                add(.wifiDetails, "identity", .unavailable, "Network name and security type unavailable",
                    evidence: [reason], limitations: limits)
            } else {
                var evidence = ["Network name (SSID): \(w.ssid ?? "unavailable")", "BSSID: \(w.bssid ?? "unavailable")"]
                evidence.append("Security: \(securityText(w.security))")
                switch w.security {
                case .open?:
                    add(.wifiDetails, "open", .securityConcern, "Open Wi-Fi network (no encryption)", evidence: evidence,
                        limitations: limits,
                        remediation: "Anyone nearby can read unencrypted traffic between this device and the access point. Use only HTTPS sites and apps, consider a trusted VPN, and avoid entering passwords; on your own router enable WPA2 or WPA3.")
                case .wep?:
                    add(.wifiDetails, "wep", .securityConcern, "WEP encryption (broken)", evidence: evidence, limitations: limits,
                        remediation: "WEP can be cracked in minutes. On your own router switch to WPA2-Personal (AES) or WPA3; otherwise treat this network as open.")
                case .personal?, .enterprise?:
                    add(.wifiDetails, "secured", .observation, "Encrypted Wi-Fi network", evidence: evidence,
                        limitations: limits + " Encryption protects the radio link only; it says nothing about who else is on the network or about the router.")
                case .unknown?, nil:
                    add(.wifiDetails, "security", .unavailable, "Wi-Fi security type unavailable", evidence: evidence,
                        limitations: limits + " The security type is only reported on iOS 15 and later.")
                }
            }
        }

        // Proxy and tunnels
        if !notChecked(.proxy), let p = o.proxy {
            let limits = "Reads the proxy settings iOS applies to this app's connections. A VPN or a configuration profile can change these per app."
            if let reason = p.unavailableReason {
                add(.proxy, "unavailable", .unavailable, "Proxy settings unavailable", evidence: [reason], limitations: limits)
            } else {
                if p.hasProxy {
                    var evidence: [String] = []
                    if let value = p.httpProxy { evidence.append("HTTP proxy: \(value)") }
                    if let value = p.httpsProxy { evidence.append("HTTPS proxy: \(value)") }
                    if let value = p.pacURL { evidence.append("Automatic configuration (PAC) URL: \(value)") }
                    if p.autoDiscovery { evidence.append("Proxy auto-discovery (WPAD) is on") }
                    add(.proxy, "proxy", .notice, "A proxy is configured", evidence: evidence, limitations: limits,
                        remediation: "Web traffic may pass through this proxy. If you did not set it up, open Settings › Wi-Fi › (i) next to this network › Configure Proxy and set it to Off, and check Settings › General › VPN & Device Management for unknown profiles.")
                } else {
                    add(.proxy, "noproxy", .observation, "No proxy configured", evidence: ["HTTP, HTTPS and automatic proxy settings are empty."], limitations: limits)
                }
                if !p.tunnelInterfaces.isEmpty {
                    add(.proxy, "tunnel", .notice, "A VPN or tunnel is active", evidence: ["Tunnel interfaces: \(p.tunnelInterfaces.joined(separator: ", "))"],
                        limitations: "While a tunnel is active, the DNS and HTTPS tests below measure the tunnel's path, not the Wi-Fi network directly.",
                        remediation: "To test the Wi-Fi network itself, disconnect the VPN (if it is yours) and run the check again.")
                }
            }
        }

        let dnsLimits = "Uses the system resolver. With iCloud Private Relay, a VPN or encrypted DNS active, this tests that path rather than the Wi-Fi router's resolver."

        // DNS resolution of a known name
        if !notChecked(.dnsResolution), let outcome = o.dnsControl {
            let host = AssessmentEndpoints.dnsControlHost
            switch outcome {
            case .addresses(let list):
                add(.dnsResolution, "ok", .observation, "DNS resolves names", evidence: ["\(host) → \(list.prefix(6).joined(separator: ", "))"], limitations: dnsLimits)
            case .notFound:
                add(.dnsResolution, "nxdomain", .notice, "The resolver says \(host) does not exist", evidence: ["\(host) → name not found"],
                    limitations: dnsLimits + " \(host) is a permanently registered documentation domain, so this indicates DNS filtering or a misconfigured resolver.",
                    remediation: "If this is your network, check the router's DNS servers and any filtering service.")
            case .failed(let reason):
                add(.dnsResolution, "failed", .connectivityProblem, "DNS lookup failed", evidence: ["\(host): \(reason)"],
                    limitations: dnsLimits + " A failed lookup is a connectivity problem, not evidence of an attack.",
                    remediation: "Check that the network has internet access; if a sign-in page is expected, complete it.")
            case .timedOut:
                add(.dnsResolution, "timeout", .connectivityProblem, "DNS lookup timed out", evidence: ["\(host): no answer within \(Int(AssessmentStep.dnsResolution.timeout)) seconds"],
                    limitations: dnsLimits, remediation: "Try again; if it persists, the network's DNS service may be down.")
            }
        }

        // DNS answers for a name that does not exist
        if !notChecked(.dnsIntegrity), let outcome = o.dnsNonexistent {
            let host = o.nonexistentHost ?? "a random name under example.com"
            let controlWorked: Bool = { if case .addresses? = o.dnsControl { return true }; return false }()
            switch outcome {
            case .addresses(let list):
                add(.dnsIntegrity, "rewrite", .securityConcern, "DNS answers are being rewritten",
                    evidence: ["\(host) should not exist, but the resolver returned \(list.prefix(6).joined(separator: ", "))"],
                    limitations: dnsLimits + " Some captive portals and ISPs do this to show search or sign-in pages; it still means DNS answers on this path are altered and could redirect other names too.",
                    remediation: "Complete any sign-in page and run the check again. If it persists on your own network, check the router's DNS settings and firmware.")
            case .notFound:
                if controlWorked {
                    add(.dnsIntegrity, "ok", .observation, "Non-existent names are answered correctly",
                        evidence: ["\(host) → name not found (expected)"], limitations: dnsLimits + " This detects one specific kind of DNS tampering only.")
                } else {
                    add(.dnsIntegrity, "inconclusive", .connectivityProblem, "DNS integrity test inconclusive",
                        evidence: ["\(host) → name not found", "The control lookup of \(AssessmentEndpoints.dnsControlHost) did not succeed, so 'not found' may just mean DNS is not working."],
                        limitations: dnsLimits)
                }
            case .failed(let reason):
                add(.dnsIntegrity, "failed", .connectivityProblem, "DNS integrity test could not complete", evidence: ["\(host): \(reason)"], limitations: dnsLimits)
            case .timedOut:
                add(.dnsIntegrity, "timeout", .connectivityProblem, "DNS integrity test timed out", evidence: ["\(host): no answer"], limitations: dnsLimits)
            }
        }

        // Captive portal / HTTP interception
        if !notChecked(.captivePortal), let outcome = o.captive {
            let url = AssessmentEndpoints.captivePortalURL.absoluteString
            let limits = "Fetches Apple's captive-network test page over plain HTTP and compares the answer with the documented page. It detects rewriting of unencrypted web traffic on this path only."
            switch outcome {
            case .response(let status, let location, let body, _):
                if status == 200 && body.contains(AssessmentEndpoints.captivePortalExpected) {
                    add(.captivePortal, "ok", .observation, "Unencrypted test page arrived unmodified",
                        evidence: ["GET \(url) → HTTP 200 with the expected content"], limitations: limits)
                } else {
                    var evidence = ["GET \(url) → HTTP \(status)"]
                    if let location = location { evidence.append("Redirected to: \(location)") }
                    if !body.isEmpty { evidence.append("Content begins: \(String(body.prefix(160)))") }
                    add(.captivePortal, "altered", .notice, "Unencrypted web traffic is intercepted or redirected", evidence: evidence,
                        limitations: limits + " This is normal for hotel, airport and guest networks that require sign-in, and is also how traffic manipulation looks.",
                        remediation: "If a sign-in page is expected, complete it and run the check again. Otherwise, avoid plain-HTTP sites on this network.")
                }
            case .trustFailure(let code, let message, _), .tlsFailure(let code, let message):
                add(.captivePortal, "tls", .notice, "Unexpected TLS error on a plain-HTTP request", evidence: ["\(url): \(message) (\(code))"], limitations: limits)
            case .connectivityFailure(let code, let message):
                add(.captivePortal, "failed", .connectivityProblem, "Test page unreachable", evidence: ["\(url): \(message) (\(code))"],
                    limitations: limits + " Unreachable is a connectivity symptom, not evidence of an attack.")
            case .timedOut:
                add(.captivePortal, "timeout", .connectivityProblem, "Test page did not answer", evidence: ["\(url): timed out"], limitations: limits)
            }
        }

        // HTTPS
        for (step, url, outcome) in [(AssessmentStep.httpsExample, AssessmentEndpoints.httpsExampleURL, o.httpsExample),
                                     (AssessmentStep.httpsApple, AssessmentEndpoints.httpsAppleURL, o.httpsApple)] {
            guard !notChecked(step), let outcome = outcome else { continue }
            let host = url.host ?? url.absoluteString
            let limits = "Checks that iOS trusts the certificate \(host) presents on this path. It cannot detect interception by a certificate authority that this device already trusts, for example one installed by a configuration profile."
            switch outcome {
            case .response(let status, _, _, let certificates):
                var evidence = ["GET \(url.absoluteString) → HTTP \(status) over a connection iOS trusted"]
                if !certificates.isEmpty { evidence.append("Certificate chain: \(certificates.joined(separator: " ← "))") }
                add(step, "trusted", .observation, "HTTPS to \(host) is trusted", evidence: evidence, limitations: limits)
            case .trustFailure(let code, let message, let certificates):
                var evidence = ["\(url.absoluteString): \(message) (\(code))"]
                if !certificates.isEmpty { evidence.append("Certificate presented: \(certificates.joined(separator: " ← "))") }
                add(step, "untrusted", .securityConcern, "Untrusted certificate for \(host)", evidence: evidence,
                    limitations: limits + " A sign-in (captive) portal can also cause this before you sign in.",
                    remediation: "Do not enter passwords or accept certificate warnings on this network. If a sign-in page is expected, complete it and run the check again; otherwise disconnect and use another network.")
            case .tlsFailure(let code, let message):
                add(step, "tls", .notice, "Secure connection to \(host) failed", evidence: ["\(url.absoluteString): \(message) (\(code))"],
                    limitations: limits + " The TLS handshake did not complete. Middleboxes that block or tamper with encrypted traffic cause this, as can some network problems.",
                    remediation: "Try again. If it persists while other sites work, the network may be interfering with encrypted connections.")
            case .connectivityFailure(let code, let message):
                add(step, "failed", .connectivityProblem, "\(host) unreachable", evidence: ["\(url.absoluteString): \(message) (\(code))"],
                    limitations: limits + " Unreachable is a connectivity symptom, not evidence of an attack.")
            case .timedOut:
                add(step, "timeout", .connectivityProblem, "\(host) did not answer", evidence: ["\(url.absoluteString): timed out"], limitations: limits)
            }
        }
        return result
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func securityText(_ security: WiFiSecurity?) -> String {
        switch security {
        case .open?: return "open (no encryption)"
        case .wep?: return "WEP"
        case .personal?: return "WPA/WPA2/WPA3 Personal"
        case .enterprise?: return "WPA/WPA2/WPA3 Enterprise"
        case .unknown?, nil: return "unavailable"
        }
    }
}
