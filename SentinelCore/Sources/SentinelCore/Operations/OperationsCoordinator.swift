import Foundation

/// One Sentinel-owned activity that can be stopped.
public struct OperationHandle {
    public let id: String
    public let title: String
    public let isActive: () -> Bool
    public let stop: () -> Void

    public init(id: String, title: String, isActive: @escaping () -> Bool, stop: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.isActive = isActive
        self.stop = stop
    }
}

public struct StopAllReport: Equatable {
    public let stopped: [String]
    public let stillActive: [String]

    public var summary: String {
        if stopped.isEmpty && stillActive.isEmpty { return "Nothing was running." }
        var text = stopped.isEmpty ? "" : "Stopped: \(stopped.joined(separator: ", "))."
        if !stillActive.isEmpty { text += " Could not confirm stop: \(stillActive.joined(separator: ", "))." }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Registry behind "Stop All Operations". It only knows about operations that
/// Sentinel started; it cannot and does not touch system services, saved
/// captures or settings. Confine to the main queue.
public final class OperationsCoordinator {
    private var handles: [OperationHandle] = []

    public init() {}

    public func register(_ handle: OperationHandle) {
        handles.removeAll { $0.id == handle.id }
        handles.append(handle)
    }

    public var activeOperations: [OperationHandle] { handles.filter { $0.isActive() } }

    @discardableResult
    public func stopAll() -> StopAllReport {
        var stopped: [String] = []
        var stillActive: [String] = []
        for handle in handles where handle.isActive() {
            handle.stop()
            if handle.isActive() { stillActive.append(handle.title) } else { stopped.append(handle.title) }
        }
        return StopAllReport(stopped: stopped, stillActive: stillActive)
    }
}
