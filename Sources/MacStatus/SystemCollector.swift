import Foundation
import Darwin
import IOKit
import IOKit.ps

// Used only on the monitor's serial utility queue (or by the diagnostic command).
final class SystemCollector {
    let machine: MachineInfo
    private var previousCPU: CPUTicks?
    private var previousNetwork: NetworkBaseline?
    private var slowUpdated = -Double.infinity
    private var disk: DiskReading?
    private var battery: BatteryReading?
    private var hasBattery: Bool?
    private var previousCores: [CPUTicks] = []
    private let connectionCollector = ConnectionCollector()
    private let detailCollector = DetailCollector()

    init() {
        machine = MachineInfo(
            model: Self.stringSysctl("hw.model") ?? "Mac",
            chip: Self.stringSysctl("machdep.cpu.brand_string") ?? "未知芯片",
            cores: ProcessInfo.processInfo.processorCount,
            memory: ProcessInfo.processInfo.physicalMemory,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalCores: Self.intSysctl("hw.physicalcpu"),
            performanceCores: Self.intSysctl("hw.perflevel0.physicalcpu"),
            efficiencyCores: Self.intSysctl("hw.perflevel1.physicalcpu"),
            architecture: Self.stringSysctl("hw.machine"), kernel: Self.stringSysctl("kern.osrelease")
        )
    }

