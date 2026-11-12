import Foundation
import SentinelCore

/// WebSocket transport for the Sentinel Node Protocol. All events are delivered on the main queue.
final class WebSocketNodeTransport: NSObject, NodeTransport, URLSessionWebSocketDelegate {
    var onEvent: ((NodeTransportEvent) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    func connect(to url: URL) {
        close()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = NodeProtocol.maxMessageBytes
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func send(text: String) {
        guard let task = task else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async { self?.report(.failed(error.localizedDescription), from: task) }
        }
    }

    func close() {
        let old = task
        task = nil
        old?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.task === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.onEvent?(.text(text))
                        self.receive(on: task)
                    case .data:
                        self.report(.failed("The node sent a binary message; protocol version 1 uses text messages only."), from: task)
                    @unknown default:
                        self.report(.failed("The node sent an unsupported message type."), from: task)
                    }
                case .failure(let error):
                    self.report(.failed(error.localizedDescription), from: task)
                }
            }
        }
    }

    /// Reports a terminal event once, then drops the connection.
    private func report(_ event: NodeTransportEvent, from source: URLSessionTask) {
        guard task === source else { return }
        close()
        onEvent?(event)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiatedProtocol: String?) {
        guard webSocketTask === task else { return }
        onEvent?(.opened)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        report(.closed(text), from: webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        report(.failed(error.localizedDescription), from: task)
    }
}
