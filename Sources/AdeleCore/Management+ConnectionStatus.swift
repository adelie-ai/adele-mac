import Foundation

// MARK: - Surfacing the daemon's preflight verdict (issue #9)
//
// Every connector runs an auth-aware preflight and reports `Unavailable
// { reason }` naming the missing piece — "Azure connection needs a resource
// endpoint (base_url) and a deployment (model)", "Vertex connection needs
// project and location", and so on. Per "no silent failures", that reason has to
// reach the user rather than being reduced to a red dot, so the UI renders
// `statusDetail` wherever a connection is shown.

extension ConnectionView {
    /// The human-readable reason this connection is unusable, or `nil` when the
    /// daemon's preflight passed. Falls back to a generic message when the
    /// daemon marks a connection unavailable without a reason, so the UI is
    /// never left showing nothing.
    public var statusDetail: String? {
        guard !availability.isOk else { return nil }
        let reason = availability.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (reason?.isEmpty == false ? reason : nil) ?? "unavailable"
    }
}
