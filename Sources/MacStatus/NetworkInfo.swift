import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

struct ConnectionInfo: Codable, Equatable {
    var primaryInterface: String?
    var router: String?
    var addresses: [String] = []
    var dns: [String] = []
    var tunnels: [String] = []
    var proxy = "未启用系统代理"
    var proxyConfiguration = ""
    var physicalAddresses: [String] = []
    var wifiRate: Double?
    var wifiRSSI: Int?
    var wifiNoise: Int?
    var wifiChannel: Int?
    // Link measurements change constantly; only routing/address configuration invalidates the IP cache.
    var identity: String { [primaryInterface ?? "", router ?? "", addresses.sorted().joined(), physicalAddresses.sorted().joined(), dns.joined(), tunnels.joined(), proxy, proxyConfiguration].joined(separator: "|") }
}

final class ConnectionCollector {
    private let store = SCDynamicStoreCreate(nil, "MacStatus" as CFString, nil, nil)
    private var wifi = ConnectionInfo()
    private var wifiUpdated = -Double.infinity

    func read(includeWifi: Bool) -> ConnectionInfo {
        func dictionary(_ key: String) -> [String: Any] {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
        }
        var info = ConnectionInfo()
        let v4 = dictionary("State:/Network/Global/IPv4")
        let v6 = dictionary("State:/Network/Global/IPv6")
        info.primaryInterface = v4["PrimaryInterface"] as? String ?? v6["PrimaryInterface"] as? String
        info.router = v4["Router"] as? String ?? v6["Router"] as? String
        info.dns = dictionary("State:/Network/Global/DNS")["ServerAddresses"] as? [String] ?? []
        if let name = info.primaryInterface {
            info.addresses = (dictionary("State:/Network/Interface/\(name)/IPv4")["Addresses"] as? [String] ?? [])
                + (dictionary("State:/Network/Interface/\(name)/IPv6")["Addresses"] as? [String] ?? [])
        }
        // An active tunnel does not by itself prove that all traffic uses a VPN.
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            defer { freeifaddrs(list) }
            var cursor = list
            var names = Set<String>()
            while let entry = cursor {
                let item = entry.pointee
                let name = String(cString: item.ifa_name)
                if name.hasPrefix("utun"), item.ifa_flags & UInt32(IFF_UP) != 0 { names.insert(name) }
                if name.hasPrefix("en"), item.ifa_flags & UInt32(IFF_UP) != 0, let address = item.ifa_addr,
                   address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        info.physicalAddresses.append(name + ":" + String(cString: buffer))
                    }
                }
                cursor = item.ifa_next
            }
            info.tunnels = names.sorted()
        }
        let proxy = dictionary("State:/Network/Global/Proxies")
        if let data = try? JSONSerialization.data(withJSONObject: proxy, options: [.sortedKeys]) {
            info.proxyConfiguration = String(data: data, encoding: .utf8) ?? ""
        }
        let enabled = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"), ("ProxyAutoConfigEnable", "PAC"), ("ProxyAutoDiscoveryEnable", "自动发现")]
            .filter { (proxy[$0.0] as? NSNumber)?.boolValue == true }.map { $0.1 }
        if !enabled.isEmpty { info.proxy = enabled.joined(separator: " · ") }
        let now = ProcessInfo.processInfo.systemUptime
        if includeWifi && now - wifiUpdated >= 30 {
            wifi = ConnectionInfo()
            if let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interface.transmitRate() > 0 {
                wifi.wifiRate = interface.transmitRate()
                let rssi = interface.rssiValue()
                if rssi < 0 { wifi.wifiRSSI = rssi }
                let noise = interface.noiseMeasurement()
                if noise < 0 { wifi.wifiNoise = noise }
                wifi.wifiChannel = interface.wlanChannel()?.channelNumber
            }
            wifiUpdated = now
        }
        info.wifiRate = wifi.wifiRate
        info.wifiRSSI = wifi.wifiRSSI
        info.wifiNoise = wifi.wifiNoise
        info.wifiChannel = wifi.wifiChannel
        return info
    }
}

struct EgressResult: Equatable {
    var address: String?
    var error: String?
    var country: CountryInfo?
}

struct EgressReading {
    var ipv4 = EgressResult()
    var ipv6 = EgressResult()
    var checkedAt: Date?
    var loading = false
    var identity = ""

    func needsRefresh(for identity: String, at date: Date = Date()) -> Bool {
        !loading && (self.identity != identity || checkedAt == nil || date.timeIntervalSince(checkedAt!) >= 300)
    }
}

enum EgressQuery {
    static func parse(_ data: Data, family: Int32) -> String? {
        struct Response: Decodable { let ip: String }
        guard data.count <= 1024, let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        return response.ip.withCString { inet_pton(family, $0, &bytes) } == 1 ? response.ip : nil
    }

    static func fetch(family: Int32, session: URLSession) async -> EgressResult {
        let host = family == AF_INET ? "api.ipify.org" : "api6.ipify.org"
        var request = URLRequest(url: URL(string: "https://\(host)?format=json")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let address = parse(data, family: family) else {
                return EgressResult(error: "查询服务返回了无效结果")
            }
            let country = await CountryQuery.fetch(address: address, session: session)
            return EgressResult(address: address, country: country)
        } catch {
            let error = error as NSError
            return EgressResult(error: error.code == NSURLErrorTimedOut ? "查询超时" : "连接失败，未能确认出口")
        }
    }
}

struct CountryInfo: Equatable {
    let code: String
    let isp: String?
    let asn: Int?
    var name: String { Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code }
    var flag: String { code.unicodeScalars.map { String(UnicodeScalar(127397 + $0.value)!) }.joined() }
}

enum CountryQuery {
    static func parse(_ data: Data, address: String) -> CountryInfo? {
        struct Response: Decodable {
            struct Connection: Decodable { let isp: String?; let asn: Int? }
            let success: Bool
            let ip: String
            let country_code: String?
            let connection: Connection?
        }
        guard data.count <= 16_384, let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success, addressesEqual(response.ip, address), let code = response.country_code?.uppercased(),
              code.count == 2, code != "ZZ", Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else { return nil }
        return CountryInfo(code: code, isp: response.connection?.isp, asn: response.connection?.asn)
    }

    private static func addressesEqual(_ first: String, _ second: String) -> Bool {
        for family in [AF_INET, AF_INET6] {
            var a = [UInt8](repeating: 0, count: 16)
            var b = a
            if first.withCString({ inet_pton(family, $0, &a) }) == 1,
               second.withCString({ inet_pton(family, $0, &b) }) == 1 { return a == b }
        }
        return false
    }

    static func fetch(address: String, session: URLSession) async -> CountryInfo? {
        guard let url = URL(string: "https://ipwho.is/\(address)?fields=success,ip,country_code,connection.isp,connection.asn") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, address: address)
    }
}
