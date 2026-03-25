import Foundation
import Network

/// A lightweight HTTP server that serves the PAC (Proxy Auto-Config) file
/// on localhost. Safari ignores `file://` PAC URLs but respects `http://`.
///
/// The server runs on port 9876 and responds to any request with the PAC file content.
final class PACServer {
    static let shared = PACServer()
    static let port: UInt16 = 9876

    private var listener: NWListener?
    private var pacContent: String = ""
    private let queue = DispatchQueue(label: "com.focusshield.pacserver")

    /// Returns the URL to use for system proxy auto-config.
    static var proxyURL: String {
        "http://127.0.0.1:\(port)/proxy.pac"
    }

    /// Update the PAC content and (re)start the server.
    func start(with pacContent: String) {
        self.pacContent = pacContent

        // If already running, just update content — no restart needed
        if listener != nil { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            print("[PACServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[PACServer] Listening on port \(Self.port)")
            case .failed(let error):
                print("[PACServer] Failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    /// Stop the PAC server.
    func stop() {
        listener?.cancel()
        listener = nil
        print("[PACServer] Stopped")
    }

    /// Update PAC content without restarting.
    func updateContent(_ content: String) {
        self.pacContent = content
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        // Read the HTTP request (we don't really need to parse it)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self else { return }

            let responseBody = self.pacContent
            let httpResponse = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/x-ns-proxy-autoconfig",
                "Content-Length: \(responseBody.utf8.count)",
                "Connection: close",
                "Cache-Control: no-cache",
                "",
                responseBody
            ].joined(separator: "\r\n")

            let responseData = httpResponse.data(using: .utf8)!

            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
