import Foundation
import Testing
@testable import MurmurCore

@Suite
struct CardPresentationTests {
    private func make(_ s: CardState, selected: Bool = false) -> CardPresentation {
        CardPresentation.make(state: s, sizeBytes: 452_000_000, selected: selected)
    }

    @Test func notDownloaded() {
        let p = make(.notDownloaded)
        #expect(p.statusText == "\(CardPresentation.bytes(452_000_000)) · Download")
        #expect(p.statusText.hasSuffix(" · Download"))
        #expect(p.primary == .download)
        #expect(p.progress == nil)
    }

    @Test func downloadingWithSpeedAndSecondsEta() {
        let p = make(.downloading(done: 100_000_000, total: 145_000_000, bytesPerSec: 1_000_000))
        #expect(p.statusText == "100 MB / 145 MB · 1.0 MB/s · 45 s left")
        #expect(p.primary == .cancel)
        #expect(p.progress != nil)
    }

    @Test func downloadingMinutesEta() {
        let p = make(.downloading(done: 0, total: 100_000_000, bytesPerSec: 1_000_000))
        #expect(p.statusText == "0 MB / 100 MB · 1.0 MB/s · 2 min left")
        #expect(p.progress == 0)
    }

    @Test func downloadingExactlyOneMinute() {
        let p = make(.downloading(done: 40_000_000, total: 100_000_000, bytesPerSec: 1_000_000))
        #expect(p.statusText.hasSuffix("· 1 min left"))
    }

    @Test func downloadingWithoutSpeedOmitsSpeedAndEta() {
        let p = make(.downloading(done: 100_000_000, total: 200_000_000, bytesPerSec: 0))
        #expect(p.statusText == "100 MB / 200 MB")
        #expect(p.progress == 0.5)
    }

    @Test func paused() {
        let p = make(.paused(done: 100_000_000, total: 200_000_000))
        #expect(p.statusText == "Paused · 100 MB / 200 MB")
        #expect(p.primary == .resume)
    }

    @Test func failedShowsReasonWithDownload() {
        let p = make(.failed("Not enough disk space: 2.3 GB needed, 1.1 GB free"))
        #expect(p.statusText == "Not enough disk space: 2.3 GB needed, 1.1 GB free")
        #expect(p.primary == .download)
    }

    @Test func verifyingAndPreparing() {
        #expect(make(.verifying).statusText == "Checking download…")
        #expect(make(.verifying).primary == nil)
        #expect(make(.preparing).statusText == "Preparing… one-time")
        #expect(make(.preparing).primary == nil)
    }

    @Test func readyFlagAndNonSelectableCard() {
        #expect(make(.ready).isReady)
        #expect(!make(.verifying).isReady)
        #expect(!make(.notDownloaded).isReady)
        let p = CardPresentation.make(state: .ready, sizeBytes: 1, selected: false, selectable: false)
        #expect(p.primary == nil)
        #expect(p.isReady)
        #expect(p.statusText == "Ready")
    }

    @Test func readyOffersUseThisOrSelected() {
        #expect(make(.ready).statusText == "Ready")
        #expect(make(.ready).primary == .useThis)
        #expect(make(.ready, selected: true).primary == .selected)
        #expect(CardButton.useThis.title == "Use this")
        #expect(CardButton.selected.title == "Selected")
    }
}
