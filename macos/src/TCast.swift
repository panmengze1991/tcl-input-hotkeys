import CommonCrypto
import Darwin
import Foundation

struct TVDevice: Hashable, Identifiable {
    let address: String
    let name: String
    var id: String { address }
}

struct TCastError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct TCastClient {
    let name = "Mac TV Hotkeys"
    let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))

    static func isAddress(_ address: String) -> Bool {
        var value = in_addr()
        return inet_pton(AF_INET, address, &value) == 1
    }

    func discover() throws -> [TVDevice] {
        let fd = try makeSocket(SOCK_DGRAM)
        defer { Darwin.close(fd) }
        try setOption(fd, SOL_SOCKET, SO_BROADCAST)
        let result = try withEndpoint("0.0.0.0", port: 6537) { Darwin.bind(fd, $0, $1) }
        guard result == 0 else { throw socketError("无法开启电视发现") }

        let destinations = broadcastAddresses()
        var devices = [String: TVDevice]()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let end = deadline(after: 3800)
        var nextBroadcast: UInt64 = 0
        while DispatchTime.now().uptimeNanoseconds < end {
            if DispatchTime.now().uptimeNanoseconds >= nextBroadcast {
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                let packet = Array("1:\(timestamp):\(name):PHONE:1:\(name):\(id):0:0\0".utf8)
                for address in destinations {
                    _ = try withEndpoint(address, port: 6537) { endpoint, size in
                        packet.withUnsafeBytes { Darwin.sendto(fd, $0.baseAddress, $0.count, 0, endpoint, size) }
                    }
                }
                nextBroadcast = deadline(after: 1100)
            }
            guard try waitFor(fd, events: Int16(POLLIN), until: min(nextBroadcast, end)) else { continue }
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout.size(ofValue: sender))
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            let fields = String(decoding: buffer.prefix(count), as: UTF8.self).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count > 3, fields[3] == "TV", let address = ipv4String(sender.sin_addr) else { continue }
            devices[address] = TVDevice(address: address, name: fields[2].isEmpty ? "TCL 电视" : String(fields[2]))
        }
        return devices.values.sorted { $0.address < $1.address }
    }
}

final class TCastConnection {
    private let client: TCastClient
    private var fd: Int32 = -1
    private var address: String?
    private var encrypted = false

    init(client: TCastClient) { self.client = client }
    deinit { disconnect() }

    func send(_ key: UInt8, to destination: String) throws {
        do {
            if destination != address || !drain() {
                disconnect()
                try connect(to: destination)
            }
            try writeFrame("149>>\(key)", until: deadline(after: 2500))
        } catch {
            disconnect()
            throw error
        }
    }

    func keepAlive() {
        guard fd >= 0 else { return }
        do {
            guard drain() else { disconnect(); return }
            try writeFrame("150>>", until: deadline(after: 2500))
        } catch {
            disconnect()
        }
    }

    private func connect(to destination: String) throws {
        fd = try makeSocket(SOCK_STREAM)
        try setOption(fd, SOL_SOCKET, SO_NOSIGPIPE)
        try setOption(fd, IPPROTO_TCP, TCP_NODELAY)
        let end = deadline(after: 2500)
        let result = try withEndpoint(destination, port: 6553) { Darwin.connect(fd, $0, $1) }
        if result < 0 {
            guard errno == EINPROGRESS else { throw socketError("无法连接电视") }
            guard try waitFor(fd, events: Int16(POLLOUT), until: end) else { throw TCastError("连接电视超时") }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw socketError("无法连接电视") }
            guard error == 0 else { throw socketError("无法连接电视", code: error) }
        }
        try writeFrame("159>>\(client.name)>>1>>\(client.id)>>1", until: end)
        for _ in 0..<12 {
            let header = try readExactly(4, until: end)
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length < 1_048_576 else { throw TCastError("T-Cast 数据帧长度无效") }
            let body = try readExactly(length, until: end)
            let fields = String(decoding: body, as: UTF8.self).components(separatedBy: ">>")
            guard fields.first == "159" else { continue }
            encrypted = fields.count > 6 && fields[6] == "1"
            address = destination
            return
        }
        throw TCastError("电视未完成 T-Cast 握手")
    }

    private func readExactly(_ size: Int, until end: UInt64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            guard try waitFor(fd, events: Int16(POLLIN), until: end) else { throw TCastError("等待电视回应超时") }
            let received = bytes.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress?.advanced(by: offset), size - offset, 0)
            }
            if received > 0 { offset += received; continue }
            if received == 0 { throw TCastError("电视已关闭连接") }
            guard errno == EINTR || errno == EWOULDBLOCK else { throw socketError("读取电视回应失败") }
        }
        return bytes
    }

    private func writeFrame(_ message: String, until end: UInt64) throws {
        let plain = Array(message.utf8)
        let body = encrypted ? try encrypt(plain) : plain
        var length = UInt32(body.count).bigEndian
        let frame = withUnsafeBytes(of: &length) { Array($0) } + body
        var offset = 0
        while offset < frame.count {
            guard try waitFor(fd, events: Int16(POLLOUT), until: end) else { throw TCastError("发送遥控指令超时") }
            let written = frame.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress?.advanced(by: offset), frame.count - offset, 0)
            }
            if written > 0 { offset += written; continue }
            guard written < 0, errno == EINTR || errno == EWOULDBLOCK else { throw socketError("发送遥控指令失败") }
        }
    }

    private func drain() -> Bool {
        guard fd >= 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {
            let received = Darwin.recv(fd, &bytes, bytes.count, 0)
            if received > 0 { continue }
            return received < 0 && (errno == EWOULDBLOCK || errno == EINTR)
        }
        return true
    }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        address = nil
        encrypted = false
    }
}

