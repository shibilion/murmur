import Foundation

// MARK: - Dictation Mode

public enum DictationMode: Sendable {
    case english
    case indian
}

// MARK: - Audio

public struct AudioClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

// MARK: - Transcription

public struct RawTranscript: Sendable, Equatable {
    public var text: String
    public var languageCode: String?

    public init(text: String, languageCode: String? = nil) {
        self.text = text
        self.languageCode = languageCode
    }
}

// MARK: - Application Context

public struct AppIdentity: Sendable, Equatable {
    public var name: String
    public var bundleId: String
    public var url: String?

    public init(name: String, bundleId: String, url: String? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.url = url
    }
}

public struct ContextSnapshot: Sendable, Equatable {
    public var app: AppIdentity
    public var beforeText: String
    public var selectedText: String
    public var afterText: String
    public var screenWords: [String]
    public var isSecureField: Bool

    public init(
        app: AppIdentity,
        beforeText: String,
        selectedText: String,
        afterText: String,
        screenWords: [String],
        isSecureField: Bool
    ) {
        self.app = app
        self.beforeText = beforeText
        self.selectedText = selectedText
        self.afterText = afterText
        self.screenWords = screenWords
        self.isSecureField = isSecureField
    }
}

// MARK: - Formatting

public enum Tone: String, Codable, Sendable {
    case neutral
    case casual
    case formal
}

public enum CleanupStrength: String, Codable, Sendable {
    case off
    case light
    case normal
}

public struct FormatRequest: Sendable {
    public var raw: RawTranscript
    public var context: ContextSnapshot?
    public var dictionary: [String]
    public var tone: Tone
    public var mode: DictationMode
    public var strength: CleanupStrength

    public init(
        raw: RawTranscript,
        context: ContextSnapshot? = nil,
        dictionary: [String] = [],
        tone: Tone = .neutral,
        mode: DictationMode = .english,
        strength: CleanupStrength = .normal
    ) {
        self.raw = raw
        self.context = context
        self.dictionary = dictionary
        self.tone = tone
        self.mode = mode
        self.strength = strength
    }
}

// MARK: - Text Insertion

public enum InsertOutcome: Sendable, Equatable {
    case pasted
    case typed
    case copiedOnly
}

// MARK: - History

public struct HistoryEntry: Codable, Sendable {
    public var date: Date
    public var raw: String
    public var final: String
    public var appBundleId: String

    public init(date: Date, raw: String, final: String, appBundleId: String) {
        self.date = date
        self.raw = raw
        self.final = final
        self.appBundleId = appBundleId
    }
}
