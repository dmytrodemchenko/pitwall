import Foundation
import Observation
import os
@preconcurrency import UserNotifications

extension Logger {
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.demchenko.Pitwall", category: "app")
}

@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var isBlocked = false
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    nonisolated static let permissionCategory = "PERMISSION", denyOnlyCategory = "PERMISSION_DENY_ONLY", loopCategory = "LOOP"
    private nonisolated static let allow = "ALLOW", deny = "DENY", stop = "STOP", sessionKey = "session"
    @ObservationIgnored var onStop: (String) -> Void = { _ in }
    @ObservationIgnored private var pending: [String: PendingPermission] = [:]

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    nonisolated static var categories: Set<UNNotificationCategory> {
        let allowAction = UNNotificationAction(identifier: allow, title: "Allow", options: .authenticationRequired)
        let denyAction = UNNotificationAction(identifier: deny, title: "Deny", options: .destructive)
        return [UNNotificationCategory(identifier: permissionCategory, actions: [allowAction, denyAction],
                                       intentIdentifiers: [], options: .customDismissAction),
                UNNotificationCategory(identifier: denyOnlyCategory, actions: [denyAction],
                                       intentIdentifiers: [], options: .customDismissAction),
                UNNotificationCategory(identifier: loopCategory,
                                       actions: [UNNotificationAction(identifier: stop, title: "Stop…", options: [.foreground, .destructive])],
                                       intentIdentifiers: [])]
    }

    func post(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pitwall"
        content.body = body
        content.sound = .default
        deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }

    func loop(_ body: String, session: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pitwall"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.loopCategory
        content.userInfo = [Self.sessionKey: session]
        deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }

    func ask(_ p: PendingPermission, project: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(project): allow \(p.request.toolName)?"
        content.body = p.request.summary.isEmpty ? "Claude Code wants to use \(p.request.toolName)." : p.request.summary
        if !p.request.isComplete { content.body += "\nTo allow it, use the terminal: it shows all of it." }
        content.sound = .default
        content.categoryIdentifier = Self.category(for: p.request)
        pending[p.id] = p
        p.onCancel = { [weak self] in
            self?.pending[p.id] = nil
            self?.center.removeDeliveredNotifications(withIdentifiers: [p.id])
        }
        deliver(UNNotificationRequest(identifier: p.id, content: content, trigger: nil)) { [weak self] delivered in
            guard !delivered else { return }
            self?.pending[p.id] = nil
            p.reply(nil)
        }
    }

    private func deliver(_ request: UNNotificationRequest, done: @escaping (Bool) -> Void) {
        let (id, title, body) = (request.identifier, request.content.title, request.content.body)
        Task {
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Logger.app.error("notification authorization failed: \(String(describing: error), privacy: .public)")
                granted = false
            }
            isBlocked = !granted
            guard granted else {
                Logger.app.error("notifications not allowed")
                return done(false)
            }
            do {
                try await center.add(request)
                Logger.app.log("posted \(id, privacy: .public) \"\(title, privacy: .private): \(body, privacy: .private)\"")
                done(true)
            } catch {
                Logger.app.error("posting \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                done(false)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier, action = response.actionIdentifier
        if action == Self.stop, let session = response.notification.request.content.userInfo[Self.sessionKey] as? String {
            await MainActor.run { onStop(session) }
            return
        }
        await MainActor.run {
            guard let p = pending.removeValue(forKey: id) else { return }
            p.reply(Self.decision(for: action))
            Logger.app.log("permission \(id, privacy: .public) answered \(Self.decision(for: action)?.rawValue ?? "none", privacy: .public)")
        }
    }

    nonisolated static func category(for request: PermissionRequest) -> String {
        request.isComplete ? permissionCategory : denyOnlyCategory
    }

    nonisolated static func decision(for action: String) -> PermissionDecision? {
        switch action {
        case allow: .allow
        case deny: .deny
        default: nil
        }
    }
}
