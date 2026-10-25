import ArgumentParser
import CoverwallSpotify
import Foundation

struct Spotify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect your Spotify account (optional; folders need none of this).",
        subcommands: [Setup.self, Login.self, Logout.self, Status.self])

    static let privacy = "https://github.com/BunhourLong/Coverwall/blob/main/PRIVACY.md"

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
            let tokens = try await SpotifyAccount().login { url in
                print("Opening your browser to log in to Spotify. If it doesn't open, visit:\n\(url.absoluteString)")
                _ = try? shell("/usr/bin/open", url.absoluteString)
            }
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
