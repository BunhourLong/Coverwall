import Foundation
import Testing
import CoverwallKit

@Test func scheduledSyncUsesAPathThatSurvivesBrewUpgrades() {
    #expect(LaunchAgent.stableBinary("/opt/homebrew/Cellar/coverwall/0.2.0/bin/coverwall") == "/opt/homebrew/opt/coverwall/bin/coverwall")
    #expect(LaunchAgent.stableBinary("/usr/local/Cellar/coverwall/1.0_1/bin/coverwall") == "/usr/local/opt/coverwall/bin/coverwall")
    #expect(LaunchAgent.stableBinary("/Users/me/.local/bin/coverwall") == "/Users/me/.local/bin/coverwall")
}

@Test func agentRunsTheSpotifySyncDailyInTheBackgroundIntoTheLog() throws {
    let plist = try LaunchAgent.plist(binary: "/opt/homebrew/opt/coverwall/bin/coverwall", log: URL(fileURLWithPath: "/tmp/cw/sync.log"))
    let dict = try #require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])

    #expect(dict["Label"] as? String == "com.bunhourlong.Coverwall.sync")
    #expect(dict["ProgramArguments"] as? [String] == ["/opt/homebrew/opt/coverwall/bin/coverwall", "spotify", "sync"])
    let when = try #require(dict["StartCalendarInterval"] as? [String: Int])
    #expect(when.keys.sorted() == ["Hour", "Minute"])  // daily; launchd runs a missed one after wake
    #expect(dict["StandardOutPath"] as? String == "/tmp/cw/sync.log" && dict["StandardErrorPath"] as? String == "/tmp/cw/sync.log")
    #expect(dict["ProcessType"] as? String == "Background")
    #expect(dict["RunAtLoad"] as? Bool == true)  // also at every login: calendar runs don't catch up after a shutdown
}
