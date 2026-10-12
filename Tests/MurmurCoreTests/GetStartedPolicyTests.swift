import Testing
@testable import MurmurCore

@Suite
struct GetStartedPolicyTests {
    @Test func upgraderWithVerifyingModelIsNotShownGetStarted() {
        #expect(!GetStartedPolicy.shouldShow(speechStates: [.verifying, .notDownloaded], permissionsOK: true, onboarded: true))
        #expect(!GetStartedPolicy.shouldShow(speechStates: [.preparing], permissionsOK: true, onboarded: true))
        #expect(!GetStartedPolicy.shouldShow(speechStates: [.ready], permissionsOK: true, onboarded: true))
    }
    @Test func showsWhenNoSpeechModelPresent() {
        #expect(GetStartedPolicy.shouldShow(speechStates: [.notDownloaded, .failed("x")], permissionsOK: true, onboarded: true))
        #expect(GetStartedPolicy.shouldShow(speechStates: [.paused(done: 1, total: 2)], permissionsOK: true, onboarded: true))
    }
    @Test func showsWhenPermissionsMissingOrNotOnboarded() {
        #expect(GetStartedPolicy.shouldShow(speechStates: [.ready], permissionsOK: false, onboarded: true))
        #expect(GetStartedPolicy.shouldShow(speechStates: [.ready], permissionsOK: true, onboarded: false))
    }
}
