import Foundation
import Testing
import CoverwallSpotify

/// Records every `security` call; answers with a canned status + stdout.
private final class FakeSecurity: @unchecked Sendable {
    var calls: [(arguments: [String], stdin: String?)] = []
    var answer: (status: Int32, stdout: String) = (0, "")
    lazy var store = KeychainSecretStore(service: "test.service") { [unowned self] arguments, stdin in
        calls.append((arguments, stdin))
        return answer
    }
}

@Test func keychainWritesTheSecretOnStdinNeverInArgv() throws {
    let security = FakeSecurity()
    try security.store.write("tok \"quoted\" \\ secret", for: "tokens")

    let call = try #require(security.calls.first)
    #expect(call.arguments == ["-i"])
    #expect(call.arguments.allSatisfy { !$0.contains("tok") })
    let base64 = Data("tok \"quoted\" \\ secret".utf8).base64EncodedString()
    #expect(call.stdin == "add-generic-password -U -s test.service -a tokens -w \(base64)\n")
}

@Test func keychainReadsBackWhatWasWrittenAndMissingIsNil() throws {
    let security = FakeSecurity()
    security.answer = (0, Data("s3cret".utf8).base64EncodedString() + "\n")
    #expect(try security.store.read("tokens") == "s3cret")
    #expect(security.calls.last?.arguments == ["find-generic-password", "-s", "test.service", "-a", "tokens", "-w"])

    security.answer = (44, "")
    #expect(try security.store.read("tokens") == nil)
    try security.store.delete("tokens")  // already gone is fine
    #expect(security.calls.last?.arguments == ["delete-generic-password", "-s", "test.service", "-a", "tokens"])
}

@Test func keychainFailuresAreErrorsNotSilentLoss() {
    let security = FakeSecurity()
    security.answer = (51, "")
    #expect(throws: SecretStoreError.keychain(51)) { try security.store.read("tokens") }
    #expect(throws: SecretStoreError.keychain(51)) { try security.store.write("x", for: "tokens") }
    #expect(throws: SecretStoreError.keychain(51)) { try security.store.delete("tokens") }
}

@Test func fileStoreKeepsSecretsInAPrivateFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coverwall-secrets-\(UUID().uuidString)/cli")
    let store = FileSecretStore(directory: dir)

    #expect(try store.read("tokens") == nil)
    try store.write("a", for: "tokens")
    try store.write("b", for: "client-id")
    try store.delete("tokens")

    #expect(try store.read("tokens") == nil && store.read("client-id") == "b")
    let file = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("secrets.json").path)
    let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
    #expect(file[.posixPermissions] as? Int == 0o600 && folder[.posixPermissions] as? Int == 0o700)
}
