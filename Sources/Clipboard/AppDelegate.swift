import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings: Settings
    private let hotKey = GlobalHotKey()
    private let monitor: ClipboardMonitor
    private let smokeTest: Bool
    private let historyWindow = HistoryWindow()
    private lazy var settingsWindow = SettingsWindow(settings: settings)
    private var store: HistoryStore?
    private var snippetStore: SnippetStore?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var showItem: NSMenuItem?
    private var settingsItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var previousApplication: NSRunningApplication?
    private var reportedStorageError = false
    private var recordingShortcut = false

    override init() {
        smokeTest = CommandLine.arguments.contains("--smoke-test")
        settings = Settings(defaults: smokeTest ? UserDefaults(suiteName: "clipboard.smoke.\(UUID().uuidString)")! : .standard)
        monitor = ClipboardMonitor(pasteboard: smokeTest ? NSPasteboard.withUniqueName() : .general)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        let root = smokeTest ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = root
            .appendingPathComponent("com.zhuzhongqian.clipboard", isDirectory: true)
            .appendingPathComponent("history.json")
        do { store = try HistoryStore(url: path, limit: settings.limit) }
        catch { DispatchQueue.main.async { self.reportStorageError(error) } }
        do {
            snippetStore = try SnippetStore(url: path.deletingLastPathComponent().appendingPathComponent("snippets.json"))
            configureSnippets()
        } catch {
            DispatchQueue.main.async { self.showError("无法加载常用文本", "原文件已保留：\(error.localizedDescription)") }
        }
        installMenu()
        configureSettings()
        monitor.paused = settings.paused
        monitor.onContent = { [weak self] content in self?.record(content) }
        monitor.start()
        historyWindow.onCopy = { [weak self] entry in
            guard let self else { return }
            guard self.monitor.copy(entry.content) else {
                self.showError("复制失败", "无法写入系统剪贴板，请重试。"); return
            }
            if !self.settings.paused { self.record(entry.content) }
            self.dismissHistory()
        }
        historyWindow.onDismiss = { [weak self] in self?.restoreFocus() }
        hotKey.onTrigger = { [weak self] in
            guard let self, !self.recordingShortcut, self.historyWindow.window?.attachedSheet == nil else { return }
            self.toggleHistory()
        }
        let result = smokeTest ? noErr : hotKey.register(keyCode: settings.shortcut.keyCode, modifiers: settings.shortcut.modifiers)
        if result != noErr {
            DispatchQueue.main.async { self.settingsWindow.showError(GlobalHotKey.failureDescription(result)) }
        }
        if smokeTest {
            // Exercise AppKit construction without changing the user's clipboard or preferences.
            historyWindow.show(entries: [])
            settingsWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let keyboardChecks = self.historyWindow.runSmokeChecks()
                self.showSettings()
                let settingsOnly = self.settingsWindow.window?.isVisible == true
                    && self.historyWindow.window?.isVisible == false
                self.settingsWindow.close()
                let staysHidden = self.historyWindow.window?.isVisible == false
                self.historyWindow.show(entries: [])
                let canReopen = self.historyWindow.window?.isVisible == true
                self.settingsWindow.showError("测试设置错误入口")
                let valid = keyboardChecks && self.statusItem?.button != nil && settingsOnly && staysHidden && canReopen
                    && self.settingsWindow.window?.isVisible == true && self.historyWindow.window?.isVisible == false
                print(valid ? "PASS: menu, settings/history isolation, common text add/edit/delete/search/copy, stable preview layout and scrolling" : "FAIL: AppKit smoke test")
                if !valid { exit(1) }
                NSApp.terminate(nil)
            }
        }
    }

    private func installApplicationMenu() {
        // AppKit routes standard editing shortcuts through the application menu.
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: "剪贴板", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "剪贴板")
        let quit = NSMenuItem(title: "退出剪贴板", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("撤销", NSSelectorFromString("undo:"), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "剪贴板历史")
        image?.isTemplate = true; item.button?.image = image
        let menu = NSMenu(); menu.delegate = self
        func add(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            entry.target = self; menu.addItem(entry); return entry
        }
        showItem = add("打开剪贴板历史", #selector(toggleHistory))
        pauseItem = add("暂停记录", #selector(togglePause))
        menu.addItem(.separator())
        settingsItem = add("设置…", #selector(showSettings), key: ",")
        clearItem = add("清空历史…", #selector(clearHistory))
        menu.addItem(.separator())
        _ = add("退出剪贴板", #selector(quit), key: "q")
        item.menu = menu; statusItem = item; refreshMenu()
    }
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
    private func refreshMenu() {
        let canOpenWindow = historyWindow.window?.attachedSheet == nil
        settingsItem?.isEnabled = canOpenWindow; clearItem?.isEnabled = canOpenWindow
        pauseItem?.title = settings.paused ? "恢复记录" : "暂停记录"
        statusItem?.button?.toolTip = "剪贴板历史（\(settings.shortcut.displayName)）\(settings.paused ? " · 已暂停" : "")"
        showItem?.title = "打开剪贴板历史（\(settings.shortcut.displayName)）"
    }
    private func configureSettings() {
        settingsWindow.onWillShow = { [weak self] in
            // Hide before activation: a floating panel can otherwise reappear over settings.
            self?.historyWindow.window?.orderOut(nil)
            self?.previousApplication = nil
        }
        settingsWindow.onShortcut = { [weak self] shortcut in
            guard let self else { return "应用已关闭" }
            guard shortcut.isValid else { return "请使用包含 ⌘、⌥ 或 ⌃ 的有效组合。" }
            let status = self.hotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
            guard status == noErr else { return GlobalHotKey.failureDescription(status) }
            self.settings.shortcut = shortcut; self.refreshMenu(); return nil
        }
        settingsWindow.onRecording = { [weak self] recording in
            guard let self else { return }
            self.recordingShortcut = recording
            if recording { self.hotKey.unregister() }
            else {
                let result = self.hotKey.register(keyCode: self.settings.shortcut.keyCode,
                                                 modifiers: self.settings.shortcut.modifiers)
                if result != noErr { self.settingsWindow.showError(GlobalHotKey.failureDescription(result)) }
            }
        }
        settingsWindow.onLimit = { [weak self] limit in
            guard let self, let store = self.store else { return "历史存储不可用。" }
            do {
                try store.trim(limit: limit); self.settings.limit = limit
                self.historyWindow.reload(store.history.entries); return nil
            } catch { return "无法保存容量设置：\(error.localizedDescription)" }
        }
    }
    private func configureSnippets() {
        guard let snippetStore else { return }
        historyWindow.reloadSnippets(snippetStore.snippets)
        historyWindow.onSaveSnippet = { [weak self] id, title, text in
            guard let self else { return "应用已关闭。" }
            do {
                try snippetStore.save(id: id, title: title, text: text)
                self.historyWindow.reloadSnippets(snippetStore.snippets)
                return nil
            } catch { return error.localizedDescription }
        }
        historyWindow.onDeleteSnippet = { [weak self] id in
            guard let self else { return "应用已关闭。" }
            do {
                try snippetStore.delete(id: id)
                self.historyWindow.reloadSnippets(snippetStore.snippets)
                return nil
            } catch { return error.localizedDescription }
        }
    }
    private func record(_ content: ClipboardContent) {
        guard let store else { return }
        do {
            try store.record(content, limit: settings.limit)
            historyWindow.reload(store.history.entries)
        } catch { reportStorageError(error) }
    }
    private func reportStorageError(_ error: Error) {
        guard !reportedStorageError else { return }
        reportedStorageError = true
        showError("无法保存剪贴板历史", "\(error.localizedDescription)\n已有历史文件保留在本机。请检查磁盘空间和文件权限后重启应用。")
    }
    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func toggleHistory() {
        if historyWindow.window?.isVisible == true { dismissHistory(); return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = frontmost }
        monitor.poll()
        historyWindow.show(entries: store?.history.entries ?? [])
    }
    private func dismissHistory() { historyWindow.window?.orderOut(nil); restoreFocus() }
    private func restoreFocus() {
        previousApplication?.activate(options: [])
        previousApplication = nil
    }
    @objc private func togglePause() {
        // Capture the latest copy before pausing; discard changes made while paused on resume.
        if !settings.paused { monitor.poll() }
        settings.paused.toggle(); monitor.paused = settings.paused; refreshMenu()
    }
    @objc private func showSettings() {
        guard historyWindow.window?.attachedSheet == nil else { return }
        settingsWindow.show()
    }
    @objc private func clearHistory() {
        guard let store, historyWindow.window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部历史？"
        alert.informativeText = "这将删除本机保存的全部记录，无法撤销。系统剪贴板中的当前内容会保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空历史")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.clear(); monitor.discardCurrentChange(); historyWindow.reload([]) }
        catch { showError("清空失败", error.localizedDescription) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
