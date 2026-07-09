import Foundation

/// A saved connection profile. The password is NOT stored here — it lives in the
/// Keychain keyed by `id` — so profiles.json is safe to read/write in the clear.
struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var wsURL: String
    var username: String

    init(id: String = UUID().uuidString, name: String, wsURL: String, username: String) {
        self.id = id
        self.name = name
        self.wsURL = wsURL
        self.username = username
    }
}

/// Persists profiles + the last-used profile id to
/// `~/Library/Application Support/adele-mac/profiles.json`.
struct ProfileStore {
    var profiles: [Profile] = []
    var lastProfileID: String?

    private struct File: Codable {
        var profiles: [Profile]
        var lastProfileID: String?
    }

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("adele-mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json")
    }

    static func load() -> ProfileStore {
        guard
            let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return ProfileStore()
        }
        return ProfileStore(profiles: file.profiles, lastProfileID: file.lastProfileID)
    }

    func save() {
        let file = File(profiles: profiles, lastProfileID: lastProfileID)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
