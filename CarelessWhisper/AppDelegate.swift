import Cocoa
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var hotkeyListener: HotkeyListener!
    private var audioRecorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var paster: Paster!
    private var fileTranscriber: FileTranscriber?
    private var fileProgressWindow: FileTranscribeProgressWindow?

    private var isProcessing = false
    private var processingTask: Task<Void, Never>?
    private var maxRecordingTimer: Timer?
    private var audioWatchdogTimer: Timer?
    private var consecutiveAudioFailures = 0
    private var onboarding: OnboardingWindow?
    private var startSoundTimer: Timer?
    private var doubleClickSoundTimer: Timer?
    private var didPlayStartSound = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()

        statusBar = StatusBarController()
        hotkeyListener = HotkeyListener()
        audioRecorder = AudioRecorder()
        transcriber = Transcriber()
        paster = Paster()

        wireCallbacks()

        // Show onboarding if any setup is incomplete
        let needsOnboarding = !PermissionChecker.isMicrophoneGranted()
            || !PermissionChecker.isAccessibilityGranted()
            || Settings.apiKey.isEmpty
            || !Settings.onboardingComplete

        if needsOnboarding {
            onboarding = OnboardingWindow()
            onboarding?.onComplete = { [weak self] in
                self?.onboarding = nil
                self?.hotkeyListener.start()
                self?.startAudioWatchdog()
                if Settings.autoCheckUpdates {
                    UpdateChecker.check(silent: true)
                }
                log.info("Onboarding complete, app ready")
            }
            onboarding?.showIfNeeded()
        } else {
            hotkeyListener.start()
            startAudioWatchdog()
            if Settings.autoCheckUpdates {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    UpdateChecker.check(silent: true)
                }
            }
        }

        log.info("CarelessWhisper launched")
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
        statusBar.onAccessibilityGranted = { [weak self] in
            log.info("Accessibility granted, restarting event tap")
            self?.hotkeyListener.stop()
            self?.hotkeyListener.start()
        }
        statusBar.onTranscribeFile = { [weak self] url in
            self?.startFileTranscription(sourceURL: url)
        }
        statusBar.onCancelProcessing = { [weak self] in
            self?.cancelProcessing()
        }
    }

    // MARK: - File Transcription

    private func startFileTranscription(sourceURL: URL) {
        guard fileTranscriber == nil else {
            log.warning("File transcription already running, ignoring")
            return
        }
        guard !Settings.apiKey.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No API key"
            alert.informativeText = "Set your OpenAI API key from the menu first."
            alert.runModal()
            return
        }

        let transcriber = FileTranscriber()
        let window = FileTranscribeProgressWindow(title: "Transcribing \(sourceURL.lastPathComponent)")
        window.onCancel = { transcriber.isCancelled = true }
        window.show()
        fileTranscriber = transcriber
        fileProgressWindow = window

        Task {
            do {
                let outURL = try await transcriber.transcribe(
                    sourceURL: sourceURL,
                    language: nil  // nil → Whisper auto-detects the audio's language
                ) { progress in
                    window.update(stage: progress.stage, fraction: progress.fraction)
                }
                await MainActor.run {
                    window.close()
                    self.fileTranscriber = nil
                    self.fileProgressWindow = nil
                    NSWorkspace.shared.open(outURL)
                }
            } catch {
                await MainActor.run {
                    window.close()
                    self.fileTranscriber = nil
                    self.fileProgressWindow = nil
                    let isCancel = (error as? FileTranscriber.FileTranscriberError)
                        .map { if case .cancelled = $0 { return true } else { return false } } ?? false
                    if !isCancel {
                        self.showErrorAlert(error)
                    }
                }
            }
        }
    }

    // MARK: - Error Alert

    /// Shows a native modal describing why transcription failed.
    private func showErrorAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Transcription failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            statusBar.setState(.recording)
            startMaxRecordingTimer()
            // Hold the start sound until the press clears the misclick
            // threshold, so a tap that won't be transcribed stays completely
            // silent. A sound can't be un-played, so it must be delayed rather
            // than retracted. Same threshold as the transcription cutoff below,
            // so sound and transcription always agree.
            didPlayStartSound = false
            startSoundTimer?.invalidate()
            startSoundTimer = Timer.scheduledTimer(withTimeInterval: Settings.minRecordingSeconds, repeats: false) { [weak self] _ in
                guard let self, self.audioRecorder.isRecording else { return }
                SoundPlayer.play(Settings.soundStart)
                self.didPlayStartSound = true
            }

            // After 400ms, if it turned out to be a double-click-and-hold, play Funk too
            doubleClickSoundTimer?.invalidate()
            doubleClickSoundTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, self.audioRecorder.isRecording, self.hotkeyListener.isDoubleClickHold else { return }
                SoundPlayer.play("Funk")
            }
            log.info("Recording started")
        } catch {
            log.error("Failed to start recording: \(error.localizedDescription)")
            statusBar.setState(.error)
            SoundPlayer.play(Settings.soundError)
        }
    }

    private func onHotkeyRelease() {
        guard audioRecorder.isRecording else { return }

        // Check if Shift is held — suppresses auto-submit for this message
        let shiftHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        let doubleClickHold = hotkeyListener.isDoubleClickHold

        cancelPressSounds()
        cancelMaxRecordingTimer()
        guard let result = audioRecorder.stop() else {
            statusBar.setState(.idle)
            return
        }

        // Pair a stop sound only with a start sound that actually played, so a
        // misclick makes no noise at either end.
        if didPlayStartSound {
            SoundPlayer.play(Settings.soundStop)
        }
        didPlayStartSound = false

        if result.duration < Settings.minRecordingSeconds {
            log.info("Recording too short (\(String(format: "%.1f", result.duration))s), ignoring")
            audioRecorder.cleanup()
            statusBar.setState(.idle)
            return
        }

        processRecording(url: result.url, suppressAutoSubmit: shiftHeld || doubleClickHold, skipTranslation: false)
    }

    private func onHotkeyCancel() {
        cancelPressSounds()
        cancelMaxRecordingTimer()
        audioRecorder.cancel()
        statusBar.setState(.idle)
        if didPlayStartSound {
            SoundPlayer.play(Settings.soundStop)
        }
        didPlayStartSound = false
        log.info("Recording cancelled")
    }

    /// Cancels both pending press sounds: the delayed start chime and the
    /// double-click-and-hold Funk.
    private func cancelPressSounds() {
        startSoundTimer?.invalidate()
        startSoundTimer = nil
        doubleClickSoundTimer?.invalidate()
        doubleClickSoundTimer = nil
    }

    private func processRecording(url: URL, suppressAutoSubmit: Bool = false, skipTranslation: Bool = false) {
        isProcessing = true
        statusBar.setState(.processing)

        processingTask = Task {
            do {
                let result = try await transcriber.transcribe(wavURL: url, skipTranslation: skipTranslation)

                // Bail quietly if the user cancelled while the request finished.
                try Task.checkCancellation()

                await MainActor.run {
                    if result.wasRetranscribed {
                        SoundPlayer.play(Settings.soundRetranscribe)
                    }

                    let autoSubmit = suppressAutoSubmit ? false : Settings.autoSubmit
                    SoundPlayer.play(Settings.soundStart)
                    paster.paste(text: result.text, autoSubmit: autoSubmit)
                    Settings.lastTranscript = result.text
                    statusBar.refreshLastTranscript()
                    statusBar.setState(.success)
                    log.info("Transcribed: \(result.text.prefix(50))...")
                }
            } catch is CancellationError {
                log.info("Transcription cancelled by user")
            } catch let urlError as URLError where urlError.code == .cancelled {
                log.info("Transcription request cancelled by user")
            } catch {
                await MainActor.run {
                    log.error("Transcription failed: \(error.localizedDescription)")
                    SoundPlayer.play(Settings.soundError)
                    statusBar.setState(.error)
                    self.showErrorAlert(error)
                }
            }

            // Cleanup
            try? FileManager.default.removeItem(at: url)

            await MainActor.run {
                self.isProcessing = false
                self.processingTask = nil
            }
        }
    }

    /// Cancel an in-flight push-to-talk transcription (invoked from the menu).
    /// Cancelling the Task aborts the URLSession request via Swift concurrency;
    /// the task's catch handles it quietly, so we only reset UI state here.
    private func cancelProcessing() {
        guard isProcessing, let task = processingTask else { return }
        log.info("User requested transcription cancel")
        task.cancel()
        processingTask = nil
        isProcessing = false
        statusBar.setState(.idle)
        SoundPlayer.play(Settings.soundStop)
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
