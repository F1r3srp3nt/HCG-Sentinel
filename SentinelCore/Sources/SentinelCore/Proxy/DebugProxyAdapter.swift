import Foundation

/// Future adapter for an authorised debugging proxy that runs on a Mac.
/// See docs/MAC_PROXY_ADAPTER.md.
///
/// This is intentionally a separate concept from:
///  * capture-file inspection (reads files; never in the traffic path), and
///  * helper filter rules (drop/allow decisions; never content inspection).
///
/// Sentinel ships no implementation. Nothing in the app installs certificates
/// or changes proxy settings.
public struct DebugProxyDescriptor: Equatable {
    public let name: String
    public let adapterVersion: Int
    /// Device identifiers the Mac side has been explicitly authorised to proxy.
    public let authorizedDeviceIDs: [String]
}

public struct ProxyFlowSummary: Equatable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let method: String
    public let host: String
    public let path: String
    public let statusCode: Int?
    /// False when the flow was TLS and the test device did not opt in to interception.
    public let contentVisible: Bool
}

public enum DebugProxyError: Error, Equatable {
    case notImplemented
    case notAuthorized
    case unreachable(String)
}

public protocol DebugProxyAdapter: AnyObject {
    static var adapterVersion: Int { get }
    func describe(completion: @escaping (Result<DebugProxyDescriptor, DebugProxyError>) -> Void)
    func listFlows(since: Date?, limit: Int, completion: @escaping (Result<[ProxyFlowSummary], DebugProxyError>) -> Void)
    func disconnect()
}

/// Placeholder used until a Mac companion exists. Every call reports `notImplemented`.
public final class UnavailableDebugProxyAdapter: DebugProxyAdapter {
    public static let adapterVersion = 1
    public init() {}

    public func describe(completion: @escaping (Result<DebugProxyDescriptor, DebugProxyError>) -> Void) {
        completion(.failure(.notImplemented))
    }

    public func listFlows(since: Date?, limit: Int, completion: @escaping (Result<[ProxyFlowSummary], DebugProxyError>) -> Void) {
        completion(.failure(.notImplemented))
    }

    public func disconnect() {}
}
