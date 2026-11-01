import AppKit
import SwiftUI
import Combine

@main
enum MacStatusApp {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--export-icon"), CommandLine.arguments.count > index + 1 {
            do { try StatusGlyph.writeAppIcon(to: CommandLine.arguments[index + 1]) }
            catch { fputs("Icon export failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let collector = SystemCollector()
            let metric = CommandLine.arguments.first(where: { $0.hasPrefix("--metric=") }).map { String($0.dropFirst(9)) }
            _ = collector.sample(detailed: true, expanded: metric)
            Thread.sleep(forTimeInterval: metric == "cpu" || metric == "memory" ? 5.2 : 2)
            let report = DiagnosticReport(machine: collector.machine, snapshot: collector.sample(detailed: true, expanded: metric))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        withExtendedLifetime(delegate) { app.run() }
    }
}

private struct DiagnosticReport: Codable {
    let machine: MachineInfo
    let snapshot: Snapshot
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: MonitorStore!
    private var observers: [NSObjectProtocol] = []
    private var previewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private lazy var loginItem = LoginItemStore()
    private var menuSubscription: AnyCancellable?
    private var menuNetwork: NetworkReading?
    private let statusContent = StatusContentView()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var menuTrackingDepth = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.macstatus.app").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }),
           let url = other.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            NSApp.terminate(nil)
            return
        }
        monitor = MonitorStore()
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 MacStatus", action: #selector(quit), keyEquivalent: "q").target = self
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            statusContent.frame = button.bounds
            statusContent.autoresizingMask = [.width, .height]
            button.addSubview(statusContent)
            button.setAccessibilityLabel("MacStatus 系统监控")
            button.toolTip = "MacStatus · 点击查看 Mac 状态"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        monitor.onMenuNetwork = { [weak self] value in self?.menuNetwork = value; self?.updateMenuSpeed() }
        menuSubscription = monitor.$menuSpeedMode.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenuSpeed() }
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 352, height: 378)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            if self?.settingsWindow != nil { self?.loginItem.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTrackingDepth += 1
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            if let self { self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1) }
        })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.monitor.setSleeping(true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.setSleeping(false)
        })
        // This is only used for manually verifying the actual popover after a build.
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel() }
        }
        if CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-dark") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 352, height: 378),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacStatus 界面预览"
            if CommandLine.arguments.contains("--preview-dark") { window.appearance = NSAppearance(named: .darkAqua) }
            window.contentViewController = makeDashboard()
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
            monitor.setVisible(true)
            NSApp.activate(ignoringOtherApps: true)
        }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        else if CommandLine.arguments.contains("--welcome") { showWelcome() }
        else if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }), !UserDefaults.standard.bool(forKey: "hasSeenWelcome") {
            showWelcome()
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开监控面板", action: #selector(showPanel), keyEquivalent: "")
            menu.addItem(withTitle: "打开活动监视器", action: #selector(openActivityMonitor), keyEquivalent: "")
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "使用引导", action: #selector(showWelcome), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 MacStatus", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    @objc private func showPanel() {
        guard let button = statusItem.button else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = makeDashboard()
        }
        monitor.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        button.window?.layoutIfNeeded()
        popover.show(relativeTo: StatusLayout.anchor(height: button.bounds.height), of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.title = "MacStatus"
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcomeWindow, welcomeWindow.isVisible { welcomeWindow.makeKeyAndOrderFront(nil) }
        else if let settingsWindow, settingsWindow.isVisible { settingsWindow.makeKeyAndOrderFront(nil) }
        else { showPanel() }
        return false
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        loginItem.refresh()
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil) }
        else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 532, height: 462), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MacStatus 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor, login: loginItem, showWelcome: { [weak self] in self?.showWelcome() }))
            settingsWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showWelcome() {
        popover.performClose(nil)
        if let welcomeWindow { welcomeWindow.makeKeyAndOrderFront(nil) }
        else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 496, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "欢迎使用 MacStatus"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: WelcomeView(finish: { [weak self] in
                self?.welcomeWindow?.close()
                self?.showPanel()
            }, openSettings: { [weak self] in
                self?.welcomeWindow?.close()
                self?.showSettings()
            }))
            welcomeWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidShow(_ notification: Notification) {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isInsidePanelOrButton(NSEvent.mouseLocation) else { return }
            self.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown, self.menuTrackingDepth == 0 else { return event }
            if !self.isInsidePanelOrButton(NSEvent.mouseLocation) { self.popover.performClose(nil) }
            return event
        }
    }

    private func isInsidePanelOrButton(_ point: NSPoint) -> Bool {
        if popover.contentViewController?.view.window?.frame.contains(point) == true { return true }
        guard let button = statusItem.button else { return false }
        return button.window?.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) == true
    }

    func popoverDidClose(_ notification: Notification) {
        removeClickMonitors()
        monitor.setVisible(previewWindow?.isVisible == true)
    }

    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === welcomeWindow { UserDefaults.standard.set(true, forKey: "hasSeenWelcome") }
        if window === previewWindow { monitor.setVisible(popover.isShown) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsWindow?.isVisible == false { self.settingsWindow = nil }
            if self.welcomeWindow?.isVisible == false { self.welcomeWindow = nil }
            if self.previewWindow?.isVisible == false { self.previewWindow = nil }
        }
    }

    private func makeDashboard() -> NSViewController {
        NSHostingController(rootView: DashboardView(monitor: monitor,
            openActivityMonitor: { [weak self] in self?.openActivityMonitor() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) },
            resizePanel: { [weak self] height in
                self?.popover.contentSize = NSSize(width: 352, height: height)
                self?.previewWindow?.setContentSize(NSSize(width: 352, height: height))
            }))
    }

    private func updateMenuSpeed() {
        guard let button = statusItem?.button else { return }
        let text = monitor.menuSpeedMode.text(network: menuNetwork)
        let length = StatusLayout.width(for: monitor.menuSpeedMode)
        if statusItem.length != length {
            statusItem.length = length
            button.window?.layoutIfNeeded()
            if popover.isShown { popover.positioningRect = StatusLayout.anchor(height: button.bounds.height) }
        }
        statusContent.update(mode: monitor.menuSpeedMode, network: menuNetwork)
        button.setAccessibilityValue(text)
        button.toolTip = text.isEmpty ? "MacStatus · 点击查看 Mac 状态" : "MacStatus · 下载 \(DisplayFormat.rate(menuNetwork?.download)) · 上传 \(DisplayFormat.rate(menuNetwork?.upload))"
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        removeClickMonitors()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
