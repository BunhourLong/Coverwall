import Testing
import CoverwallKit

@Test func newerInstanceOnTheSameScreenSupersedesTheOlderOne() {
    var roster = SaverRoster()
    #expect(roster.started(1, on: 7) == nil)  // background instance
    #expect(roster.started(2, on: 7) == 1)    // the session's instance takes over
    #expect(roster.started(1, on: 7) == 2)    // whoever starts last wins
}

@Test func instancesOnDifferentScreensRunSideBySide() {
    var roster = SaverRoster()
    #expect(roster.started(1, on: 7) == nil)
    #expect(roster.started(2, on: 8) == nil)
    #expect(roster.started(3, on: 8) == 2)
}

@Test func restartingTheCurrentInstanceSupersedesNobody() {
    var roster = SaverRoster()
    _ = roster.started(1, on: 7)
    #expect(roster.started(1, on: 7) == nil)
}
