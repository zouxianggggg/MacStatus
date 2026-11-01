import Foundation
import Combine
import Darwin

final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var lowPower = UserDefaults.standard.bool(forKey: "lowPower")
    @Published private(set) var egress = EgressReading()
    @Published private(set) var menuSpeedMode = MenuSpeedMode(rawValue: UserDefaults.standard.string(forKey: "menuSpeedMode") ?? "") ?? .hidden
    @Published private(set) var cardLayout = CardLayout(order: UserDefaults.standard.stringArray(forKey: "cardOrder") ?? [], hidden: UserDefaults.standard.stringArray(forKey: "hiddenCards") ?? [])
    @Published private(set) var publicIPEnabled = UserDefaults.standard.object(forKey: "publicIPEnabled") as? Bool ?? true
    var onMenuNetwork: ((NetworkReading?) -> Void)?
    let machine: MachineInfo
    private let collector: SystemCollector
    private let queue = DispatchQueue(label: "MacStatus.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var points: [HistoryPoint] = []
    private var visible = false
    private var sleeping = false
    private var economical: Bool
    private var egressTask: Task<Void, Never>?
    private var egressGeneration = 0
    private var networkExpanded = false
    private var panelVisible = false
    private var samplingSpeedMode: MenuSpeedMode = .hidden
    private var expandedMetric: String?
    private var samplingPolicy = SamplingPolicy()
    private lazy var ipSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    var activeInterval: Int { lowPower ? 5 : 2 }
    var backgroundInterval: Int { menuSpeedMode == .hidden ? (lowPower ? 30 : 10) : activeInterval }

    init() {
        collector = SystemCollector()
        machine = collector.machine
        economical = UserDefaults.standard.bool(forKey: "lowPower")
        samplingSpeedMode = menuSpeedMode
        queue.async { [weak self] in
            self?.sample()
            self?.schedule()
        }
    }

    func setVisible(_ value: Bool) {
        panelVisible = value
        if !value { cancelEgress() }
        queue.async { [weak self] in
            guard let self else { return }
            self.visible = value
            if !value { self.collector.endDetails() }
            if value && !self.sleeping { self.sample() }
            self.schedule()
        }
    }

    func setExpandedMetric(_ value: String?) {
        queue.async { [weak self] in
            self?.expandedMetric = value
            if let self, self.visible { self.sample() }
        }
        setNetworkExpanded(value == "network")
    }

    func setMenuSpeedMode(_ value: MenuSpeedMode) {
        menuSpeedMode = value
        UserDefaults.standard.set(value.rawValue, forKey: "menuSpeedMode")
        queue.async { [weak self] in
            self?.samplingSpeedMode = value
            self?.sample()
            self?.schedule()
        }
    }

    private func setNetworkExpanded(_ value: Bool) {
        networkExpanded = value
        if !value { cancelEgress() }
    }

    func refreshEgress(force: Bool = false) {
        let identity = snapshot.connection.identity
        guard panelVisible, networkExpanded, publicIPEnabled, force || egress.needsRefresh(for: identity), !egress.loading else { return }
        cancelEgress()
        egress = EgressReading(loading: true, identity: identity)
        let generation = egressGeneration
        let session = ipSession
        egressTask = Task { @MainActor [weak self] in
            async let v4 = EgressQuery.fetch(family: AF_INET, session: session)
            async let v6 = EgressQuery.fetch(family: AF_INET6, session: session)
            let result = await (v4, v6)
            guard !Task.isCancelled, let self, self.egressGeneration == generation else { return }
            self.egress = EgressReading(ipv4: result.0, ipv6: result.1, checkedAt: Date(), identity: identity)
            self.egressTask = nil
        }
    }

    private func cancelEgress() {
        egressGeneration += 1
        egressTask?.cancel()
        egressTask = nil
        if egress.loading { egress.loading = false }
    }

    func setLowPower(_ value: Bool) {
        lowPower = value
        UserDefaults.standard.set(value, forKey: "lowPower")
        queue.async { [weak self] in
            self?.economical = value
            self?.schedule()
        }
    }

    func setPublicIPEnabled(_ value: Bool) {
        publicIPEnabled = value
        UserDefaults.standard.set(value, forKey: "publicIPEnabled")
        if value { refreshEgress() }
        else { cancelEgress(); egress = EgressReading(identity: snapshot.connection.identity) }
    }

    func setMetricVisible(_ metric: Metric, visible: Bool) {
        var layout = cardLayout
        if visible { layout.hidden.remove(metric) } else { layout.hidden.insert(metric) }
        saveCardLayout(layout)
    }

    func moveMetric(_ metric: Metric, by offset: Int) {
        var layout = cardLayout
        layout.move(metric, by: offset)
        saveCardLayout(layout)
    }

    private func saveCardLayout(_ layout: CardLayout) {
        cardLayout = layout
        UserDefaults.standard.set(layout.order.map(\.rawValue), forKey: "cardOrder")
        UserDefaults.standard.set(layout.hidden.map(\.rawValue), forKey: "hiddenCards")
        if let expandedMetric, layout.hidden.contains(where: { $0.rawValue == expandedMetric }) { setExpandedMetric(nil) }
    }

    func restoreDefaults() {
        setLowPower(false)
        setMenuSpeedMode(.hidden)
        setPublicIPEnabled(true)
        saveCardLayout(CardLayout())
    }

    func setSleeping(_ value: Bool) {
        if value { cancelEgress() }
        queue.async { [weak self] in
            guard let self else { return }
            self.sleeping = value
            self.collector.resetBaselines()
            self.samplingPolicy.reset()
            if !value { self.sample() }
            self.schedule()
        }
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard !sleeping else { return }
        let seconds = SamplingPolicy.interval(visible: visible, showsSpeed: samplingSpeedMode != .hidden, lowPower: economical)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    private func sample() {
        guard !sleeping else { return }
        let work = samplingPolicy.next(at: ProcessInfo.processInfo.systemUptime, visible: visible, showsSpeed: samplingSpeedMode != .hidden, lowPower: economical)
        if work == .networkOnly {
            let network = collector.sampleNetwork()
            DispatchQueue.main.async { [weak self] in self?.onMenuNetwork?(network) }
            return
        }
        let value = collector.sample(detailed: visible, expanded: expandedMetric)
        points.append(HistoryPoint(date: value.date, cpu: value.cpu?.total,
                                   memory: value.memory?.fraction, download: value.network?.download, upload: value.network?.upload))
        // At most fifteen minutes and 450 points, including when the panel is open.
        points.removeAll { $0.date < value.date.addingTimeInterval(-900) }
        if points.count > 450 { points.removeFirst(points.count - 450) }
        if samplingSpeedMode != .hidden {
            DispatchQueue.main.async { [weak self] in self?.onMenuNetwork?(value.network) }
        }
        guard visible else { return }
        let history = points
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = value
            self?.history = history
            if let self, self.egress.identity != value.connection.identity {
                self.cancelEgress()
                self.egress = EgressReading(identity: value.connection.identity)
            }
            if let self, self.networkExpanded { self.refreshEgress() }
        }
    }
}
