import Testing
@testable import MurmurCore

@Test func holdStartsAndStops() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 1.0))
    #expect(events2 == [.stop])
}

@Test func shiftSelectsIndian() {
    var recognizer = GestureRecognizer()

    let events = recognizer.handle(.fnDown(shift: true, t: 0))
    #expect(events == [.start(.indian)])
}

@Test func fnPlusArrowIsModifier() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.otherKeyDown(keyCode: 126, t: 0.05))
    #expect(events2 == [.abortedAsModifier])

    let events3 = recognizer.handle(.fnUp(t: 0.2))
    #expect(events3 == [])
}

@Test func doubleTapTogglesHandsFree() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnDown(shift: false, t: 0.25))
    #expect(events3 == [.toggleHandsFree(.english)])

    let events4 = recognizer.handle(.fnUp(t: 0.3))
    #expect(events4 == [])

    let events5 = recognizer.handle(.fnDown(shift: false, t: 5.0))
    #expect(events5 == [.stop])

    let events6 = recognizer.handle(.fnUp(t: 5.1))
    #expect(events6 == [])
}

@Test func slowSecondTapIsNewHold() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnDown(shift: false, t: 0.5))
    #expect(events3 == [.start(.english)])
}

@Test func escCancelsHold() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.otherKeyDown(keyCode: 53, t: 0.5))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnUp(t: 0.8))
    #expect(events3 == [])
}

@Test func escCancelsHandsFree() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnDown(shift: false, t: 0.25))
    #expect(events3 == [.toggleHandsFree(.english)])

    let events4 = recognizer.handle(.fnUp(t: 0.3))
    #expect(events4 == [])

    let events5 = recognizer.handle(.otherKeyDown(keyCode: 53, t: 2.0))
    #expect(events5 == [.cancel])

    let events6 = recognizer.handle(.fnDown(shift: false, t: 3.0))
    #expect(events6 == [.start(.english)])
}

@Test func tapUnder150msWithoutSecondTapIsIgnored() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.otherKeyDown(keyCode: 0, t: 1.0))
    #expect(events3 == [])
}

@Test func typingDuringHandsFreeIgnored() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnDown(shift: false, t: 0.25))
    #expect(events3 == [.toggleHandsFree(.english)])

    let events4 = recognizer.handle(.fnUp(t: 0.3))
    #expect(events4 == [])

    let events5 = recognizer.handle(.otherKeyDown(keyCode: 0, t: 2.0))
    #expect(events5 == [])
}

@Test func idleKeysIgnored() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.otherKeyDown(keyCode: 0, t: 0))
    #expect(events1 == [])

    let events2 = recognizer.handle(.fnUp(t: 0))
    #expect(events2 == [])
}

@Test func holdWithOtherKeyAborts() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.otherKeyDown(keyCode: 0, t: 0.05))
    #expect(events2 == [.abortedAsModifier])

    let events3 = recognizer.handle(.fnUp(t: 0.2))
    #expect(events3 == [])
}

@Test func quickTapAt150msIsStop() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.150))
    #expect(events2 == [.stop])
}

@Test func quickTapUnder150msIsCancel() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.149))
    #expect(events2 == [.cancel])
}

@Test func doubleTapAt350msIsToggle() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnDown(shift: false, t: 0.350))
    #expect(events3 == [.toggleHandsFree(.english)])
}

@Test func doubleTapOver350msIsNewHold() {
    var recognizer = GestureRecognizer()

    let events1 = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(events1 == [.start(.english)])

    let events2 = recognizer.handle(.fnUp(t: 0.1))
    #expect(events2 == [.cancel])

    let events3 = recognizer.handle(.fnDown(shift: false, t: 0.351))
    #expect(events3 == [.start(.english)])
}

@Test func doubleTapKeepsFirstTapMode() {
    var recognizer = GestureRecognizer()
    #expect(recognizer.handle(.fnDown(shift: true, t: 0)) == [.start(.indian)])
    #expect(recognizer.handle(.fnUp(t: 0.1)) == [.cancel])
    #expect(recognizer.handle(.fnDown(shift: false, t: 0.25)) == [.toggleHandsFree(.indian)])
}

@Test func fnDownWhileHoldingResyncs() {
    var recognizer = GestureRecognizer()
    #expect(recognizer.handle(.fnDown(shift: false, t: 0)) == [.start(.english)])
    #expect(recognizer.handle(.fnDown(shift: false, t: 2.0)) == [.cancel, .start(.english)])
    #expect(recognizer.handle(.fnUp(t: 3.0)) == [.stop])
}

@Test func fnDownWhileSuppressedStartsFresh() {
    var recognizer = GestureRecognizer()
    #expect(recognizer.handle(.fnDown(shift: false, t: 0)) == [.start(.english)])
    #expect(recognizer.handle(.otherKeyDown(keyCode: 126, t: 0.05)) == [.abortedAsModifier])
    #expect(recognizer.handle(.fnDown(shift: false, t: 1.0)) == [.start(.english)])
}

@Test func resetReturnsToIdle() {
    var recognizer = GestureRecognizer()
    _ = recognizer.handle(.fnDown(shift: false, t: 0))
    recognizer.reset()
    #expect(recognizer.handle(.fnUp(t: 1.0)) == [])
    #expect(recognizer.handle(.fnDown(shift: true, t: 2.0)) == [.start(.indian)])
}

@Test func recognizerIsIdleReflectsState() {
    var recognizer = GestureRecognizer()
    #expect(recognizer.isIdle)
    _ = recognizer.handle(.fnDown(shift: false, t: 0))
    #expect(!recognizer.isIdle)
    _ = recognizer.handle(.fnUp(t: 1.0))
    #expect(recognizer.isIdle)
    _ = recognizer.handle(.fnDown(shift: false, t: 2.0))
    recognizer.reset()
    #expect(recognizer.isIdle)
}
