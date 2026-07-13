import Foundation
import Observation

/// Drives a debounced save off Swift Observation: it watches whatever
/// observable state `track` reads, and on the next change to any of it
/// schedules `save` to run after `delay`, coalescing a burst of mutations
/// into a single write. It re-arms itself after every change.
///
/// This is what lets an in-progress session reach disk WITHOUT a clean
/// app-lifecycle transition. A `SIGKILL` — Xcode's Stop button, a jetsam
/// kill, a crash — never delivers `.background`, so a flush wired only to
/// scene phase is lost; a change-driven debounced write is not.
///
/// Generic on purpose: the caller supplies the tracked reads and the write,
/// so there is no dependency on any particular model. The one rule is that
/// EVERY property whose value should trigger a save must be read inside
/// `track` — reads there are what Observation records. Mutating a nested
/// element of a tracked value-type collection (e.g. `array[i].field`) writes
/// back through the collection's own property, so it trips the observation
/// too.
@MainActor
public final class AutosaveObserver {
    private let delay: Duration
    private let track: () -> Void
    private let save: () -> Void
    private var pending: Task<Void, Never>?

    /// Whether a debounced write is currently scheduled and has not yet run.
    public var isPending: Bool { pending != nil }

    /// - Parameters:
    ///   - delay: how long to coalesce mutations before writing (default 1s).
    ///   - track: reads the observable state to watch.
    ///   - save: performs the write. Always invoked on the main actor.
    public init(
        delay: Duration = .seconds(1),
        track: @escaping () -> Void,
        save: @escaping () -> Void
    ) {
        self.delay = delay
        self.track = track
        self.save = save
    }

    /// Begins watching. Call once, AFTER the initial state is in place — so
    /// restoring a session doesn't immediately rewrite the file it just read.
    public func start() {
        arm()
    }

    /// Writes immediately and drops any pending debounced write. For a
    /// clean-shutdown flush (scene phase `.inactive` / `.background`).
    public func flush() {
        pending?.cancel()
        pending = nil
        save()
    }

    /// Drops any pending write without saving.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Coalesces mutations into a single write `delay` from now, replacing any
    /// write already scheduled.
    public func scheduleSave() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.delay)
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.save()
        }
    }

    private func arm() {
        withObservationTracking(track) { [weak self] in
            // onChange fires DURING the mutation, on an arbitrary thread; hop
            // to the main actor before we both schedule the save and
            // re-establish tracking (the documented Observation pattern).
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSave()
                self.arm()
            }
        }
    }
}
