import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - FocusShield DNS Proxy
// A lightweight DNS proxy server that blocks domains by returning 127.0.0.1
// and forwards all other queries to an upstream DNS server.
//
// Usage: focusshield-dns <blocked-domains-file> <upstream-dns-ip>
//   - blocked-domains-file: one domain per line
//   - upstream-dns-ip: e.g. "8.8.8.8"
//
// Signals:
//   SIGHUP  → reload blocked domains from file
//   SIGTERM → graceful shutdown

// --- Parse arguments ---
guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: focusshield-dns <domains-file> <upstream-dns-ip> [blacklist|whitelist]\n", stderr)
    exit(1)
}

let domainsFilePath = CommandLine.arguments[1]
let upstreamDNS = CommandLine.arguments[2]
let filterMode = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "blacklist"

// --- System safelist (always allowed in whitelist mode) ---
let systemSafelist: Set<String> = [
    "apple.com", "icloud.com", "mzstatic.com", "cdn-apple.com",
    "apple-dns.net", "push.apple.com", "aaplimg.com", "ocsp.apple.com",
    "gs.apple.com", "swscan.apple.com", "configuration.apple.com",
    "xp.apple.com", "gsa.apple.com", "setup.icloud.com", "p-setup.icloud.com",
    "swdist.apple.com", "swcdn.apple.com", "updates.cdn-apple.com",
    "apps.apple.com", "itunes.apple.com",
    "time.apple.com", "time.euro.apple.com",
    "localhost", "local", "broadcasthost",
    "captive.apple.com",
]

// --- Load domains (blocked or whitelisted depending on mode) ---
func loadDomains(from path: String) -> Set<String> {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("[DNS] Warning: cannot read domains file: \(path)\n", stderr)
        return []
    }
    let domains = content.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    fputs("[DNS] Loaded \(domains.count) domains (mode: \(filterMode))\n", stderr)
    return Set(domains)
}

var domainList = loadDomains(from: domainsFilePath)

// --- Signal handlers ---
signal(SIGHUP) { _ in
    domainList = loadDomains(from: domainsFilePath)
}

signal(SIGTERM) { _ in
    fputs("[DNS] Shutting down\n", stderr)
    exit(0)
}

// --- Write PID file ---
let pidPath = "/tmp/focusshield-dns.pid"
try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)

// --- DNS Proxy Logic ---

func parseDomainFromQuery(_ data: Data) -> String? {
    guard data.count > 12 else { return nil }
    var offset = 12
    var labels: [String] = []
    while offset < data.count {
        let length = Int(data[offset])
        if length == 0 { break }
        offset += 1
        guard offset + length <= data.count else { return nil }
        if let label = String(data: data[offset..<offset+length], encoding: .ascii) {
            labels.append(label)
        }
        offset += length
    }
    return labels.joined(separator: ".").lowercased()
}

func isDomainBlocked(_ domain: String) -> Bool {
    if domainList.contains(domain) { return true }
    // Check parent domains for wildcard matching
    var parts = domain.split(separator: ".")
    while parts.count > 1 {
        parts.removeFirst()
        if domainList.contains(parts.joined(separator: ".")) { return true }
    }
    return false
}

/// In whitelist mode, check if domain is allowed (in list or system safelist).
func isDomainAllowed(_ domain: String) -> Bool {
    // Always allow system-critical domains
    if isInSafelist(domain) { return true }
    // Check exact match in allowed list
    if domainList.contains(domain) { return true }
    // Check parent domains for wildcard matching
    var parts = domain.split(separator: ".")
    while parts.count > 1 {
        parts.removeFirst()
        let parent = parts.joined(separator: ".")
        if domainList.contains(parent) { return true }
        if isInSafelist(parent) { return true }
    }
    return false
}

func isInSafelist(_ domain: String) -> Bool {
    if systemSafelist.contains(domain) { return true }
    var parts = domain.split(separator: ".")
    while parts.count > 1 {
        parts.removeFirst()
        if systemSafelist.contains(parts.joined(separator: ".")) { return true }
    }
    return false
}

