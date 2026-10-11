import MonitorCore

// MARK: - ActivityFeedTail

struct ActivityFeedTail: Equatable {
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var children: [TaskDetailTimelineChild] = []
}
