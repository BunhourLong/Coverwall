import Foundation
import Testing
import CoverwallKit

private let allConditions: [SaverActivity.Event] = [.sessionStarted, .animationStarted]

@Test func activeOnlyWhenSessionAndStartedInAnyOrder() {
    var activity = SaverActivity()
    #expect(!activity.isActive)
    for event in allConditions.reversed() {
        #expect(!activity.isActive)
        activity.handle(event)
    }
    #expect(activity.isActive)
}

@Test(arguments: allConditions.indices)
func idleWhenAnyConditionIsMissing(missing: Int) {
    var activity = SaverActivity()
    for (i, event) in allConditions.enumerated() where i != missing { activity.handle(event) }
    #expect(!activity.isActive)
}

private func runningActivity() -> SaverActivity {
    var activity = SaverActivity()
    allConditions.forEach { activity.handle($0) }
    return activity
}

@Test func abandonedInstanceStaysIdleThroughTheNextSession() {
    var activity = runningActivity()
    activity.handle(.sessionStopped)
    #expect(!activity.isActive)
    activity.handle(.sessionStarted)  // didstart fans out to every live instance…
    #expect(!activity.isActive)       // …but only the session's instances get startAnimation
    activity.handle(.animationStarted)
    #expect(activity.isActive)
}

@Test func instanceCreatedMidSessionPicksUpTheProcessWideFlag() {
    var activity = SaverActivity(sessionActive: true)
    activity.handle(.animationStarted)
    #expect(activity.isActive)
}

@Test func supersededOrStoppedInstanceIdlesUntilStartedAgain() {
    var activity = runningActivity()
    activity.handle(.animationStopped)  // stopAnimation, or a newer instance started on this screen
    #expect(!activity.isActive)
    activity.handle(.animationStarted)
    #expect(activity.isActive)
}

@Test func displaySleepPausesAndWakeResumes() {
    var activity = runningActivity()
    activity.handle(.displayAsleep(true))
    #expect(!activity.isActive)
    activity.handle(.displayAsleep(false))
    #expect(activity.isActive)
}

@Test func normalConditionsKeepTheProfileSettings() {
    var activity = runningActivity()
    activity.handle(.thermal(.fair))
    #expect(activity.interval(base: 4) == 4)
    #expect(activity.transition(preferred: .flip) == .flip)
}

@Test(arguments: [SaverActivity.Event.thermal(.serious), .thermal(.critical), .lowPower(true)])
func heatOrLowPowerDoublesIntervalAndFades(event: SaverActivity.Event) {
    var activity = runningActivity()
    activity.handle(event)
    #expect(activity.isActive)
    #expect(activity.interval(base: 4) == 8)
    #expect(activity.transition(preferred: .flip) == .fade)
}

@Test func reduceMotionFadesWithoutSlowingDown() {
    var activity = runningActivity()
    activity.handle(.reduceMotion(true))
    #expect(activity.interval(base: 4) == 4)
    #expect(activity.transition(preferred: .flip) == .fade)
}
