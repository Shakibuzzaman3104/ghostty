import Cocoa
import Combine
import os.log

/// Per-window façade over `SidebarStore` that publishes tab metadata for
/// one window's sidebar.
///
/// All discovery, caching, and rebuild work happens once, app-wide, in
/// `SidebarStore`. This class only holds the published slice for its
/// window's tab group, the selection state, and the user-action entry
/// points (select/close/move/git/...). One instance exists per tab window
/// because each tab window hosts its own sidebar view.
@MainActor
class SidebarTabManager: ObservableObject {
    private static let orderLog = Logger(
        subsystem: "com.hankyone.ghostty.sidebar", category: "order")

    /// What the tab's status dot should communicate. Ordered by priority.
    ///
    /// Display convention (matching the strongest patterns across T3 Code,
    /// Conductor, Emdash, cmux): a dot **pulses only when the tab needs the
    /// user** — everything else is solid or absent. "Done" and "failed" are
    /// gated on *unseen* and clear when the tab is visited.
    enum TabIndicator: Equatable, Hashable {
        /// An agent is waiting for input/approval — pulsing orange.
        case needsInput
        /// A run finished and the user hasn't looked yet — solid green.
        case doneUnseen
        /// A command/agent run failed and the user hasn't looked — solid red.
        case error
        /// Agent or foreground process is busy — small solid accent dot.
        case working
        /// Nothing worth showing.
        case none
    }

    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let gitDiffStats: String?
        let surfaceId: UUID?
        let statusEntries: [TabMetadataStore.StatusEntry]
        let needsAttention: Bool
        /// Latest desktop-notification text (OSC 9/777), shown as a row
        /// subtitle until the tab is selected. This is how agents without
        /// hooks (e.g. Devin) report "finished" — same source cmux shows.
        let notificationText: String?
        /// True when the tab has a completion that hasn't been viewed yet.
        let hasUnreadCompletion: Bool
        let tabColor: TerminalTabColor
        let faviconImage: NSImage?
        /// The detected project root directory for this tab, or nil if not in a project.
        let projectRoot: String?
        /// When this tab last had real activity (command execution, status change).
        var lastActivity: Date?
        /// When this tab was first created (persisted across restarts).
        var createdAt: Date?
        /// What the status dot should show. Computed by the store from
        /// hooks, OSC signals, and the screen-quiescence classifier.
        var indicator: TabIndicator = .none
        /// What the agent's own transcript says it is doing, when we can read
        /// one. Finer-grained than the dot: it names the tool and knows the
        /// difference between reasoning and acting.
        var activity: AgentTranscriptWatcher.Activity?

        /// The last command the shell reported running in this tab, if any.
        /// Shown in the sidebar and offered in the context menu; never typed
        /// into the terminal without the user asking.
        var lastCommand: String? {
            guard let value = statusEntries.first(where: { $0.key == "last-command" })?.value,
                  !value.isEmpty else { return nil }
            return value
        }

