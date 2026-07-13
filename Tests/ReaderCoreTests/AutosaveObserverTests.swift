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
/// These tests are deliberately deadline-free: the whole package test run is
/// heavily parallel, so the observer's `@MainActor` debounce task can be
/// scheduled late under contention. They poll for the expected outcome with a
/// generous ceiling instead of asserting at a fixed wall-clock instant.
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

    /// Short debounce so a scheduled write resolves quickly.
    private static let delay: Duration = .milliseconds(50)

    private func makeObserver(
        _ fixture: Fixture, _ recorder: SaveRecorder
    ) -> AutosaveObserver {
        AutosaveObserver(
            delay: Self.delay,
            track: { _ = fixture.items; _ = fixture.flag },
            save: { recorder.count += 1 }
        )
    }

    /// Polls `condition` up to ~3s, yielding the main actor between checks so
    /// the debounced write can run even on a loaded machine.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Waits well past the debounce and asserts no write happened. Safe for
    /// negative cases: nothing was scheduled (or it was cancelled), so load
    /// can't turn this into a false pass.
    private func expectNoSaveSettles(_ recorder: SaveRecorder) async {
        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.count == 0)
    }

    @Test("a tracked mutation schedules exactly one debounced save")
    func mutationTriggersSave() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        fixture.flag = true
        #expect(recorder.count == 0)  // debounced, not written synchronously
        #expect(await eventually { recorder.count == 1 })
        #expect(recorder.count == 1)  // and only once
    }

    @Test("no mutation means no write")
    func idleDoesNotSave() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        await expectNoSaveSettles(recorder)
    }

    @Test("mutating a nested array element trips the observation")
    func nestedElementMutationTriggersSave() async {
        // The regression guard for the scroll path: ReaderSessionModel writes
        // `tabs[i].pageIndex`, which must reach disk. If a subscript write
        // stopped tripping the array observation, this is what would catch it.
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        fixture.items[0].value = 99
        #expect(await eventually { recorder.count == 1 })
    }

    @Test("a burst of mutations coalesces into one write")
    func burstCoalesces() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        for i in 1...20 { fixture.items[0].value = i }
        #expect(await eventually { recorder.count == 1 })
        // Give any stray extra write a chance to appear, then confirm it didn't.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(recorder.count == 1)
    }

    @Test("re-arming: a second change after the first save writes again")
    func rearmsAfterSave() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        fixture.flag = true
        #expect(await eventually { recorder.count == 1 })

        fixture.flag = false
        #expect(await eventually { recorder.count == 2 })
    }

    @Test("flush writes immediately and cancels the pending debounce")
    func flushWritesOnceImmediately() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        fixture.flag = true
        #expect(await eventually { observer.isPending })  // schedule has landed
        observer.flush()
        #expect(recorder.count == 1)      // written right away, no wait
        #expect(!observer.isPending)      // pending debounce was dropped

        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.count == 1)      // and not written a second time
    }

    @Test("cancel drops a pending write")
    func cancelDropsPending() async {
        let fixture = Fixture()
        let recorder = SaveRecorder()
        let observer = makeObserver(fixture, recorder)
        observer.start()

        fixture.flag = true
        #expect(await eventually { observer.isPending })  // schedule has landed
        observer.cancel()
        #expect(!observer.isPending)
        await expectNoSaveSettles(recorder)
    }
}
