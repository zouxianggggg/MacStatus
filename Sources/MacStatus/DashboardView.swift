import SwiftUI
import AppKit

private extension Metric {
    var tint: Color {
        switch self {
        case .cpu: return Color(red: 0.18, green: 0.47, blue: 0.95)
        case .memory: return Color(red: 0.55, green: 0.40, blue: 0.87)
        case .network: return Color(red: 0.08, green: 0.57, blue: 0.65)
        case .disk: return Color(red: 0.84, green: 0.52, blue: 0.21)
        case .battery: return Color(red: 0.24, green: 0.62, blue: 0.39)
        case .system: return Color(red: 0.43, green: 0.49, blue: 0.58)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: MonitorStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Metric?
    var openActivityMonitor: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    private var snapshot: Snapshot { monitor.snapshot }
    var resizePanel: (CGFloat) -> Void
    private var panelHeight: CGFloat { expanded != nil ? 550 : max(190, 96 + CGFloat(monitor.cardLayout.visible.count) * 47) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 7) {
                        if monitor.cardLayout.visible.isEmpty {
                            VStack(spacing: 10) {
                                Text("所有卡片已隐藏").font(.headline)
                                Button("管理卡片", action: openSettings)
                            }.frame(height: 90)
                        }
                        ForEach(monitor.cardLayout.visible) { metric in
                            VStack(spacing: 0) {
                                compactCard(metric)
                                if expanded == metric {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Divider().opacity(0.4)
                                        detail(metric)
                                    }.padding(.horizontal, 13).padding(.bottom, 14)
                                }
                            }
                            .cardSurface(tint: metric.tint).id(metric.id)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 10)
                }
                .onChange(of: expanded) { metric in
                    monitor.setExpandedMetric(metric?.rawValue)
                    let target = metric ?? monitor.cardLayout.visible.first ?? .cpu
                    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.22)) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            proxy.scrollTo(target.id, anchor: .top)
                        }
                    }
                }
            }
            footer
        }
        .frame(width: 352, height: panelHeight)
        .onChange(of: panelHeight) { resizePanel($0) }
        .onChange(of: monitor.cardLayout) { layout in
            if let expanded, layout.hidden.contains(expanded) { self.expanded = nil }
        }
        .onAppear {
            if let expanded, monitor.cardLayout.hidden.contains(expanded) { self.expanded = nil }
            monitor.setExpandedMetric(self.expanded?.rawValue)
        }
        .background(.regularMaterial)
    }

    private func select(_ metric: Metric) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded = expanded == metric ? nil : metric }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: StatusGlyph.header).foregroundStyle(.primary).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacStatus").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("\(monitor.machine.chip)  ·  \(DisplayFormat.bytes(monitor.machine.memory))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 14)).frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("打开设置")
        }.padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 10)
    }

    private func compactCard(_ metric: Metric) -> some View {
        Button { select(metric) } label: {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol).font(.system(size: 13)).foregroundStyle(metric.tint).frame(width: 17)
                Text(metric.title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 5)
                Text(summary(metric)).font(.system(size: metric == .network ? 10 : 11, weight: .medium))
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: expanded == metric ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(metric.title)，\(summary(metric))，\(expanded == metric ? "收起详情" : "展开详情")")
    }

    private func headline(_ value: String, size: CGFloat = 24) -> some View {
        Text(value).font(.system(size: size, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.65)
    }
    private func summary(_ metric: Metric) -> String {
        switch metric {
        case .cpu: return DisplayFormat.percent(snapshot.cpu?.total) + " · \(monitor.machine.cores) 核"
        case .memory: return snapshot.memory.map { DisplayFormat.bytes($0.used) + " / " + DisplayFormat.bytes($0.total) } ?? "采样中"
        case .network: return "↓ \(DisplayFormat.rate(snapshot.network?.download))  ↑ \(DisplayFormat.rate(snapshot.network?.upload))"
        case .disk: return snapshot.disk.map { "可用 \(DisplayFormat.bytes($0.free))" } ?? "采样中"
        case .battery: return snapshot.hasBattery == false ? "外接电源" : DisplayFormat.percent(snapshot.battery?.fraction) + " · " + (snapshot.battery?.state ?? "")
        case .system: return snapshot.thermal + " · " + DisplayFormat.uptime(snapshot.uptime)
        }
    }
    private func note(_ value: String) -> some View {
        Text(value).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func detail(_ metric: Metric) -> some View {
        switch metric {
        case .cpu:
            headline(DisplayFormat.percent(snapshot.cpu?.total))
            TrendChart(points: monitor.history, metric: \.cpu, color: metric.tint, maximum: 1)
            DetailPair("用户进程", DisplayFormat.percent(snapshot.cpu?.user), "系统进程", DisplayFormat.percent(snapshot.cpu?.system))
            if !snapshot.coreUsage.isEmpty {
                Text("各核心使用率").font(.system(size: 10)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(Array(snapshot.coreUsage.enumerated()), id: \.offset) { index, usage in
                        VStack(spacing: 5) {
                            Ring(fraction: usage ?? 0, tint: metric.tint)
                                .overlay(Text(DisplayFormat.percent(usage)).font(.system(size: 10)).monospacedDigit()).frame(width: 44, height: 44)
                            Text("核心 \(index + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            InfoRow(title: "平均负载 · 1 / 5 / 15 分钟", value: snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            InfoRow(title: "空闲", value: DisplayFormat.percent(snapshot.cpu.map { max(0, 1 - $0.total) }))
            processList(memory: false)
            note("负载是任务数；进程 CPU 以一个核心的 100% 为基准，可能超过 100%。排行每 5 秒更新，仅包含可读取的进程。")
        case .memory:
            headline(snapshot.memory.map { DisplayFormat.bytes($0.used) } ?? "—")
            TrendChart(points: monitor.history, metric: \.memory, color: metric.tint, maximum: 1)
            MemoryComposition(memory: snapshot.memory).frame(height: 8)
            if let memory = snapshot.memory {
                DetailPair("应用 · 估算", DisplayFormat.bytes(memory.apps), "联动内存", DisplayFormat.bytes(memory.wired))
                DetailPair("压缩内存", DisplayFormat.bytes(memory.compressed), "文件缓存 · 估算", DisplayFormat.bytes(memory.cached))
                DetailPair("交换空间", memory.swap.map(DisplayFormat.bytes) ?? "暂不可用", "内存压力", memory.pressure ?? "系统未提供")
                DetailPair("空闲物理页", DisplayFormat.bytes(memory.free), "累计页读入 / 写出", "\(DisplayFormat.bytes(memory.pageIns)) / \(DisplayFormat.bytes(memory.pageOuts))")
                processList(memory: true)
                note("色条依次为应用、联动、压缩内存和剩余空间。页读写为开机以来累计，不等同于交换空间用量；组成按系统页计数估算。")
            }
        case .network:
            networkDetail
        case .disk:
            if let disk = snapshot.disk {
                headline(DisplayFormat.bytes(disk.free))
                InfoRow(title: "数据卷", value: disk.name)
                CapacityBar(fraction: disk.fraction, color: metric.tint)
                DetailPair("已用", DisplayFormat.bytes(disk.used), "可用", DisplayFormat.bytes(disk.free))
                DetailPair("总容量", DisplayFormat.bytes(disk.total), "使用比例", DisplayFormat.percent(disk.fraction))
                InfoRow(title: "文件系统", value: disk.format ?? "系统未提供")
                InfoRow(title: "卷访问", value: disk.readOnly.map { $0 ? "只读" : "可读写" } ?? "未知")
                InfoRow(title: "重要用途可用容量", value: disk.importantAvailable.map(DisplayFormat.bytes) ?? "系统未提供")
                if let activity = snapshot.diskActivity {
                    DetailPair("磁盘读取", DisplayFormat.rate(activity.download), "磁盘写入", DisplayFormat.rate(activity.upload))
                    DetailPair("累计读取", DisplayFormat.bytes(activity.received), "累计写入", DisplayFormat.bytes(activity.sent))
                } else { note("当前驱动未提供磁盘读写计数。") }
                note("读写为可读取的块存储驱动合计；重要用途容量可能包含可清除空间。APFS 容器共享可用空间；此处不把可清除空间计入空闲容量。")
            }
        case .battery:
            if let battery = snapshot.battery {
                headline(DisplayFormat.percent(battery.fraction))
                InfoRow(title: "电源状态", value: battery.state)
                CapacityBar(fraction: battery.fraction ?? 0, color: metric.tint)
                DetailPair("循环次数", battery.cycles.map(String.init) ?? "—", "满充 / 设计容量", battery.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                DetailPair("满充容量", battery.fullCapacity.map { String(format: "%.0f mAh", $0) } ?? "—", "设计容量", battery.designCapacity.map { String(format: "%.0f mAh", $0) } ?? "—")
                DetailPair("电压", battery.voltage.map { String(format: "%.2f V", $0) } ?? "—", "电池电流", battery.amperage.map { String(format: "%+.2f A", $0) } ?? "—")
                DetailPair("电池端功率", battery.power.map { String(format: "%+.2f W", $0) } ?? "—", "适配器额定功率", battery.adapterWatts.map { String(format: "%.0f W", $0) } ?? "系统未提供")
                InfoRow(title: battery.state == "正在充电" ? "预计充满" : "预计剩余", value: battery.remainingMinutes.map { "\($0) 分钟" } ?? "系统正在估算 / 不适用")
                note("容量比来自电池原始容量，不等同于系统设置中的电池健康值。负电流表示放电。")
            } else { note(snapshot.hasBattery == false ? "此 Mac 没有内置电池。" : "电池信息暂不可用。") }
        case .system:
            headline(snapshot.thermal)
            InfoRow(title: "机型标识", value: monitor.machine.model)
            InfoRow(title: "芯片", value: monitor.machine.chip)
            DetailPair("逻辑核心", "\(monitor.machine.cores)", "物理内存", DisplayFormat.bytes(monitor.machine.memory))
            InfoRow(title: "系统版本", value: monitor.machine.os)
            InfoRow(title: "开机时长", value: DisplayFormat.uptime(snapshot.uptime))
            InfoRow(title: "热状态", value: snapshot.thermal)
            InfoRow(title: "物理核心", value: monitor.machine.physicalCores.map(String.init) ?? "未知")
            InfoRow(title: "性能 / 能效核心", value: "\(monitor.machine.performanceCores.map(String.init) ?? "—") / \(monitor.machine.efficiencyCores.map(String.init) ?? "—")")
            InfoRow(title: "架构 · 内核", value: "\(monitor.machine.architecture ?? "—") · \(monitor.machine.kernel ?? "—")")
            InfoRow(title: "系统低电量模式", value: snapshot.systemLowPower ? "开启" : "关闭")
            InfoRow(title: "本次开机时间", value: Date().addingTimeInterval(-snapshot.uptime).formatted(date: .abbreviated, time: .shortened))
            note("热状态是 macOS 报告的系统等级，不是摄氏温度。")
        }
    }

    private func processList(memory: Bool) -> some View {
        let rows = memory ? monitor.snapshot.processes.sorted { $0.memory > $1.memory }.prefix(5)
                          : monitor.snapshot.processes.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(5)
        return VStack(alignment: .leading, spacing: 8) {
            Text(memory ? "内存占用前五 · RSS" : "CPU 占用前五").font(.system(size: 11, weight: .semibold))
            if rows.isEmpty { note("正在采集可读取的进程…") }
            ForEach(Array(rows)) { process in
                InfoRow(title: process.name.isEmpty ? "PID \(process.id)" : process.name,
                        value: memory ? DisplayFormat.bytes(process.memory) : DisplayFormat.percent(process.cpu))
            }
            if memory { note("RSS 包含共享页面，不能将进程 RSS 相加作为整机已用内存。") }
        }
    }

    private var networkDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("互联网出口").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { monitor.refreshEgress(force: true) } label: {
                    Label(monitor.egress.loading ? "查询中" : "刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(Metric.network.tint).disabled(monitor.egress.loading || !monitor.publicIPEnabled)
            }
            InfoRow(title: "公网 IPv4", value: egressText(monitor.egress.ipv4), copyValue: monitor.egress.ipv4.address)
            InfoRow(title: "公网 IPv6", value: egressText(monitor.egress.ipv6), copyValue: monitor.egress.ipv6.address)
            if !monitor.publicIPEnabled { Button("在设置中管理在线查询", action: openSettings).font(.caption) }
            ForEach([("IPv4", monitor.egress.ipv4), ("IPv6", monitor.egress.ipv6)], id: \.0) { family, result in
                if let country = result.country {
                    InfoRow(title: "\(family) 归属地", value: country.flag + " " + country.name)
                    InfoRow(title: "\(family) 网络提供商", value: country.isp ?? "未知")
                    if let asn = country.asn { InfoRow(title: "\(family) 自治系统", value: "AS\(asn)") }
                } else if result.address != nil { InfoRow(title: "\(family) 归属地", value: "未能确认") }
            }
            if let date = monitor.egress.checkedAt {
                Text("ipify / ipwho.is · 查询于 \(date.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            note("HTTPS 请求出口，可能经过代理或 VPN。国旗表示 IP 数据库归属地。")
            Divider().opacity(0.5)
            DetailPair("下载", DisplayFormat.rate(snapshot.network?.download), "上传", DisplayFormat.rate(snapshot.network?.upload))
            HStack(spacing: 12) {
                Text("↓ 下载").foregroundStyle(Metric.network.tint)
                Text("↑ 上传").foregroundStyle(.indigo)
            }.font(.system(size: 10, weight: .medium))
            TrendChart(points: monitor.history, metric: \.download, color: Metric.network.tint, maximum: nil, secondaryMetric: \.upload)
            Divider().opacity(0.5)
            Text("本地连接").font(.system(size: 12, weight: .semibold))
            InfoRow(title: "系统主接口", value: snapshot.connection.primaryInterface ?? "未连接")
            ForEach(snapshot.connection.addresses, id: \.self) { address in
                InfoRow(title: address.contains(":") ? "主接口 IPv6" : "主接口 IPv4", value: address, copyValue: address)
            }
            ForEach(snapshot.network?.interfaces.filter { $0.name != snapshot.connection.primaryInterface && ($0.address != nil || !$0.ipv6Addresses.isEmpty) } ?? [], id: \.name) { interface in
                if let address = interface.address { InfoRow(title: "局域网 IPv4 · \(interface.name)", value: address, copyValue: address) }
                ForEach(interface.ipv6Addresses, id: \.self) { address in InfoRow(title: "本地 IPv6 · \(interface.name)", value: address, copyValue: address) }
            }
            InfoRow(title: "网关", value: snapshot.connection.router ?? "系统未提供")
            InfoRow(title: "DNS", value: snapshot.connection.dns.isEmpty ? "系统未提供" : snapshot.connection.dns.joined(separator: "\n"), copyValue: snapshot.connection.dns.isEmpty ? nil : snapshot.connection.dns.joined(separator: "\n"))
            InfoRow(title: "系统代理", value: snapshot.connection.proxy)
            if !snapshot.connection.tunnels.isEmpty {
                InfoRow(title: "活动隧道接口", value: snapshot.connection.tunnels.joined(separator: ", "))
                note("活动隧道也可能由系统服务创建，不表示全部流量经过 VPN。")
            }
            if let rate = snapshot.connection.wifiRate {
                Divider().opacity(0.5)
                Text("Wi-Fi 链路").font(.system(size: 12, weight: .semibold))
                DetailPair("协商发送速率", String(format: "%.0f Mbps", rate), "信道", snapshot.connection.wifiChannel.map(String.init) ?? "—")
                DetailPair("信号 RSSI", snapshot.connection.wifiRSSI.map { "\($0) dBm" } ?? "—", "噪声", snapshot.connection.wifiNoise.map { "\($0) dBm" } ?? "—")
                note("链路速率不是实际网速；Wi-Fi 信息每 30 秒更新。")
            }
            if let network = snapshot.network {
                ForEach(network.interfaces.filter { $0.address != nil || !$0.ipv6Addresses.isEmpty }, id: \.name) { interface in
                    InfoRow(title: "\(interface.name) 速度", value: "↓ \(DisplayFormat.rate(interface.download)) ↑ \(DisplayFormat.rate(interface.upload))")
                    InfoRow(title: "\(interface.name) MTU", value: interface.mtu.map { "\($0) 字节" } ?? "未知")
                    DetailPair("\(interface.name) 已接收", DisplayFormat.bytes(interface.received), "已发送", DisplayFormat.bytes(interface.sent))
                }
                Divider().opacity(0.5)
                DetailPair("接口累计接收", DisplayFormat.bytes(network.received), "接口累计发送", DisplayFormat.bytes(network.sent))
                note("速度与累计量按物理接口合计，避免重复计入隧道流量。")
            }
        }
    }

    private func egressText(_ result: EgressResult) -> String {
        if !monitor.publicIPEnabled { return "已关闭在线查询" }
        if monitor.egress.loading { return "正在确认出口…" }
        if let address = result.address { return (result.country?.flag ?? "🌐") + " " + address }
        return result.error ?? "尚未查询"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 4, height: 4)
            Text("实时 · \(monitor.activeInterval) 秒").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("活动监视器", action: openActivityMonitor).font(.system(size: 10)).foregroundStyle(.secondary)
            Button(action: quit) { Image(systemName: "power").font(.system(size: 11)).frame(width: 26, height: 26) }
                .foregroundStyle(.secondary).accessibilityLabel("退出 MacStatus")
        }.buttonStyle(.plain).padding(.horizontal, 15).padding(.bottom, 6).padding(.top, 2)
    }
}

private struct CardSurface: ViewModifier {
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(scheme == .dark ? 0.70 : 0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.08 : 0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.045), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.08 : 0.025), radius: 3, y: 2)
    }
}
private extension View {
    func cardSurface(tint: Color) -> some View { modifier(CardSurface(tint: tint)) }
}
private struct Ring: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 3)
            Circle().trim(from: 0, to: min(1, max(0, fraction))).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
        }.padding(2).accessibilityHidden(true)
    }
}
private struct MemoryComposition: View {
    let memory: MemoryReading?
    var body: some View {
        GeometryReader { geo in
            let total = Double(memory?.total ?? 1)
            HStack(spacing: 2) {
                ForEach(Array([memory?.apps ?? 0, memory?.wired ?? 0, memory?.compressed ?? 0].enumerated()), id: \.offset) { index, bytes in
                    Rectangle().fill([Color.purple, Color.blue, Color.pink][index])
                        .frame(width: max(0, (geo.size.width - 6) * min(1, Double(bytes) / total)))
                }
                Rectangle().fill(Color.primary.opacity(0.07))
            }.clipShape(Capsule())
        }.accessibilityHidden(true)
    }
}

