import AppKit
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.parrrot", category: "StatusBar")

enum AppState {
    case idle
    case recording
    case processing
    case success
    case error
}

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var animTimer: Timer?
    private var animTime: TimeInterval = 0
    private var permCheckCounter: Int = 0

    private(set) var state: AppState = .idle

    // Animation constants (matching Python)
    private let animFPS: TimeInterval = 10
    private let breathPeriod: TimeInterval = 0.8
    private let jumpPeriod: TimeInterval = 0.5
    private let maxJump: CGFloat = 2.5
    private let scaleMin: CGFloat = 0.82
    private let scaleMax: CGFloat = 1.0
    private let successDuration: TimeInterval = 1.5
    private let errorDuration: TimeInterval = 2.0
    private let permCheckInterval = 50  // ticks (~5s at 10fps)

    // Menu items
    private var versionItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var microphoneItem: NSMenuItem!
    private var apiKeyItem: NSMenuItem!
    private var removeApiKeyItem: NSMenuItem!
    private var autoSubmitItem: NSMenuItem!

    // Callbacks
    var onAPIKeyEntered: ((String) -> Void)?
    var onRemoveAPIKey: (() -> Void)?
    var onRestart: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        statusItem.menu = menu
        updateIcon()
        startAnimation()
    }

    func setState(_ newState: AppState) {
        DispatchQueue.main.async {
            self.state = newState
            self.animTime = 0

            if newState == .success {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.successDuration) {
                    if self.state == .success { self.setState(.idle) }
                }
            } else if newState == .error {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.errorDuration) {
                    if self.state == .error { self.setState(.idle) }
                }
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildTime = buildTimestamp()
        versionItem = NSMenuItem(title: "parrrot \(version) · \(buildTime)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        accessibilityItem = NSMenuItem(title: "    Accessibility", action: #selector(onPermClick(_:)), keyEquivalent: "")
        accessibilityItem.target = self
        accessibilityItem.tag = 0
        menu.addItem(accessibilityItem)

        microphoneItem = NSMenuItem(title: "    Microphone", action: #selector(onPermClick(_:)), keyEquivalent: "")
        microphoneItem.target = self
        microphoneItem.tag = 1
        menu.addItem(microphoneItem)

        apiKeyItem = NSMenuItem(title: "    API Key", action: #selector(onAPIKeyStatusClick), keyEquivalent: "")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        menu.addItem(.separator())

        autoSubmitItem = NSMenuItem(title: "", action: #selector(onToggleAutoSubmit(_:)), keyEquivalent: "")
        autoSubmitItem.target = self
        menu.addItem(autoSubmitItem)

        menu.addItem(.separator())

        removeApiKeyItem = NSMenuItem(title: "Remove API key", action: #selector(onClickRemoveAPIKey), keyEquivalent: "")
        removeApiKeyItem.target = self
        menu.addItem(removeApiKeyItem)

        let restartItem = NSMenuItem(title: "Restart", action: #selector(onClickRestart), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        refreshPermissions()
    }

    func refreshPermissions() {
        let accOK = PermissionChecker.isAccessibilityGranted()
        let micOK = PermissionChecker.isMicrophoneGranted()
        let apiOK = !Settings.apiKey.isEmpty

        accessibilityItem.title = "\(accOK ? "✓" : "  ")  Accessibility"
        microphoneItem.title = "\(micOK ? "✓" : "  ")  Microphone"
        apiKeyItem.title = "\(apiOK ? "✓" : "  ")  API Key"
        autoSubmitItem.title = "\(Settings.autoSubmit ? "✓" : "  ")  Auto-submit (Enter)"
        removeApiKeyItem.isEnabled = apiOK
    }

    @objc private func onPermClick(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: PermissionChecker.openAccessibilitySettings()
        case 1: PermissionChecker.openMicrophoneSettings()
        default: break
        }
    }

    @objc private func onAPIKeyStatusClick() {
        DispatchQueue.main.async { [weak self] in self?.showAPIKeyAlert() }
    }

    private func showAPIKeyAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API Key"
        alert.informativeText = "Your API key is stored locally and used only for Whisper transcription."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "sk-..."
        if !Settings.apiKey.isEmpty {
            textField.stringValue = Settings.apiKey
        }
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let key = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                onAPIKeyEntered?(key)
                refreshPermissions()
            }
        }
    }

    @objc private func onToggleAutoSubmit(_ sender: NSMenuItem) {
        Settings.autoSubmit.toggle()
        refreshPermissions()
    }

    @objc private func onClickRemoveAPIKey() {
        onRemoveAPIKey?()
        refreshPermissions()
    }

    @objc private func onClickRestart() {
        onRestart?()
    }

    // MARK: - Animation

    private func startAnimation() {
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / animFPS, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        animTime += 1.0 / animFPS
        permCheckCounter += 1

        if permCheckCounter >= permCheckInterval {
            permCheckCounter = 0
            refreshPermissions()
        }

        updateIcon()
    }

    private func updateIcon() {
        let image: NSImage
        switch state {
        case .idle:
            image = IconDrawer.idle()
        case .recording:
            let phase = 0.5 + 0.5 * sin(animTime / breathPeriod * 2 * .pi)
            let scale = scaleMin + (scaleMax - scaleMin) * CGFloat(phase)
            image = IconDrawer.recording(scale: scale)
        case .processing:
            let offsetY = abs(sin(animTime / jumpPeriod * .pi)) * maxJump
            image = IconDrawer.processing(offsetY: offsetY)
        case .success:
            image = IconDrawer.success()
        case .error:
            image = IconDrawer.error()
        }
        statusItem.button?.image = image
    }

    private func buildTimestamp() -> String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return "?"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
