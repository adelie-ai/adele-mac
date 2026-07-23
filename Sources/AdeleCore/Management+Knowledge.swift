import Foundation

/// `CommandResult::MaintenanceTaskStarted` — the registered background-task id
/// for an on-demand maintenance run. Progress and completion arrive as `Task*`
/// events; the run is cancellable with the ordinary task-cancel command.
struct MaintenanceTaskStartedPayload: Decodable {
    let task_id: String
}

extension AdeleCore {
    /// Start a knowledge-maintenance pass. Returns the background-task id so the
    /// caller can correlate it with the tasks panel.
    ///
    /// A daemon too old to know the command answers `Ack` (no `task_id`); that
    /// decodes to `nil` rather than throwing a `DecodingError`, so we can report
    /// it as an unsupported command instead of a parse failure.
    @MainActor
    @discardableResult
    public func startKnowledgeMaintenance(_ op: KnowledgeMaintenanceOp) async throws -> String {
        let data = try await sendCommand(AdeleCommand.startKnowledgeMaintenance(op))
        let envelope = try? JSONDecoder()
            .decode(CommandResultEnvelope<MaintenanceTaskStartedPayload>.self, from: data)
        guard let taskID = envelope?.result?.task_id else {
            throw CommandError.failed("daemon returned no maintenance task id (unsupported?)")
        }
        return taskID
    }
}
