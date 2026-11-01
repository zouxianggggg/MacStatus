import Foundation
import Darwin
import IOKit

struct ProcessReading: Codable, Identifiable {
    let id: Int32
    let name: String
    let memory: UInt64
    let cpu: Double?
    let threads: Int32
}

struct ProcessCounter {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    let start: UInt64
    let cpuTime: UInt64
    func usage(since old: ProcessCounter, elapsed: Double) -> Double? {
        guard start == old.start, elapsed > 0, cpuTime >= old.cpuTime else { return nil }
        return Double(cpuTime - old.cpuTime) * Self.secondsPerTick / elapsed
    }
}

final class DetailCollector {
    private var previous: [Int32: ProcessCounter] = [:]
    private var previousTime: Double?
    private var updated = -Double.infinity
    private var processes: [ProcessReading] = []
    private var diskBaseline: NetworkBaseline?

    func reset() {
        processes = []
        previous = [:]
        previousTime = nil
        updated = -Double.infinity
        diskBaseline = nil
    }

    func readProcesses(enabled: Bool, now: Double) -> [ProcessReading] {
        guard enabled else { previous = [:]; previousTime = nil; updated = -Double.infinity; processes = []; return [] }
        guard now - updated >= 5 else { return processes }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var counters: [Int32: ProcessCounter] = [:]
        var readings: [ProcessReading] = []
        for pid in pids.prefix(max(0, min(Int(actual), pids.count))) where pid > 0 {
            var info = proc_taskallinfo()
            let size = MemoryLayout<proc_taskallinfo>.size
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(size)) == size else { continue }
            let counter = ProcessCounter(start: UInt64(info.pbsd.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbsd.pbi_start_tvusec),
                                         cpuTime: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system)
            counters[pid] = counter
            let cpu = previous[pid].flatMap { counter.usage(since: $0, elapsed: now - (previousTime ?? now)) }
            var name = [CChar](repeating: 0, count: 256)
            _ = proc_name(pid, &name, UInt32(name.count))
            readings.append(ProcessReading(id: pid, name: String(cString: name), memory: info.ptinfo.pti_resident_size,
                                           cpu: cpu, threads: info.ptinfo.pti_threadnum))
        }
        previous = counters
        previousTime = now
        updated = now
        // Retain only rows used by either ranking.
        let topCPU = readings.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(5)
        let topMemory = readings.sorted { $0.memory > $1.memory }.prefix(5)
        processes = Array(Dictionary((Array(topCPU) + Array(topMemory)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        return processes
    }

    func readDiskActivity(enabled: Bool, now: Double) -> NetworkReading? {
        guard enabled else { diskBaseline = nil; return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var interfaces: [NetworkInterface] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber, let written = stats["Bytes (Write)"] as? NSNumber else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            interfaces.append(NetworkInterface(name: String(id), received: read.uint64Value, sent: written.uint64Value))
        }
        guard !interfaces.isEmpty else { return nil }
        let baseline = NetworkBaseline(time: now, interfaces: interfaces)
        let rates = diskBaseline.flatMap { baseline.rates(since: $0) }
        diskBaseline = baseline
        return NetworkReading(download: rates?.0, upload: rates?.1, received: interfaces.reduce(0) { $0 + $1.received },
                              sent: interfaces.reduce(0) { $0 + $1.sent }, interfaces: interfaces)
    }
}