    func sample(detailed: Bool = false, expanded: String? = nil) -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if now - slowUpdated >= 30 {
            disk = readDisk()
            (hasBattery, battery) = readBattery()
            slowUpdated = now
        }
        var snapshot = Snapshot()
        if let ticks = readCPU() {
            snapshot.cpu = previousCPU.flatMap { ticks.usage(since: $0) }
            previousCPU = ticks
        } else {
            previousCPU = nil
        }
        snapshot.memory = readMemory()
        snapshot.connection = connectionCollector.read(includeWifi: detailed && expanded == "network")
        if detailed && expanded == "cpu" {
            let cores = readCores()
            snapshot.coreUsage = cores.enumerated().map { index, ticks in
                index < previousCores.count ? ticks.usage(since: previousCores[index])?.total : nil
            }
            previousCores = cores
            var loads = [Double](repeating: 0, count: 3)
            if getloadavg(&loads, 3) == 3 { snapshot.loadAverage = loads }
        } else { previousCores = [] }
        snapshot.network = sampleNetwork()
        snapshot.processes = detailCollector.readProcesses(enabled: detailed && (expanded == "cpu" || expanded == "memory"), now: now)
        snapshot.diskActivity = detailCollector.readDiskActivity(enabled: detailed && expanded == "disk", now: now)
        snapshot.systemLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        snapshot.disk = disk
        snapshot.battery = battery
        snapshot.hasBattery = hasBattery
        snapshot.uptime = now
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: snapshot.thermal = "正常"
        case .fair: snapshot.thermal = "略有升温"
        case .serious: snapshot.thermal = "较高"
        case .critical: snapshot.thermal = "过高"
        @unknown default: snapshot.thermal = "未知"
        }
        return snapshot
    }

    func sampleNetwork() -> NetworkReading? {
        guard let interfaces = readInterfaces() else { previousNetwork = nil; return nil }
        let baseline = NetworkBaseline(time: ProcessInfo.processInfo.systemUptime, interfaces: interfaces)
        let rates = previousNetwork.flatMap { baseline.rates(since: $0) }
        previousNetwork = baseline
        return NetworkReading(download: rates?.0, upload: rates?.1,
                              received: interfaces.reduce(0) { $0 + $1.received },
                              sent: interfaces.reduce(0) { $0 + $1.sent }, interfaces: interfaces)
    }

    func endDetails() {
        previousCores = []
        detailCollector.reset()
    }

    func resetBaselines() {
        detailCollector.reset()
        previousCPU = nil
        previousCores = []
        previousNetwork = nil
        slowUpdated = -Double.infinity
    }

    private func readCores() -> [CPUTicks] {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(count) * MemoryLayout<integer_t>.size)) }
        guard Int(count) >= Int(cores) * 4 else { return [] }
        return (0..<Int(cores)).map { core in
            CPUTicks(user: UInt32(bitPattern: info[core * 4]), system: UInt32(bitPattern: info[core * 4 + 1]),
                     idle: UInt32(bitPattern: info[core * 4 + 2]), nice: UInt32(bitPattern: info[core * 4 + 3]))
        }
    }

    private func readCPU() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readMemory() -> MemoryReading? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let active = UInt64(info.active_count) + UInt64(info.inactive_count)
        let reclaimable = UInt64(info.external_page_count) + UInt64(info.purgeable_count)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        let pressureText: String?
        if pressureResult != 0 { pressureText = nil }
        else {
            switch pressure {
            case 1: pressureText = "正常"
            case 2: pressureText = "偏高"
            case 4: pressureText = "高"
            default: pressureText = nil
            }
        }
        return MemoryReading(
            total: machine.memory, apps: (active > reclaimable ? active - reclaimable : 0) * page,
            wired: UInt64(info.wire_count) * page, compressed: UInt64(info.compressor_page_count) * page,
            cached: reclaimable * page, swap: swapResult == 0 ? swap.xsu_used : nil, pressure: pressureText,
            free: UInt64(info.free_count) * page, pageIns: info.pageins * page, pageOuts: info.pageouts * page
        )
    }

    private func readInterfaces() -> [NetworkInterface]? {
        guard let counters = readInterfaceCounters() else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var interfaces: [String: NetworkInterface] = [:]
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            // Physical en interfaces only: counting VPN/bridge traffic as well duplicates bytes.
            guard name.hasPrefix("en"), item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  let address = item.ifa_addr else { continue }
            let index = if_nametoindex(item.ifa_name)
            guard let counter = counters[index] else { continue }
            var interface = interfaces[name] ?? NetworkInterface(name: name, received: counter.0, sent: counter.1, mtu: counter.2)
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: buffer)
                    if family == AF_INET { interface.address = text }
                    else if !interface.ipv6Addresses.contains(text) { interface.ipv6Addresses.append(text) }
                }
            }
            interfaces[name] = interface
        }
        return interfaces.values.sorted { $0.name < $1.name }.map { interface in
            var value = interface
            if let old = previousNetwork {
                let current = NetworkBaseline(time: ProcessInfo.processInfo.systemUptime, interfaces: [interface])
                let rates = current.rates(since: old)
                value.download = rates?.0
                value.upload = rates?.1
            }
            return value
        }
    }

    private func readInterfaceCounters() -> [UInt32: (UInt64, UInt64, UInt32)]? {
        // getifaddrs exposes 32-bit byte counters, which wrap after only 4 GiB.
        // NET_RT_IFLIST2 provides the kernel's full 64-bit interface counters.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            var counters: [UInt32: (UInt64, UInt64, UInt32)] = [:]
            var offset = 0
            while offset + 4 <= size {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { break }
                let type = bytes[offset + 3]
                if type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    counters[UInt32(info.ifm_index)] = (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes, info.ifm_data.ifi_mtu)
                }
                offset += length
            }
            return counters
        }
    }

    private func readDisk() -> DiskReading? {
        // Query the writable Data volume; on APFS the free space is shared by its container.
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
              total > 0, free >= 0 else { return nil }
        return DiskReading(total: UInt64(total), free: UInt64(free), name: values.volumeName ?? "数据卷", format: values.volumeLocalizedFormatDescription,
                           importantAvailable: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }, readOnly: values.volumeIsReadOnly)
    }

    private func readBattery() -> (Bool?, BatteryReading?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Double
            let maximum = description[kIOPSMaxCapacityKey] as? Double
            let fraction = current.flatMap { value in maximum.flatMap { $0 > 0 ? min(1, max(0, value / $0)) : nil } }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let state = charging ? "正在充电" : (onAC ? "已接电源" : "使用电池")
            let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            var cycles: Int?
            var health: Double?
            var fullCapacity: Double?
            var designCapacity: Double?
            var voltage: Double?
            var amperage: Double?
            var adapterWatts: Double?
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let values = properties?.takeRetainedValue() as? [String: Any] {
                    cycles = values["CycleCount"] as? Int
                    adapterWatts = (values["AdapterDetails"] as? [String: Any])?["Watts"] as? Double
                    let batteryData = values["BatteryData"] as? [String: Any] ?? [:]
                    let capacity = values["AppleRawMaxCapacity"] as? Double
                        ?? batteryData["AppleRawMaxCapacity"] as? Double
                        ?? batteryData["FullChargeCapacity"] as? Double
                    let design = values["DesignCapacity"] as? Double ?? batteryData["DesignCapacity"] as? Double
                    fullCapacity = capacity
                    designCapacity = design
                    voltage = (values["Voltage"] as? Double).map { $0 / 1000 }
                    amperage = (values["InstantAmperage"] as? NSNumber).map { Double($0.int64Value) / 1000 }
                    if let capacity, let design, design > 0 {
                        health = capacity / design * 100
                    }
                }
            }
            return (true, BatteryReading(fraction: fraction, state: state,
                remainingMinutes: (charging || !onAC) ? minutes.flatMap { $0 > 0 ? $0 : nil } : nil,
                cycles: cycles, healthPercent: health, fullCapacity: fullCapacity,
                designCapacity: designCapacity, voltage: voltage, amperage: amperage, adapterWatts: adapterWatts))
        }
        return (false, nil)
    }

    private static func intSysctl(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func stringSysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
