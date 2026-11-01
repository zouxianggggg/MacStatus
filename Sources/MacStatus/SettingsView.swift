import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var login: LoginItemStore
    var showWelcome: () -> Void
    @State private var copiedReport = false
    @State private var confirmReset = false

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            cards.tabItem { Label("卡片", systemImage: "rectangle.stack") }
            privacy.tabItem { Label("隐私", systemImage: "hand.raised") }
            support.tabItem { Label("关于与反馈", systemImage: "info.circle") }
        }.padding(16).frame(width: 500, height: 430)
            .alert("恢复应用默认设置？", isPresented: $confirmReset) {
                Button("取消", role: .cancel) {}
                Button("恢复", role: .destructive) { monitor.restoreDefaults() }
            } message: { Text("将恢复卡片、采样、菜单栏和公网查询设置。系统开机启动设置保持原状。") }
    }
    private var general: some View {
        Form {
            Section {
                Picker("菜单栏显示", selection: Binding(get: { monitor.menuSpeedMode }, set: monitor.setMenuSpeedMode)) {
                    ForEach(MenuSpeedMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("采样策略", selection: Binding(get: { monitor.lowPower }, set: monitor.setLowPower)) {
                    Text("标准 · 查看时 2 秒").tag(false)
                    Text("节能 · 查看时 5 秒").tag(true)
                }
                Text("面板关闭后，完整指标每 \(monitor.lowPower ? 30 : 10) 秒采样。菜单栏网速单独按 \(monitor.activeInterval) 秒刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("登录时自动打开 MacStatus", isOn: Binding(get: { login.enabled }, set: login.setEnabled)).disabled(login.busy)
                HStack {
                    Text(login.statusText).foregroundStyle(.secondary)
                    Spacer()
                    if login.status == .requiresApproval { Button("前往系统设置", action: login.openSystemSettings) }
                }.font(.caption)
                if let error = login.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section {
                HStack {
                    Button("查看使用引导", action: showWelcome)
                    Spacer()
                    Button("恢复默认设置…") { confirmReset = true }
                }
            }
        }.formStyle(.grouped)
    }
    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让常用信息排在前面").font(.headline)
            Text("隐藏卡片不会影响菜单栏网速。详情仅在展开时采集。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(monitor.cardLayout.order.enumerated()), id: \.element) { index, metric in
                    HStack(spacing: 10) {
                        Image(systemName: metric.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Toggle(metric.title, isOn: Binding(get: { !monitor.cardLayout.hidden.contains(metric) }, set: { monitor.setMetricVisible(metric, visible: $0) }))
                        Spacer()
                        Button { monitor.moveMetric(metric, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("上移\(metric.title)")
                        Button { monitor.moveMetric(metric, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == monitor.cardLayout.order.count - 1).accessibilityLabel("下移\(metric.title)")
                    }.padding(10)
                    if index < monitor.cardLayout.order.count - 1 { Divider().padding(.horizontal, 10) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
        }.padding(18)
    }
    private var privacy: some View {
        Form {
            Section {
                Toggle("允许查询公网 IP 与归属地", isOn: Binding(get: { monitor.publicIPEnabled }, set: monitor.setPublicIPEnabled))
                Text("仅在打开网络详情时查询，结果在内存缓存 5 分钟。关闭此选项会取消查询并清除结果，本地网速和系统指标照常显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("在线查询说明") {
                Text("ipify 获取本应用 HTTPS 请求的出口 IP；ipwho.is 接收该公网 IP 并返回国别和网络提供商。国旗表示 IP 数据库归属地，不代表设备实际位置。")
                Text("不向这些服务附带本机指标、局域网地址或设备标识。代理与 VPN 可能影响查询结果。")
            }.font(.caption).foregroundStyle(.secondary)
            Section("本地数据") {
                Text("偏好保存在本机；趋势只留在内存，最多 15 分钟。没有账号、遥测或自动上传问题报告。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var support: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: StatusGlyph.header).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacStatus").font(.title2.weight(.semibold))
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · 第一阶段内测版")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("发现问题？").font(.headline)
            Text("复制基础环境报告，补充复现步骤后再分享给开发者。不会自动发送任何内容。")
            Button(copiedReport ? "已复制问题报告" : "复制问题报告") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
                copyText(SupportReport.make(machine: monitor.machine, lowPower: monitor.lowPower, menuMode: monitor.menuSpeedMode, version: version))
                copiedReport = true
            }
            Text("报告仅包含应用版本、系统版本、机型、芯片、内存和采样设置；不附带 IP、DNS、进程列表或文件路径。反馈地址将在公开测试前配置。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("原生监控 · 按需采样 · 本地优先").font(.caption).foregroundStyle(.tertiary)
        }.padding(24)
    }
}

struct WelcomeView: View {
    var finish: () -> Void
    var openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: StatusGlyph.header).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac 的状态，一眼看见").font(.system(size: 23, weight: .semibold))
                    Text("MacStatus 常驻顶部菜单栏，平时安静运行。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            step("menubar.rectangle", "点击顶部仪表图标", "六项状态浓缩为一行；点击卡片展开，再次点击收起。")
            step("arrow.up.arrow.down", "把网速放在菜单栏", "在设置中选择上传、下载或双向速度，宽度保持固定。")
            step("leaf", "只在需要时读取详情", "进程、核心和磁盘活动按展开模块采集；可随时启用节能模式。")
            Text("网络详情会使用 ipify 和 ipwho.is 查询公网 IP 与国别，可在隐私设置中关闭。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("先打开设置", action: openSettings)
                Spacer()
                Button("开始使用", action: finish).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 440)
    }
    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.blue).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func copyText(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
