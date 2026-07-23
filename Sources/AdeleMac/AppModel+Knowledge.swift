import AdeleCore
import Foundation

// Knowledge-base intents beyond the plain CRUD in `AppModel`: on-demand
// maintenance passes and the live-refresh path.
//
// Live refresh: the daemon broadcasts `Event::KnowledgeChanged` to every one of a
// user's subscribed connections whenever the KB changes — a manual edit from
// another client, or a maintenance pass writing entries as it runs. The event
// carries no payload (by design), so the response is a debounced refetch:
// extraction fires it once per scanned conversation, and refetching per event
// would hammer the daemon during a long pass.
extension AppModel {
    /// Debounce window for `knowledge_changed` bursts.
    private static var knowledgeRefreshDelay: Duration { .milliseconds(400) }

    /// Start an on-demand maintenance pass. The daemon registers it as a
    /// background task and returns immediately; progress, logs, and cancel all
    /// ride the existing tasks panel, so there is no second progress surface here.
    func startKnowledgeMaintenance(_ op: KnowledgeMaintenanceOp) {
        guard connected else { return }
        settingsError = nil
        Task {
            do {
                let taskID = try await core.startKnowledgeMaintenance(op)
                knowledgeMaintenanceTaskIDs.insert(taskID)
                showToast("\(op.title) started — see Tasks for progress.")
            } catch {
                settingsError = "\(error)"
            }
        }
    }

    /// Fold a `knowledge_changed` event: refetch the browser, debounced, and only
    /// while it is actually open.
    func knowledgeChanged() {
        knowledgeRefreshTask?.cancel()
        knowledgeRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.knowledgeRefreshDelay)
            guard !Task.isCancelled, let self, self.showKnowledge else { return }
            self.loadKnowledge()
        }
    }

    /// A background task finished. If it was one of our maintenance runs, refresh
    /// the browser — this is also the fallback that keeps the panel current when
    /// the core does not surface `knowledge_changed`.
    func knowledgeMaintenanceTaskCompleted(_ id: String) {
        guard knowledgeMaintenanceTaskIDs.remove(id) != nil else { return }
        knowledgeChanged()
    }

    /// Maintenance runs we started that are still pending/running, used to show
    /// an in-progress indicator on the browser's Maintenance menu.
    var activeKnowledgeMaintenanceTasks: [TaskView] {
        tasks.filter { knowledgeMaintenanceTaskIDs.contains($0.id) && $0.isActive }
    }
}
