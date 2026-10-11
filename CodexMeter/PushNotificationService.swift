import Combine
import Foundation

/// Runs only bounded, event-triggered deliveries; idle channels have no timers or background work.
final class PushNotificationService: ObservableObject {
    @Published private(set) var deliveryStatuses: [PushChannel: PushDeliveryStatus] = [:]
    private let settings: AppSettings
    private var resetTracker = QuotaResetTracker()
    private var ledger = PushDeliveryLedger()
    private let session: URLSession
    private let redirectGuard = PushRedirectGuard()
    private var observations = Set<AnyCancellable>()
    private var jobs: [UUID: DeliveryJob] = [:]

    private final class DeliveryJob {
        let id = UUID()
        let channel: PushChannel
        let configuration: PushChannelConfiguration
        let generation: UUID
        let request: URLRequest
        let isTest: Bool
        let duration: Int?
        let completion: ((Bool, String?) -> Void)?
        var attempt = 0
        var task: URLSessionDataTask?
        var retry: DispatchWorkItem?
        init(channel: PushChannel, configuration: PushChannelConfiguration, generation: UUID,
             request: URLRequest, isTest: Bool, duration: Int?, completion: ((Bool, String?) -> Void)?) {
            self.channel = channel
            self.configuration = configuration
            self.generation = generation
            self.request = request
            self.isTest = isTest
            self.duration = duration
            self.completion = completion
        }
    }

    init(settings: AppSettings, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.settings = settings
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        settings.objectWillChange.sink { [weak self] _ in
            // Published settings emit before their values change.
            DispatchQueue.main.async { self?.cancelObsoleteJobs() }
        }.store(in: &observations)
    }

    func evaluate(windows: [CodexUsageWindow]) {
        for window in resetTracker.evaluate(windows: windows) {
            let supported: Bool
            switch window.windowDurationMins {
            case 300: supported = settings.pushFiveHourResetEnabled
            case 10080: supported = settings.pushWeeklyResetEnabled
            default: supported = false
            }
            guard supported else { continue }
            let title = L10n.string("push.reset.title")
            let body = L10n.format("push.reset.body_format", window.name, window.remainingPercent)
            let eventID = "\(window.historyID):\(window.resetsAt?.timeIntervalSince1970 ?? 0):\(window.remainingPercent)"
            for channel in PushChannel.allCases where isEnabled(channel) {
                guard ledger.claim(eventID: eventID, channel: channel) else { continue }
                send(channel: channel, title: title, body: body, isTest: false,
                     duration: window.windowDurationMins, completion: nil)
            }
        }
    }

    func resetEvaluationState() {
        resetTracker.reset()
        ledger.reset()
        for job in Array(jobs.values) { cancel(job) }
        deliveryStatuses.removeAll()
    }

    func sendTestBark(completion: ((Bool, String?) -> Void)? = nil) { sendTest(channel: .bark, completion: completion) }
    func sendTestGotify(completion: ((Bool, String?) -> Void)? = nil) { sendTest(channel: .gotify, completion: completion) }

    func sendTest(channel: PushChannel, completion: ((Bool, String?) -> Void)? = nil) {
        // A repeated test replaces only the previous test, never a real reset notification.
        for job in Array(jobs.values) where job.channel == channel && job.isTest { cancel(job) }
        send(channel: channel, title: L10n.string("settings.push.test_title"),
             body: L10n.string("settings.push.test_body"), isTest: true, duration: nil, completion: completion)
    }

    private func send(channel: PushChannel, title: String, body: String, isTest: Bool, duration: Int?,
                      completion: ((Bool, String?) -> Void)?) {
        let config = configuration(channel)
        do {
            let request = try PushRequestBuilder.request(configuration: config, title: title, body: body)
            guard jobs.values.filter({ $0.channel == channel }).count < 8 else {
                updateStatus(channel, finished: .failed(.network))
                completion?(false, L10n.string(PushDeliveryFailure.network.localizedKey))
                return
            }
            let job = DeliveryJob(channel: channel, configuration: config, generation: ledger.generation,
                                  request: request, isTest: isTest, duration: duration, completion: completion)
            jobs[job.id] = job
            perform(job)
        } catch {
            updateStatus(channel, finished: .failed(.invalidConfiguration))
            completion?(false, L10n.string(PushDeliveryFailure.invalidConfiguration.localizedKey))
        }
    }

