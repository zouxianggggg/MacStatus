import Foundation
import Combine
import ServiceManagement

final class LoginItemStore: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?
    @Published private(set) var busy = false

    var enabled: Bool { status == .enabled }
    var statusText: String {
        switch status {
        case .enabled: return "已启用"
        case .notRegistered: return "未启用"
        case .requiresApproval: return "需要在系统设置中允许"
        case .notFound: return "系统未找到登录项，请检查应用安装位置"
        @unknown default: return "系统状态未知"
        }
    }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ value: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor [weak self] in
            do {
                if value { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self?.error = "无法更新开机启动：\(error.localizedDescription)" }
            self?.refresh()
            self?.busy = false
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
