import AdeleCore
import SwiftUI

/// A sheet that lets the user curate which models appear in the header model
/// picker. The daemon can expose hundreds of models (e.g. Bedrock), so this
/// mirrors the GTK client's client-side filter. Models are grouped by connection;
/// each row is a toggle bound to a locally-persisted `SelectedModelsStore`.
///
/// Empty selection means "show everything", so leaving every row off (or hitting
/// "Select None") shows all models in the picker rather than an empty list.
///
/// Present as a sheet, e.g.:
///     .sheet(isPresented: $showSelectModels) { SelectModelsView() }
struct SelectModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Owns its own store instance: loaded from disk on `.task`, saved on every
    /// toggle (the store persists itself).
    @State private var store = SelectedModelsStore()

    var body: some View {
        NavigationStack {
            Group {
                if model.models.isEmpty {
                    ContentUnavailableView(
                        "No Models",
                        systemImage: "cpu",
                        description: Text("Connect to a daemon to choose which models appear in the picker.")
                    )
                } else {
                    Form {
                        Section {
                            ForEach(model.modelsByConnection, id: \.label) { group in
                                Section(group.label) {
                                    ForEach(group.listings) { listing in
                                        Toggle(isOn: binding(for: listing)) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(listing.model.displayName)
                                                Text(listing.model.id)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text("If no models are selected, all of them appear in the picker.")
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Select Models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select All") { store.selectAll(model.models) }
                        Button("Select None") { store.selectNone() }
                    } label: {
                        Text("Select")
                    }
                    .disabled(model.models.isEmpty)
                }
            }
        }
        .frame(width: 460, height: 520)
        .task { store = SelectedModelsStore.load() }
    }

    private func binding(for listing: ModelListing) -> Binding<Bool> {
        Binding(
            get: {
                store.isSelected(
                    connectionId: listing.connectionId,
                    modelId: listing.model.id
                )
            },
            set: { _ in
                store.toggle(
                    connectionId: listing.connectionId,
                    modelId: listing.model.id
                )
            }
        )
    }
}
