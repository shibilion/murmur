import Foundation

public enum CleanupProvider: String, Codable, Sendable, CaseIterable {
    case auto
    case builtIn
    case appleIntelligence
    case ollama
    case cloud
    case none
}

public struct ProviderAvailability: Sendable, Equatable {
    public var builtInReady: Bool
    public var appleAvailable: Bool
    public var ollamaReachable: Bool

    public init(builtInReady: Bool, appleAvailable: Bool, ollamaReachable: Bool) {
        self.builtInReady = builtInReady
        self.appleAvailable = appleAvailable
        self.ollamaReachable = ollamaReachable
    }

    public static let legacy = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: true)
}

extension CleanupProvider {
    /// What `.auto` resolves to right now (other values resolve to themselves). Used to highlight the active card.
    public func effective(_ a: ProviderAvailability) -> CleanupProvider {
        guard self == .auto else { return self }
        if a.builtInReady { return .builtIn }
        if a.appleAvailable { return .appleIntelligence }
        if a.ollamaReachable { return .ollama }
        return .none
    }
}

public enum ProviderResolver {
    public static func localFormatter(_ p: CleanupProvider, _ a: ProviderAvailability) -> String {
        switch p {
        case .auto:
            if a.builtInReady {
                return "llama"
            } else if a.appleAvailable {
                return "apple"
            } else if a.ollamaReachable {
                return "ollama"
            } else {
                return "passthrough"
            }
        case .builtIn:
            return a.builtInReady ? "llama" : "passthrough"
        case .appleIntelligence:
            return a.appleAvailable ? "apple" : "passthrough"
        case .ollama:
            return "ollama"
        case .cloud:
            // .cloud uses the local result of .auto
            return localFormatter(.auto, a)
        case .none:
            return "passthrough"
        }
    }
}

public struct AppRule: Codable, Sendable, Equatable {
    public enum Force: String, Codable, Sendable {
        case local
        case cloud
    }

    public var bundleId: String
    public var force: Force?
    public var cleanupOff: Bool
    public var tone: Tone?

    public init(bundleId: String, force: Force? = nil, cleanupOff: Bool = false, tone: Tone? = nil) {
        self.bundleId = bundleId
        self.force = force
        self.cleanupOff = cleanupOff
        self.tone = tone
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var cloudBoost = false
    public var sendContextToCloud = true
    public var strength: CleanupStrength = .normal
    public var rules: [AppRule] = []
    public var dictionary: [String] = []
    public var snippets: [Snippet] = []
    public var replacements: [String: String] = [:]
    /// English engine when cloud is off: "parakeet" or "whisperkit".
    public var englishEngine: String = "parakeet"
    /// Sarvam speech-to-text model name.
    public var sarvamModel: String = "saaras:v4"
    public var soundsEnabled: Bool = true
    /// Ollama cleanup model. Must be a non-thinking (instruct) model.
    public var ollamaModel: String = "qwen3:4b-instruct"
    /// Quietly load the Whisper model in the background after launch (only if already downloaded).
    public var prewarmIndianModel: Bool = true
    /// Which cleanup provider to use
    public var cleanupProvider: CleanupProvider = .auto

    public init(
        cloudBoost: Bool = false,
        sendContextToCloud: Bool = true,
        strength: CleanupStrength = .normal,
        rules: [AppRule] = [],
        dictionary: [String] = [],
        snippets: [Snippet] = [],
        replacements: [String: String] = [:],
        englishEngine: String = "parakeet",
        sarvamModel: String = "saaras:v4",
        cleanupProvider: CleanupProvider = .auto
    ) {
        self.cloudBoost = cloudBoost
        self.sendContextToCloud = sendContextToCloud
        self.strength = strength
        self.rules = rules
        self.dictionary = dictionary
        self.snippets = snippets
        self.replacements = replacements
        self.englishEngine = englishEngine
        self.sarvamModel = sarvamModel
        self.cleanupProvider = cleanupProvider
    }

    // Forward-compatible decoding: missing keys fall back to defaults
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cloudBoost = try container.decodeIfPresent(Bool.self, forKey: .cloudBoost) ?? false
        self.sendContextToCloud = try container.decodeIfPresent(Bool.self, forKey: .sendContextToCloud) ?? true
        self.strength = try container.decodeIfPresent(CleanupStrength.self, forKey: .strength) ?? .normal
        self.rules = try container.decodeIfPresent([AppRule].self, forKey: .rules) ?? []
        self.dictionary = try container.decodeIfPresent([String].self, forKey: .dictionary) ?? []
        self.snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        self.replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        self.englishEngine = try container.decodeIfPresent(String.self, forKey: .englishEngine) ?? "parakeet"
        self.sarvamModel = try container.decodeIfPresent(String.self, forKey: .sarvamModel) ?? "saaras:v4"
        self.soundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? true
        self.ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "qwen3:4b-instruct"
        self.prewarmIndianModel = try container.decodeIfPresent(Bool.self, forKey: .prewarmIndianModel) ?? true
        self.cleanupProvider = try container.decodeIfPresent(CleanupProvider.self, forKey: .cleanupProvider) ?? .auto
    }
}

public struct Pipeline: Sendable, Equatable {
    public var primaryTranscriber: String
    public var fallbackTranscriber: String?
    public var primaryFormatter: String
    public var fallbackFormatter: String?
    public var sendContext: Bool
    public var tone: Tone
    public var strength: CleanupStrength

    public init(
        primaryTranscriber: String,
        fallbackTranscriber: String?,
        primaryFormatter: String,
        fallbackFormatter: String?,
        sendContext: Bool,
        tone: Tone,
        strength: CleanupStrength
    ) {
        self.primaryTranscriber = primaryTranscriber
        self.fallbackTranscriber = fallbackTranscriber
        self.primaryFormatter = primaryFormatter
        self.fallbackFormatter = fallbackFormatter
        self.sendContext = sendContext
        self.tone = tone
        self.strength = strength
    }
}

public enum Router {
    public static func route(
        mode: DictationMode,
        settings: Settings,
        bundleId: String,
        availability: ProviderAvailability = .legacy
    ) -> Pipeline {
        let rule = settings.rules.first { $0.bundleId == bundleId }
        let force = rule?.force

        let cloudSpeech = (settings.cloudBoost && force != .local) || force == .cloud
        let cloudCleanup = cloudSpeech || settings.cleanupProvider == .cloud

        let localFormatter = ProviderResolver.localFormatter(settings.cleanupProvider, availability)

        let transcriber: (String, String?)
        switch (mode, cloudSpeech) {
        case (.english, false): transcriber = (settings.englishEngine, nil)
        case (.english, true): transcriber = ("groq", settings.englishEngine)
        case (.indian, false): transcriber = ("whisperkit", nil)
        case (.indian, true): transcriber = ("sarvam", "whisperkit")
        }

        let formatter: (String, String?)
        if rule?.cleanupOff == true || settings.strength == .off {
            formatter = ("passthrough", nil)
        } else if cloudCleanup {
            formatter = ("claude", localFormatter)
        } else {
            let fallback = localFormatter == "passthrough" ? nil : "passthrough"
            formatter = (localFormatter, fallback)
        }

        return Pipeline(
            primaryTranscriber: transcriber.0,
            fallbackTranscriber: transcriber.1,
            primaryFormatter: formatter.0,
            fallbackFormatter: formatter.1,
            sendContext: formatter.0 == "claude" ? settings.sendContextToCloud : true,
            tone: rule?.tone ?? .neutral,
            strength: settings.strength
        )
    }
}