        /// The command that resumes this tab's last agent session, if the
        /// agent supports it and a session id was recorded.
        var agentResume: (agent: AgentType, command: String)? {
            guard let agent = AgentType.detect(from: statusEntries),
                  let sessionId = statusEntries.first(where: { $0.key == agent.sessionKey })?.value,
                  !sessionId.isEmpty,
                  let command = agent.resumeCommand(sessionId: sessionId) else { return nil }
            return (agent, command)
        }

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return ((pwd as NSString).expandingTildeInPath as NSString).lastPathComponent
        }

        /// Title with bell/ghost emoji stripped for clean sidebar display.
        var displayTitle: String {
            var t = title
            // Strip bell emoji prefix (sidebar has its own attention indicator)
            // and ghost emoji prefix (default Ghostty window title). Note:
            // dropFirst counts Characters, so each emoji+space prefix is 2.
            for prefix in ["\u{1F514} ", "\u{1F47B} "] {
                if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
            }
            // If title is just "Ghostty" or empty after stripping, use directory name
            if t.isEmpty || t == "Ghostty" {
                if let dir = directoryName { return dir }
            }
            return t
        }

        /// The id of the display group this tab belongs to: a project root path,
        /// or "__home__" / "__other__". Single source of truth for group
        /// membership — used by both `SidebarStore.buildProjectGroups` and the
        /// drag-and-drop validator so grouping and drop-eligibility can never
        /// disagree (a mismatch previously broke Home-group reordering).
        var groupID: String {
            if let projectRoot { return projectRoot }
            if let pwd, (pwd as NSString).expandingTildeInPath == NSHomeDirectory() {
                return "__home__"
            }
            return "__other__"
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
                && lhs.pwd == rhs.pwd && lhs.gitDiffStats == rhs.gitDiffStats
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.notificationText == rhs.notificationText
                && lhs.hasUnreadCompletion == rhs.hasUnreadCompletion
                && lhs.tabColor == rhs.tabColor
                && lhs.faviconImage === rhs.faviconImage
                && lhs.projectRoot == rhs.projectRoot
                && lhs.lastActivity == rhs.lastActivity
                && lhs.indicator == rhs.indicator
                && lhs.activity == rhs.activity
        }
    }

    /// A group of tabs sharing the same project root.
    struct ProjectGroup: Identifiable, Equatable {
        let id: String  // projectRoot path, "__home__", or "__other__" for ungrouped
        let name: String
        let projectRoot: String?
        let tabs: [TabItem]
        let faviconImage: NSImage?
        /// Aggregated git diff stats across all tabs in this project.
        let gitDiffStats: String?

        /// Whether this is the "Other" group for ungrouped tabs.
        var isOtherGroup: Bool { id == "__other__" }

        /// Whether this is the Home group for tabs in the home directory.
        var isHomeGroup: Bool { id == "__home__" }

        /// Where a terminal launched from this group's header should open.
        ///
        /// Home has no project root, but it does have an obvious folder, and
        /// falling through to "wherever the last tab happened to be" is the
        /// one answer nobody means when they click the header that says Home.
        /// Other stays inherited: it is a bag of unrelated directories, so
        /// there is nothing to point at.
        var launchDirectory: String? {
            if let projectRoot { return projectRoot }
            return isHomeGroup ? NSHomeDirectory() : nil
        }

        static func == (lhs: ProjectGroup, rhs: ProjectGroup) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name
                && lhs.tabs == rhs.tabs
                && lhs.faviconImage === rhs.faviconImage
                && lhs.gitDiffStats == rhs.gitDiffStats
        }
    }

    enum SortMode: String, CaseIterable {
        case manual = "Manual"
        case createdAt = "Created at"
        case lastActivity = "Last activity"
    }

    enum GitActionStatus: Equatable {
        case inProgress
        case error(String)
    }

    // MARK: - Published State

    @Published private(set) var tabs: [TabItem] = []
    @Published private(set) var projectGroups: [ProjectGroup] = []
    @Published var selectedTabID: ObjectIdentifier?
    @Published private(set) var collapsedProjects: Set<String> = []

    private(set) weak var window: NSWindow?
    private(set) var isInvalidated = false

    /// Guard flag: when true, notification-driven refreshSelection() calls are
    /// suppressed so they don't overwrite the optimistic selectedTabID that
    /// selectTab() just set. The tabGroup.selectedWindow setter fires key-window
    /// notifications synchronously during assignment, and at that point the tab
    /// group's selectedWindow can return intermediate (old) state.
    private var isSelectingTab = false

    private var store: SidebarStore { SidebarStore.shared }

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        SidebarStore.shared.register(self, bellTriggersAttention: bellTriggersAttention)
        refreshSelection()
    }

    /// Resolve a tab's live NSWindow from the current tab group.
    ///
    /// `TabItem` deliberately does not retain its window — every sidebar used
    /// to hold a strong ref to every other tab's window, which kept closed
    /// terminals (and their Metal layers / keepers) alive after close.
    func window(for tab: TabItem) -> NSWindow? {
        guard let window else { return nil }
        return store.orderedTabWindows(for: window).first {
            ObjectIdentifier($0) == tab.id
        }
    }

    /// Clear published tab rows when the owning tab closes.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        store.unregister(self)
        tabs.removeAll()
        projectGroups.removeAll()
        selectedTabID = nil
    }

    deinit {
        // Store holds only a weak reference; nothing to tear down here.
    }

    // MARK: - Store Callbacks

    /// Whether the given window belongs to the same tab group as ours.
    func isInSameTabGroup(as other: NSWindow) -> Bool {
        guard let window else { return false }
        if let group = window.tabGroup {
            return other.tabGroup === group
        }
        return other === window
    }

    /// Receive a freshly built slice from the store. Publishes only on change.
    func apply(
        tabs newTabs: [TabItem],
        projectGroups newGroups: [ProjectGroup],
        collapsed: Set<String>,
        republishForTimeLabels: Bool = false
    ) {
        guard !isInvalidated else { return }
        let tabsChanged = newTabs != tabs
        if tabsChanged {
            tabs = newTabs
        }
        if newGroups != projectGroups {
            projectGroups = newGroups
        } else if !tabsChanged && republishForTimeLabels {
            // Data identical, but relative-time labels ("3m") rendered from
            // it are stale — poke SwiftUI without touching the arrays.
            objectWillChange.send()
        }
        if collapsed != collapsedProjects {
            collapsedProjects = collapsed
        }
        refreshSelection()
    }

    func applyCollapsed(_ collapsed: Set<String>) {
        guard !isInvalidated else { return }
        if collapsed != collapsedProjects {
            collapsedProjects = collapsed
        }
    }

    /// The store's git action state changed; re-render.
    func noteGitActionChanged() {
        guard !isInvalidated else { return }
        objectWillChange.send()
    }

    // MARK: - Selection

    /// Lightweight update that only syncs `selectedTabID` from the window's
    /// tab group, without rebuilding anything.
    func refreshSelection() {
        guard !isInvalidated else { return }
        guard !isSelectingTab else { return }
        guard let window else { return }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let newID = ObjectIdentifier(selectedWindow)
        if selectedTabID != newID {
            selectedTabID = newID
        }
    }

    func selectTab(_ tab: TabItem) {
        guard let tabWindow = window(for: tab) else { return }
        Self.orderLog.info("selectTab: \(tab.displayTitle, privacy: .public) win#\(tabWindow.windowNumber)")

        // Don't rebuild here — the next store refresh picks up the
        // attention/acknowledgment changes.
        store.clearAttentionOnSelect(windowID: tab.id)
        acknowledgeCompletion(for: tab)
        // Only publish when the value actually changes. `@Published` fires on
        // every assignment, even to an equal value.
        if selectedTabID != tab.id { selectedTabID = tab.id }
        // Guard against notification-driven refreshSelection() calls that fire
        // synchronously during the tabGroup.selectedWindow setter. Without this,
        // those handlers read intermediate state and revert our optimistic update.
        isSelectingTab = true
        if let window,
           let tabGroup = window.tabGroup,
           tabGroup.windows.contains(tabWindow) {
            tabGroup.selectedWindow = tabWindow
        } else {
            tabWindow.makeKeyAndOrderFront(nil)
        }
        isSelectingTab = false

        // After the setter, the target window's sidebar is now visible to the user.
        // Its manager's refreshSelection may have run during the setter and read
        // intermediate (old) state. Correct it now that the setter has completed.
        if let targetController = tabWindow.windowController as? TerminalController,
           let targetManager = targetController.sidebarTabManager,
           targetManager !== self,
           targetManager.selectedTabID != tab.id {
            targetManager.selectedTabID = tab.id
        }
    }

    /// Acknowledge the current completion token for a tab so its green dot stops pulsing.
    private func acknowledgeCompletion(for tab: TabItem) {
        guard let sid = tab.surfaceId else { return }
        guard let agent = AgentType.detect(from: tab.statusEntries) else { return }
        guard let token = tab.statusEntries.first(where: { $0.key == agent.doneAtKey })?.value else { return }
        TabMetadataStore.shared.acknowledgedDoneToken[sid] = token
    }

    // MARK: - Refresh

    func refresh() {
        guard !isInvalidated else { return }
        store.requestRefresh(reason: "manual", force: true)
    }

    // MARK: - Sorting & Grouping passthroughs

    var projectSortMode: SortMode { store.projectSortMode }

    func setProjectSortMode(_ mode: SortMode) {
        store.projectSortMode = mode
    }

    func toggleProjectCollapsed(_ groupId: String) {
        store.toggleProjectCollapsed(groupId)
    }

    func moveProjectGroup(fromId: String, toId: String) {
        store.moveProjectGroup(fromId: fromId, toId: toId, currentGroups: projectGroups)
    }

    // MARK: - Git Actions passthroughs

    func gitCommit(projectRoot: String) {
        guard confirmStageAll(projectRoot: projectRoot, andPush: false) else { return }
        store.gitCommit(projectRoot: projectRoot)
    }
    func gitPush(projectRoot: String) { store.gitPush(projectRoot: projectRoot) }
    func gitCommitAndPush(projectRoot: String) {
        guard confirmStageAll(projectRoot: projectRoot, andPush: true) else { return }
        store.gitCommitAndPush(projectRoot: projectRoot)
    }

    /// Commit stages everything with `git add -A`, untracked files included,
    /// so ask first.
    private func confirmStageAll(projectRoot: String, andPush: Bool) -> Bool {
        let alert = NSAlert()
        let name = (projectRoot as NSString).lastPathComponent
        alert.messageText = andPush ? "Commit and push all changes in \(name)?" : "Commit all changes in \(name)?"
        alert.informativeText = """
            This stages every change, including untracked files (git add -A), \
            and commits with a generated message\(andPush ? ", then pushes the current branch" : "").
            """
        alert.addButton(withTitle: andPush ? "Commit & Push" : "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func gitActionStatus(forProjectRoot root: String?) -> GitActionStatus? {
        store.gitActionStatus(forProjectRoot: root)
    }

    // MARK: - Tool Launch

    /// Represents a coding agent the sidebar knows about — the single source
    /// of truth for both the new-tab menu and status/session tracking.
    ///
    /// To add an agent, add a case here and fill in the switches below; the
    /// menu, installed-detection, launch, resume, status keys, transient-key
    /// filtering and stale-session sweep all derive from `allCases`.
    ///
    /// `rawValue` is the internal key prefix used by the hook IPC protocol
    /// (e.g. `claude-session`) and must stay stable — it is NOT the display
    /// name and NOT necessarily the binary name.
    enum AgentType: String, CaseIterable {
        case claude
        case codex
        case opencode
        case grok
        case devin
        case cursor
        case antigravity
        case cline

        /// Human-facing name shown in the new-tab menu.
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .opencode: return "OpenCode"
            case .grok: return "Grok Build"
            case .devin: return "Devin"
            case .cursor: return "Cursor"
            case .antigravity: return "Antigravity"
            case .cline: return "Cline"
            }
        }

        /// The executable name to look for on the user's PATH. This can differ
        /// from both the display name and the rawValue key prefix.
        var binaryName: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .opencode: return "opencode"
            case .grok: return "grok"
            case .devin: return "devin"
            case .cursor: return "cursor-agent"
            case .antigravity: return "agy"
            case .cline: return "cline"
            }
        }

        /// Asset-catalog image name for the agent's official menu mark.
        var icon: String {
            switch self {
            case .claude: return "ClaudeIcon"
            case .codex: return "CodexIcon"
            case .opencode: return "OpenCodeIcon"
            case .grok: return "GrokIcon"
            case .devin: return "DevinIcon"
            case .cursor: return "CursorIcon"
            case .antigravity: return "AntigravityIcon"
            case .cline: return "ClineIcon"
            }
        }

        /// Extra flags needed to start the agent's interactive session. Agents
        /// launch with their normal permission prompts; nothing here bypasses
        /// approvals or sandboxing.
        private var launchFlags: String? {
            switch self {
            // Cline needs -i for its interactive TUI (bare `cline` runs a
            // single non-interactive prompt).
            case .cline: return "-i"
            case .claude, .codex, .opencode, .grok, .devin, .cursor, .antigravity: return nil
            }
        }

        /// The shell command to launch a fresh session of this agent.
        var launchCommand: String {
            [binaryName, launchFlags].compactMap { $0 }.joined(separator: " ")
        }

        /// The shell command to resume a prior session, or nil if resume isn't
        /// supported. `sessionId` is the stored value of `sessionKey`.
        func resumeCommand(sessionId: String) -> String? {
            // Guard against command injection: session ids are typed straight
            // into the shell, so only allow a safe charset.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let idIsSafe = sessionId.unicodeScalars.allSatisfy { allowed.contains($0) }
            switch self {
            case .claude:
                guard idIsSafe else { return nil }
                return "claude --resume \(sessionId)"
            case .codex:
                guard idIsSafe else { return nil }
                return "codex resume \(sessionId)"
            case .grok:
                guard idIsSafe else { return nil }
                return "grok --resume \(sessionId)"
            case .cursor:
                guard idIsSafe else { return nil }
                return "cursor-agent --resume \(sessionId)"
            case .devin:
                // Devin exposes no session id in hooks, so there's nothing to
                // validate — launch its interactive session picker instead.
                return "devin -r"
            case .opencode, .antigravity, .cline:
                // No hook-provided session id / resume support yet.
                return nil
            }
        }

        /// The session key (e.g. "claude-session"). Presence of this key
        /// indicates the tab is running this agent.
        var sessionKey: String { "\(rawValue)-session" }

        /// Whether this agent's own record of the conversation is readable.
        ///
        /// For these, silence is information: it means the agent has not
        /// started a turn yet, not that we are in the dark. Guessing a state
        /// from the shape of the screen on top of that is how a freshly
        /// opened agent sitting at its own prompt ends up demanding
        /// attention it does not want.
        var hasDirectStatus: Bool {
            switch self {
            case .claude, .codex, .grok, .opencode, .devin, .cline: return true
            case .cursor, .antigravity: return false
            }
        }

        /// The active status key (e.g. "claude-active"). Values: "working", "done", "needs-input".
        var activeKey: String { "\(rawValue)-active" }

        /// The PID key (e.g. "claude-pid"). Used for stale session detection.
        var pidKey: String { "\(rawValue)-pid" }

        /// The completion token key (e.g. "claude-done-at"). A UUID emitted on Stop.
        var doneAtKey: String { "\(rawValue)-done-at" }

        /// The prompt text key (e.g. "claude"). Holds the truncated last user prompt.
        var promptKey: String { rawValue }

        /// Detect which agent is running for a set of status entries.
        /// Returns the first matching agent (agents are mutually exclusive).
        static func detect(from entries: [TabMetadataStore.StatusEntry]) -> AgentType? {
            for agent in allCases {
                if entries.contains(where: { $0.key == agent.sessionKey }) {
                    return agent
                }
            }
            return nil
        }
    }

    /// Create a new tab, optionally in a project directory and/or running an
    /// agent. A nil `agent` opens a plain terminal.
    func createNewTab(agent: AgentType? = nil, projectRoot: String? = nil) {
        guard let window,
              let controller = window.windowController as? TerminalController else {
            // Fallback: create a generic new tab
            NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
            return
        }

        var config = Ghostty.SurfaceConfiguration()
        if let root = projectRoot {
            config.workingDirectory = root
        }
        // Set the agent command as initialInput — this is fed directly into
        // the PTY as stdin data, so the shell reads and executes it as if
        // the user typed it and pressed Enter.
        if let command = agent?.launchCommand {
            config.initialInput = command + "\n"
        }

        _ = TerminalController.newTab(
            controller.ghostty,
            from: window,
            withBaseConfig: config
        )
    }

    /// Ask for a folder and open a tab in it. The tab joins that folder's
    /// project group, or starts one, like any other tab.
    static func openFolder(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true

        let open: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                openTab(in: url.path, from: window)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(panel.runModal())
        }
    }

    /// Open a tab with `directory` as its working directory, in `window`'s
    /// tab group when there is one, otherwise in a new window.
    static func openTab(in directory: String, from window: NSWindow?) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory
        if let window, window.windowController is TerminalController {
            _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
        } else {
            _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
        }
    }

    // MARK: - Tab Actions

    func createNewTab() {
        NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
    }

    /// Select a tab and type `text` at its prompt without pressing Enter, so
    /// the user can read it before running it.
    func typeAtPrompt(_ text: String, in tab: TabItem) {
        guard let controller = window(for: tab)?.windowController as? BaseTerminalController,
              let surface = controller.surfaceTree.first(where: { $0.id == tab.surfaceId })
                ?? controller.focusedSurface else { return }
        // The text comes from IPC-settable metadata; drop control characters
        // so an embedded newline or escape sequence cannot run anything.
        let safe = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ))
        guard !safe.isEmpty else { return }
        selectTab(tab)
        surface.sendText(safe)
    }

    func setTabColor(_ color: TerminalTabColor, for tab: TabItem) {
        (window(for: tab) as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = window(for: tab)?.windowController as? TerminalController else { return }
        controller.closeTab(nil)
    }

    /// The window shown directly above `window` in the sidebar, or the one
    /// below it when `window` is the very first row. Nil if it's the only tab.
    ///
    /// Used to choose which tab takes over when the visible one closes.
    func tabAdjacentInDisplayOrder(to window: NSWindow) -> NSWindow? {
        let ordered = projectGroups.flatMap(\.tabs)
        let id = ObjectIdentifier(window)
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        if index > 0 { return self.window(for: ordered[index - 1]) }
        return ordered.count > 1 ? self.window(for: ordered[1]) : nil
    }

    func renameTab(_ tab: TabItem, to newTitle: String) {
        guard let controller = window(for: tab)?.windowController as? BaseTerminalController else { return }
        controller.titleOverride = newTitle.isEmpty ? nil : newTitle
        refresh()
    }

    func promptRenameTab(_ tab: TabItem) {
        guard let controller = window(for: tab)?.windowController as? BaseTerminalController else { return }
        controller.promptTabTitle()
    }

    func closeOtherTabs(_ tab: TabItem) {
        guard let window else { return }
        let tabWindows = store.orderedTabWindows(for: window)
        guard tabWindows.count > 1 else { return }
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows = store.orderedTabWindows(for: window)
        guard tabWindows.count > 1 else { return }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        let tabsToClose = Array(tabWindows[(idx + 1)...])
        for w in tabsToClose {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    // MARK: - Moving Between Windows

    struct WindowTarget: Identifiable {
        let id: ObjectIdentifier
        let title: String
        let window: NSWindow
    }

    private func windowTarget(for window: NSWindow, withCount: Bool) -> WindowTarget {
        let selected = window.tabGroup?.selectedWindow ?? window
        let count = window.tabGroup?.windows.count ?? 1
        var title = selected.title.isEmpty ? "Window" : selected.title
        if title.hasPrefix("\u{1F514} ") { title = String(title.dropFirst(2)) }
        if withCount && count > 1 { title += " (\(count) tabs)" }
        return WindowTarget(id: window.tabGroup.map { ObjectIdentifier($0) } ?? ObjectIdentifier(window),
                            title: title, window: selected)
    }

    func ownWindowTarget() -> WindowTarget? {
        window.map { windowTarget(for: $0, withCount: false) }
    }

    private func isOwnGroup(_ window: NSWindow, for tab: TabItem) -> Bool {
        guard let source = self.window(for: tab) else { return false }
        return window === source || (source.tabGroup != nil && window.tabGroup === source.tabGroup)
    }

    func otherWindowTargets(for tab: TabItem) -> [WindowTarget] {
        guard window(for: tab) != nil else { return [] }
        var seen: Set<ObjectIdentifier> = []
        return TerminalController.all.compactMap { controller in
            guard let window = controller.window, !isOwnGroup(window, for: tab),
                  !window.styleMask.contains(.fullScreen) else { return nil }
            let target = windowTarget(for: window, withCount: true)
            return seen.insert(target.id).inserted ? target : nil
        }
    }

    func canMoveTabToNewWindow(_ tab: TabItem) -> Bool {
        guard let window = window(for: tab), !window.styleMask.contains(.fullScreen) else { return false }
        return (window.tabGroup?.windows.count ?? 1) > 1
    }

    func moveTabToNewWindow(_ tab: TabItem, at point: NSPoint? = nil) {
        guard canMoveTabToNewWindow(tab), let window = window(for: tab),
              let group = window.tabGroup else { return }
        let frame = window.frame
        let remaining = group.windows.filter { $0 !== window }
        var newFrame = frame
        if let point, !frame.contains(point) {
            newFrame.origin = NSPoint(x: point.x - 40, y: point.y + 20 - frame.height)
        } else {
            newFrame.origin = NSPoint(x: frame.origin.x + 40, y: frame.origin.y - 40)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point ?? frame.origin) }) ?? window.screen {
            let visible = screen.visibleFrame
            newFrame.origin.x = max(visible.minX, min(newFrame.origin.x, visible.maxX - newFrame.width))
            newFrame.origin.y = max(visible.minY, min(newFrame.origin.y, visible.maxY - newFrame.height))
        }
        group.removeWindow(window)
        Self.restoreFrame(frame, for: remaining)
        window.setFrame(newFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
        DispatchQueue.main.async { [weak window] in
            guard let window, window.frame != newFrame else { return }
            window.setFrame(newFrame, display: true)
        }
    }

    func dropTargetWindow(for tab: TabItem, at point: NSPoint) -> WindowTarget? {
        for window in NSApp.orderedWindows {
            guard window is TerminalWindow, window.isVisible, window.frame.contains(point) else { continue }
            if isOwnGroup(window, for: tab) { return nil }
            return windowTarget(for: window, withCount: false)
        }
        return nil
    }

    /// Preserve both group frames because AppKit may cascade a detached window.
    @discardableResult
    func moveTab(
        _ tab: TabItem,
        to target: WindowTarget,
        relativeTo targetTab: TabItem? = nil,
        position: TabInsertionPosition = .after
    ) -> Bool {
        guard let window = window(for: tab), !isOwnGroup(target.window, for: tab),
              !window.styleMask.contains(.fullScreen),
              !target.window.styleMask.contains(.fullScreen) else { return false }
        let group = window.tabGroup
        let sourceFrame = window.frame
        let sourceWindows = (group?.windows ?? []).filter { $0 !== window }
        let targetWindows = target.window.tabGroup?.windows ?? [target.window]
        let anchor = targetTab.flatMap { tab in targetWindows.first { ObjectIdentifier($0) == tab.id } }
            ?? targetWindows.last ?? target.window
        let targetFrame = anchor.frame
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group?.removeWindow(window)
        Self.restoreFrame(sourceFrame, for: sourceWindows)
        window.setFrame(targetFrame, display: false)
        let added = anchor.addTabbedWindowSafely(window, ordered: targetTab == nil || position == .after ? .above : .below)
        if added {
            Self.restoreFrame(targetFrame, for: anchor.tabGroup?.windows ?? [anchor, window])
            let windows = anchor.tabGroup?.windows ?? [anchor, window]
            let ids = windows.compactMap { store.tabOrderKey(for: $0) }
            if ids.count == windows.count { store.persistTabOrder(ids, for: windows) }
            window.makeKeyAndOrderFront(nil)
        } else {
            if let sourceAnchor = sourceWindows.last {
                sourceAnchor.addTabbedWindowSafely(window, ordered: .above)
                Self.restoreFrame(sourceFrame, for: sourceAnchor.tabGroup?.windows ?? [sourceAnchor, window])
            } else {
                window.setFrame(sourceFrame, display: true)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSAnimationContext.endGrouping()
        refresh()
        return added
    }

    private static func restoreFrame(_ frame: NSRect, for windows: [NSWindow]) {
        for window in windows where window.frame != frame {
            window.setFrame(frame, display: false)
        }
    }

    enum TabInsertionPosition: Equatable {
        case before
        case after
    }

    /// Reorder one tab relative to another by identity.
    ///
    /// The sidebar display groups tabs by project, while AppKit and the
    /// persisted order are a flat window list. Keeping integer indices across
    /// those two spaces is unsafe, so the drop boundary passes stable window
    /// identities and this method derives one desired flat order used by both
    /// AppKit and persistence.
    @discardableResult
    func moveTab(
        _ movingTab: TabItem,
        relativeTo targetTab: TabItem,
        position: TabInsertionPosition
    ) -> Bool {
        guard let movingWindowRef = window(for: movingTab),
              let targetWindowRef = window(for: targetTab) else { return false }
        Self.orderLog.info(
            "moveTab win#\(movingWindowRef.windowNumber) \(position == .before ? "before" : "after") win#\(targetWindowRef.windowNumber)")

        guard movingTab.id != targetTab.id,
              movingTab.groupID == targetTab.groupID,
              let window else { return false }

        let currentWindows = store.orderedTabWindows(for: window)
        guard let sourceIndex = currentWindows.firstIndex(where: {
            ObjectIdentifier($0) == movingTab.id
        }), currentWindows.contains(where: {
            ObjectIdentifier($0) == targetTab.id
        }) else { return false }

        let movingWindow = currentWindows[sourceIndex]
        var desiredWindows = currentWindows
        desiredWindows.remove(at: sourceIndex)

        guard let targetIndex = desiredWindows.firstIndex(where: {
            ObjectIdentifier($0) == targetTab.id
        }) else { return false }
        let insertionIndex = position == .before ? targetIndex : targetIndex + 1
        desiredWindows.insert(movingWindow, at: insertionIndex)

        guard desiredWindows.map(ObjectIdentifier.init) != currentWindows.map(ObjectIdentifier.init)
        else { return false }

        // Capture the visible member before AppKit mutates the tab group.
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let preMoveFrame = selectedWindow.frame

        // Position the moving window against its neighbor in the final order.
        // AppKit's `.below` inserts before the receiver and `.above` after it.
        if insertionIndex == 0 {
            desiredWindows[1].addTabbedWindow(movingWindow, ordered: .below)
        } else {
            desiredWindows[insertionIndex - 1].addTabbedWindow(movingWindow, ordered: .above)
        }

        let reorderedIds = desiredWindows.compactMap { store.tabOrderKey(for: $0) }
        if reorderedIds.count == desiredWindows.count {
            store.persistTabOrder(reorderedIds, for: currentWindows)
        }

        // A macOS tab group renders a single shared frame (the key window's).
        // Reordering via addTabbedWindow + makeKeyAndOrderFront can make the
        // group adopt the re-inserted/newly-key window's own cascade-offset
        // origin, teleporting the whole visible window on drop. Capture the
        // current on-screen frame and restore it afterward so the window stays
        // put. (Same teleport class the showWindow secondary-tab guard prevents.)
        if let tabGroup = window.tabGroup,
           tabGroup.windows.contains(selectedWindow) {
            tabGroup.selectedWindow = selectedWindow
        }
        if selectedWindow.tabGroup?.windows.contains(selectedWindow) == true || selectedWindow === window {
            selectedWindow.makeKeyAndOrderFront(nil)
            if selectedWindow.frame != preMoveFrame {
                selectedWindow.setFrame(preMoveFrame, display: true)
            }
        }

        refresh()
        return true
    }
}
