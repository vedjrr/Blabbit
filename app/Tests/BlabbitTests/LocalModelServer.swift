import Foundation

/// Minimal HTTP/1.1 file server for download tests: GET with `Range: bytes=N-`,
/// optional delay per 256 KiB chunk. One connection at a time, loopback only.
final class LocalModelServer: @unchecked Sendable {
    let port: UInt16
    private let file: URL
    private let listener: Int32
    private let lock = NSLock()
    private var _ranges: [UInt64?] = []
    var delayPerChunk: TimeInterval = 0

    var ranges: [UInt64?] { lock.lock(); defer { lock.unlock() }; return _ranges }

    init(serving file: URL) throws {
        self.file = file
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        self.listener = listener
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var endpoint: String { "http://127.0.0.1:\(port)" }

    func stop() { close(listener) }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var nosigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(Data("\r\n\r\n".utf8)) {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { return }
            request.append(buffer, count: n)
        }
        let head = String(decoding: request, as: UTF8.self).lowercased()
        let start: UInt64? = head.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("range: bytes=") }
            .flatMap { UInt64($0.dropFirst("range: bytes=".count).trimmingCharacters(in: CharacterSet(charactersIn: "- "))) }
        lock.lock(); _ranges.append(start); lock.unlock()
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = try? handle.seekToEnd() else { return }
        let from = start ?? 0
        let header = start == nil
            ? "HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 206 Partial Content\r\nContent-Length: \(size - from)\r\nContent-Range: bytes \(from)-\(size - 1)/\(size)\r\nConnection: close\r\n\r\n"
        guard send(client, header) else { return }
        try? handle.seek(toOffset: from)
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            if delayPerChunk > 0 { Thread.sleep(forTimeInterval: delayPerChunk) }
            guard send(client, chunk) else { return }
        }
    }

    private func send(_ client: Int32, _ text: String) -> Bool { send(client, Data(text.utf8)) }

    private func send(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
