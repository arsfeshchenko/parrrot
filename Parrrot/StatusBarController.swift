import AppKit
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "StatusBar")

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
    private let animFPS: TimeInterval = 60
    private let breathPeriod: TimeInterval = 0.675
    private let jumpPeriod: TimeInterval = 0.5
    private let maxJump: CGFloat = 2.5
    private let opacityMin: CGFloat = 0.5
    private let opacityMax: CGFloat = 1.0
    private let successDuration: TimeInterval = 1.5
    private let errorDuration: TimeInterval = 2.0
    private let permCheckInterval = 300  // ticks (~5s at 60fps)

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
        versionItem = NSMenuItem(title: "CarelessWhisper", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        versionItem.attributedTitle = {
            let para = NSMutableParagraphStyle()
            let title = NSMutableAttributedString(string: "CarelessWhisper\n", attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .paragraphStyle: para
            ])
            #if DEBUG
            let versionPrefix = "dev · "
            #else
            let versionPrefix = ""
            #endif
            let subtitle = NSAttributedString(string: "\(versionPrefix)\(version) · \(buildTime)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            title.append(subtitle)
            return title
        }()
        menu.addItem(versionItem)

        let hintItem = NSMenuItem(title: "Hold right ⌥ to record", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        hintItem.attributedTitle = {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let text = NSMutableAttributedString(string: "Hold right ⌥ Opt to record\n", attributes: attrs)
            text.append(NSAttributedString(string: "Press ⎋ Esc to cancel", attributes: attrs))
            return text
        }()
        menu.addItem(hintItem)

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

        let listenItem = NSMenuItem(title: "♪  Listen to Masterpiece", action: #selector(onClickListen), keyEquivalent: "")
        listenItem.target = self
        menu.addItem(listenItem)

        removeApiKeyItem = NSMenuItem(title: "Remove API key", action: #selector(onClickRemoveAPIKey), keyEquivalent: "")
        removeApiKeyItem.target = self
        menu.addItem(removeApiKeyItem)

        let restartItem = NSMenuItem(title: "Restart", action: #selector(onClickRestart), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(onClickQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

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

    private func showAPIKeyAlert(prefill: String? = nil, errorMessage: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Enter OpenAI API Key"
        if let err = errorMessage {
            alert.informativeText = "⚠️ \(err)"
        } else {
            alert.informativeText = "Your API key is stored locally and used only for Whisper transcription."
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // Native multiline NSTextField — gets rounded bezel automatically
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.placeholderString = "sk-..."
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = false
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        let currentKey = prefill ?? (Settings.apiKey.isEmpty ? "" : Settings.apiKey)
        textField.stringValue = currentKey

        alert.accessoryView = textField
        alert.layout()
        alert.window.initialFirstResponder = textField
        alert.window.makeFirstResponder(textField)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        // Validate OpenAI key format
        guard key.hasPrefix("sk-") else {
            showAPIKeyAlert(prefill: key, errorMessage: "Invalid key format. OpenAI keys must start with 'sk-'.")
            return
        }

        onAPIKeyEntered?(key)
        refreshPermissions()
    }

    @objc private func onToggleAutoSubmit(_ sender: NSMenuItem) {
        Settings.autoSubmit.toggle()
        refreshPermissions()
    }

    @objc private func onClickRemoveAPIKey() {
        onRemoveAPIKey?()
        refreshPermissions()
    }

    @objc private func onClickListen() {
        NSWorkspace.shared.open(URL(string: "https://youtube.com/shorts/WkRH_4wJbhw?si=Lb0LnlyNzJfTMKMp")!)
    }

    @objc private func onClickRestart() {
        onRestart?()
    }

    @objc private func onClickQuit() {
        NSApplication.shared.terminate(nil)
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
            statusItem.button?.alphaValue = 1.0
            statusItem.button?.contentTintColor = nil
            image = IconDrawer.idle()
        case .recording:
            let phase = 0.5 + 0.5 * sin(animTime / breathPeriod * 2 * .pi)
            let opacity = opacityMin + (opacityMax - opacityMin) * CGFloat(phase)
            statusItem.button?.alphaValue = 1.0
            image = IconDrawer.recording(opacity: opacity)
        case .processing:
            statusItem.button?.alphaValue = 1.0
            statusItem.button?.contentTintColor = nil
            let offsetY = abs(sin(animTime / jumpPeriod * .pi)) * maxJump
            image = IconDrawer.processing(offsetY: offsetY)
        case .success:
            statusItem.button?.alphaValue = 1.0
            statusItem.button?.contentTintColor = nil
            image = IconDrawer.success()
        case .error:
            statusItem.button?.alphaValue = 1.0
            statusItem.button?.contentTintColor = nil
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
