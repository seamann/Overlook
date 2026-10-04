import Foundation
import Network

@main
struct KVMDeviceEndpointTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("bracketed IPv6 becomes a numeric Network host", bracketedIPv6),
            ("IPv6 remains bracketed in HTTP and Janus URLs", bracketedURLs),
            ("IPv4 keeps the existing numeric Network host", unchangedIPv4),
            ("DNS names retain their original Network host", unchangedDNS),
            ("invalid bracketed text retains the existing host interpretation", invalidBracketFallback),
        ]
        var failures: [String] = []
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)") }
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        try expect(failures.isEmpty, "\(failures.count) device endpoint regressions")
        print("KVMDeviceEndpointTests: \(tests.count) groups passed; Network address parsing only, no DNS or connection")
    }

    private static func bracketedIPv6() throws {
        for literal in ["::1", "2001:db8::1"] {
            let endpoint = device(host: "[\(literal)]")
            guard case .ipv6(let address) = endpoint.networkHost else {
                throw Failure.message("Bracketed literal became a DNS host: \(endpoint.networkHost)")
            }
            try expect(address == IPv6Address(literal), "Numeric address changed")
            try expect(endpoint.host == "[\(literal)]", "URL authority representation changed")
        }
    }

    private static func bracketedURLs() throws {
        for host in ["[::1]", "[2001:db8::1]"] {
            let endpoint = device(host: host)
            try expect(endpoint.originURL == "https://\(host):443", "HTTP authority lost brackets")
            try expect(endpoint.webRTCURL == "wss://\(host):443/janus/ws", "Janus authority lost brackets")
            try expect(URL(string: endpoint.originURL)?.port == 443, "HTTP endpoint is invalid")
            try expect(URL(string: endpoint.webRTCURL)?.path == "/janus/ws", "Janus endpoint is invalid")
        }
    }

    private static func unchangedIPv4() throws {
        let endpoint = device(host: "192.0.2.7")
        guard case .ipv4(let address) = endpoint.networkHost else {
            throw Failure.message("IPv4 host became a name")
        }
        try expect(address == IPv4Address("192.0.2.7"), "IPv4 numeric address changed")
        try expect(endpoint.networkHost == NWEndpoint.Host(endpoint.host), "IPv4 Network behavior changed")
        try expect(endpoint.originURL == "https://192.0.2.7:443", "IPv4 HTTP URL changed")
        try expect(endpoint.webRTCURL == "wss://192.0.2.7:443/janus/ws", "IPv4 Janus URL changed")
    }

    private static func unchangedDNS() throws {
        let endpoint = device(host: "kvm.local")
        guard case .name(let name, let interface) = endpoint.networkHost else {
            throw Failure.message("DNS endpoint became a numeric address")
        }
        try expect(name == "kvm.local" && interface == nil, "DNS endpoint acquired another name or interface")
        try expect(endpoint.networkHost == NWEndpoint.Host(endpoint.host), "DNS Network behavior changed")
        try expect(endpoint.originURL == "https://kvm.local:443", "DNS HTTP URL changed")
        try expect(endpoint.webRTCURL == "wss://kvm.local:443/janus/ws", "DNS Janus URL changed")
    }

    private static func invalidBracketFallback() throws {
        let endpoint = device(host: "[foo:bar]")
        try expect(endpoint.networkHost == NWEndpoint.Host(endpoint.host), "Invalid text was reinterpreted as an IPv6 address")
    }

    private static func device(host: String) -> KVMDevice {
        KVMDevice(id: "test", name: "Synthetic", host: host, port: 443,
                  type: .glinetComet, authToken: "", capabilities: [])
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.message(message) }
    }

    private enum Failure: Error { case message(String) }
}
