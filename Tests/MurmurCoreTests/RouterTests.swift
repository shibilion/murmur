import Foundation
import Testing
@testable import MurmurCore

private func route(
    _ mode: DictationMode,
    _ settings: Settings = Settings(),
    bundle: String = "com.app"
) -> Pipeline {
    Router.route(mode: mode, settings: settings, bundleId: bundle)
}

@Test func englishLocalRoute() {
    let p = route(.english)
    #expect(p.primaryTranscriber == "parakeet")
    #expect(p.fallbackTranscriber == nil)
    #expect(p.primaryFormatter == "ollama")
    #expect(p.fallbackFormatter == "passthrough")
    #expect(p.sendContext)
}

@Test func englishLocalUsesConfiguredEngine() {
    let p = route(.english, Settings(englishEngine: "whisperkit"))
    #expect(p.primaryTranscriber == "whisperkit")
    #expect(p.fallbackTranscriber == nil)
}

@Test func englishCloudRoute() {
    let p = route(.english, Settings(cloudBoost: true))
    #expect(p.primaryTranscriber == "groq")
    #expect(p.fallbackTranscriber == "parakeet")
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "ollama")
}

@Test func englishCloudFallsBackToConfiguredEngine() {
    let p = route(.english, Settings(cloudBoost: true, englishEngine: "whisperkit"))
    #expect(p.fallbackTranscriber == "whisperkit")
}

@Test func indianLocalRoute() {
    let p = route(.indian)
    #expect(p.primaryTranscriber == "whisperkit")
    #expect(p.fallbackTranscriber == nil)
    #expect(p.primaryFormatter == "ollama")
    #expect(p.fallbackFormatter == "passthrough")
}

@Test func indianCloudRoute() {
    let p = route(.indian, Settings(cloudBoost: true))
    #expect(p.primaryTranscriber == "sarvam")
    #expect(p.fallbackTranscriber == "whisperkit")
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "ollama")
}

@Test func forceLocalBeatsCloudBoost() {
    let s = Settings(cloudBoost: true, rules: [AppRule(bundleId: "com.app", force: .local)])
    let p = route(.english, s)
    #expect(p.primaryTranscriber == "parakeet")
    #expect(p.primaryFormatter == "ollama")
}

@Test func forceCloudWorksWithoutBoost() {
    let s = Settings(cloudBoost: false, rules: [AppRule(bundleId: "com.app", force: .cloud)])
    let p = route(.indian, s)
    #expect(p.primaryTranscriber == "sarvam")
    #expect(p.primaryFormatter == "claude")
}

@Test func ruleForOtherAppIsIgnored() {
    let s = Settings(cloudBoost: true, rules: [AppRule(bundleId: "com.other", force: .local)])
    #expect(route(.english, s).primaryTranscriber == "groq")
}

@Test func cleanupOffRuleUsesPassthrough() {
    let s = Settings(cloudBoost: true, rules: [AppRule(bundleId: "com.app", cleanupOff: true)])
    let p = route(.english, s)
    #expect(p.primaryFormatter == "passthrough")
    #expect(p.fallbackFormatter == nil)
    #expect(p.primaryTranscriber == "groq")
}

@Test func strengthOffUsesPassthrough() {
    let p = route(.english, Settings(strength: .off))
    #expect(p.primaryFormatter == "passthrough")
    #expect(p.fallbackFormatter == nil)
}

@Test func contextNotSentToCloudWhenDisabled() {
    let p = route(.english, Settings(cloudBoost: true, sendContextToCloud: false))
    #expect(p.primaryFormatter == "claude")
    #expect(!p.sendContext)
}

@Test func localFormatterAlwaysGetsContext() {
    let p = route(.english, Settings(sendContextToCloud: false))
    #expect(p.sendContext)
}

@Test func ruleToneIsApplied() {
    let s = Settings(strength: .light, rules: [AppRule(bundleId: "com.app", tone: .formal)])
    let p = route(.english, s)
    #expect(p.tone == .formal)
    #expect(p.strength == .light)
    #expect(route(.english).tone == .neutral)
}

@Test func everyCloudStageHasLocalFallback() {
    for mode in [DictationMode.english, .indian] {
        let p = route(mode, Settings(cloudBoost: true))
        #expect(p.fallbackTranscriber != nil)
        #expect(p.fallbackFormatter != nil)
    }
}

@Test func soundsEnabledDefaultsTrueAndDecodesWhenMissing() throws {
    #expect(Settings().soundsEnabled)
    let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(old.soundsEnabled)
    var s = Settings()
    s.soundsEnabled = false
    let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(!round.soundsEnabled)
}

@Test func ollamaModelAndPrewarmDefaultWhenMissing() throws {
    #expect(Settings().ollamaModel == "qwen3:4b-instruct")
    #expect(Settings().prewarmIndianModel)
    let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(old.ollamaModel == "qwen3:4b-instruct")
    #expect(old.prewarmIndianModel)
}

// MARK: - Cleanup Provider Tests