private struct DetailPair: View {
    let firstTitle: String
    let firstValue: String
    let secondTitle: String
    let secondValue: String

    init(_ firstTitle: String, _ firstValue: String, _ secondTitle: String, _ secondValue: String) {
        self.firstTitle = firstTitle
        self.firstValue = firstValue
        self.secondTitle = secondTitle
        self.secondValue = secondValue
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            item(firstTitle, firstValue)
            item(secondTitle, secondValue)
        }
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoRow: View {
    let title: String
    let value: String
    var copyValue: String?
    @State private var copied = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled).monospacedDigit()
            if let copyValue {
                Button { copyText(copyValue); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("复制\(title)").accessibilityLabel("复制\(title)")
            }
        }.font(.system(size: 11)).onChange(of: copyValue) { _ in copied = false }
    }
}

private struct CapacityBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }.frame(height: 5).accessibilityHidden(true)
    }
}

private struct TrendChart: View {
    let points: [HistoryPoint]
    let metric: KeyPath<HistoryPoint, Double?>
    let color: Color
    let maximum: Double?
    var secondaryMetric: KeyPath<HistoryPoint, Double?>?

    var body: some View {
        let end = points.last?.date ?? Date()
        let segments = TrendSeries.segments(points: points, metric: metric, endingAt: end)
        let secondary = secondaryMetric.map { TrendSeries.segments(points: points, metric: $0, endingAt: end) } ?? []
        let upper = maximum ?? max((segments + secondary).flatMap { $0 }.map(\.value).max() ?? 1, 1024)
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let tail = segments.last?.last
                ZStack {
                    TrendTrace(segments: segments, end: end.timeIntervalSince1970, maximum: upper, filled: true)
                        .fill(LinearGradient(colors: [color.opacity(0.14), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    TrendTrace(segments: segments, end: end.timeIntervalSince1970, maximum: upper, filled: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if secondaryMetric != nil {
                        TrendTrace(segments: secondary, end: end.timeIntervalSince1970, maximum: upper, filled: false)
                            .stroke(Color.indigo.opacity(0.8), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    }
                    if let tail {
                        Circle().fill(color).frame(width: 4, height: 4)
                            .position(x: TrendSeries.horizontalPosition(date: tail.date, endingAt: end) * (geometry.size.width - 8) + 4,
                                      y: (1 - min(1, max(0, tail.value / upper))) * (geometry.size.height - 8) + 4)
                    } else {
                        Text("正在采集趋势").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 58).clipped()
            HStack {
                Text("2 分钟前")
                Spacer()
                Text("现在")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近两分钟趋势，从右侧开始显示已采集数据")
    }
}

private struct TrendTrace: Shape {
    let segments: [[TrendSample]]
    let end: TimeInterval
    let maximum: Double
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            for segment in segments where segment.count >= 2 {
                let locations = segment.map { sample in
                    CGPoint(x: TrendSeries.horizontalPosition(date: sample.date, endingAt: Date(timeIntervalSince1970: end)) * (rect.width - 8) + 4,
                            y: (1 - min(1, max(0, sample.value / maximum))) * (rect.height - 8) + 4)
                }
                guard let first = locations.first, let last = locations.last else { continue }
                path.move(to: first)
                for location in locations.dropFirst() { path.addLine(to: location) }
                if filled {
                    path.addLine(to: CGPoint(x: last.x, y: rect.height))
                    path.addLine(to: CGPoint(x: first.x, y: rect.height))
                    path.closeSubpath()
                }
            }
        }
    }
}
