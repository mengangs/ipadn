import Foundation

#if canImport(TestFlightKit)
import TestFlightKit
#endif

/// Read-only account identity snapshot for TestFlight (see `docs/ACCOUNT-MODEL.md`).
///
/// Backed solely by `AppleService`: never creates a second persistence store, never
/// mutates `AppleAccount.dsid` on conflict, and never touches `HTTPCookieStorage.shared`.
struct TFAccountIdentity: Identifiable, Equatable {
    let email: String
    let dsid: String
    let displayName: String
    let hasValidSession: Bool
    let hasTFJarSnapshot: Bool
    let hasPersistedTFSession: Bool

    var id: String { email }

    var label: String {
        displayName.isEmpty ? email : displayName
    }

    /// True when either a Keychain TF session or a persisted 10-cookie jar exists for this account.
    var isTFReady: Bool {
        hasPersistedTFSession || hasTFJarSnapshot
    }
}

/// Thin read-only facade over `AppleService` matching the `AccountStore` contract in
/// `docs/ACCOUNT-MODEL.md`.
@MainActor
struct TFAccountStore {
    let apple: AppleService

    var active: TFAccountIdentity? {
        apple.active.map(Self.makeIdentity)
    }

    var accounts: [TFAccountIdentity] {
        apple.accounts.map(Self.makeIdentity)
    }

    func account(for email: String) -> AppleAccount? {
        let normalized = AppleAccount.normalizedIdentifier(email)
        return apple.accounts.first {
            AppleAccount.normalizedIdentifier($0.id) == normalized
        }
    }

    func activate(_ email: String) {
        apple.select(email)
    }

    /// True when both sides have a non-empty DSID and they disagree. Callers must surface
    /// this as a warning and never overwrite `AppleAccount.dsid`.
    static func hasDSIDConflict(storeDsid: String, petDsid: String) -> Bool {
        let a = storeDsid.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = petDsid.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && !b.isEmpty && a != b
    }

    private static func makeIdentity(_ account: AppleAccount) -> TFAccountIdentity {
        let hasSnapshot: Bool
        let hasPersistedSession: Bool
        #if canImport(TestFlightKit)
        let cleanDsid = account.dsid.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single read point invariant: only `AccountScope.cookies(for:)` may inspect snapshots.
        hasSnapshot = !cleanDsid.isEmpty && AccountScope.cookies(for: cleanDsid) != nil
        hasPersistedSession = TFSessionStore.hasSession(dsid: cleanDsid, email: account.id)
        #else
        hasSnapshot = false
        hasPersistedSession = false
        #endif
        return TFAccountIdentity(
            email: account.id,
            dsid: account.dsid,
            displayName: account.name,
            hasValidSession: account.hasValidSession,
            hasTFJarSnapshot: hasSnapshot,
            hasPersistedTFSession: hasPersistedSession
        )
    }
}
