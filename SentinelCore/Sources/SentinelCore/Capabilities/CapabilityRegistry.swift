import Foundation

/// Single source of truth for what Sentinel can do right now.
///
/// Verification is recorded only through `recordVerified`, which the tools call
/// from the completion of a real operation. The registry refuses to mark a
/// capability verified when it is not implemented, not enabled, or unsupported.
/// Confine to the main queue.
public final class CapabilityRegistry {
    public private(set) var states: [CapabilityState]
    public var onChange: (() -> Void)?
    private let now: () -> Date

    public init(descriptors: [CapabilityDescriptor] = CapabilityCatalog.all, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.states = descriptors.map {
            CapabilityState(descriptor: $0, environment: CapabilityCatalog.initialEnvironment(for: $0.id),
                            userEnabled: false, verification: .unverified)
        }
    }

    public func state(_ id: CapabilityID) -> CapabilityState? {
        states.first { $0.id == id }
    }

    public func states(in tier: CapabilityTier) -> [CapabilityState] {
        states.filter { $0.descriptor.tier == tier }
    }

    public var verifiedCount: Int { states.filter { $0.readiness == .verified }.count }

    public func setEnvironment(_ id: CapabilityID, _ environment: EnvironmentSupport) {
        mutate(id) {
            guard $0.environment != environment else { return }
            $0.environment = environment
            if case .unsupported = environment { $0.verification = .unverified }
        }
    }

    public func setUserEnabled(_ id: CapabilityID, _ enabled: Bool) {
        mutate(id) {
            guard $0.userEnabled != enabled else { return }
            $0.userEnabled = enabled
            if !enabled { $0.verification = .unverified }
        }
    }

    /// Returns false (and changes nothing) when the capability cannot legitimately be verified.
    @discardableResult
    public func recordVerified(_ id: CapabilityID, evidence: String) -> Bool {
        guard let current = state(id), current.descriptor.implementation == .included, current.userEnabled else { return false }
        if case .unsupported = current.environment { return false }
        mutate(id) { $0.verification = .verified(at: now(), evidence: evidence) }
        return true
    }

    public func recordFailure(_ id: CapabilityID, reason: String) {
        guard let current = state(id), current.descriptor.implementation == .included else { return }
        mutate(id) { $0.verification = .failed(at: now(), reason: reason) }
    }

    public func resetVerification(_ id: CapabilityID) {
        mutate(id) { $0.verification = .unverified }
    }

    private func mutate(_ id: CapabilityID, _ change: (inout CapabilityState) -> Void) {
        guard let index = states.firstIndex(where: { $0.id == id }) else { return }
        let before = states[index]
        change(&states[index])
        if states[index] != before { onChange?() }
    }
}

/// Signals about privileged access. Hints never amount to proof: only an
/// authenticated helper session that answers a capability report does.
public struct PrivilegeAssessment: Equatable {
    public enum Hint: String, CaseIterable {
        case packageManagerPresent
        case sideloaded
        case filesystemMarker
        case userAsserted
    }

    public enum Conclusion: Equatable {
        case noEvidence
        case hintsOnly
        case helperVerified
    }

    public let hints: Set<Hint>
    public let helperSessionAuthenticated: Bool
    public let helperReportedCapabilities: Bool

    public init(hints: Set<Hint>, helperSessionAuthenticated: Bool, helperReportedCapabilities: Bool) {
        self.hints = hints
        self.helperSessionAuthenticated = helperSessionAuthenticated
        self.helperReportedCapabilities = helperReportedCapabilities
    }

    public var conclusion: Conclusion {
        if helperSessionAuthenticated && helperReportedCapabilities { return .helperVerified }
        return hints.isEmpty ? .noEvidence : .hintsOnly
    }

    public var isPrivilegedAccessVerified: Bool { conclusion == .helperVerified }
}
