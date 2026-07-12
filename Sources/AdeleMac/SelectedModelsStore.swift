import AdeleCore
import Observation
import Foundation

/// Persists the user's curated model selection to
/// `~/Library/Application Support/adele-mac/selected_models.json` (mirrors
/// `ProfileStore`: a `Codable` file with `load()` / `save()`).
///
/// The pure membership/filter logic lives in `AdeleCore.SelectedModels`; this
/// `@Observable` wrapper adds on-disk persistence and forwards the operations so
/// a SwiftUI view can bind to it and the header picker can filter its model list.
/// An empty selection means "show everything".
@Observable
final class SelectedModelsStore {
    /// The curated selection (the exact value persisted to disk).
    private(set) var selection: SelectedModels

    /// In-memory init (for previews/tests) — takes the selection directly so no
    /// filesystem is touched.
    init(selection: SelectedModels = SelectedModels()) {
        self.selection = selection
    }

    // MARK: - Queries

    var isEmpty: Bool { selection.isEmpty }

    func isSelected(connectionId: String, modelId: String) -> Bool {
        selection.isSelected(connectionId: connectionId, modelId: modelId)
    }

    /// Return only the curated listings (or all, if the selection is empty).
    /// This is what the header model picker calls to trim its list.
    func filter(_ listings: [ModelListing]) -> [ModelListing] {
        selection.filter(listings)
    }

    // MARK: - Mutations (auto-persist)

    func toggle(connectionId: String, modelId: String) {
        selection.toggle(connectionId: connectionId, modelId: modelId)
        save()
    }

    func selectAll(_ listings: [ModelListing]) {
        selection.selectAll(listings)
        save()
    }

    func selectNone() {
        selection.clear()
        save()
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("adele-mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("selected_models.json")
    }

    static func load() -> SelectedModelsStore {
        guard
            let data = try? Data(contentsOf: fileURL),
            let selection = try? JSONDecoder().decode(SelectedModels.self, from: data)
        else {
            return SelectedModelsStore()
        }
        return SelectedModelsStore(selection: selection)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
