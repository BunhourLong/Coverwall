import Foundation

/// Per-instance energy gating (PLAN.md §4.6): the view feeds it events and only runs its timer
/// and keeps decoded images while `isActive`.
public struct SaverActivity: Equatable, Sendable {
    public enum Event: Sendable {
        case sessionStarted     // com.apple.screensaver.didstart
        case sessionStopped     // com.apple.screensaver.willstop
        case animationStarted   // startAnimation()
        case visible(Bool)      // window occlusionState contains .visible
        case displayAsleep(Bool) // NSWorkspace.screensDidSleep / screensDidWake
        case thermal(ProcessInfo.ThermalState)
        case lowPower(Bool)     // ProcessInfo.isLowPowerModeEnabled
        case reduceMotion(Bool) // NSWorkspace.accessibilityDisplayShouldReduceMotion
    }

    private var session: Bool
    private var started = false
    private var visible = false
    private var displayAsleep = false
    private var thermal = ProcessInfo.ThermalState.nominal
    private var lowPower = false
    private var reduceMotion = false

    /// `sessionActive`: the process-wide didstart/willstop flag, for instances created mid-session.
    public init(sessionActive: Bool = false) {
        session = sessionActive
    }

    public var isActive: Bool { session && started && visible && !displayAsleep }

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
        case .visible(let isVisible): visible = isVisible
        case .displayAsleep(let asleep): displayAsleep = asleep
        case .thermal(let state): thermal = state
        case .lowPower(let on): lowPower = on
        case .reduceMotion(let on): reduceMotion = on
        }
    }
}
