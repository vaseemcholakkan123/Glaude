import Carbon
import Foundation

/// Glaude's global shortcuts, through Carbon hot keys (no Accessibility permission).
final class Hotkeys {
    enum Action: UInt32, CaseIterable {
        case togglePanel = 1
        case jumpToSession = 2

        /// ⌃⌥G and ⌃⌥J.
        var keyCode: Int { self == .togglePanel ? kVK_ANSI_G : kVK_ANSI_J }
        var display: String { self == .togglePanel ? "⌃⌥G" : "⌃⌥J" }
        var keyEquivalent: String { self == .togglePanel ? "g" : "j" }
    }

    var onPress: ((Action) -> Void)?
    /// Shortcuts another app already holds.
    private(set) var unavailable: Set<Action> = []
    private var refs: [EventHotKeyRef] = []

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: id.id) { DispatchQueue.main.async { hotkeys.onPress?(action) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x474C_4144), id: action.rawValue)  // 'GLAD'
            let status = RegisterEventHotKey(UInt32(action.keyCode), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                unavailable.insert(action)
                NSLog("Glaude: shortcut \(action.display) is taken by another app")
            }
        }
    }
}
