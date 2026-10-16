import AppKit
import UserNotifications

/// Glaude's own macOS notifications, with Reply, answer and Allow/Deny buttons. Sent
/// only while the panel is closed, and only when the mod's `notifications` option is
/// "glaude" (the default).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let store: SessionStore
    private let center = UNUserNotificationCenter.current()
    /// Open the panel on a session, or bring its terminal forward.
    var onOpen: ((String) -> Void)?
    var onOpenTerminal: ((String) -> Void)?
    private(set) var isAuthorized = false
    /// Categories for the questions currently on screen, by request key.
    private var questionCategories: [String: UNNotificationCategory] = [:]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifications") }
    }

    /// macOS only allows notifications for an app in an Applications folder.
    var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        guard isInstalled else { return }
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.isAuthorized = granted }
        }
    }

    private var shouldPost: Bool { isInstalled && isEnabled && isAuthorized && store.notifyMode == "glaude" }

    // MARK: Posting

    func sessionFinished(_ session: Session, text: String, footer: String) {
        guard shouldPost else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.name) finished"
        content.subtitle = footer
        content.body = String(text.prefix(240))
        content.categoryIdentifier = "done"
        content.userInfo = ["session": session.id]
        post("done-\(session.id)", content)
    }

    func sessionNeedsYou(_ session: Session, title: String) {
        guard shouldPost, let pending = session.pending else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.name) needs you"
        content.userInfo = ["session": session.id, "request": pending.key ?? ""]
        switch pending.kind {
        case .permission(let tool, let detail):
            content.subtitle = "Allow \(tool)?"
            content.body = String(detail.prefix(240))
            content.categoryIdentifier = "permission"
        case .questions(let questions):
            content.subtitle = questions.first?.text ?? title
            content.body = questions.first?.options.map(\.label).joined(separator: " · ") ?? ""
            content.categoryIdentifier = questionCategory(for: pending, questions: questions) ?? "open"
        case .terminal(let cardTitle, let detail):
            content.subtitle = cardTitle
            content.body = String(detail.prefix(240))
            content.categoryIdentifier = "terminal"
        }
        post("needs-\(session.id)", content)
    }

    /// The session stopped waiting: take its "needs you" notification down.
    func clearNeedsYou(_ sessionID: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["needs-\(sessionID)"])
    }

    private func post(_ id: String, _ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Categories

    private var baseCategories: [UNNotificationCategory] {
        let open = UNNotificationAction(identifier: "open", title: "Open Glaude", options: [.foreground])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Claude…")
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let terminal = UNNotificationAction(identifier: "terminal", title: "Open terminal", options: [.foreground])
        return [
            UNNotificationCategory(identifier: "done", actions: [reply, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [allow, deny, terminal], intentIdentifiers: []),
            UNNotificationCategory(identifier: "terminal", actions: [terminal], intentIdentifiers: []),
            UNNotificationCategory(identifier: "open", actions: [open], intentIdentifiers: []),
        ]
    }

    private func registerCategories() {
        center.setNotificationCategories(Set(baseCategories + questionCategories.values))
    }

    /// One button per option, for a single single-select question of up to four options.
    private func questionCategory(for request: PendingRequest, questions: [Question]) -> String? {
        guard let key = request.key, questions.count == 1, let question = questions.first,
              !question.multiSelect, (1...4).contains(question.options.count) else { return nil }
        let actions = question.options.enumerated().map { index, option in
            UNNotificationAction(identifier: "option-\(index)", title: option.label, options: [])
        }
        let id = "question-\(key)"
        if questionCategories.count > 8 { questionCategories.removeAll() }
        questionCategories[key] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
        registerCategories()
        return id
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])  // the app already played its own sound
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sessionID = info["session"] as? String ?? ""
        let key = info["request"] as? String ?? ""
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        DispatchQueue.main.async { [weak self] in
            self?.handle(action, sessionID: sessionID, key: key, text: text)
            done()
        }
    }

    private func handle(_ action: String, sessionID: String, key: String, text: String?) {
        // A request already settled (answered in the terminal or the panel) has no pending
        // card with this key any more, so a late button does nothing.
        let pending = store.session(sessionID)?.pending.flatMap { $0.key == key ? $0 : nil }
        switch action {
        case "reply":
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                store.send(text, to: sessionID)
            }
        case "allow", "deny":
            if let pending { store.answerPermission(pending, allow: action == "allow") } else { onOpen?(sessionID) }
        case "terminal":
            onOpenTerminal?(sessionID)
        case let option where option.hasPrefix("option-"):
            if let pending, case .questions(let questions) = pending.kind, let question = questions.first,
               let index = Int(option.dropFirst("option-".count)), question.options.indices.contains(index) {
                store.answerQuestions(pending, answers: [question.text: question.options[index].label])
            }
        default:
            onOpen?(sessionID)  // the notification itself, or "Open Glaude"
        }
    }
}
