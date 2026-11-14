import Foundation

/// Where a capability's real work has to happen.
public enum CapabilityTier: String, CaseIterable, Codable {
    /// Supported, public iOS APIs inside the app sandbox.
    case onDevice
    /// An external Mac or radio node that Sentinel only talks to.
    case externalNode
    /// A separately installed, compatible privileged helper.
    case privilegedHelper

    public var title: String {
        switch self {
        case .onDevice: return "On this device"
        case .externalNode: return "External Mac or radio node"
        case .privilegedHelper: return "Privileged helper"
        }
    }
}

public enum CapabilityID: String, CaseIterable, Codable {
    case connectionDiagnostics
    case captureFileInspection
    case bluetoothDiscovery
    case requestComposer
    case networkAssessment
    case nearbyWifiDiscovery
    case radioNodeLink
    case radioSpectrum
    case macDebugProxy
    case helperLink
    case deviceWideCapture
    case trafficFiltering
    case secretScanning
    case exposureCheck
    case authDefenseLab
    case serverAssessments
}

/// Whether Sentinel ships working code for the capability.
public enum ImplementationStatus: Equatable {
    case included
    /// Only the interface, validation and tests exist; there is no backend.
    case interfaceOnly(String)
    case notIncluded(String)
}

/// Whether the current device/environment can run the capability.
public enum EnvironmentSupport: Equatable {
    case supported
    case unsupported(String)
    /// Not yet determined; the string says what would determine it.
    case unknown(String)
}

/// Set only by the outcome of a real operation, never by inference.
public enum VerificationStatus: Equatable {
    case unverified
    case verified(at: Date, evidence: String)
    case failed(at: Date, reason: String)
}

public enum CapabilityReadiness: Equatable {
    case notIncluded
    case interfaceOnly
    case unsupported
    case disabled
    case environmentUnknown
    case failed
    case ready
    case verified

    public var label: String {
        switch self {
        case .notIncluded: return "Not included"
        case .interfaceOnly: return "Interface only"
        case .unsupported: return "Unavailable"
        case .disabled: return "Off"
        case .environmentUnknown: return "Unverified"
        case .failed: return "Failed"
        case .ready: return "Unverified"
        case .verified: return "Verified"
        }
    }
}

public struct CapabilityDescriptor: Equatable {
    public let id: CapabilityID
    public let title: String
    public let summary: String
    public let tier: CapabilityTier
    public let implementation: ImplementationStatus
    /// What a successful verification consists of.
    public let verificationMethod: String
    /// What Sentinel explicitly does not do or claim for this capability.
    public let limits: String
}

public struct CapabilityState: Equatable, Identifiable {
    public let descriptor: CapabilityDescriptor
    public var environment: EnvironmentSupport
    public var userEnabled: Bool
    public var verification: VerificationStatus

    public var id: CapabilityID { descriptor.id }

    public var readiness: CapabilityReadiness {
        switch descriptor.implementation {
        case .notIncluded: return .notIncluded
        case .interfaceOnly: return .interfaceOnly
        case .included: break
        }
        if case .unsupported = environment { return .unsupported }
        guard userEnabled else { return .disabled }
        switch verification {
        case .verified: return .verified
        case .failed: return .failed
        case .unverified: break
        }
        if case .unknown = environment { return .environmentUnknown }
        return .ready
    }

    /// Why the capability is in its current state.
    public var explanation: String {
        switch readiness {
        case .notIncluded:
            if case .notIncluded(let note) = descriptor.implementation { return note }
            return "Not part of this build."
        case .interfaceOnly:
            if case .interfaceOnly(let note) = descriptor.implementation { return note }
            return "Only the interface is defined."
        case .unsupported:
            if case .unsupported(let reason) = environment { return reason }
            return "Not supported in this environment."
        case .disabled:
            return "Turned off. Nothing runs until you enable it."
        case .environmentUnknown:
            if case .unknown(let reason) = environment { return reason }
            return "Support has not been determined yet."
        case .failed:
            if case .failed(_, let reason) = verification { return "Last attempt failed: \(reason)" }
            return "Last attempt failed."
        case .ready:
            return "Implemented and enabled, but no operation has confirmed it yet. \(descriptor.verificationMethod)"
        case .verified:
            if case .verified(_, let evidence) = verification { return "Confirmed by a real operation: \(evidence)" }
            return "Confirmed by a real operation."
        }
    }

    /// What the user can do next, if anything.
    public var action: String? {
        switch readiness {
        case .notIncluded: return nil
        case .interfaceOnly: return "Needs a backend that does not exist yet. See the project documentation for what is required."
        case .unsupported: return "Resolve the condition above, then try again."
        case .disabled: return "Enable it in Settings or in the tool itself."
        case .environmentUnknown, .ready, .failed: return descriptor.verificationMethod
        case .verified: return nil
        }
    }
}
