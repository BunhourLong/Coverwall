import Foundation

/// CLI-only: the user LaunchAgent behind `coverwall spotify schedule on` (PLAN.md §4.7, 7.5).
public enum LaunchAgent {
    public static let label = "com.bunhourlong.Coverwall.sync"

    /// Homebrew's Cellar path changes with every upgrade; its `opt` link doesn't.
    public static func stableBinary(_ path: String) -> String {
        guard let cellar = path.range(of: "/Cellar/coverwall/") else { return path }
        return path[..<cellar.lowerBound] + "/opt/coverwall/bin/coverwall"
    }

    /// Daily at 05:00 (launchd catches up after sleep) and at every login (it doesn't after a shutdown), as a
    /// background process, output appended to `log`.
    public static func plist(binary: String, log: URL) throws -> Data {
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "spotify", "sync"],
            "StartCalendarInterval": ["Hour": 5, "Minute": 0],
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "ProcessType": "Background",
            "RunAtLoad": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
    }
}
