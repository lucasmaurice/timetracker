import Foundation
import Testing
@testable import timetracker

/// #19 — credentials must reach the Keychain only AFTER validation succeeds.
///
/// The original bug wrote the PAT first and relied on the caller's `catch` to call `disconnect()`;
/// that made a property of secret storage depend on every future call site's error handling.
///
/// These run fully offline: `connect(org: "")` fails in `orgBase()` (`notConfigured`) before any
/// request is attempted. Every test redirects the Keychain to a throwaway account first — if the
/// ordering ever regresses, a test like this would otherwise overwrite a real working PAT with the
/// bogus one it just tried.
@Suite(.serialized)
struct CredentialOrderingTests {

    /// Unique per test so a leftover item from a previous run can't produce a false pass.
    private func withTestAccount(_ body: (String) async throws -> Void) async rethrows {
        let account = "tt-test-\(UUID().uuidString)"
        AzureDevOps.keychainAccountOverride = account
        defer { Keychain.delete(account: account); AzureDevOps.keychainAccountOverride = nil }
        try await body(account)
    }

    /// Positive control. An "assert nothing was written" test is worthless if writes never land in
    /// the place being checked — this proves the seam and the assertion both work, so the real
    /// test below can only pass for the right reason.
    @Test func theSeamActuallyStoresAndReadsBack() async {
        await withTestAccount { account in
            #expect(Keychain.getCodable(AzureDevOps.Credentials.self, account: account) == nil)
            Keychain.setCodable(AzureDevOps.Credentials(org: "acme", pat: "secret"), account: account)
            #expect(Keychain.getCodable(AzureDevOps.Credentials.self, account: account)?.org == "acme")
        }
    }

    /// The actual regression test: a `connect` that throws must leave the Keychain untouched.
    @Test func aFailedConnectPersistsNothing() async {
        await withTestAccount { account in
            let azdo = AzureDevOps(config: testConfig())
            await #expect(throws: (any Error).self) {
                _ = try await azdo.connect(org: "", pat: "bogus-pat-that-must-never-be-stored")
            }
            #expect(Keychain.getCodable(AzureDevOps.Credentials.self, account: account) == nil,
                    "an unverified PAT reached the Keychain")
        }
    }

    /// Documents the other half of the contract, which is why `disconnect()` in the caller's catch
    /// still matters: the credentials ARE held in memory during validation (testConnection needs
    /// them), so a failed connect leaves the client looking configured until the caller clears it.
    @Test func aFailedConnectStillLeavesCredentialsInMemoryUntilDisconnect() async {
        await withTestAccount { _ in
            let azdo = AzureDevOps(config: testConfig())
            _ = try? await azdo.connect(org: "", pat: "bogus")
            #expect(azdo.configured, "testConnection needs the credentials in memory to validate them")
            azdo.disconnect()
            #expect(!azdo.configured)
        }
    }
}
