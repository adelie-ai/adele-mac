import Foundation

/// A stable identity for one curated model: a `(connectionId, modelId)` pair.
/// Mirrors `ModelListing.id` semantics — the same modelId under two different
/// connections is two distinct entries.
public struct SelectedModelKey: Hashable, Codable, Sendable {
    public let connectionId: String
    public let modelId: String

    public init(connectionId: String, modelId: String) {
        self.connectionId = connectionId
        self.modelId = modelId
    }
}

/// The user's curated subset of models to show in the header picker — the daemon
/// can expose hundreds (e.g. Bedrock), so the client filters down to the chosen
/// few. Pure, value-typed, and file-free: `SelectedModelsStore` (app target) wraps
/// this with JSON persistence.
///
/// Semantics: an **empty** selection means "show everything", so a fresh user is
/// never stranded with an empty picker. A non-empty selection shows only its
/// members, preserving the input listing order.
public struct SelectedModels: Codable, Equatable, Sendable {
    /// The chosen `(connectionId, modelId)` pairs.
    public private(set) var keys: Set<SelectedModelKey>

    public init(keys: Set<SelectedModelKey> = []) {
        self.keys = keys
    }

    /// No curation yet — the filter returns all listings.
    public var isEmpty: Bool { keys.isEmpty }

    /// Whether a given model is in the curated set.
    public func isSelected(connectionId: String, modelId: String) -> Bool {
        keys.contains(SelectedModelKey(connectionId: connectionId, modelId: modelId))
    }

    /// Add the model if absent, remove it if present.
    public mutating func toggle(connectionId: String, modelId: String) {
        let key = SelectedModelKey(connectionId: connectionId, modelId: modelId)
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
    }

    /// Select every model in `listings` (used by a "Select All" affordance).
    public mutating func selectAll(_ listings: [ModelListing]) {
        keys = Set(listings.map {
            SelectedModelKey(connectionId: $0.connectionId, modelId: $0.model.id)
        })
    }

    /// Clear the curated set. Because empty means "show everything", the picker
    /// then shows all models again.
    public mutating func clear() {
        keys.removeAll()
    }

    /// The heart of the feature: return only the curated listings, preserving
    /// order — but if nothing is curated, return every listing unchanged.
    public func filter(_ listings: [ModelListing]) -> [ModelListing] {
        guard !keys.isEmpty else { return listings }
        return listings.filter {
            isSelected(connectionId: $0.connectionId, modelId: $0.model.id)
        }
    }
}
