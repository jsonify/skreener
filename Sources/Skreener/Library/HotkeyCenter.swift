import AppKit
import Carbon.HIToolbox

struct Hotkey {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
    /// Character shown in menus for this key.
    let keyEquivalent: String

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyEquivalent.uppercased()
    }
}

enum HotkeyAction: UInt32, CaseIterable {
    case captureArea = 1, captureFullscreen, captureWindow, capturePreviousArea, captureText, toggleRecording, pickColor, watchArea

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureWindow: "Capture Window…"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureText: "Capture Text (OCR)"
        case .toggleRecording: "Record Screen…"
        case .pickColor: "Pick Color From Screen"
        case .watchArea: "Watch Area for Changes"
        }
    }

    /// ⌘⇧ + digit, like CleanShot. macOS's own ⌘⇧3/4/5/6 screenshot shortcuts must be turned off
    /// in System Settings › Keyboard › Keyboard Shortcuts › Screenshots, or they take precedence.
    var defaultHotkey: Hotkey {
        let mods: NSEvent.ModifierFlags = [.command, .shift]
        switch self {
        case .captureArea: return Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: mods, keyEquivalent: "4")
        case .captureFullscreen: return Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: mods, keyEquivalent: "3")
        case .captureWindow: return Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: mods, keyEquivalent: "5")
        case .capturePreviousArea: return Hotkey(keyCode: UInt32(kVK_ANSI_7), modifiers: mods, keyEquivalent: "7")
        case .captureText: return Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: mods, keyEquivalent: "2")
        case .toggleRecording: return Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: mods, keyEquivalent: "6")
        case .pickColor: return Hotkey(keyCode: UInt32(kVK_ANSI_8), modifiers: mods, keyEquivalent: "8")
        case .watchArea: return Hotkey(keyCode: UInt32(kVK_ANSI_9), modifiers: mods, keyEquivalent: "9")
        }
    }
}

/// Registers system-wide hotkeys through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private static let signature: OSType = 0x534B524E // 'SKRN'

    func register(_ hotkey: Hotkey, id: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        } else {
            NSLog("Skreener: could not register hotkey \(hotkey.displayString) (status \(status))")
        }
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
