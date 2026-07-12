import Testing
import Foundation
@testable import AdeleCore

/// Spec: the pure "Select Models" filter — a curated subset of `(connectionId,
/// modelId)` pairs. Membership, toggle, empty-means-all filtering, and JSON
/// round-trip are exercised without touching the filesystem (the persistence
/// wrapper lives in the app target; this is the file-free core it delegates to).
@Suite struct SelectedModelsTests {
    /// Decode `ModelListing`s from the daemon's wire JSON, since `ModelListing`
    /// exposes no cross-module memberwise initializer.
    private func listings() throws -> [ModelListing] {
        let json = """
        [
          {"connection_id":"c1","connection_label":"C1","model":{"id":"m1","display_name":"M1"}},
          {"connection_id":"c1","connection_label":"C1","model":{"id":"m2","display_name":"M2"}},
          {"connection_id":"c2","connection_label":"C2","model":{"id":"m3","display_name":"M3"}}
        ]
        """
        return try JSONDecoder().decode([ModelListing].self, from: Data(json.utf8))
    }

    @Test func emptySelectionReturnsAllListings() throws {
        let all = try listings()
        let selection = SelectedModels()
        #expect(selection.isEmpty)
        #expect(selection.filter(all).map(\.id) == all.map(\.id))
    }

    @Test func nonEmptySelectionReturnsOnlySelected() throws {
        let all = try listings()
        var selection = SelectedModels()
        selection.toggle(connectionId: "c1", modelId: "m2")
        selection.toggle(connectionId: "c2", modelId: "m3")
        let filtered = selection.filter(all)
        #expect(filtered.map(\.id) == ["c1/m2", "c2/m3"])
    }

    @Test func membershipCheck() {
        var selection = SelectedModels()
        #expect(selection.isSelected(connectionId: "c1", modelId: "m1") == false)
        selection.toggle(connectionId: "c1", modelId: "m1")
        #expect(selection.isSelected(connectionId: "c1", modelId: "m1"))
        // Same modelId under a different connection is a distinct membership.
        #expect(selection.isSelected(connectionId: "c2", modelId: "m1") == false)
    }

    @Test func toggleAddsThenRemoves() {
        var selection = SelectedModels()
        selection.toggle(connectionId: "c1", modelId: "m1")
        #expect(selection.isSelected(connectionId: "c1", modelId: "m1"))
        selection.toggle(connectionId: "c1", modelId: "m1")
        #expect(selection.isSelected(connectionId: "c1", modelId: "m1") == false)
        #expect(selection.isEmpty)
    }

    @Test func jsonRoundTrip() throws {
        var selection = SelectedModels()
        selection.toggle(connectionId: "c1", modelId: "m1")
        selection.toggle(connectionId: "c2", modelId: "m3")

        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(SelectedModels.self, from: data)

        #expect(decoded == selection)
        #expect(decoded.isSelected(connectionId: "c1", modelId: "m1"))
        #expect(decoded.isSelected(connectionId: "c2", modelId: "m3"))
        #expect(decoded.isSelected(connectionId: "c1", modelId: "m2") == false)
    }

    @Test func emptyAfterDecodeStillReturnsAll() throws {
        let all = try listings()
        let data = try JSONEncoder().encode(SelectedModels())
        let decoded = try JSONDecoder().decode(SelectedModels.self, from: data)
        #expect(decoded.filter(all).count == all.count)
    }
}
