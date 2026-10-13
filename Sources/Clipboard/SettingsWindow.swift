import AppKit
import ServiceManagement

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private let loginItems: LoginItemController
    private let loginToggle = NSButton(checkboxWithTitle: "开机自启（登录后启动）", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let recorder = ShortcutRecorderButton()
    private let limit = NSPopUpButton(frame: .zero, pullsDown: false)
    private let error = NSTextField(wrappingLabelWithString: "")
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    var onShortcut: ((Shortcut) -> String?)?
    var onLimit: ((Int) -> String?)?
    var onRecording: ((Bool) -> Void)?
    var onWillShow: (() -> Void)?
    init(settings: Settings, loginItems: LoginItemController = LoginItemController()) {
        self.settings = settings
        self.loginItems = loginItems
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "剪贴板设置"
        window.minSize = NSSize(width: 480, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        loginToggle.target = self; loginToggle.action = #selector(changeLoginItem)
        let startup = NSStackView(views: [loginToggle, NSView(),
            NSButton(title: "系统登录项…", target: self, action: #selector(openLoginSettings))])
        startup.orientation = .horizontal; startup.alignment = .centerY; startup.spacing = 12
        loginStatus.font = .systemFont(ofSize: 12)
        recorder.bezelStyle = .rounded
        recorder.target = recorder; recorder.action = #selector(ShortcutRecorderButton.beginRecording)
        recorder.onRecordingChanged = { [weak self] in self?.onRecording?($0) }
        recorder.onShortcut = { [weak self] shortcut in
            guard let self else { return false }
            let result = self.onShortcut?(shortcut)
            self.error.stringValue = result ?? ""
            self.recorder.shortcut = self.settings.shortcut
            return result == nil
        }
        limit.addItems(withTitles: ["50 条", "100 条", "200 条", "500 条", "1000 条"])
        limit.target = self; limit.action = #selector(changeLimit)
        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetShortcut))
        let row = NSStackView(views: [NSTextField(labelWithString: "唤起快捷键"), recorder, reset])
        let capacity = NSStackView(views: [NSTextField(labelWithString: "历史条数上限"), limit])
        let hint = NSTextField(wrappingLabelWithString: "点击快捷键后按下新组合，需包含 ⌘、⌥ 或 ⌃；Esc 取消。")
        let privacy = NSTextField(wrappingLabelWithString: "历史仅保存在本机，不联网。单条文本上限 100 KiB，单张图片上限 5 MiB / 2000 万像素，文本与图片总量上限 20 MiB。超出容量时删除最旧记录。暂停期间的复制不会补录。")
        let version = AppVersion.current
        let versionValue = NSTextField(labelWithString: version.displayName)
        versionValue.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        let buildSource = NSTextField(wrappingLabelWithString: version.sourceDescription)
        let versionRow = NSStackView(views: [NSTextField(labelWithString: "当前版本"), versionValue,
                                             NSView(), NSButton(title: "检查更新", target: self,
                                                                action: #selector(checkForUpdates))])
        versionRow.orientation = .horizontal; versionRow.alignment = .centerY; versionRow.spacing = 12
        buildSource.font = .systemFont(ofSize: 11); buildSource.textColor = .secondaryLabelColor
        updateStatus.font = .systemFont(ofSize: 11); updateStatus.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 12); privacy.textColor = .secondaryLabelColor
        error.textColor = .systemRed; error.font = .systemFont(ofSize: 12)
        let versionHeading = NSTextField(labelWithString: "版本")
        versionHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [startup, loginStatus, row, hint, capacity, privacy, separator, versionHeading,
                                       versionRow, buildSource, updateStatus, error])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        for view in [startup, loginStatus, hint, privacy, separator, buildSource, updateStatus, error] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func show() {
        onWillShow?()
        refreshLoginItem()
        recorder.shortcut = settings.shortcut; recorder.title = settings.shortcut.displayName
        limit.selectItem(at: [50, 100, 200, 500, 1000].firstIndex(of: settings.limit) ?? 2)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func showError(_ message: String) { error.stringValue = message; show() }
    func windowWillClose(_ notification: Notification) { recorder.stopRecording() }
    func windowDidBecomeKey(_ notification: Notification) { refreshLoginItem() }
    func windowDidResignKey(_ notification: Notification) { recorder.stopRecording() }
    private func refreshLoginItem() {
        loginItems.refresh()
        loginToggle.state = loginItems.isRequested ? .on : .off
        loginStatus.stringValue = loginItems.errorMessage ?? loginItems.statusText
        loginStatus.textColor = loginItems.errorMessage == nil ? .secondaryLabelColor : .systemRed
    }
    @objc private func changeLoginItem() {
        loginItems.setEnabled(loginToggle.state == .on)
        refreshLoginItem()
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func changeLimit() {
        error.stringValue = onLimit?([50, 100, 200, 500, 1000][limit.indexOfSelectedItem]) ?? ""
        limit.selectItem(at: [50, 100, 200, 500, 1000].firstIndex(of: settings.limit) ?? 2)
    }
    @objc private func checkForUpdates() {
        updateStatus.stringValue = AppVersion.current.updateStatus
    }
    @objc private func resetShortcut() {
        recorder.stopRecording()
        error.stringValue = onShortcut?(.default) ?? ""
        recorder.shortcut = settings.shortcut; recorder.title = settings.shortcut.displayName
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut = .default
    var onShortcut: ((Shortcut) -> Bool)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        guard !isRecording else { return }
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = "请按下快捷键…"
        onRecordingChanged?(true)
    }
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        title = shortcut.displayName
        onRecordingChanged?(false)
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopRecording(); return }
        if onShortcut?(Shortcut(event: event)) == true { stopRecording() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
}
