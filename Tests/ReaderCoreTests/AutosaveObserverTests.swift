import Clocks
import Foundation
import Observation
import Testing
@testable import ReaderCore

/// The autosave contract that `ReaderSessionModel` relies on: a change to any
/// tracked observable state schedules exactly one debounced write, and the
/// re-arming keeps that true across successive changes — including the
/// easy-to-break case of mutating a nested element of a tracked array
/// (the `tabs[i].pageIndex` scroll-tick path).
///
/// These tests are deterministic: the observer sleeps on an injected
/// `TestClock`, so the debounced write fires exactly when the test advances the
/// clock — never on elapsed real time. That removes the whole class of flakiness
/// where a `@MainActor` debounce task is scheduled late on a loaded runner and a
/// fixed poll ceiling expires before it runs. `TestClock.advance(by:)` moves
/// virtual time forward and yields the executor enough for the woken write to
/// complete before it returns.
@MainActor
@Suite struct AutosaveObserverTests {
    /// Stand-in for the session model: one observed array of value-type
    /// elements plus a scalar, mirroring `tabs` + `activeTabID`.
    @Observable final class Fixture {
        struct Item { var value: Int }
        var items: [Item] = [Item(value: 0)]
        var flag: Bool = false
    }

    /// Records how many times `save` ran (reference type so the escaping save
    /// closure and the test share one counter).
    final class SaveRecorder { var count = 0 }

    /// The virtual debounce interval. Its value is irrelevant to wall-clock
    /// time — the test advances the `TestClock` by exactly this to fire a write.
    private static let delay: Duration = .seconds(1)

    private func makeObserver(
        _ fixture: Fixture, _ recorder: SaveRecorder, clock: TestClock<Duration>
    ) -> AutosaveObserver {
        AutosaveObserver(
            delay: Self.delay,
            clock: clock,
            track: { _ = fixture.items; _ = fixture.flag },
            save: { recorder.count += 1 }
        )
    }

    /// Cooperatively yields until a debounced write has been scheduled. The
    /// Observation callback hops to the main actor via a `Task`, so `isPending`
    /// only flips after that task runs; yielding lets it. Bounded by the observer
    /// making progress, not by any deadline — a loaded runner just takes a few
    /// more yields. Ensures the sleeper is on the clock before we advance it.
    private func awaitPending(_ observer: AutosaveObserver) async {
        while !observer.isPending { await Task.yield() }
    }

    @Test("a tracked mutation schedules exactly one debounced save")
    func mutationTriggersSave() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        fixture.flag = true
        #expect(recorder.count == 0)  // debounced, not written synchronously
        await awaitPending(observer)
        #expect(recorder.count == 0)  // still only scheduled; the clock hasn't moved
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 1)  // debounce elapsed → written exactly once
        #expect(!observer.isPending)
    }

    @Test("no mutation means no write")
    func idleDoesNotSave() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        // Even with time passing, an untouched fixture schedules nothing.
        await clock.advance(by: Self.delay)
        #expect(!observer.isPending)
        #expect(recorder.count == 0)
    }

    @Test("mutating a nested array element trips the observation")
    func nestedElementMutationTriggersSave() async {
        // The regression guard for the scroll path: ReaderSessionModel writes
        // `tabs[i].pageIndex`, which must reach disk. If a subscript write
        // stopped tripping the array observation, this is what would catch it.
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        fixture.items[0].value = 99
        await awaitPending(observer)
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 1)
    }

    @Test("a burst of mutations coalesces into one write")
    func burstCoalesces() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        for i in 1...20 { fixture.items[0].value = i }
        await awaitPending(observer)
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 1)   // the whole burst collapsed to one write
        #expect(!observer.isPending)   // and nothing else is queued behind it
    }

    @Test("re-arming: a second change after the first save writes again")
    func rearmsAfterSave() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        fixture.flag = true
        await awaitPending(observer)
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 1)

        fixture.flag = false
        await awaitPending(observer)
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 2)
    }

    @Test("flush writes immediately and cancels the pending debounce")
    func flushWritesOnceImmediately() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        fixture.flag = true
        await awaitPending(observer)   // schedule has landed
        observer.flush()
        #expect(recorder.count == 1)   // written right away, no wait
        #expect(!observer.isPending)   // pending debounce was dropped

        // The clock's debounce deadline never arrives (we don't advance to it),
        // and the write task was cancelled — so it can never fire a second time.
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 1)
    }

    @Test("cancel drops a pending write")
    func cancelDropsPending() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let clock = TestClock()
        let observer = makeObserver(fixture, recorder, clock: clock)
        observer.start()

        fixture.flag = true
        await awaitPending(observer)   // schedule has landed
        observer.cancel()
        #expect(!observer.isPending)

        // Advancing past the debounce proves the cancelled write never runs.
        await clock.advance(by: Self.delay)
        #expect(recorder.count == 0)
    }
}
