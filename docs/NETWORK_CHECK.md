# Check My Network

A user-started, bounded assessment of the network this device is using. It looks for specific, observable problems
and reports each finding with its evidence, the time it was observed, what the test cannot tell you, and what to do.

It never says a network is "safe". When nothing is found, the result reads "No security concerns found by these
checks", followed by a statement that this does not mean the network is safe.

Code: `SentinelCore/Sources/SentinelCore/Assessment/` (engine and analysis, tested on Linux and macOS) and
`HCGSentinel/Platform/PlatformNetworkProbe.swift` (the iOS data sources).

## Steps

| Step | Source | Sends anything? | Time limit |
| --- | --- | --- | --- |
| Connection | `NWPathMonitor`: status, interface types, IPv4/IPv6/DNS support, metered, Low Data Mode, gateway addresses | No | 5 s |
| Wi-Fi details | `NEHotspotNetwork.fetchCurrent`: SSID, BSSID, security type (iOS 15+) | No | 5 s |
| Proxy and VPN | `CFNetworkCopySystemProxySettings`: HTTP/HTTPS proxy, PAC URL, auto-discovery, tunnel interfaces | No | 3 s |
| DNS resolution | `getaddrinfo("example.com")` | DNS query | 5 s |
| DNS integrity | `getaddrinfo("sentinel-check-<random>.example.com")` — a name that does not exist | DNS query | 5 s |
| Captive portal / HTTP interception | `GET http://captive.apple.com/hotspot-detect.html`, redirects not followed | HTTP request | 10 s |
| HTTPS | `GET https://example.com/` and `GET https://www.apple.com/library/test/success.html`, system trust evaluation, presented chain recorded | HTTPS requests | 10 s each |

Endpoints: `example.com` is the IANA documentation domain (RFC 2606). The captive-network page is the one Apple's
devices use to detect sign-in portals; it is fetched over plain HTTP on purpose, and `captive.apple.com` is the only
non-local host the app's App Transport Security settings allow over HTTP.

Every step has a time limit enforced by the engine itself, so a resolver or connection that never answers cannot
stall the check. Cancel stops the request in flight immediately and keeps the findings so far; late answers are
ignored. If the device is offline, network steps are reported as "not checked" and nothing is sent.

## Findings

| Kind | Meaning | Examples |
| --- | --- | --- |
| Security concern | Something observed that can expose traffic or credentials | Open or WEP Wi-Fi; DNS answers for a non-existent name; an untrusted HTTPS certificate |
| Notice | Worth knowing; may be harmless | Proxy configured; VPN active; captive portal redirect; TLS handshake failure; not on Wi-Fi |
| Connectivity | A test could not complete. **Not evidence of an attack** | Timeouts, unreachable hosts, DNS failures |
| Unavailable | iOS does not provide the information to this app | Wi-Fi name and security without the Access Wi-Fi Information entitlement |
| Not checked | The step did not run | Offline, cancelled |
| Observed | What was seen, with nothing wrong found | HTTPS trusted, with the certificate chain |

Unavailable information is shown as unavailable with the reason; it is never filled in with a guess.

## Known limits

* **Wi-Fi name and security type**: iOS returns them only to apps with Apple's *Access Wi-Fi Information*
  entitlement plus location permission. Sentinel has neither (no entitlements were added), so on a normal install
  these are reported as unavailable. Security type is also iOS 15+ only.
* **Nearby networks** are not visible to ordinary iOS apps at all. They are available only from an authenticated
  external node that offers `wifi_scan` (see `NODE_PROTOCOL.md`).
* Only this device's own path is tested. Other devices on the network, the router's configuration and attacks that
  leave no trace in these tests are invisible.
* With iCloud Private Relay, a VPN or encrypted DNS active, the DNS and HTTPS tests measure that path.
* Interception by a certificate authority this device already trusts (for example one installed with a
  configuration profile) cannot be detected by trust evaluation.
* `example.com` is assumed to have no wildcard DNS records, which is true today.
