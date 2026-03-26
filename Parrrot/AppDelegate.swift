import Cocoa
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.parrrot", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var hotkeyListener: HotkeyListener!
    private var audioRecorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var paster: Paster!

    private var isProcessing = false
    private var maxRecordingTimer: Timer?
    private var audioWatchdogTimer: Timer?
    private var consecutiveAudioFailures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()

        // Prompt for Accessibility if not granted
        if !PermissionChecker.isAccessibilityGranted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            log.info("Accessibility permission requested")
        }

        statusBar = StatusBarController()
        hotkeyListener = HotkeyListener()
        audioRecorder = AudioRecorder()
        transcriber = Transcriber()
        paster = Paster()

        wireCallbacks()
        hotkeyListener.start()
        startAudioWatchdog()

        // Request mic permission on first launch
        if !PermissionChecker.isMicrophoneGranted() {
            PermissionChecker.requestMicrophoneAccess { granted in
                log.info("Microphone access: \(granted)")
            }
        }

        log.info("parrrot launched")
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        NSApp.mainMenu = mainMenu
    }

    private func wireCallbacks() {
        hotkeyListener.onPress = { [weak self] in self?.onHotkeyPress() }
        hotkeyListener.onRelease = { [weak self] in self?.onHotkeyRelease() }
        hotkeyListener.onCancel = { [weak self] in self?.onHotkeyCancel() }

        statusBar.onAPIKeyEntered = { key in
            Settings.apiKey = key
            log.info("API key updated")
        }
        statusBar.onRemoveAPIKey = {
            Settings.apiKey = ""
            log.info("API key removed")
        }
        statusBar.onRestart = {
            log.info("Restart requested")
            let url = Bundle.main.bundleURL
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Push-to-Talk Workflow

    private func onHotkeyPress() {
        guard !isProcessing else {
            log.info("Still processing, ignoring press")
            return
        }
        guard !Settings.apiKey.isEmpty else {
            log.warning("No API key set")
            statusBar.setState(.error)
            SoundPlayer.play(Settings.soundError)
            return
        }

        do {
            try audioRecorder.start()
            SoundPlayer.play(Settings.soundStart)
            statusBar.setState(.recording)
            startMaxRecordingTimer()
            log.info("Recording started")
        } catch {
            log.error("Failed to start recording: \(error.localizedDescription)")
            statusBar.setState(.error)
            SoundPlayer.play(Settings.soundError)
        }
    }

    private func onHotkeyRelease() {
        guard audioRecorder.isRecording else { return }

        cancelMaxRecordingTimer()
        guard let result = audioRecorder.stop() else {
            statusBar.setState(.idle)
            return
        }

        SoundPlayer.play(Settings.soundStop)

        if result.duration < Settings.minRecordingSeconds {
            log.info("Recording too short (\(String(format: "%.1f", result.duration))s), discarding")
            audioRecorder.cleanup()
            statusBar.setState(.error)
            SoundPlayer.play(Settings.soundError)
            return
        }

        processRecording(url: result.url)
    }

    private func onHotkeyCancel() {
        cancelMaxRecordingTimer()
        audioRecorder.cancel()
        statusBar.setState(.idle)
        SoundPlayer.play(Settings.soundStop)
        log.info("Recording cancelled")
    }

    private func processRecording(url: URL) {
        isProcessing = true
        statusBar.setState(.processing)

        Task {
            do {
                let result = try await transcriber.transcribe(wavURL: url)

                await MainActor.run {
                    if result.wasRetranscribed {
                        SoundPlayer.play(Settings.soundRetranscribe)
                    }

                    paster.paste(text: result.text, autoSubmit: Settings.autoSubmit)
                    // Delay Tink so it plays after paste+Enter (and after the target app's own sound)
                    let soundDelay = Settings.autoSubmit ? 0.5 : 0.1
                    DispatchQueue.main.asyncAfter(deadline: .now() + soundDelay) {
                        SoundPlayer.play(Settings.soundStart)
                    }
                    statusBar.setState(.success)
                    log.info("Transcribed: \(result.text.prefix(50))...")
                }
            } catch {
                await MainActor.run {
                    log.error("Transcription failed: \(error.localizedDescription)")
                    SoundPlayer.play(Settings.soundError)
                    statusBar.setState(.error)
                }
            }

            // Cleanup
            try? FileManager.default.removeItem(at: url)

            await MainActor.run {
                self.isProcessing = false
            }
        }
    }

    // MARK: - Max Recording Timer

    private func startMaxRecordingTimer() {
        let max = Settings.maxRecordingSeconds
        guard max > 0 else { return }
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: max, repeats: false) { [weak self] _ in
            log.warning("Max recording duration reached")
            self?.onHotkeyRelease()
        }
    }

    private func cancelMaxRecordingTimer() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
    }

    // MARK: - Audio Watchdog

    private func startAudioWatchdog() {
        audioWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 37, repeats: true) { [weak self] _ in
            self?.checkAudioDevice()
        }
    }

    private func checkAudioDevice() {
        guard !audioRecorder.isRecording, !isProcessing else { return }

        if audioRecorder.checkDeviceAvailable() {
            consecutiveAudioFailures = 0
        } else {
            consecutiveAudioFailures += 1
            log.warning("Audio device check failed (\(self.consecutiveAudioFailures)/3)")
            if consecutiveAudioFailures >= 3 {
                log.error("3 consecutive audio failures, restarting")
                exit(1)
            }
        }
    }
}