func getQueryType(_ data: Data) -> UInt16 {
    guard data.count > 12 else { return 0 }
    // Skip past QNAME
    var offset = 12
    while offset < data.count {
        let length = Int(data[offset])
        if length == 0 { offset += 1; break }
        offset += 1 + length
    }
    guard offset + 2 <= data.count else { return 0 }
    return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

func buildBlockedResponse(for query: Data) -> Data {
    guard query.count > 12 else { return Data() }

    let qtype = getQueryType(query)
    var response = Data()

    // ID (copy from query)
    response.append(query[0])
    response.append(query[1])

    // Flags: QR=1, AA=1, RD=1, RA=1
    response.append(0x85)
    response.append(0x80)

    // QDCOUNT = 1
    response.append(contentsOf: [0x00, 0x01])
    // ANCOUNT = 1 (for A/AAAA, 0 for others)
    if qtype == 1 || qtype == 28 {
        response.append(contentsOf: [0x00, 0x01])
    } else {
        response.append(contentsOf: [0x00, 0x00])
    }
    // NSCOUNT = 0, ARCOUNT = 0
    response.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

    // Copy question section
    var offset = 12
    while offset < query.count {
        let length = Int(query[offset])
        response.append(query[offset])
        offset += 1
        if length == 0 { break }
        for _ in 0..<length {
            guard offset < query.count else { break }
            response.append(query[offset])
            offset += 1
        }
    }
    // QTYPE + QCLASS
    guard offset + 4 <= query.count else { return response }
    response.append(contentsOf: query[offset..<offset+4])

    // For non-A/AAAA queries, return NXDOMAIN
    guard qtype == 1 || qtype == 28 else {
        response[2] = 0x85
        response[3] = 0x83 // RCODE = NXDOMAIN
        return response
    }

    // Answer section
    // NAME: pointer to QNAME at offset 12
    response.append(contentsOf: [0xC0, 0x0C])
    // TYPE
    response.append(UInt8(qtype >> 8))
    response.append(UInt8(qtype & 0xFF))
    // CLASS: IN
    response.append(contentsOf: [0x00, 0x01])
    // TTL: 60 seconds
    response.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])

    if qtype == 1 { // A record → 127.0.0.1
        response.append(contentsOf: [0x00, 0x04]) // RDLENGTH
        response.append(contentsOf: [0x7F, 0x00, 0x00, 0x01])
    } else { // AAAA record → ::1
        response.append(contentsOf: [0x00, 0x10]) // RDLENGTH
        for _ in 0..<15 { response.append(0x00) }
        response.append(0x01)
    }

    return response
}

func forwardToUpstream(_ query: Data, upstreamIP: String) -> Data? {
    let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard sock >= 0 else { return nil }
    defer { close(sock) }

    // 3-second timeout
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(53).bigEndian
    inet_pton(AF_INET, upstreamIP, &addr.sin_addr)

    let sent = query.withUnsafeBytes { ptr in
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock, ptr.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 4096)
    var fromAddr = sockaddr_in()
    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

    let received = withUnsafeMutablePointer(to: &fromAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(sock, &buffer, buffer.count, 0, $0, &fromLen)
        }
    }
    guard received > 0 else { return nil }
    return Data(buffer[0..<received])
}

// --- Main server loop ---
fputs("[DNS] Starting DNS proxy on port 53 (upstream: \(upstreamDNS))\n", stderr)

let serverSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
guard serverSock >= 0 else {
    fputs("[DNS] FATAL: socket() failed\n", stderr)
    exit(1)
}

var opt: Int32 = 1
setsockopt(serverSock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))
setsockopt(serverSock, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

var bindAddr = sockaddr_in()
bindAddr.sin_family = sa_family_t(AF_INET)
bindAddr.sin_port = UInt16(53).bigEndian
bindAddr.sin_addr.s_addr = inet_addr("127.0.0.1")

let bindResult = withUnsafePointer(to: &bindAddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(serverSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0 else {
    fputs("[DNS] FATAL: bind() failed (errno: \(errno)). Are you running as root?\n", stderr)
    exit(1)
}

fputs("[DNS] Listening on 127.0.0.1:53 (PID: \(getpid()))\n", stderr)

var buffer = [UInt8](repeating: 0, count: 4096)

while true {
    var clientAddr = sockaddr_in()
    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)

    let bytesRead = withUnsafeMutablePointer(to: &clientAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(serverSock, &buffer, buffer.count, 0, $0, &clientLen)
        }
    }
    guard bytesRead > 0 else { continue }

    let queryData = Data(buffer[0..<bytesRead])
    let domain = parseDomainFromQuery(queryData) ?? "?"

    let responseData: Data?

    if filterMode == "whitelist" {
        // Whitelist mode: block everything EXCEPT listed + safelist domains
        if isDomainAllowed(domain) {
            responseData = forwardToUpstream(queryData, upstreamIP: upstreamDNS)
        } else {
            fputs("[DNS] BLOCKED (whitelist): \(domain)\n", stderr)
            responseData = buildBlockedResponse(for: queryData)
        }
    } else {
        // Blacklist mode: forward everything EXCEPT listed domains
        if isDomainBlocked(domain) {
            fputs("[DNS] BLOCKED: \(domain)\n", stderr)
            responseData = buildBlockedResponse(for: queryData)
        } else {
            responseData = forwardToUpstream(queryData, upstreamIP: upstreamDNS)
        }
    }

    if let responseData = responseData {
        _ = responseData.withUnsafeBytes { ptr in
            withUnsafePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(serverSock, ptr.baseAddress, responseData.count, 0, $0, clientLen)
                }
            }
        }
    }
}
