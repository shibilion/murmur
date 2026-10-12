import Foundation
import Testing
@testable import MurmurCore

@Suite
struct AboutCopyTests {
    @Test
    func aboutCopyMatchesSpec() {
        // Test exact strings match the spec
        #expect(AboutCopy.tagline == "Private voice typing for your Mac.")
        #expect(AboutCopy.developer == "Muhamed Shibili")
        #expect(AboutCopy.websiteLabel == "shibili.works")
        #expect(AboutCopy.websiteURL == URL(string: "https://shibili.works/")!)

        // Test credits contain required attributions
        #expect(AboutCopy.credits.contains("Parakeet (CC-BY-4.0)"))
        #expect(AboutCopy.credits.contains("Whisper"))
        #expect(AboutCopy.credits.contains("Qwen3 (Apache-2.0)"))
        #expect(AboutCopy.credits.contains("Built with llama.cpp (MIT), WhisperKit (MIT) and FluidAudio (Apache-2.0)."))
    }
}
