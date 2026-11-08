import AppKit
import Carbon

/// A global key combination as Carbon registers it, with the key's label as
/// typed when it was recorded.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier bits (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
    var modifiers: UInt32
    var key: String

    static let openPanelDefault = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Space")
    static let dictateDefault = KeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), key: "V")

    /// `⌃⌥Space`, in the order macOS menus use.
    var display: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    /// `Control–Option–Space`, for help and VoiceOver.
    var spoken: String {
        ([(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1) + [key]).joined(separator: "–")
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil unless Control, Option or Command is held, or the key is a function
    /// key: a Shift-only or bare letter would take over ordinary typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let functionKey = Self.functionKeys[Int(event.keyCode)]
        guard !flags.intersection([.control, .option, .command]).isEmpty || functionKey != nil else { return nil }
        guard let key = functionKey ?? Self.specialKeys[Int(event.keyCode)]
                ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), key: key)
    }

    /// The same keys are the same shortcut whatever label the layout gave them.
    static func == (a: KeyShortcut, b: KeyShortcut) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }

    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && UInt32(event.keyCode) == keyCode
            && KeyShortcut(event: event)?.modifiers == modifiers
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// What a global shortcut does. Each has its own Settings row and preference.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case openPanel
    case dictate

    var id: String { rawValue }
    var key: String { "notch.shortcut.\(rawValue)" }
    var hotKeyID: UInt32 { self == .openPanel ? 1 : 2 }
    var defaultShortcut: KeyShortcut { self == .openPanel ? .openPanelDefault : .dictateDefault }
    var title: String { self == .openPanel ? "Open the notch" : "Dictate a new session" }

    /// A cleared shortcut is stored as empty data, so it stays off instead of
    /// returning to the default.
    func load(_ defaults: UserDefaults) -> KeyShortcut? {
        guard let data = defaults.data(forKey: key) else { return defaultShortcut }
        return try? JSONDecoder().decode(KeyShortcut.self, from: data)
    }

    func save(_ shortcut: KeyShortcut?, _ defaults: UserDefaults) {
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }
}

/// What a key typed into a Settings recorder does.
enum ShortcutRecording: Equatable {
    case cancel
    /// Turns the shortcut off.
    case clear
    case set(KeyShortcut)
    /// Keeps recording and shows why the key was refused.
    case refuse(String)

    /// Escape cancels and a bare Delete clears; anything else must be a valid
    /// combination no other action uses.
    static func decide(_ event: NSEvent, for action: ShortcutAction, current: (ShortcutAction) -> KeyShortcut?) -> ShortcutRecording {
        let bare = event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
        if bare && Int(event.keyCode) == kVK_Escape { return .cancel }
        if bare && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) { return .clear }
        guard let shortcut = KeyShortcut(event: event) else { return .refuse("Add ⌃, ⌥ or ⌘") }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && current($0) == shortcut }) {
            return .refuse("Used by \(other.title)")
        }
        return .set(shortcut)
    }
}

/// Registering a chosen shortcut does not require global keyboard monitoring.
@MainActor
final class CompanionHotKeys {
    private var handlerRef: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            let hotKeys = Unmanaged<CompanionHotKeys>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard let action = hotKeys.actions[id.id] else { return OSStatus(eventNotHandledErr) }
                action()
                return noErr
            }
        }, 1, &eventType, context, &handlerRef)
    }

    /// Replaces the shortcut under `id`; false when macOS refused it (another
    /// app holds the combination).
    @discardableResult
    func register(_ id: UInt32, _ shortcut: KeyShortcut?, action: @escaping () -> Void) -> Bool {
        unregister(id)
        guard let shortcut, handlerRef != nil else { return shortcut == nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4E434D50, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        hotKeys[id] = ref
        actions[id] = action
        return true
    }

    func unregister(_ id: UInt32) {
        if let ref = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    func unregisterAll() {
        for id in Array(hotKeys.keys) { unregister(id) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
