import AdeleCore
import SwiftUI

/// The knowledge browser's "Maintenance" menu — on-demand triggers for the
/// daemon's three background passes (the "dream cycle").
///
/// Each pass runs as a tracked background task, so this surface deliberately
/// shows no progress of its own: it starts the run and points at the tasks panel,
/// which already has status, logs, and cancel. Passes that rewrite or re-embed
/// existing entries confirm first (`KnowledgeMaintenanceOp.needsConfirmation`).
struct KnowledgeMaintenanceMenu: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: KnowledgeMaintenanceOp?

    private var running: [TaskView] { model.activeKnowledgeMaintenanceTasks }

    var body: some View {
        Menu {
            ForEach(KnowledgeMaintenanceOp.allCases, id: \.self) { op in
                Button(op.title) { trigger(op) }
                    .help(op.detail)
            }
            if !running.isEmpty {
                Divider()
                Section("Running") {
                    ForEach(running) { task in
                        Text(task.progressHint.flatMap { $0.isEmpty ? nil : $0 } ?? task.title)
                    }
                }
            }
        } label: {
            // A run in progress is marked here only as a hint — the authoritative
            // progress/log/cancel surface is the tasks panel.
            Label(running.isEmpty ? "Maintenance" : "Maintenance…", systemImage: "wand.and.stars")
        }
        .disabled(!model.connected)
        .help(running.isEmpty
              ? "Run a knowledge-maintenance pass"
              : "A maintenance pass is running — see Tasks")
        .confirmationDialog(
            confirming.map { "Run \($0.title)?" } ?? "",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirming
        ) { op in
            Button(op.title, role: .destructive) {
                confirming = nil
                model.startKnowledgeMaintenance(op)
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { op in
            Text(op.detail)
        }
    }

    private func trigger(_ op: KnowledgeMaintenanceOp) {
        if op.needsConfirmation {
            confirming = op
        } else {
            model.startKnowledgeMaintenance(op)
        }
    }
}
