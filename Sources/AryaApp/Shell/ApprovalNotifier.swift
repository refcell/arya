import Arya
import Foundation
import UserNotifications

/// A notification about one pending approval.
struct ApprovalNotice: Hashable, Sendable {
    let approval: String
    let title: String
    let body: String
}

/// Posts approval notices. The app uses `SystemNotificationPoster`; tests record notices.
@MainActor
protocol NotificationPosting: AnyObject {
    func post(_ notice: ApprovalNotice)
}

/// Decides which approvals deserve a notification: those that became pending since the last
/// look. The first look only records what is pending, so opening the app never floods.
struct ApprovalNotifier {
    private var seen: Set<String> = []
    private var primed = false

    /// The approvals to announce now, oldest first.
    mutating func newlyPending(
        _ approvals: [ApprovalSummary], stewardNames: [String: String]
    ) -> [ApprovalNotice] {
        let pending = approvals.filter { $0.status == .pending }
        defer {
            seen.formUnion(pending.map(\.id))
            primed = true
        }
        guard primed else { return [] }
        return pending.filter { !seen.contains($0.id) }.map { approval in
            Self.notice(for: approval, steward: stewardNames[approval.steward] ?? approval.steward)
        }
    }

    /// Plain words: who asks and for what (STYLE.md Voice and copy).
    static func notice(for approval: ApprovalSummary, steward: String) -> ApprovalNotice {
        switch approval.kind {
        case .action:
            let action = [approval.actionKind, approval.target].compactMap { $0 }
                .joined(separator: " ")
            return ApprovalNotice(
                approval: approval.id, title: "\(steward) wants to \(action)",
                body: approval.text)
        case .question:
            return ApprovalNotice(
                approval: approval.id, title: "\(steward) has a question", body: approval.text)
        }
    }
}

/// Posts through the system notification center with Approve and Deny actions. Only used when
/// the app runs from its bundle; a bare binary or a test never touches the center.
@MainActor
final class SystemNotificationPoster: NSObject, NotificationPosting,
    UNUserNotificationCenterDelegate
{
    nonisolated static let category = "arya.approval"
    nonisolated static let approveAction = "arya.approve"
    nonisolated static let denyAction = "arya.deny"

    /// Called with the approval id and whether the person approved.
    private let decide: @MainActor (String, Bool) -> Void
    private var authorized = false

    init(decide: @escaping @MainActor (String, Bool) -> Void) {
        self.decide = decide
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.approveAction, title: "Approve"),
                    UNNotificationAction(
                        identifier: Self.denyAction, title: "Deny", options: [.destructive]),
                ],
                intentIdentifiers: [])
        ])
    }

    func post(_ notice: ApprovalNotice) {
        Task {
            let center = UNUserNotificationCenter.current()
            if !authorized {
                authorized =
                    (try? await center.requestAuthorization(options: [.alert, .sound]))
                    ?? false
            }
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.categoryIdentifier = Self.category
            content.userInfo = ["approval": notice.approval]
            try? await center.add(
                UNNotificationRequest(identifier: notice.approval, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard let approval = response.notification.request.content.userInfo["approval"] as? String,
            action == Self.approveAction || action == Self.denyAction
        else { return }
        await MainActor.run { decide(approval, action == Self.approveAction) }
    }
}
