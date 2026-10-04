import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. It works in every app and needs no permission.
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a virtual key code, for example `kVK_ANSI_S`.
    ///   - modifiers: Carbon modifier flags, for example `cmdKey | optionKey`.
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        id = UInt32(Self.actions.count + 1)
        Self.actions[id] = action
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5344_4F47), id: id) // "SDOG"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            // Carbon calls the handler on the main thread.
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &type, nil, nil)
    }
}
