import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A lightweight HTTP server that serves per-app PAC (Proxy Auto-Config) files.
///
/// Endpoints (all dynamically keyed, nothing hardcoded):
///   /proxy.pac          — global PAC (system proxy default, used by Safari if not overridden)
///   /{bundleID}.pac     — per-app PAC for any app the user adds (e.g. /com.google.Chrome.pac)
///   /cli-{name}.pac     — per-CLI tool PAC (injected via http_proxy env var in wrappers)
final class PACServer {
    static let shared = PACServer()
    static let port: UInt16 = 9876

    private let queue = DispatchQueue(label: "com.focusshield.pacserver")
    private var listeningSockets: [Int32] = []
    private var acceptSources: [DispatchSourceRead] = []

    /// PAC content keyed by URL path (e.g. "/proxy.pac", "/com.google.Chrome.pac")
    private var pacTable: [String: String] = [:]

    // MARK: - URL helpers

    /// System proxy URL — always the global PAC (or Safari-override if user adds Safari)
    static var proxyURL: String { "http://localhost:\(port)/proxy.pac" }

    /// Returns the PAC URL for any app given its bundle ID.
    static func pacURL(bundleID: String) -> String {
        "http://localhost:\(port)/\(bundleID).pac"
    }

    /// Returns the PAC URL for a CLI tool given its executable name.
    static func cliPACURL(tool: String) -> String {
        "http://localhost:\(port)/cli-\(tool).pac"
    }

    // MARK: - Content management

    func updateAll(globalPAC: String, appPACs: [String: String], cliPACs: [String: String] = [:]) {
        var table: [String: String] = ["/proxy.pac": globalPAC]
        for (bundleID, content) in appPACs {
            table["/\(bundleID).pac"] = content
        }
        for (tool, content) in cliPACs {
            table["/cli-\(tool).pac"] = content
        }
        pacTable = table
        ensureRunning()
    }

    func start(with pacContent: String) {
        updateAll(globalPAC: pacContent, appPACs: [:])
    }

    func updateContent(_ content: String) {
        pacTable["/proxy.pac"] = content
        ensureRunning()
    }

    func stop() {
        acceptSources.forEach { $0.cancel() }
        acceptSources.removeAll()
        listeningSockets.removeAll()
    }

    // MARK: - Private

    private func ensureRunning() {
        guard acceptSources.isEmpty else { return }

        let sockets = [makeIPv4Socket(), makeIPv6Socket()].compactMap { $0 }
        guard !sockets.isEmpty else {
            print("[PACServer] Failed to bind any loopback socket on port \(Self.port)")
            return
        }

        for socket in sockets {
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptConnections(on: socket)
            }
            source.setCancelHandler {
                close(socket)
            }
            source.resume()
            acceptSources.append(source)
            listeningSockets.append(socket)
        }

        print("[PACServer] Listening on 127.0.0.1 and/or ::1 port \(Self.port)")
    }

    private func makeIPv4Socket() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        if configureSocket(fd) == false {
            close(fd)
            return nil
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0, listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            return nil
        }

        return fd
    }

    private func makeIPv6Socket() -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        if configureSocket(fd) == false {
            close(fd)
            return nil
        }

        var onlyV6: Int32 = 1
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &onlyV6, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(Self.port).bigEndian
        addr.sin6_addr = in6addr_loopback

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        guard bindResult == 0, listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            return nil
        }

        return fd
    }

    private func configureSocket(_ fd: Int32) -> Bool {
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        return true
    }

    private func acceptConnections(on socket: Int32) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(socket, $0, &length)
                }
            }

            if client < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                }
                return
            }

            queue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }

        let requestStr = String(decoding: buffer.prefix(count), as: UTF8.self)
        let requestPath = requestStr
            .components(separatedBy: "\r\n").first?
            .components(separatedBy: " ")
            .dropFirst().first ?? "/proxy.pac"

        let body = pacTable[requestPath]
            ?? pacTable["/proxy.pac"]
            ?? "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"

        let response = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-ns-proxy-autoconfig",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "Cache-Control: no-cache",
            "",
            body,
        ].joined(separator: "\r\n")

        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer in
                write(client, rawBuffer.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            guard written > 0 else { break }
            sent += written
        }
    }
}
