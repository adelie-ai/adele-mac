import AdeleCore
import SwiftUI

/// Toolbar entry point for background tasks: an icon with an active-count badge
/// that opens the tasks popover.
struct TasksButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .overlay(alignment: .topTrailing) {
            if model.activeTaskCount > 0 {
                Text("\(model.activeTaskCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .offset(x: 8, y: -7)
            }
        }
        .help("Background tasks")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TasksPanel()
                .frame(width: 400, height: 480)
        }
    }
}

private struct TasksPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "checklist",
                        description: Text("Background tasks started by Adele appear here.")
                    )
                } else {
                    List(model.tasks) { task in
                        NavigationLink {
                            TaskLogsView(task: task)
                        } label: {
                            TaskRow(task: task)
                        }
                    }
                }
            }
            .navigationTitle("Tasks")
        }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskView

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TaskStyle.color(task.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(1)
                if let hint = task.progressHint, !hint.isEmpty {
                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(task.status.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                if let error = task.lastError, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if task.isActive {
                Button {
                    model.cancelTask(task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel task")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TaskLogsView: View {
    @Environment(AppModel.self) private var model
    let task: TaskView

    private var logs: [TaskLogEntry] { model.taskLogs[task.id] ?? [] }

    var body: some View {
        List(logs) { entry in
            HStack(alignment: .top, spacing: 6) {
                Text(entry.level.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(TaskStyle.logColor(entry.level))
                    .frame(width: 42, alignment: .leading)
                Text(entry.message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(task.title)
        .overlay {
            if logs.isEmpty {
                ContentUnavailableView("No Logs Yet", systemImage: "doc.plaintext")
            }
        }
        .onAppear { model.fetchTaskLogs(task.id) }
    }
}

enum TaskStyle {
    static func color(_ status: String) -> Color {
        switch status {
        case "running": return .blue
        case "completed": return .green
        case "failed": return .red
        case "cancelled": return .secondary
        default: return .orange  // pending
        }
    }

    static func logColor(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        case "info": return .primary
        default: return .secondary
        }
    }
}
