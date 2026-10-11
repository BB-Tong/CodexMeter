import Foundation

/// Sends push notifications to external Bark and Gotify servers when quota resets.
final class PushNotificationService {
    private let settings: AppSettings
    private var resetTracker = QuotaResetTracker()
    private let session: URLSession

    init(settings: AppSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    /// Evaluates quota windows for resets and sends push notifications when detected.
    func evaluate(windows: [CodexUsageWindow]) {
        let resetWindows = resetTracker.evaluate(windows: windows)
        guard settings.barkEnabled || settings.gotifyEnabled else { return }

        for window in resetWindows {
            let isFiveHour = window.windowDurationMins == 5 * 60
            let isWeekly = window.windowDurationMins == 7 * 24 * 60

            let isEnabledForWindow: Bool
            if isFiveHour {
                isEnabledForWindow = settings.pushFiveHourResetEnabled
            } else if isWeekly {
                isEnabledForWindow = settings.pushWeeklyResetEnabled
            } else {
                isEnabledForWindow = settings.pushFiveHourResetEnabled || settings.pushWeeklyResetEnabled
            }

            if isEnabledForWindow {
                sendResetNotification(for: window)
            }
        }
    }

    /// Clears tracked state so that account switches do not trigger false resets.
    func resetEvaluationState() {
        resetTracker.reset()
    }

    /// Sends a test notification to configured Bark server.
    func sendTestBark(completion: ((Bool, String?) -> Void)? = nil) {
        let title = L10n.string("settings.push.test_title")
        let body = L10n.string("settings.push.test_body")
        sendBark(title: title, body: body, completion: completion)
    }

    /// Sends a test notification to configured Gotify server.
    func sendTestGotify(completion: ((Bool, String?) -> Void)? = nil) {
        let title = L10n.string("settings.push.test_title")
        let body = L10n.string("settings.push.test_body")
        sendGotify(title: title, body: body, completion: completion)
    }

    private func sendResetNotification(for window: CodexUsageWindow) {
        let title = L10n.string("push.reset.title")
        let body = L10n.format("push.reset.body_format", window.name)

        if settings.barkEnabled {
            sendBark(title: title, body: body)
        }
        if settings.gotifyEnabled {
            sendGotify(title: title, body: body)
        }
    }

    private func sendBark(title: String, body: String, completion: ((Bool, String?) -> Void)? = nil) {
        let serverURL = settings.barkServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceKey = settings.barkDeviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !deviceKey.isEmpty else {
            completion?(false, "Missing Bark server URL or device key")
            return
        }

        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let targetURLString = base.hasSuffix(deviceKey) ? base : "\(base)/\(deviceKey)"
        guard let url = URL(string: targetURLString) else {
            completion?(false, "Invalid Bark server URL")
            return
        }

        var payload: [String: Any] = [
            "title": title,
            "body": body,
            "group": "CodexMeter",
            "isArchive": "1"
        ]

        let iconURL = settings.barkIconURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !iconURL.isEmpty {
            payload["icon"] = iconURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion?(false, error.localizedDescription)
            return
        }

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion?(false, error.localizedDescription)
            } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                completion?(true, nil)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion?(false, "HTTP \(code)")
            }
        }.resume()
    }

    private func sendGotify(title: String, body: String, completion: ((Bool, String?) -> Void)? = nil) {
        let serverURL = settings.gotifyServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let appToken = settings.gotifyAppToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !appToken.isEmpty else {
            completion?(false, "Missing Gotify server URL or app token")
            return
        }

        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let targetURLString = base.hasSuffix("/message") ? base : "\(base)/message"
        guard let url = URL(string: targetURLString) else {
            completion?(false, "Invalid Gotify server URL")
            return
        }

        let payload: [String: Any] = [
            "title": title,
            "message": body,
            "priority": settings.gotifyPriority
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appToken, forHTTPHeaderField: "X-Gotify-Key")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion?(false, error.localizedDescription)
            return
        }

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion?(false, error.localizedDescription)
            } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                completion?(true, nil)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion?(false, "HTTP \(code)")
            }
        }.resume()
    }
}
