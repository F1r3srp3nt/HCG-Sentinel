# Future Mac debugging-proxy adapter

Status: **interface only** (`DebugProxyAdapter` in `SentinelCore/Sources/SentinelCore/Proxy/`). The only
implementation, `UnavailableDebugProxyAdapter`, answers every call with `notImplemented`. No Mac companion exists.

## Purpose

Today the Request Composer can only shape requests that Sentinel itself sends. To inspect or modify traffic from
*other* apps on a test device, that traffic has to pass through a proxy the tester controls. On iOS this is done
properly from a Mac:

* the test device is configured (by its owner, by hand) to use the Mac as an HTTP(S) proxy, and
* for TLS content, the owner manually installs and trusts the proxy's CA on that test device.

Sentinel would then act as a remote view and control surface for that Mac proxy.

## Boundaries

| Concern | Lives in | Never does |
| --- | --- | --- |
| Capture-file inspection | `Capture/` | Sits in the traffic path. |
| Helper filter rules | `Helper/` | Reads or rewrites content. |
| Debugging proxy (this) | `Proxy/` + future Mac app | Runs on the phone, or installs anything automatically. |

These share no types and no state.

## Requirements for the Mac companion

1. Only devices listed in an explicit allowlist on the Mac (`authorizedDeviceIDs`) are proxied. Everything else is
   refused, not passed through silently.
2. Sentinel never installs a certificate or profile and never changes proxy settings. The documentation for the
   companion must describe the manual steps and how to undo them.
3. TLS flows from apps that pin certificates, or on devices where the CA is not trusted, are reported with
   `contentVisible: false`. They are not broken or downgraded.
4. The link between Sentinel and the Mac is authenticated and encrypted. Reusing the helper handshake
   (`docs/HELPER_INTERFACE.md`) over TLS is the intended starting point.
5. Flow bodies stay on the Mac by default; `ProxyFlowSummary` carries metadata only.

## Adapter surface (version 1)

```swift
protocol DebugProxyAdapter: AnyObject {
    static var adapterVersion: Int { get }
    func describe(completion: (Result<DebugProxyDescriptor, DebugProxyError>) -> Void)
    func listFlows(since: Date?, limit: Int, completion: (Result<[ProxyFlowSummary], DebugProxyError>) -> Void)
    func disconnect()
}
```

Request rewriting rules are intentionally not specified yet; they should be designed against a working read-only
companion first.

## To make this real

* Choose or build the Mac proxy engine and define the wire protocol between it and the adapter.
* Implement a concrete adapter and switch the `macDebugProxy` capability from `interfaceOnly` to `included`.
* Verification evidence: an authenticated session in which the Mac lists the connected device as authorised.