    private func perform(_ job: DeliveryJob) {
        guard isCurrent(job) else { cancel(job); return }
        job.attempt += 1
        deliveryStatuses[job.channel] = .sending
        job.task = session.dataTask(with: job.request) { [weak self, weak job] data, response, error in
            DispatchQueue.main.async {
                guard let self, let job, self.isCurrent(job) else { return }
                job.task = nil
                let http = response as? HTTPURLResponse
                let outcome = PushDeliveryOutcome.evaluate(channel: job.channel, statusCode: http?.statusCode,
                    data: data, networkError: error != nil, retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"))
                if let delay = PushRetryPolicy.delay(afterAttempt: job.attempt, outcome: outcome) {
                    let retry = DispatchWorkItem { [weak self, weak job] in
                        guard let self, let job else { return }
                        job.retry = nil
                        self.perform(job)
                    }
                    job.retry = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
                } else {
                    self.jobs.removeValue(forKey: job.id)
                    if let failure = outcome.failure {
                        self.updateStatus(job.channel, finished: .failed(failure))
                        job.completion?(false, L10n.string(failure.localizedKey))
                    } else {
                        self.updateStatus(job.channel, finished: .sent)
                        job.completion?(true, nil)
                    }
                }
            }
        }
        job.task?.resume()
    }

    private func isCurrent(_ job: DeliveryJob) -> Bool {
        jobs[job.id] === job && ledger.accepts(job.generation) &&
            (job.isTest || (isEnabled(job.channel) && isWindowEnabled(job.duration))) &&
            job.configuration == configuration(job.channel)
    }

    private func isWindowEnabled(_ duration: Int?) -> Bool {
        switch duration {
        case 300: return settings.pushFiveHourResetEnabled
        case 10080: return settings.pushWeeklyResetEnabled
        default: return false
        }
    }

    private func cancelObsoleteJobs() {
        for job in Array(jobs.values) where !isCurrent(job) { cancel(job) }
    }

    private func cancel(_ job: DeliveryJob) {
        job.task?.cancel()
        job.retry?.cancel()
        jobs.removeValue(forKey: job.id)
        updateStatus(job.channel, finished: .idle)
    }

    private func updateStatus(_ channel: PushChannel, finished: PushDeliveryStatus) {
        deliveryStatuses[channel] = jobs.values.contains(where: { $0.channel == channel }) ? .sending : finished
    }

    private func isEnabled(_ channel: PushChannel) -> Bool {
        switch channel {
        case .bark: return settings.barkEnabled
        case .gotify: return settings.gotifyEnabled
        case .telegram: return settings.telegramEnabled
        case .discord: return settings.discordEnabled
        }
    }

    private func configuration(_ channel: PushChannel) -> PushChannelConfiguration {
        switch channel {
        case .bark:
            return .init(channel: channel, serverURL: settings.barkServerURL, credential: settings.barkDeviceKey,
                         iconURL: settings.barkIconURL)
        case .gotify:
            return .init(channel: channel, serverURL: settings.gotifyServerURL, credential: settings.gotifyAppToken,
                         priority: settings.gotifyPriority)
        case .telegram:
            return .init(channel: channel, credential: settings.telegramBotToken, target: settings.telegramChatID)
        case .discord:
            return .init(channel: channel, credential: settings.discordWebhookURL)
        }
    }

    deinit {
        jobs.values.forEach { $0.task?.cancel(); $0.retry?.cancel() }
        session.invalidateAndCancel()
    }
}

/// Refuse redirects rather than forwarding credentials or quota information to another origin.
private final class PushRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
