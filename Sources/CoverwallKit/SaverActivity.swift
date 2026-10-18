import Foundation

/// Per-instance energy gating (PLAN.md §4.6): the view feeds it events and only runs its timer
/// and keeps decoded images while `isActive`.
public struct SaverActivity: Equatable, Sendable {
    public enum Event: Sendable {
        case sessionStarted     // com.apple.screensaver.didstart
        case sessionStopped     // com.apple.screensaver.willstop
        case animationStarted   // startAnimation()
        case animationStopped   // stopAnimation(), or a newer instance started on this screen
        case displayAsleep(Bool) // NSWorkspace.screensDidSleep / screensDidWake
        case thermal(ProcessInfo.ThermalState)
        case lowPower(Bool)     // ProcessInfo.isLowPowerModeEnabled
        case reduceMotion(Bool) // NSWorkspace.accessibilityDisplayShouldReduceMotion
    }

    private var session: Bool
    private var started = false
    private var displayAsleep = false
    private var thermal = ProcessInfo.ThermalState.nominal
    private var lowPower = false
    private var reduceMotion = false

    /// `sessionActive`: the process-wide didstart/willstop flag, for instances created mid-session.
    /// Occlusion isn't an input: it says "hidden" for every full-screen instance (SPIKE_NOTES Phase 3).
    public init(sessionActive: Bool = false) {
        session = sessionActive
    }

    public var isActive: Bool { session && started && !displayAsleep }

    private var throttled: Bool { thermal == .serious || thermal == .critical || lowPower }

    public func interval(base: TimeInterval) -> TimeInterval { throttled ? base * 2 : base }

    public func transition(preferred: Transition) -> Transition { throttled || reduceMotion ? .fade : preferred }

    public mutating func handle(_ event: Event) {
        switch event {
        case .sessionStarted: session = true
        // stopAnimation never arrives (SPIKE_NOTES Q4): willstop also ends "started", so instances
        // the host abandons stay idle; only a new startAnimation brings one back.
        case .sessionStopped: (session, started) = (false, false)
        case .animationStarted: started = true
        case .animationStopped: started = false
        case .displayAsleep(let asleep): displayAsleep = asleep
        case .thermal(let state): thermal = state
        case .lowPower(let on): lowPower = on
        case .reduceMotion(let on): reduceMotion = on
        }
    }
}

/// Process-wide: the instance on screen is the last one to receive `startAnimation` on that display
/// (SPIKE_NOTES Phase 3); the host's background instance and abandoned ones must give way to it.
public struct SaverRoster: Sendable {
    private var current: [UInt32: Int] = [:]  // display id → instance

    public init() {}

    /// Records that `instance` started on `screen`; returns the instance it supersedes, if any.
    public mutating func started(_ instance: Int, on screen: UInt32) -> Int? {
        defer { current[screen] = instance }
        return current[screen].flatMap { $0 == instance ? nil : $0 }
    }
}
