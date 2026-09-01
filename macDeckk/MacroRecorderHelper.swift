import Cocoa
import CoreGraphics

class MacroRecorderHelper {
    var onEvent: ((CGEvent) -> Void)?
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var fallbackMonitor: Any?

    func start() {
        stop()
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let helper = Unmanaged<MacroRecorderHelper>.fromOpaque(refcon).takeUnretainedValue()
            
            if type == .keyDown {
                DispatchQueue.main.async {
                    helper.onEvent?(event)
                }
                return nil // Swallow keyDown event so it doesn't type into text fields or trigger app actions
            }
            return Unmanaged.passRetained(event)
        }
        
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        
        if tap == nil {
            NSLog("PhoneDeck: Failed to create CGEvent tap.")
        }
        
        // ALWAYS setup the local monitor as a fallback!
        // If Secure Input is enabled by any app (e.g. 1Password, Terminal), macOS will silently block the CGEventTap.
        // The local monitor ensures that if the app is focused, keystrokes are still recorded.
        self.fallbackMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let cgEvent = event.cgEvent {
                DispatchQueue.main.async {
                    self?.onEvent?(cgEvent)
                }
            }
            return nil // Swallow locally
        }
        
        if let tap = tap {
            self.eventTap = tap
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                self.runLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                NSLog("PhoneDeck: Failed to create run loop source for CGEvent tap.")
            }
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            self.eventTap = nil
            self.runLoopSource = nil
        }
        if let monitor = fallbackMonitor {
            NSEvent.removeMonitor(monitor)
            self.fallbackMonitor = nil
        }
    }
}