private func route(
    _ mode: DictationMode,
    _ settings: Settings = Settings(),
    bundle: String = "com.app",
    availability: ProviderAvailability = .legacy
) -> Pipeline {
    Router.route(mode: mode, settings: settings, bundleId: bundle, availability: availability)
}

@Test func autoPrefersBuiltIn() {
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, availability: avail)
    #expect(p.primaryFormatter == "llama")
}

@Test func autoFallsBackToApple() {
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: true, ollamaReachable: false)
    let p = route(.english, availability: avail)
    #expect(p.primaryFormatter == "apple")
}

@Test func autoFallsBackToOllama() {
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: true)
    let p = route(.english, availability: avail)
    #expect(p.primaryFormatter == "ollama")
}

@Test func autoFallsBackToNone() {
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, availability: avail)
    #expect(p.primaryFormatter == "passthrough")
}

@Test func explicitBuiltInHonoured() {
    let settings = Settings()
    var s = settings
    s.cleanupProvider = .builtIn
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: true, ollamaReachable: true)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "llama")
}

@Test func explicitAppleIntelligenceHonoured() {
    var s = Settings()
    s.cleanupProvider = .appleIntelligence
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: true, ollamaReachable: true)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "apple")
}

@Test func explicitOllamaHonoured() {
    var s = Settings()
    s.cleanupProvider = .ollama
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: true, ollamaReachable: true)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "ollama")
}

@Test func explicitNoneHonoured() {
    var s = Settings()
    s.cleanupProvider = .none
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: true, ollamaReachable: true)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "passthrough")
}

@Test func explicitBuiltInButUnavailableFallsBack() {
    var s = Settings()
    s.cleanupProvider = .builtIn
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "passthrough")
}

@Test func explicitAppleButUnavailableFallsBack() {
    var s = Settings()
    s.cleanupProvider = .appleIntelligence
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "passthrough")
}

@Test func cloudProviderUsesClaudeWithLocalFallback() {
    var s = Settings()
    s.cleanupProvider = .cloud
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "llama")
}

@Test func cloudBoostStillOverridesForEnglish() {
    var s = Settings()
    s.cloudBoost = true
    s.cleanupProvider = .auto
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: true)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "ollama")
}

@Test func deletingSelectedReResolves() {
    var s = Settings()
    s.cleanupProvider = .builtIn
    let avail1 = ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: false)
    let p1 = route(.english, s, availability: avail1)
    #expect(p1.primaryFormatter == "llama")

    let avail2 = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: false)
    let p2 = route(.english, s, availability: avail2)
    #expect(p2.primaryFormatter == "passthrough")
}

@Test func settingsDecodesMissingCleanupProviderAsAuto() throws {
    let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(old.cleanupProvider == .auto)
}

@Test func legacyAvailabilityPreservesExistingBehavior() {
    // When availability == .legacy and cleanupProvider == .auto,
    // local formatter should be "ollama" exactly as before
    let s = Settings(cloudBoost: false)
    let p = route(.english, s, availability: .legacy)
    #expect(p.primaryFormatter == "ollama")
    #expect(p.fallbackFormatter == "passthrough")
}

@Test func cloudCleanupProviderKeepsSpeechLocalEnglish() {
    var s = Settings()
    s.cleanupProvider = .cloud
    s.cloudBoost = false
    let avail = ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryTranscriber == "parakeet")
    #expect(p.fallbackTranscriber == nil)
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "llama")
}

@Test func cloudCleanupProviderKeepsSpeechLocalIndian() {
    var s = Settings()
    s.cleanupProvider = .cloud
    s.cloudBoost = false
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: false)
    let p = route(.indian, s, availability: avail)
    #expect(p.primaryTranscriber == "whisperkit")
    #expect(p.fallbackTranscriber == nil)
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "passthrough")
}

@Test func cloudProviderFallsBackToPassthroughWhenNothingLocal() {
    var s = Settings()
    s.cleanupProvider = .cloud
    let avail = ProviderAvailability(builtInReady: false, appleAvailable: false, ollamaReachable: false)
    let p = route(.english, s, availability: avail)
    #expect(p.primaryFormatter == "claude")
    #expect(p.fallbackFormatter == "passthrough")
}

@Test func autoEffectiveProviderFollowsAvailability() {
    func a(_ b: Bool, _ ap: Bool, _ o: Bool) -> ProviderAvailability {
        ProviderAvailability(builtInReady: b, appleAvailable: ap, ollamaReachable: o)
    }
    #expect(CleanupProvider.auto.effective(a(true, true, true)) == .builtIn)
    #expect(CleanupProvider.auto.effective(a(false, true, true)) == .appleIntelligence)
    #expect(CleanupProvider.auto.effective(a(false, false, true)) == .ollama)
    #expect(CleanupProvider.auto.effective(a(false, false, false)) == .none)
    #expect(CleanupProvider.none.effective(a(true, true, true)) == .none)
    #expect(CleanupProvider.cloud.effective(a(true, true, true)) == .cloud)
}
