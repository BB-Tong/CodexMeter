import XCTest
@testable import CodexMeterCore

final class PushDeliveryTests: XCTestCase {
    func testBarkEscapesCredentialAsOnePathComponentAndAvoidsDuplicates() throws {
        let config = PushChannelConfiguration(channel: .bark, serverURL: "https://push.example/prefix/", credential: "a/b?c")
        let request = try PushRequestBuilder.request(configuration: config, title: "Title", body: "Body")
        XCTAssertEqual(request.url?.absoluteString, "https://push.example/prefix/a%2Fb%3Fc")
        let complete = PushChannelConfiguration(channel: .bark, serverURL: "https://push.example/device", credential: "device")
        XCTAssertEqual(try PushRequestBuilder.request(configuration: complete, title: "", body: "").url?.path, "/device")
    }

    func testGotifyUsesHeaderAndPreservesServerSubpath() throws {
        let config = PushChannelConfiguration(channel: .gotify, serverURL: "https://push.example/gotify/", credential: "secret", priority: 500)
        let request = try PushRequestBuilder.request(configuration: config, title: "Title", body: "Body")
        XCTAssertEqual(request.url?.absoluteString, "https://push.example/gotify/message")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gotify-Key"), "secret")
        XCTAssertEqual(try payload(request)["priority"] as? Int, 10)
        XCTAssertNil(request.url?.query)
    }

    func testBarkIconAllowsNormalHTTPSImageQueryParameters() throws {
        let config = PushChannelConfiguration(channel: .bark, serverURL: "https://push.example", credential: "device",
                                              iconURL: "https://images.example/icon.png?version=2")
        let request = try PushRequestBuilder.request(configuration: config, title: "Title", body: "Body")
        XCTAssertEqual(try payload(request)["icon"] as? String, config.iconURL)
    }

    func testTelegramRequestUsesOfficialHostAndPlainText() throws {
        let config = PushChannelConfiguration(channel: .telegram, credential: "123:ABC_def-", target: "-100123")
        let request = try PushRequestBuilder.request(configuration: config, title: "Quota", body: "<b>80%</b> & text")
        XCTAssertEqual(request.url?.absoluteString, "https://api.telegram.org/bot123:ABC_def-/sendMessage")
        let json = try payload(request)
        XCTAssertEqual(json["chat_id"] as? String, "-100123")
        XCTAssertEqual(json["text"] as? String, "Quota\n<b>80%</b> & text")
        XCTAssertNil(json["parse_mode"])
        XCTAssertThrowsError(try PushRequestBuilder.request(configuration: .init(channel: .telegram, credential: "123:abc/evil", target: "1"), title: "", body: ""))
    }

    func testDiscordRequestsConfirmationAndDisablesMentions() throws {
        let config = PushChannelConfiguration(channel: .discord, credential: "https://discord.com/api/webhooks/123/token")
        let request = try PushRequestBuilder.request(configuration: config, title: "Quota", body: "@everyone 80%")
        XCTAssertEqual(request.url?.query, "wait=true")
        XCTAssertEqual(try payload(request)["content"] as? String, "Quota\n@everyone 80%")
        let mentions = try payload(request)["allowed_mentions"] as? [String: Any]
        XCTAssertEqual(mentions?["parse"] as? [String], [])
    }

    func testInvalidOrInsecureEndpointsAreRejected() {
        for server in ["http://push.example", "https://user:pass@push.example", "https://push.example?token=value", "https://push.example#fragment", "not a url"] {
            XCTAssertThrowsError(try PushRequestBuilder.request(configuration: .init(channel: .gotify, serverURL: server, credential: "secret"), title: "", body: ""))
        }
        for webhook in ["https://evil.example/api/webhooks/123/token", "https://discord.com/other/123/token", "https://discord.com/api/notaversion/webhooks/123/token", "https://discord.com/api/webhooks/notanid/token"] {
            XCTAssertThrowsError(try PushRequestBuilder.request(configuration: .init(channel: .discord, credential: webhook), title: "", body: ""))
        }
    }

    func testEmptyCredentialsAndTelegramTargetsAreRejected() {
        for channel in PushChannel.allCases {
            XCTAssertThrowsError(try PushRequestBuilder.request(configuration: .init(channel: channel, serverURL: "https://push.example"), title: "", body: ""))
        }
        XCTAssertThrowsError(try PushRequestBuilder.request(configuration: .init(channel: .telegram, credential: "123:abc"), title: "", body: ""))
    }

