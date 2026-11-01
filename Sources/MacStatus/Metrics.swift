import Foundation

struct CPUReading: Codable {
    let user: Double
    let system: Double
    var total: Double { user + system }
}

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func usage(since previous: CPUTicks) -> CPUReading? {
        // Kernel counters can wrap. Wrapping subtraction preserves the interval.
        let userDelta = UInt64(user &- previous.user) + UInt64(nice &- previous.nice)
        let systemDelta = UInt64(system &- previous.system)
        let total = userDelta + systemDelta + UInt64(idle &- previous.idle)
        guard total > 0 else { return nil }
        return CPUReading(user: Double(userDelta) / Double(total), system: Double(systemDelta) / Double(total))
    }
}

struct MemoryReading: Codable {
    let total: UInt64
    let apps: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swap: UInt64?
    let pressure: String?
    var free: UInt64 = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var used: UInt64 { min(total, apps + wired + compressed) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkInterface: Codable {
    let name: String
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var address: String?
    var ipv6Addresses: [String] = []
    var mtu: UInt32?
    var download: Double?
    var upload: Double?
}

struct NetworkReading: Codable {
    let download: Double?
    let upload: Double?
    let received: UInt64
    let sent: UInt64
    let interfaces: [NetworkInterface]
}

struct NetworkBaseline {
    let time: TimeInterval
    let interfaces: [NetworkInterface]

    func rates(since previous: NetworkBaseline) -> (Double, Double)? {
        let elapsed = time - previous.time
        guard elapsed > 0 else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var comparable = false
        for interface in interfaces {
            guard let old = previous.interfaces.first(where: { $0.name == interface.name }),
                  interface.received >= old.received, interface.sent >= old.sent else { continue }
            comparable = true
            received += interface.received - old.received
            sent += interface.sent - old.sent
        }
        return comparable ? (Double(received) / elapsed, Double(sent) / elapsed) : nil
    }
}

struct DiskReading: Codable {
    let total: UInt64
    let free: UInt64
    var name: String = "数据卷"
    var format: String?
    var importantAvailable: UInt64?
    var readOnly: Bool?
    var used: UInt64 { total - min(total, free) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct BatteryReading: Codable {
    let fraction: Double?
    let state: String
    let remainingMinutes: Int?
    let cycles: Int?
    let healthPercent: Double?
    var fullCapacity: Double?
    var designCapacity: Double?
    var voltage: Double?
    var amperage: Double?
    var adapterWatts: Double?
    var power: Double? { voltage.flatMap { voltage in amperage.map { voltage * $0 } } }
}

struct MachineInfo: Codable {
    let model: String
    let chip: String
    let cores: Int
    let memory: UInt64
    let os: String
    var physicalCores: Int?
    var performanceCores: Int?
    var efficiencyCores: Int?
    var architecture: String?
    var kernel: String?
}

struct Snapshot: Codable {
    var date = Date()
    var cpu: CPUReading?
    var memory: MemoryReading?
    var network: NetworkReading?
    var disk: DiskReading?
    var battery: BatteryReading?
    var hasBattery: Bool?
    var uptime: TimeInterval = 0
    var thermal = "未知"
    var coreUsage: [Double?] = []
    var loadAverage: [Double] = []
    var connection = ConnectionInfo()
    var processes: [ProcessReading] = []
    var diskActivity: NetworkReading?
    var systemLowPower = false
}

enum MenuSpeedMode: String, CaseIterable {
    case hidden, download, upload, both
    var title: String {
        switch self {
        case .hidden: return "仅图标"
        case .download: return "下载速度"
        case .upload: return "上传速度"
        case .both: return "上传与下载"
        }
    }
    func text(network: NetworkReading?) -> String {
        switch self {
        case .hidden: return ""
        case .download: return "↓ " + DisplayFormat.menuRate(network?.download)
        case .upload: return "↑ " + DisplayFormat.menuRate(network?.upload)
        case .both: return "↓ " + DisplayFormat.menuRate(network?.download) + "  ↑ " + DisplayFormat.menuRate(network?.upload)
        }
    }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
    let download: Double?
    var upload: Double?
}

struct TrendSample {
    let date: Date
    let value: Double
}

enum TrendSeries {
    static let duration: TimeInterval = 120

    static func horizontalPosition(date: Date, endingAt end: Date) -> Double {
        1 + date.timeIntervalSince(end) / duration
    }

    static func segments(points: [HistoryPoint], metric: KeyPath<HistoryPoint, Double?>, endingAt end: Date) -> [[TrendSample]] {
        var result: [[TrendSample]] = []
        var current: [TrendSample] = []
        for point in points where point.date >= end.addingTimeInterval(-duration) && point.date <= end {
            guard let value = point[keyPath: metric] else {
                if !current.isEmpty { result.append(current); current = [] }
                continue
            }
            if let previous = current.last, point.date.timeIntervalSince(previous.date) > 35 {
                result.append(current)
                current = []
            }
            current.append(TrendSample(date: point.date, value: value))
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum DisplayFormat {
    static func menuRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value < 1024 { return String(format: "%.0fB/s", value) }
        if value < 1_048_576 { return String(format: "%.0fK/s", value / 1024) }
        if value < 1_073_741_824 { return String(format: "%.1fM/s", value / 1_048_576) }
        return String(format: "%.1fG/s", value / 1_073_741_824)
    }
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "采样中" }
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1_048_576 { return String(format: "%.1f KB/s", value / 1024) }
        return String(format: "%.1f MB/s", value / 1_048_576)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        return days > 0 ? "\(days) 天 \(minutes / 60 % 24) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, battery, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "处理器"
        case .memory: return "内存"
        case .network: return "网络"
        case .disk: return "存储"
        case .battery: return "电池"
        case .system: return "系统"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .battery: return "battery.75percent"
        case .system: return "laptopcomputer"
        }
    }
}
