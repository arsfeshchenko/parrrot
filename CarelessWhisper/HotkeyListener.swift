import Cocoa
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Hotkey")

final class HotkeyListener {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyWatchdogTimer: Timer?
    private(set) var isHeld = false

    // Right Option key code = 61
    private let rightOptionKeyCode: UInt16 = 61

    private var retryCount = 0
    private let maxRetries = 5

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
                return listener.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            retryCount += 1
            if retryCount <= maxRetries {
                let delay = Double(retryCount) * 1.0
                log.warning("Event tap creation failed, retrying in \(delay)s (\(self.retryCount)/\(self.maxRetries))")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.start()
                }
            } else {
                log.error("Failed to create event tap after \(self.maxRetries) retries. Check Accessibility permissions.")
            }
            return
        }

        retryCount = 0
        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("Event tap started")
    }

    func stop() {
        stopKeyWatchdog()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled by system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Escape cancels recording
        if type == .keyDown && isHeld {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 53 { // Escape
                log.info("Escape pressed, cancelling recording")
                isHeld = false
                stopKeyWatchdog()
                DispatchQueue.main.async { self.onCancel?() }
                return nil // Consume the event
            }
        }

        // Flags changed — detect Right Option
        if type == .flagsChanged {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            if keyCode == rightOptionKeyCode {
                let optionDown = flags.contains(.maskAlternate)
                if optionDown && !isHeld {
                    isHeld = true
                    startKeyWatchdog()
                    DispatchQueue.main.async { self.onPress?() }
                } else if !optionDown && isHeld {
                    isHeld = false
                    stopKeyWatchdog()
                    DispatchQueue.main.async { self.onRelease?() }
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Key Watchdog

    private func startKeyWatchdog() {
        stopKeyWatchdog()
        // Grace period of 1s, then poll every 0.5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.isHeld else { return }
            self.keyWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.pollKeyState()
            }
        }
    }

    private func stopKeyWatchdog() {
        keyWatchdogTimer?.invalidate()
        keyWatchdogTimer = nil
    }

    private func pollKeyState() {
        guard isHeld else {
            stopKeyWatchdog()
            return
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let optionHeld = flags.contains(.maskAlternate)
        if !optionHeld {
            log.warning("Key watchdog: Option key released but event tap missed it")
            isHeld = false
            stopKeyWatchdog()
            DispatchQueue.main.async { self.onRelease?() }
        }
    }
}
