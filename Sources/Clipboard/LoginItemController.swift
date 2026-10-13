import ServiceManagement

protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Read the system's state instead of persisting a separate, potentially stale preference.
final class LoginItemController {
    private let service: LoginItemService
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?

    init(service: LoginItemService = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: return "已开启，下次登录时启动"
        case .requiresApproval: return "等待系统批准，请在系统「登录项」中允许"
        case .notRegistered: return "未开启"
        case .notFound: return "系统未找到应用，请从完整的 Clipboard.app 运行"
        @unknown default: return "无法确定状态，请查看系统登录项"
        }
    }

    func refresh() { status = service.status }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        guard enabled != isRequested else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            errorMessage = "无法更新开机自启：\(error.localizedDescription)"
        }
        refresh()
    }
}
