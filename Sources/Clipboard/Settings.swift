import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), keyName: "V")
    static let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    var isValid: Bool {
        keyCode < 128 && ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
            && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
            && modifiers & ~Self.allowedModifiers == 0 && !keyName.isEmpty && keyName.count <= 24
            && !(keyCode == UInt32(kVK_Tab) && modifiers == UInt32(cmdKey))
    }

    var displayName: String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
         (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map { $0.1 }.joined() + keyName
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyName = keyName
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var mask: UInt32 = 0
        if event.modifierFlags.contains(.command) { mask |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mask |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mask |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mask |= UInt32(shiftKey) }
        modifiers = mask
        let names: [UInt16: String] = [48: "Tab", 49: "Space", 36: "Return", 76: "Enter",
            51: "Delete", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        keyName = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
    }
}

final class Settings {
    private let defaults: UserDefaults
    var limit: Int {
        didSet { defaults.set(limit, forKey: "historyLimit") }
    }
    var paused: Bool {
        didSet { defaults.set(paused, forKey: "paused") }
    }
    var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: "historyLimit")
        limit = (1...1000).contains(stored) ? stored : 200
        paused = defaults.bool(forKey: "paused")
        let saved = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        shortcut = saved?.isValid == true ? saved! : .default
    }
}
