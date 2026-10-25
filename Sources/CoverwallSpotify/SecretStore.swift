import CoverwallKit
import Foundation

/// The only way to tokens and the Client ID (CLAUDE.md 11). Values are never logged or put in argv.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(Int32)

    public var description: String {
        switch self {
        case .keychain(let status): "the login keychain refused (security exit \(status)) — unlock it in Keychain Access and try again"
        }
    }
}

/// Default store (SPIKE_NOTES Phase 7.0): `/usr/bin/security`, secret on stdin via `security -i`. Its ACL trusts
/// `security`, not our binary, so rebuilds, brew upgrades and launchd runs never prompt.
public struct KeychainSecretStore: SecretStore {
    public typealias Run = @Sendable (_ arguments: [String], _ stdin: String?) throws -> (status: Int32, stdout: String)
    static let notFound: Int32 = 44

    let service: String
    let run: Run

    public init(service: String = "com.bunhourlong.Coverwall", run: @escaping Run = KeychainSecretStore.security) {
        (self.service, self.run) = (service, run)
    }

    public func read(_ key: String) throws -> String? {
        let (status, stdout) = try run(["find-generic-password", "-s", service, "-a", key, "-w"], nil)
        if status == Self.notFound { return nil }
        guard status == 0 else { throw SecretStoreError.keychain(status) }
        return Data(base64Encoded: stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// base64 keeps quotes, spaces and newlines out of the `security -i` command line.
    public func write(_ value: String, for key: String) throws {
        let line = "add-generic-password -U -s \(service) -a \(key) -w \(Data(value.utf8).base64EncodedString())\n"
        let (status, _) = try run(["-i"], line)
        guard status == 0 else { throw SecretStoreError.keychain(status) }
    }

    public func delete(_ key: String) throws {
        let (status, _) = try run(["delete-generic-password", "-s", service, "-a", key], nil)
        guard status == 0 || status == Self.notFound else { throw SecretStoreError.keychain(status) }
    }

    public static let security: Run = { arguments, stdin in
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        (process.standardInput, process.standardOutput, process.standardError) = (input, output, FileHandle.nullDevice)
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self))
    }
}

/// Fallback when `/usr/bin/security` is missing: `secrets.json`, 0600, in a 0700 `Paths.cliDir`.
public struct FileSecretStore: SecretStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("secrets.json") }

    public init(directory: URL = Paths.cliDir) {
        self.directory = directory
    }

    public func read(_ key: String) throws -> String? { try all()[key] }

    public func write(_ value: String, for key: String) throws {
        var secrets = try all()
        secrets[key] = value
        try save(secrets)
    }

    public func delete(_ key: String) throws {
        var secrets = try all()
        guard secrets.removeValue(forKey: key) != nil else { return }
        try save(secrets)
    }

    private func all() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    private func save(_ secrets: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(secrets).write(to: file, options: .atomic)  // the 0700 dir hides the brief default-mode temp file
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public enum SecretStores {
    /// `COVERWALL_CLI_DIR` (test-only, like `COVERWALL_DATA_DIR`) keeps secrets in that dir, out of the real Keychain.
    public static var `default`: any SecretStore {
        if ProcessInfo.processInfo.environment["COVERWALL_CLI_DIR"] != nil { return FileSecretStore() }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/security") ? KeychainSecretStore() : FileSecretStore()
    }
}
