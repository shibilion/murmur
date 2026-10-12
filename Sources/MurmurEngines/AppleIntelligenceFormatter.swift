import Foundation
import MurmurCore
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case other(String)

    /// User-facing explanation; nil when available.
    public var message: String? {
        switch self {
        case .available: nil
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
        case .notEnabled: "Turn on Apple Intelligence in System Settings."
        case .modelNotReady: "Apple Intelligence is still getting ready."
        case .other(let reason): "Apple Intelligence is unavailable (\(reason))."
        }
    }
}

/// Cleanup with the on-device Apple Foundation Model. A fresh session per dictation, greedy sampling.
public struct AppleIntelligenceFormatter: MurmurCore.Formatter {
    public let id = "apple"
    private let availabilityProvider: @Sendable () -> AppleAvailability
    private let responder: @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String

    public init(
        availability: @escaping @Sendable () -> AppleAvailability = { AppleIntelligenceFormatter.availability() },
        respond: @escaping @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String = AppleIntelligenceFormatter.systemRespond
    ) {
        availabilityProvider = availability
        responder = respond
    }

    public func format(_ req: FormatRequest) async throws -> String {
        let a = availabilityProvider()
        guard a == .available else { throw EngineError.unavailable(a.message ?? "unavailable") }
        let system = PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone, contextStyle: .hints)
        let user = PromptBuilder.user(req, includeContext: req.context != nil, style: .hints)
        let cap = OllamaFormatter.tokenCap(forRawWordCount: req.raw.text.split(whereSeparator: \.isWhitespace).count)
        let out = try await responder(system, user, cap)
        return OllamaFormatter.stripThink(out)
    }

    /// Loads the model ahead of the first dictation. Optional.
    public func prewarm() {
        #if canImport(FoundationModels)
        guard Self.availability() == .available else { return }
        LanguageModelSession().prewarm()
        #endif
    }

    // MARK: - System model

    /// False when this build lacks the FoundationModels framework (older SDK); the UI hides Apple Intelligence then.
    public static var isCompiledIn: Bool {
        #if canImport(FoundationModels)
        true
        #else
        false
        #endif
    }

    /// True only when the framework is compiled in and the system model can run now.
    public static var isUsable: Bool { isCompiledIn && availability() == .available }

    public static func availability() -> AppleAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .other("\(reason)")
            }
        }
        #else
        return .other("this build lacks the macOS 26 SDK")
        #endif
    }

    @Sendable public static func systemRespond(system: String, user: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: system)
        do {
            let r = try await session.respond(to: user, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens))
            return r.content
        } catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation, .refusal: throw EngineError.refused
            default: throw e
            }
        }
        #else
        throw EngineError.unavailable("this build lacks the macOS 26 SDK")
        #endif
    }
}
