import Carbon.HIToolbox
import Foundation

protocol HotKeyBackend {
    /// 可替代注册服务，使冲突与替换测试不占用用户的真实快捷键。
    func register(keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ reference: EventHotKeyRef)
}

struct CarbonHotKeyBackend: HotKeyBackend {
    func register(keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &reference)
        return (status, reference)
    }
    func unregister(_ reference: EventHotKeyRef) { UnregisterEventHotKey(reference) }
}

/// 系统全局快捷键；默认 ⌘⇧V，使用系统事件回调，不持续扫描键盘。
final class GlobalHotKey {
    private let backend: HotKeyBackend
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredKey: (keyCode: UInt32, modifiers: UInt32)?
    fileprivate var activeID: UInt32 = 0
    var onTrigger: (() -> Void)?

    init(backend: HotKeyBackend = CarbonHotKeyBackend()) { self.backend = backend }

    fileprivate static let signature: FourCharCode = 0x434C_5031 // "CLP1"

    static var defaultKeyCode: UInt32 { UInt32(kVK_ANSI_V) }
    static var defaultModifiers: UInt32 { UInt32(cmdKey | shiftKey) }

    static func failureDescription(_ status: OSStatus) -> String {
        switch status {
        case OSStatus(eventHotKeyExistsErr): return "快捷键已被占用，请选择其他组合。"
        case OSStatus(eventInternalErr): return "无法连接系统快捷键服务，请从正常的桌面会话启动应用。"
        default: return "无法注册快捷键（错误码：\(status)）。"
        }
    }

    @discardableResult
    func register(keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
                  modifiers: UInt32 = GlobalHotKey.defaultModifiers) -> OSStatus {
        if let registeredKey, registeredKey.keyCode == keyCode, registeredKey.modifiers == modifiers {
            return noErr
        }

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let userData = Unmanaged.passUnretained(self).toOpaque()
            let installStatus = InstallEventHandler(GetEventDispatcherTarget(),
                                                    hotKeyEventHandler,
                                                    1,
                                                    &eventType,
                                                    userData,
                                                    &handlerRef)
            guard installStatus == noErr else {
                unregister()
                return installStatus
            }
        }

        // 先注册新组合，成功后才注销旧组合，保证失败时旧快捷键仍有效。
        let nextID = activeID &+ 1
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        let (status, replacement) = backend.register(keyCode: keyCode, modifiers: modifiers, id: id)

        if status != noErr {
            NSLog("Clipboard: RegisterEventHotKey failed with status \(status)")
            if hotKeyRef == nil { unregister() }
        } else {
            if let hotKeyRef { backend.unregister(hotKeyRef) }
            hotKeyRef = replacement
            registeredKey = (keyCode, modifiers)
            activeID = nextID
        }
        return status
    }

    func unregister() {
        registeredKey = nil
        activeID &+= 1
        if let hotKeyRef {
            backend.unregister(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, userData -> OSStatus in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()

    var hkID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hkID)
    guard status == noErr, hkID.signature == GlobalHotKey.signature,
          hkID.id == me.activeID else {
        return OSStatus(eventNotHandledErr)
    }

    DispatchQueue.main.async {
        // 已排队的旧按键不能在快捷键切换或注销后重新触发历史窗口。
        guard hkID.id == me.activeID else { return }
        me.onTrigger?()
    }
    return noErr
}
