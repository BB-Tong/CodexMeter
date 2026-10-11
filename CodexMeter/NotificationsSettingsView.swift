import SwiftUI

/// Keeps local alerts and optional remote channels in the same settings category.
struct NotificationsSettingsView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var push: PushNotificationService

    var body: some View {
        Form {
            Section(L10n.string("settings.push.local")) {
                Toggle(L10n.string("settings.notifications"), isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { service.setNotificationsEnabled($0) }
                ))
                if settings.notificationsEnabled {
                    Picker(L10n.string("settings.notification_threshold"), selection: $settings.notificationThreshold) {
                        ForEach([10, 20, 30, 40], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
            }
            Section(L10n.string("settings.push.title")) {
                Toggle(L10n.string("settings.push.five_hour"), isOn: $settings.pushFiveHourResetEnabled)
                Toggle(L10n.string("settings.push.weekly"), isOn: $settings.pushWeeklyResetEnabled)
                Text(L10n.string("settings.push.description"))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = settings.pushCredentialError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Bark") {
                Toggle(L10n.string("settings.push.bark_enable"), isOn: $settings.barkEnabled)
                if settings.barkEnabled {
                    TextField(L10n.string("settings.push.bark_server"), text: $settings.barkServerURL)
                    SecureField(L10n.string("settings.push.bark_key"), text: $settings.barkDeviceKey)
                    TextField(L10n.string("settings.push.bark_icon"), text: $settings.barkIconURL)
                    testControls(.bark, configured: hasText(settings.barkServerURL) && hasText(settings.barkDeviceKey))
                }
            }
            Section("Gotify") {
                Toggle(L10n.string("settings.push.gotify_enable"), isOn: $settings.gotifyEnabled)
                if settings.gotifyEnabled {
                    TextField(L10n.string("settings.push.gotify_server"), text: $settings.gotifyServerURL)
                    SecureField(L10n.string("settings.push.gotify_token"), text: $settings.gotifyAppToken)
                    Picker(L10n.string("settings.push.gotify_priority"), selection: $settings.gotifyPriority) {
                        ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    testControls(.gotify, configured: hasText(settings.gotifyServerURL) && hasText(settings.gotifyAppToken))
                }
            }
            Section("Telegram") {
                Toggle(L10n.string("settings.push.telegram_enable"), isOn: $settings.telegramEnabled)
                if settings.telegramEnabled {
                    SecureField(L10n.string("settings.push.telegram_token"), text: $settings.telegramBotToken)
                    TextField(L10n.string("settings.push.telegram_chat"), text: $settings.telegramChatID)
                    Text(L10n.string("settings.push.telegram_help"))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(L10n.string("settings.push.setup_guide"), destination: URL(string: "https://core.telegram.org/bots/tutorial")!)
                    testControls(.telegram, configured: hasText(settings.telegramBotToken) && hasText(settings.telegramChatID))
                }
            }
            Section("Discord") {
                Toggle(L10n.string("settings.push.discord_enable"), isOn: $settings.discordEnabled)
                if settings.discordEnabled {
                    SecureField(L10n.string("settings.push.discord_webhook"), text: $settings.discordWebhookURL)
                    Text(L10n.string("settings.push.discord_help"))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(L10n.string("settings.push.setup_guide"), destination: URL(string: "https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks")!)
                    testControls(.discord, configured: hasText(settings.discordWebhookURL))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func testControls(_ channel: PushChannel, configured: Bool) -> some View {
        let status = push.deliveryStatuses[channel] ?? .idle
        Button(L10n.string("settings.push.test")) { push.sendTest(channel: channel) }
            .disabled(!configured || status == .sending)
        switch status {
        case .idle:
            EmptyView()
        case .sending:
            Label(L10n.string("settings.push.sending"), systemImage: "arrow.up.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .sent:
            Label(L10n.string("settings.push.sent"), systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let error):
            Label(L10n.string(error.localizedKey), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
