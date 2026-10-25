import ArgumentParser
import CoverwallKit
import CoverwallSpotify
import Foundation

struct Spotify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect your Spotify account (optional; folders need none of this).",
        subcommands: [Setup.self, Login.self, Logout.self, Status.self, Sync.self, Schedule.self])

    static let privacy = "https://github.com/BunhourLong/Coverwall/blob/main/PRIVACY.md"

    static func openBrowser(_ url: URL) {
        warn("Opening your browser to log in to Spotify. If it doesn't open, visit:\n\(url.absoluteString)")  // stderr: `--json` stays clean
        _ = try? shell("/usr/bin/open", url.absoluteString)
    }

    /// `add … spotify:…` in a terminal logs in first instead of failing; without a terminal it fails with the next step.
    static func loginIfNeeded() async throws {
        let account = SpotifyAccount()
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0, try account.clientID() != nil, try !account.isLoggedIn() else { return }
        warn("Not logged in to Spotify yet — logging in first.")
        _ = try await account.login(open: openBrowser)
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Refresh every Spotify profile (what the daily schedule runs).")
        @Flag(help: "Print Spotify's raw error replies.") var verbose = false

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)  // into the log file: keep stdout lines in order with stderr's
            print("— \(Date().formatted(date: .abbreviated, time: .standard)) spotify sync")  // the log is appended to daily
            let store = Store(source: SpotifySources.factory(trace: trace(verbose), http: URLSession.spotifyPatient))
            let names = try store.load().profiles.filter { SpotifySource.Kind(source: $0.value.source) != nil }.keys.sorted()
            guard !names.isEmpty else { return print("no Spotify profiles — add one with `coverwall add <name> spotify:saved-albums`") }
            var failed = false
            for name in names {
                do {
                    let report = try await store.sync(name)
                    print("\(name): \(report.images) covers (\(report.added) new, \(report.removed) gone)")
                } catch {
                    warn("\(name): \(error)")  // the others still sync
                    failed = true
                }
            }
            if failed { throw ExitCode.failure }
        }
    }

    /// Unloads and deletes the daily sync's LaunchAgent; fine if it isn't there.
    static func unschedule() {
        _ = try? shell("/bin/launchctl", "bootout", "gui/\(getuid())/\(LaunchAgent.label)")
        try? FileManager.default.removeItem(at: Paths.launchAgent)
    }

    struct Schedule: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn the daily Spotify sync on or off (a user LaunchAgent).")
        enum State: String, ExpressibleByArgument { case on, off }
        @Argument(help: "on or off.") var state: State

        func run() throws {
            guard state == .on else {
                Spotify.unschedule()
                return print("daily Spotify sync off")
            }
            let domain = "gui/\(getuid())"
            _ = try shell("/bin/launchctl", "bootout", "\(domain)/\(LaunchAgent.label)")  // not loaded is fine
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                throw ValidationError("can't tell where this coverwall lives — run it by its full path")
            }
            let fm = FileManager.default
            try fm.createDirectory(at: Paths.cliDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgent.plist(binary: LaunchAgent.stableBinary(executable), log: Paths.syncLog).write(to: Paths.launchAgent, options: .atomic)
            guard try shell("/bin/launchctl", "bootstrap", domain, Paths.launchAgent.path).status == 0 else {
                warn("launchctl couldn't load \(Paths.launchAgent.path) — run `launchctl bootstrap \(domain) \(Paths.launchAgent.path)` to see why")
                throw ExitCode.failure
            }
            print("daily Spotify sync on (05:00, after wake if the Mac slept, and at every login) — log: \(Paths.syncLog.path)")
            if !((try? SpotifyAccount().isLoggedIn()) ?? false) { warn("not logged in yet — run `coverwall spotify login`, or the sync will fail") }
        }
    }

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register your own Spotify app and store its Client ID.")
        @Option(name: .customLong("client-id"), help: "Skip the prompt.") var clientID: String?

        func run() throws {
            // The Premium/allowlist limits come first: no point creating an app that can't work (PLAN.md §4.7).
            print("""
                Before you start: Spotify only runs apps in Development Mode if the app's owner has Spotify Premium.
                With coverwall you create your own app, so the owner is you. Up to 5 Spotify accounts can use it,
                each added under User Management in the dashboard.

                1. Open https://developer.spotify.com/dashboard and log in.
                2. Create app: any name and description. Redirect URI: http://127.0.0.1/callback (exactly, no port).
                   Under "Which API/SDKs are you planning to use?" tick Web API. Save.
                3. Open the app's Settings and copy the Client ID.

                What coverwall stores and where: \(Spotify.privacy)

                """)
            var id = clientID
            if id == nil {
                print("Client ID: ", terminator: "")
                id = readLine()
            }
            try SpotifyAccount().setClientID(id ?? "")
            print("saved — next: coverwall spotify login")
        }
    }

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Log in through your browser (waits up to 2 minutes).")

        func run() async throws {
            let tokens = try await SpotifyAccount().login(open: openBrowser)
            print("logged in — access to: \(tokens.scope.isEmpty ? "(none)" : tokens.scope)")
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget the Spotify login on this Mac.")
        @Flag(help: "Also forget the Client ID.") var all = false

        func run() throws {
            try SpotifyAccount().logout(all: all)
            // Covers fetched with this login may not outlive it (Spotify's terms); the profiles stay and refill on sync.
            let purged = try store().purgeExpiringCaches()
            print("""
                logged out\(all ? " and Client ID removed" : "") on this Mac\(purged.isEmpty ? "" : "; removed the cached covers of \(purged.joined(separator: ", "))").
                To also remove coverwall's access from your account: Spotify account page → Manage apps → Remove access.
                """)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the Spotify setup and check the login live.")
        @Flag(help: "Print as JSON.") var json = false

        func run() async throws {
            let status = try await SpotifyAccount().status()
            if json {
                try printJSON(status)
            } else {
                print("Client ID: " + (status.clientID ? "set" : "not set — run `coverwall spotify setup`"))
                guard status.loggedIn else { return print("Login: no — run `coverwall spotify login`") }
                print("Login: yes" + (status.user.map { " as \($0)" } ?? ""))
                print("Access: \(status.scopes.joined(separator: ", "))")
                if let expiresAt = status.expiresAt { print("Token renews automatically; current one valid until \(expiresAt.formatted(date: .omitted, time: .shortened))") }
                if let problem = status.problem { warn("Live check failed: \(problem)") }
            }
            if status.problem != nil { throw ExitCode.failure }  // with --json too, like `doctor`
        }
    }
}
