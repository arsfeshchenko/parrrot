import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.carelesswhisper", category: "Settings")

private let keychainService = "com.arsfeshchenko.carelesswhisper"

private var apiKeyFileURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = support.appendingPathComponent("com.arsfeshchenko.carelesswhisper", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("apikey")
}

@propertyWrapper
struct Setting<T> {
    let key: String
    let defaultValue: T

    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum Settings {
    static var apiKey: String {
        get {
            (try? String(contentsOf: apiKeyFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            if newValue.isEmpty {
                try? FileManager.default.removeItem(at: apiKeyFileURL)
            } else {
                try? newValue.write(to: apiKeyFileURL, atomically: true, encoding: .utf8)
            }
            // Clean up any old keychain items
            let deleteQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                                kSecAttrService: keychainService,
                                                kSecAttrAccount: "apiKey"]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    @Setting(key: "whisperModel", defaultValue: "whisper-1")
    static var whisperModel: String

    @Setting(key: "soundStart", defaultValue: "Tink")
    static var soundStart: String

    @Setting(key: "soundStop", defaultValue: "Pop")
    static var soundStop: String

    @Setting(key: "soundError", defaultValue: "Basso")
    static var soundError: String

    @Setting(key: "soundRetranscribe", defaultValue: "Morse")
    static var soundRetranscribe: String

    @Setting(key: "autoSubmit", defaultValue: true)
    static var autoSubmit: Bool

    /// The single misclick threshold. A press shorter than this is ignored
    /// completely: no start/stop sound and no transcription. The sound delay is
    /// derived from this value so the two can never drift apart and create a
    /// window where the app chimes but transcribes nothing.
    @Setting(key: "minRecordingSeconds", defaultValue: 0.3)
    static var minRecordingSeconds: Double

    @Setting(key: "maxRecordingSeconds", defaultValue: 600.0)
    static var maxRecordingSeconds: Double

    @Setting(key: "soundsEnabled", defaultValue: true)
    static var soundsEnabled: Bool

    @Setting(key: "autoCheckUpdates", defaultValue: false)
    static var autoCheckUpdates: Bool

    @Setting(key: "onboardingComplete", defaultValue: false)
    static var onboardingComplete: Bool

    @Setting(key: "lastTranscript", defaultValue: "")
    static var lastTranscript: String

    /// Forced output language for push-to-talk transcription:
    /// "auto" = smart (detect; translate non-EN/UK clips to Ukrainian),
    /// "en"   = always English (via Whisper's audio/translations endpoint),
    /// "uk"   = always Ukrainian (transcribe, then GPT-translate if needed).
    @Setting(key: "outputLanguage", defaultValue: "auto")
    static var outputLanguage: String

    /// Comma-separated terms fed to Whisper's `prompt` param to bias spelling
    /// (e.g. "Claude, Claude Code, Anthropic, Xcode"). Empty = no biasing.
    @Setting(key: "vocabulary", defaultValue: "")
    static var vocabulary: String

    /// The stored vocabulary as a cleaned list of non-empty terms.
    static var vocabularyTerms: [String] {
        vocabularyTermsFrom(vocabulary)
    }

    /// Parse an arbitrary string (commas and/or newlines) into cleaned terms.
    static func vocabularyTermsFrom(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
