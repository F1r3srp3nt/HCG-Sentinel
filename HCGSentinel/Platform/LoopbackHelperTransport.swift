import Foundation
import Network
import SentinelCore

/// Loopback-only TCP transport for the optional privileged helper.
///
/// It connects exclusively to 127.0.0.1, so it can only ever reach a process
/// on this same device. When nothing is listening (the normal case, because
/// Sentinel ships no helper) the attempt fails and is reported as such.
final class LoopbackHelperTransport: HelperTransport {
    var onEvent: ((HelperTransportEvent) -> Void)?
    var port: UInt16
    private var connection: NWConnection?

    init(port: UInt16) {
        self.port = port
    }

    func connect() {
        close()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onEvent?(.failed("The helper port is not valid."))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.onEvent?(.opened)
                self.receive(on: connection)
            case .waiting(let error), .failed(let error):
                self.close()
                self.onEvent?(.failed("No helper answered on 127.0.0.1:\(self.port) (\(error.localizedDescription))."))
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil
        old?.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection, self.connection === connection else { return }
            if let data = data, !data.isEmpty { self.onEvent?(.data(data)) }
            guard self.connection === connection else { return }
            if isComplete || error != nil {
                self.close()
                self.onEvent?(.closed)
            } else {
                self.receive(on: connection)
            }
        }
    }
}
