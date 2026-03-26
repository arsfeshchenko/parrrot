import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.arsfeshchenko.parrrot", category: "Settings")

private let keychainService = "com.arsfeshchenko.parrrot"

private var apiKeyFileURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = support.appendingPathComponent("com.arsfeshchenko.parrrot", isDirectory: true)
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

    @Setting(key: "autoSubmit", defaultValue: false)
    static var autoSubmit: Bool

    @Setting(key: "minRecordingSeconds", defaultValue: 0.3)
    static var minRecordingSeconds: Double

    @Setting(key: "maxRecordingSeconds", defaultValue: 300.0)
    static var maxRecordingSeconds: Double

    @Setting(key: "soundsEnabled", defaultValue: true)
    static var soundsEnabled: Bool
}
