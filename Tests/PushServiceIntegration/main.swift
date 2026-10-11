import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var barkEnabled = true
    @Published var gotifyEnabled = false
    @Published var telegramEnabled = false
    @Published var discordEnabled = false
    @Published var pushFiveHourResetEnabled = true
    @Published var pushWeeklyResetEnabled = true
    @Published var barkServerURL = "https://push.example"
    @Published var barkDeviceKey = "fake-key"
    @Published var barkIconURL = ""
    @Published var gotifyServerURL = ""
    @Published var gotifyAppToken = ""
    @Published var gotifyPriority = 5
    @Published var telegramBotToken = ""
    @Published var telegramChatID = ""
    @Published var discordWebhookURL = ""
}
enum L10n {
    static func string(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String { "quota \(args)" }
}
extension CodexUsageWindow {
    var historyID: String { "\(id):\(windowDurationMins ?? 0)" }
}
enum QuotaCycleDetection {
    static func startsNewCycle(previousRemaining: Int, previousReset: Date?, currentRemaining: Int, currentReset: Date?) -> Bool {
        currentRemaining - previousRemaining >= 3
    }
}
final class FakePushProtocol: URLProtocol {
    static var responses: [(Int, String, TimeInterval)] = []
    static var count = 0
    static var lastPayload: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        Self.lastPayload = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let response = Self.responses.isEmpty ? (200, "{\"code\":200}", 0) : Self.responses.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + response.2) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil,
                    headerFields: ["Retry-After": "1"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
@main struct Integration {
    static func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }
    static func setup(_ responses: [(Int, String, TimeInterval)] = []) -> (AppSettings, PushNotificationService) {
        FakePushProtocol.count = 0; FakePushProtocol.responses = responses; FakePushProtocol.lastPayload = [:]
        let settings = AppSettings()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FakePushProtocol.self]
        return (settings, PushNotificationService(settings: settings, sessionConfiguration: config))
    }
    static func window(_ used: Int, duration: Int = 300) -> CodexUsageWindow {
        .init(id: "quota", name: "Quota", usedPercent: used, windowDurationMins: duration, resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    static func trigger(_ service: PushNotificationService) {
        service.evaluate(windows: [window(60)]); service.evaluate(windows: [window(0)])
    }
    static func main() {
        do {
            let (_, service) = setup([(503, "{}", 0), (200, "{\"code\":200}", 0)])
            trigger(service); wait(1.4)
            check(FakePushProtocol.count == 2 && service.deliveryStatuses[.bark] == .sent, "transient HTTP error retries and succeeds")
        }
        do {
            let (_, service) = setup([(503, "{}", 0), (503, "{}", 0), (503, "{}", 0)])
            trigger(service); wait(2.5)
            check(FakePushProtocol.count == 3 && service.deliveryStatuses[.bark] == .failed(.http), "retry exhaustion stops at three attempts and reports failure")
        }
        do {
            let (_, service) = setup([(401, "{}", 0)])
            trigger(service); wait(1.3)
            check(FakePushProtocol.count == 1 && service.deliveryStatuses[.bark] == .failed(.http), "permanent rejection does not retry")
        }
        do {
            let (_, service) = setup([(503, "{}", 0)])
            trigger(service); wait(0.2); service.resetEvaluationState(); wait(1.3)
            check(FakePushProtocol.count == 1 && service.deliveryStatuses.isEmpty, "account switch cancels retry")
        }
        do {
            let (_, service) = setup([(200, "{\"code\":200}", 0.4)])
            trigger(service); wait(0.1); service.resetEvaluationState(); wait(0.6)
            check(service.deliveryStatuses.isEmpty, "account switch ignores late callback")
        }
        do {
            let (settings, service) = setup([(503, "{}", 0)])
            trigger(service); wait(0.2); settings.barkEnabled = false; wait(1.3)
            check(FakePushProtocol.count == 1 && service.deliveryStatuses[.bark] == .idle, "disabling channel cancels retry")
        }
        do {
            let (settings, service) = setup([(503, "{}", 0)])
            trigger(service); wait(0.2); settings.pushFiveHourResetEnabled = false; wait(1.3)
            check(FakePushProtocol.count == 1 && service.deliveryStatuses[.bark] == .idle, "disabling quota reset type cancels retry")
        }
        do {
            let (settings, service) = setup([(503, "{}", 0)])
            trigger(service); wait(0.2); settings.barkDeviceKey = "new-fake-key"; wait(1.3)
            check(FakePushProtocol.count == 1 && service.deliveryStatuses[.bark] == .idle, "changing endpoint credential cancels old delivery")
        }
        do {
            let (_, service) = setup()
            trigger(service); wait(0.2); service.evaluate(windows: [window(60)]); service.evaluate(windows: [window(0)]); wait(0.2)
            check(FakePushProtocol.count == 1, "duplicate re-observed reset is suppressed")
        }
        do {
            let (_, service) = setup()
            service.evaluate(windows: [window(60, duration: 1440)]); service.evaluate(windows: [window(0, duration: 1440)]); wait(0.2)
            check(FakePushProtocol.count == 0, "unsupported reset duration is ignored")
        }
        do {
            let (_, service) = setup()
            service.evaluate(windows: [window(60)]); service.evaluate(windows: [window(20)]); wait(0.2)
            check((FakePushProtocol.lastPayload["body"] as? String)?.contains("80") == true,
                  "partial replenishment notification uses actual remaining percentage")
        }
        do {
            let (_, service) = setup([(200, "{\"code\":400}", 0)])
            trigger(service); wait(1.3)
            check(FakePushProtocol.count == 1 && service.deliveryStatuses[.bark] == .failed(.rejected),
                  "HTTP200 API rejection fails without retry")
        }
        do {
            let (_, service) = setup([(503, "{}", 0), (200, "{\"code\":200}", 0)])
            trigger(service); wait(0.2); service.sendTest(channel: .bark); wait(0.2)
            check(service.deliveryStatuses[.bark] == .sending, "completed test does not hide an outstanding real reset delivery")
            wait(1.2)
            check(FakePushProtocol.count == 3 && service.deliveryStatuses[.bark] == .sent, "real delivery still completes after concurrent test")
        }
        print("All 13 real-service fake-transport scenarios passed; no remote request sent.")
    }
}