private func encrypt(_ input: [UInt8]) throws -> [UInt8] {
    let key = Array("tnscreentnscreen".utf8)
    let iv: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef]
    let capacity = input.count + kCCBlockSizeAES128
    var output = [UInt8](repeating: 0, count: capacity)
    var length = 0
    let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, iv, input, input.count, &output, capacity, &length)
    guard status == kCCSuccess else { throw TCastError("T-Cast 指令加密失败") }
    return Array(output.prefix(length))
}

private func makeSocket(_ type: Int32) throws -> Int32 {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw socketError("无法打开网络连接") }
    if fcntl(fd, F_SETFL, O_NONBLOCK) == -1 {
        let error = socketError("无法初始化网络连接")
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func setOption(_ fd: Int32, _ level: Int32, _ option: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd, level, option, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
        throw socketError("无法设置网络连接")
    }
}

private func withEndpoint<T>(_ address: String, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var endpoint = sockaddr_in()
    let size = MemoryLayout<sockaddr_in>.size
    endpoint.sin_len = UInt8(size)
    endpoint.sin_family = sa_family_t(AF_INET)
    endpoint.sin_port = port.bigEndian
    guard inet_pton(AF_INET, address, &endpoint.sin_addr) == 1 else { throw TCastError("电视 IPv4 地址无效") }
    return withUnsafePointer(to: &endpoint) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(size)) }
    }
}

private func ipv4String(_ address: in_addr) -> String? {
    var value = address
    var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &value, &bytes, socklen_t(bytes.count)) != nil else { return nil }
    return String(cString: bytes)
}

private func broadcastAddresses() -> Set<String> {
    var addresses: Set<String> = ["255.255.255.255"]
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let interfaces else { return addresses }
    defer { freeifaddrs(interfaces) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = interfaces
    while let interface = pointer?.pointee {
        pointer = interface.ifa_next
        guard interface.ifa_flags & UInt32(IFF_UP) != 0,
              interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              let address = interface.ifa_addr, address.pointee.sa_family == AF_INET,
              let mask = interface.ifa_netmask else { continue }
        let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
        let bits = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
        if let broadcast = ipv4String(in_addr(s_addr: ip | ~bits)) { addresses.insert(broadcast) }
    }
    return addresses
}

private func deadline(after milliseconds: UInt64) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
}

private func waitFor(_ fd: Int32, events: Int16, until end: UInt64) throws -> Bool {
    var descriptor = pollfd(fd: fd, events: events, revents: 0)
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { return false }
        let timeout = Int32((end - now + 999_999) / 1_000_000)
        let result = poll(&descriptor, 1, timeout)
        if result >= 0 { return result > 0 }
        guard errno == EINTR else { throw socketError("网络连接失败") }
    }
}

private func socketError(_ message: String, code: Int32 = errno) -> TCastError {
    TCastError("\(message)（\(String(cString: strerror(code)))）")
}
