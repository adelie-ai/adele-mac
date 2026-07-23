import Foundation

// MARK: - Knowledge maintenance command builder

extension AdeleCommand {
    /// `Command::StartKnowledgeMaintenance { op }` — kick off an on-demand
    /// maintenance pass. The daemon replies immediately with
    /// `CommandResult::MaintenanceTaskStarted { task_id }`; the work then runs as
    /// a tracked background task emitting `Task*` and `KnowledgeChanged` events.
    public static func startKnowledgeMaintenance(_ op: KnowledgeMaintenanceOp) -> String {
        struct Cmd: Encodable {
            struct P: Encodable { let op: String }
            let start_knowledge_maintenance: P
        }
        return encode(Cmd(start_knowledge_maintenance: .init(op: op.rawValue)))
    }
}
