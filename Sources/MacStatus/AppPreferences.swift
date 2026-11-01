import Foundation

struct CardLayout: Equatable {
    var order: [Metric]
    var hidden: Set<Metric>
    var visible: [Metric] { order.filter { !hidden.contains($0) } }

    init(order: [String] = [], hidden: [String] = []) {
        var seen: Set<Metric> = []
        self.order = (order.compactMap(Metric.init(rawValue:)) + Metric.allCases).filter { seen.insert($0).inserted }
        self.hidden = Set(hidden.compactMap(Metric.init(rawValue:)))
    }

    mutating func move(_ metric: Metric, by offset: Int) {
        guard let index = order.firstIndex(of: metric), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
    }
}

enum SamplingWork { case full, networkOnly }

struct SamplingPolicy {
    private var lastFullSample: TimeInterval?
    static func interval(visible: Bool, showsSpeed: Bool, lowPower: Bool) -> Int {
        visible || showsSpeed ? (lowPower ? 5 : 2) : (lowPower ? 30 : 10)
    }
    mutating func next(at time: TimeInterval, visible: Bool, showsSpeed: Bool, lowPower: Bool) -> SamplingWork {
        // Match the timer's 250 ms leeway so a slightly early tick does not skip a full interval.
        let fullDue = lastFullSample.map { time - $0 >= Double(lowPower ? 30 : 10) - 0.25 } ?? true
        if visible || !showsSpeed || fullDue {
            lastFullSample = time
            return .full
        }
        return .networkOnly
    }
    mutating func reset() { lastFullSample = nil }
}

enum SupportReport {
    // Deliberately takes no snapshot, address, process list, username or device identifier.
    static func make(machine: MachineInfo, lowPower: Bool, menuMode: MenuSpeedMode, version: String) -> String {
        """
        MacStatus 问题报告
        版本：\(version)
        系统：\(machine.os)
        机型：\(machine.model)
        芯片：\(machine.chip)，\(machine.cores) 核，\(DisplayFormat.bytes(machine.memory)) 内存
        采样策略：\(lowPower ? "节能" : "标准")
        菜单栏：\(menuMode.title)

        问题描述：
        复现步骤：
        预期结果：
        实际结果：

        本报告未附带 IP、DNS、进程列表、用户名、序列号或文件路径。
        请在分享前检查你自行补充的信息。
        """
    }
}
