import Foundation
import Combine

/// Projects that had a tab open recently, for the sidebar's "Recent" section.
///
/// Fed by `SidebarStore` with the project roots on screen after each refresh.
/// A project is stamped when it opens and again when its last tab closes, so
/// the list orders by when it was last in use. Only projects with no open tab
/// are listed: the open ones already have a section of their own.
final class RecentProjectsStore: ObservableObject {
    static let shared = RecentProjectsStore()

    struct Entry: Identifiable, Equatable {
        let path: String
        let lastUsed: Date

        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Recent projects with no open tab, most recent first.
    @Published private(set) var recent: [Entry] = []

    private static let defaultsKey = "SidebarRecentProjects"
    private static let maxStored = 30
    private static let maxListed = 8

    private var lastUsed: [String: Date] = [:]
    private var openRoots: Set<String> = []

    private init() {
        load()
        publish()
    }

    /// Record the project roots that currently have tabs. Cheap when nothing
    /// changed, so it can run on every sidebar refresh.
    func sync(openRoots roots: Set<String>) {
        guard roots != openRoots else { return }
        let now = Date()
        // Opened and closed projects both count as use.
        for root in roots.symmetricDifference(openRoots) {
            lastUsed[root] = now
        }
        openRoots = roots
        trim()
        save()
        publish()
    }

    /// Forget a project, e.g. from the row's context menu.
    func remove(_ path: String) {
        guard lastUsed.removeValue(forKey: path) != nil else { return }
        save()
        publish()
    }

    func clear() {
        lastUsed = lastUsed.filter { openRoots.contains($0.key) }
        save()
        publish()
    }

    private func publish() {
        let fm = FileManager.default
        let entries = lastUsed
            .filter { !openRoots.contains($0.key) && fm.fileExists(atPath: $0.key) }
            .map { Entry(path: $0.key, lastUsed: $0.value) }
            .sorted { $0.lastUsed > $1.lastUsed }
        let listed = Array(entries.prefix(Self.maxListed))
        if listed != recent { recent = listed }
    }

    private func trim() {
        guard lastUsed.count > Self.maxStored else { return }
        let keep = lastUsed.sorted { $0.value > $1.value }.prefix(Self.maxStored)
        lastUsed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func load() {
        guard let stored = UserDefaults.ghostty.dictionary(forKey: Self.defaultsKey) as? [String: Double] else { return }
        lastUsed = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        UserDefaults.ghostty.set(lastUsed.mapValues { $0.timeIntervalSince1970 }, forKey: Self.defaultsKey)
    }
}
