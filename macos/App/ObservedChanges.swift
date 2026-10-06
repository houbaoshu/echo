import Dispatch
import Observation

/// Keeps one of the observers below running. Cancelling it, or releasing it, stops the observer.
@MainActor final class ObservationHandle {
    private var stop: (@MainActor () -> Void)?
    fileprivate init(_ stop: @escaping @MainActor () -> Void) { self.stop = stop }
    func cancel() { stop?(); stop = nil }
    isolated deinit { cancel() }
}

/// Calls `onChange` with what `value` returns, each time a write to an observable property that
/// `value` read changes the result. The call happens synchronously inside that write, after the
/// new value is stored, so reading the subject from `onChange` sees it. Results equal to the last
/// one are dropped. `initial` also delivers the current result first.
///
/// Watching continues until the returned handle is cancelled or released.
@MainActor func observeChanges<Value: Equatable>(
    _ value: @escaping @MainActor () -> Value,
    initial: Bool = false,
    onChange: @escaping @MainActor (Value) -> Void
) -> ObservationHandle {
    let loop = ObservedChanges(value) { _, next in onChange(next) }
    loop.start(initial: initial)
    return ObservationHandle { loop.cancel() }
}

/// `observeChanges` that also hands over the result it replaces: what `value` returned before the
/// write, and what it returns now.
@MainActor func observeTransitions<Value: Equatable>(
    _ value: @escaping @MainActor () -> Value,
    onChange: @escaping @MainActor (_ old: Value, _ new: Value) -> Void
) -> ObservationHandle {
    let loop = ObservedChanges(value, onChange: onChange)
    loop.start(initial: false)
    return ObservationHandle { loop.cancel() }
}

/// Runs `read` now and watches every observable property it read. After one of them changes,
/// `read` runs again on the next main-queue turn, which picks what to watch next. Changes made
/// before that turn are folded into it: one run however many writes.
///
/// For work that depends on everything it reads, such as a window that mirrors a store, instead of
/// listing what it reads; and for work that may run at most once per turn anyway.
///
/// Everything `read` reads counts, including what code it calls reads. Observation records reads
/// per thread and adds an inner scope's to the enclosing one, so an observer that `read` starts
/// (a window controller it creates) or a save it runs would add its reads to these, and `read`
/// would rerun when they change. There is no public way to pause that recording short of running
/// the code later, so keep such calls out of `read`. An in-place write (`x.append`, `x.y = ...`)
/// also reads `x`; a write-only sink can write through `withMutation` instead, as
/// `VoiceDiagnostics.record` does.
@MainActor func observeReads(_ read: @escaping @MainActor () -> Void) -> ObservationHandle {
    let reads = ObservedReads(read)
    reads.arm()
    return ObservationHandle { reads.cancel() }
}

/// `withObservationTracking` reports one write and then stops; this re-arms it from inside each
/// report, before the handler runs, so a write the handler itself makes is reported too.
@MainActor private final class ObservedChanges<Value: Equatable> {
    private let value: @MainActor () -> Value
    private var onChange: (@MainActor (Value, Value) -> Void)?
    private var last: Value?
    /// Bumped on every re-arm and on cancel: a registration from before cannot be withdrawn, so a
    /// stale one recognizes itself when it fires and does nothing.
    private var generation = 0

    init(_ value: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value, Value) -> Void) {
        self.value = value; self.onChange = onChange
    }
    func start(initial: Bool) {
        let current = track()
        last = current
        if initial { onChange?(current, current) }
    }
    func cancel() {
        onChange = nil
        generation += 1
    }
    private func track() -> Value {
        generation += 1
        let armed = generation
        return withObservationTracking(options: [.didSet]) { value() } onChange: { [weak self] _ in
            // Observed subjects are main-actor state, so their writes, and this report, are on main.
            MainActor.assumeIsolated {
                guard let self, self.generation == armed, self.onChange != nil else { return }
                let next = self.track()
                guard let previous = self.last, next != previous else { return }
                self.last = next
                self.onChange?(previous, next)
            }
        }
    }
}

@MainActor private final class ObservedReads {
    private let read: @MainActor () -> Void
    private var cancelled = false

    init(_ read: @escaping @MainActor () -> Void) { self.read = read }
    func arm() {
        withObservationTracking(options: [.didSet]) { read() } onChange: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fire() } }
        }
    }
    func cancel() { cancelled = true }
    private func fire() {
        guard !cancelled else { return }
        arm()
    }
}
