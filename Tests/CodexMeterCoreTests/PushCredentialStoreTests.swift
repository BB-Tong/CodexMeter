import XCTest
@testable import CodexMeterCore

final class PushCredentialStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var backend: FakeCredentialBackend!
    private var store: PushCredentialStore!

    override func setUp() {
        super.setUp()
        suiteName = "CodexMeter.PushCredentialStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        backend = FakeCredentialBackend()
        store = PushCredentialStore(defaults: defaults, backend: backend)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        backend = nil
        defaults = nil
        super.tearDown()
    }

    func testMissingCredentialsDefaultToEmptyWithoutCreatingItems() {
        for credential in PushCredential.allCases {
            let loaded = store.load(credential)
            XCTAssertEqual(loaded.value, "")
            XCTAssertFalse(loaded.failed)
        }
        XCTAssertTrue(backend.saved.isEmpty)
    }

    func testLegacyCredentialsMigrateOnlyAfterSuccessfulSecureSave() {
        for credential in [PushCredential.barkDeviceKey, .gotifyAppToken] {
            defaults.set("test-secret", forKey: credential.legacyDefaultsKey)
            let loaded = store.load(credential)
            XCTAssertEqual(loaded.value, "test-secret")
            XCTAssertFalse(loaded.failed)
            XCTAssertEqual(backend.values[credential], "test-secret")
            XCTAssertNil(defaults.object(forKey: credential.legacyDefaultsKey))
        }
    }

    func testMigrationSaveFailureKeepsLegacyValueAndReportsFailure() {
        defaults.set("legacy-secret", forKey: PushCredential.barkDeviceKey.legacyDefaultsKey)
        backend.failSave = true
        let loaded = store.load(.barkDeviceKey)
        XCTAssertEqual(loaded.value, "legacy-secret")
        XCTAssertTrue(loaded.failed)
        XCTAssertEqual(defaults.string(forKey: PushCredential.barkDeviceKey.legacyDefaultsKey), "legacy-secret")
        XCTAssertNil(backend.values[.barkDeviceKey])
    }

    func testMigrationReadFailureDoesNotOverwritePotentialSecureValue() {
        defaults.set("legacy-secret", forKey: PushCredential.gotifyAppToken.legacyDefaultsKey)
        backend.values[.gotifyAppToken] = "secure-secret"
        backend.failRead = true
        let loaded = store.load(.gotifyAppToken)
        XCTAssertEqual(loaded.value, "legacy-secret")
        XCTAssertTrue(loaded.failed)
        XCTAssertTrue(backend.saved.isEmpty)
        XCTAssertEqual(backend.values[.gotifyAppToken], "secure-secret")
        XCTAssertNotNil(defaults.object(forKey: PushCredential.gotifyAppToken.legacyDefaultsKey))
    }

    func testSecureCredentialWinsOverStaleLegacyPreference() {
        defaults.set("stale-secret", forKey: PushCredential.barkDeviceKey.legacyDefaultsKey)
        backend.values[.barkDeviceKey] = "secure-secret"
        let loaded = store.load(.barkDeviceKey)
        XCTAssertEqual(loaded.value, "secure-secret")
        XCTAssertFalse(loaded.failed)
        XCTAssertEqual(backend.values[.barkDeviceKey], "secure-secret")
        XCTAssertNil(defaults.object(forKey: PushCredential.barkDeviceKey.legacyDefaultsKey))
    }

    func testFailedSavePreservesExistingSecureAndLegacyValues() {
        backend.values[.discordWebhookURL] = "old-webhook"
        defaults.set("legacy-webhook", forKey: PushCredential.discordWebhookURL.legacyDefaultsKey)
        backend.failSave = true
        XCTAssertThrowsError(try store.save("new-webhook", for: .discordWebhookURL))
        XCTAssertEqual(backend.values[.discordWebhookURL], "old-webhook")
        XCTAssertEqual(defaults.string(forKey: PushCredential.discordWebhookURL.legacyDefaultsKey), "legacy-webhook")
    }

    func testNewSecretsAreNotStoredInDefaultsAndEmptyValueDeletesSecureItem() throws {
        try store.save("test-bot-token", for: .telegramBotToken)
        XCTAssertEqual(backend.values[.telegramBotToken], "test-bot-token")
        XCTAssertNil(defaults.object(forKey: PushCredential.telegramBotToken.legacyDefaultsKey))
        try store.save("", for: .telegramBotToken)
        XCTAssertNil(backend.values[.telegramBotToken])
    }

    func testMigrationCanBeRetriedAfterTemporaryFailure() {
        defaults.set("legacy-secret", forKey: PushCredential.gotifyAppToken.legacyDefaultsKey)
        backend.failSave = true
        XCTAssertTrue(store.load(.gotifyAppToken).failed)
        backend.failSave = false
        XCTAssertFalse(store.load(.gotifyAppToken).failed)
        XCTAssertEqual(backend.values[.gotifyAppToken], "legacy-secret")
        XCTAssertNil(defaults.object(forKey: PushCredential.gotifyAppToken.legacyDefaultsKey))
    }
}

private final class FakeCredentialBackend: PushCredentialBackend {
    var values: [PushCredential: String] = [:]
    var saved: [PushCredential] = []
    var failRead = false
    var failSave = false

    func read(_ credential: PushCredential) throws -> String? {
        if failRead { throw FakeFailure.denied }
        return values[credential]
    }

    func save(_ value: String, for credential: PushCredential) throws {
        if failSave { throw FakeFailure.denied }
        saved.append(credential)
        values[credential] = value.isEmpty ? nil : value
    }

    private enum FakeFailure: Error { case denied }
}