    func testSuccessfulAPIResponsesAreValidated() {
        for (channel, json) in [(PushChannel.bark, #"{"code":200}"#), (.gotify, #"{"id":1}"#), (.telegram, #"{"ok":true}"#), (.discord, #"{"id":"123"}"#)] {
            XCTAssertNil(PushDeliveryOutcome.evaluate(channel: channel, statusCode: 200, data: Data(json.utf8), networkError: false).failure)
            XCTAssertEqual(PushDeliveryOutcome.evaluate(channel: channel, statusCode: 200, data: Data("{}".utf8), networkError: false).failure, .rejected)
        }
    }

    func testTelegramSemanticFailureIsNotTreatedAsHTTP200Success() {
        let outcome = PushDeliveryOutcome.evaluate(channel: .telegram, statusCode: 200, data: Data(#"{"ok":false,"error_code":400,"description":"secret"}"#.utf8), networkError: false)
        XCTAssertEqual(outcome.failure, .rejected)
        XCTAssertFalse(outcome.retryable)
        XCTAssertEqual(outcome.failure?.localizedKey, "settings.push.error.rejected")
    }

    func testNullOrInvalidMessageIDsAreNotSuccessfulDeliveries() {
        for channel in [PushChannel.gotify, .discord] {
            for json in [#"{"id":null}"#, #"{"id":""}"#, #"{"id":false}"#, #"{"id":-1}"#] {
                XCTAssertEqual(PushDeliveryOutcome.evaluate(channel: channel, statusCode: 200,
                    data: Data(json.utf8), networkError: false).failure, .rejected)
            }
        }
    }

    func testRetryPolicyOnlyRetriesTransientFailuresAndStopsAfterThreeAttempts() {
        for code in [429, 500, 503] {
            let outcome = PushDeliveryOutcome.evaluate(channel: .gotify, statusCode: code, data: nil, networkError: false)
            XCTAssertEqual(PushRetryPolicy.delay(afterAttempt: 1, outcome: outcome), 2)
            XCTAssertEqual(PushRetryPolicy.delay(afterAttempt: 2, outcome: outcome), 5)
            XCTAssertNil(PushRetryPolicy.delay(afterAttempt: 3, outcome: outcome))
        }
        for code in [301, 400, 401, 403, 404] {
            XCTAssertNil(PushRetryPolicy.delay(afterAttempt: 1, outcome: .evaluate(channel: .bark, statusCode: code, data: nil, networkError: false)))
        }
        XCTAssertEqual(PushRetryPolicy.delay(afterAttempt: 1, outcome: .evaluate(channel: .bark, statusCode: nil, data: nil, networkError: true)), 2)
    }

    func testRetryAfterIsRespectedButBounded() {
        let header = PushDeliveryOutcome.evaluate(channel: .discord, statusCode: 429, data: nil, networkError: false, retryAfterHeader: "100000")
        XCTAssertEqual(PushRetryPolicy.delay(afterAttempt: 1, outcome: header), 60)
        let body = PushDeliveryOutcome.evaluate(channel: .telegram, statusCode: 429, data: Data(#"{"parameters":{"retry_after":8}}"#.utf8), networkError: false)
        XCTAssertEqual(PushRetryPolicy.delay(afterAttempt: 1, outcome: body), 8)
        XCTAssertEqual(PushRetryPolicy.delay(afterAttempt: 1, outcome: .init(failure: .network, retryable: true, retryAfter: -.infinity)), 60)
    }

    func testDedupIsPerChannelAndAccountResetInvalidatesCallbacks() {
        var ledger = PushDeliveryLedger()
        let oldGeneration = ledger.generation
        XCTAssertTrue(ledger.claim(eventID: "reset", channel: .bark))
        XCTAssertFalse(ledger.claim(eventID: "reset", channel: .bark))
        XCTAssertTrue(ledger.claim(eventID: "reset", channel: .telegram))
        XCTAssertTrue(ledger.accepts(oldGeneration))
        ledger.reset()
        XCTAssertFalse(ledger.accepts(oldGeneration))
        XCTAssertTrue(ledger.claim(eventID: "reset", channel: .bark))
    }

    private func payload(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}
