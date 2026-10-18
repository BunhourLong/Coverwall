import Foundation

/// `config.json`, written by the CLI, read by the saver (PLAN.md §4.1).
public struct Config: Codable, Equatable, Sendable {
    public var version: Int
    public var activeProfile: String?
    public var profiles: [String: Profile]

    public var active: Profile? { activeProfile.flatMap { profiles[$0] } }

    public static let currentVersion = 1

    /// Decodes and validates; the first problem found is thrown.
    public static func decode(_ data: Data) throws -> Config {
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw ConfigError.unsupportedVersion(version) }
        if let activeProfile, profiles[activeProfile] == nil { throw ConfigError.unknownActiveProfile(activeProfile) }
        for (name, profile) in profiles {
            guard Self.isSafeName(name) else { throw ConfigError.invalidProfileName(name) }
            try profile.validate(name: name)
        }
    }

    /// Profile names become directory names under the data dir.
    static func isSafeName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case unknownActiveProfile(String)
    case invalidProfileName(String)
    case invalid(profile: String, field: String, expected: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v):
            "config.json version \(v) is newer than this coverwall understands (\(Config.currentVersion)) — upgrade coverwall"
        case .unknownActiveProfile(let name):
            "active profile '\(name)' does not exist — run `coverwall list`, then `coverwall use <name>`"
        case .invalidProfileName(let name):
            "profile name '\(name)' is invalid — use letters, digits, '-' or '_' (not starting with '-')"
        case .invalid(let profile, let field, let expected):
            "profile '\(profile)': \(field) must be \(expected) — fix it with `coverwall set \(profile) ...`"
        }
    }
}

public struct Profile: Codable, Equatable, Sendable {
    public var source: String
    public var grid: Grid
    public var intervalSeconds: Double
    public var swapsPerTick: Int
    public var transition: Transition
    public var tileMaxPixels: Int
    public var background: String
    public var gapPoints: Double

    func validate(name: String) throws {
        func check(_ ok: Bool, _ field: String, _ expected: String) throws {
            if !ok { throw ConfigError.invalid(profile: name, field: field, expected: expected) }
        }
        let range = 1...16
        try check(source.hasPrefix("/"), "source", "an absolute path")
        try check(range.contains(grid.columns) && range.contains(grid.rows), "grid", "1x1 … 16x16")
        try check(intervalSeconds > 0, "intervalSeconds", "> 0")
        try check((1...grid.columns * grid.rows).contains(swapsPerTick), "swapsPerTick", "1 … columns × rows")
        try check(tileMaxPixels > 0, "tileMaxPixels", "> 0")
        try check(background.count == 7 && background.first == "#" && background.dropFirst().allSatisfy(\.isHexDigit),
                  "background", "#RRGGBB")
        try check(gapPoints >= 0, "gapPoints", ">= 0")
    }
}

public struct Grid: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public enum Transition: String, Codable, Sendable {
    case flip, fade
}
