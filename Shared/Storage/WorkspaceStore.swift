import Foundation
import Observation
import PDFKit

@MainActor @Observable final class WorkspaceStore {
    private(set) var state: WorkspaceState {
        didSet {
            invalidateRecordQueries()
            #if os(iOS)
            scheduleWidgetSnapshot()
            #endif
        }
    }
    var feedbackSequence = 0
    var errorMessage: String?
    var information: String?
    var navigation = AppDestination.overview
    var openedRecordID: UUID?
    var createKind: ItemKind?
    var pendingImport: WorkspaceState?
    var importDescription = ""
    let isDemoMode: Bool
    @ObservationIgnored private let preferenceStorage: WorkspacePreferenceStorage
    var preferences: WorkspacePreferences {
        get { preferenceStorage.value }
        set { preferenceStorage.value = newValue }
    }
    var projectCategoryKeys: [String] {
        var seen = Set<String>()
        let keys = WorkspacePreferences.builtinProjectCategoryKeys.filter { !preferences.hiddenBuiltinProjectCategories.contains($0) }
            + preferences.customProjectCategories
            + state.records.filter { $0.kind.isProjectGroup && $0.deletedAt == nil }.map(\.projectKind)
        return keys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
    }
    func applyCreationPreferences(to record: inout WorkspaceRecord) { preferences.apply(to: &record) }
    func renameProjectCategory(_ key: String, to name: String) throws {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target.utf16.count <= 240,
              !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("分类名称须为 1–240 个字符，且不能包含换行。"))
        }
        guard projectCategoryKeys.contains(key) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此分类已改变，请重新打开。")) }
        guard target != key else { return }
        guard !projectCategoryKeys.contains(target) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("已有这个分类，请使用其他名称。")) }
        var updated = preferences
        updated.customProjectCategories.removeAll { $0 == key }
        updated.customProjectCategories.append(target)
        if WorkspacePreferences.builtinProjectCategoryKeys.contains(key) { updated.hiddenBuiltinProjectCategories.append(key) }
        if updated.defaultProjectCategory == key { updated.defaultProjectCategory = target }
        let normalized = updated.normalized()
        guard normalized.customProjectCategories.contains(target) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("自定义分类最多保留 50 个。")) }
        let used = state.records.contains { $0.kind.isProjectGroup && $0.deletedAt == nil && $0.projectKind == key }
        if used {
            try commit { draft in
                _ = try WorkspaceLogic.renameProjectCategory(from: key, to: target, in: &draft)
            }
        }
        preferences = normalized
        feedbackSequence += 1
    }

    func removeProjectCategory(_ key: String) throws {
        guard projectCategoryKeys.contains(key) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此分类已改变，请重新打开。")) }
        let used = state.records.contains { $0.kind.isProjectGroup && $0.deletedAt == nil && $0.projectKind == key }
        if used {
            try commit { draft in
                _ = try WorkspaceLogic.removeProjectCategory(key, in: &draft)
            }
        }
        // Update local options only after the workspace change has saved successfully.
        preferences.removeProjectCategory(key)
        feedbackSequence += 1
    }

    private(set) var demoStore: WorkspaceStore?
    @ObservationIgnored private weak var demoOwner: WorkspaceStore?
    var activeStore: WorkspaceStore { demoStore ?? self }
    var demoAppearance = "system"
    var demoColorTheme = "blue"
    var demoHapticsEnabled = true
    var demoPlaysLaunchAnimation = false
    #if os(iOS)
    var demoWidgetSharingEnabled = true
    var widgetSharingEnabled: Bool {
        get { isDemoMode ? demoWidgetSharingEnabled : WorkspaceWidgetStorage.isSharingEnabled }
        set {
            if isDemoMode { demoWidgetSharingEnabled = newValue }
            else { WorkspaceWidgetStorage.isSharingEnabled = newValue }
        }
    }
    #endif
    var hapticsEnabled: Bool { isDemoMode ? demoHapticsEnabled : UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true }
    let notifications: NotificationCoordinator
    let backend: BackendService
    let courses: CourseLibraryService
    #if os(iOS)
    let liveActivity: DeadlineLiveActivityCoordinator
    #endif
    private(set) var syncing = false
    private var syncStatusKey = "尚未同步"
    var syncStatus: String { WorkspaceLocalization.string(syncStatusKey) }
    private(set) var syncNeedsRetry = false
    private var displayedWorkspaceScope: String? {
        didSet {
            #if os(iOS)
            scheduleWidgetSnapshot()
            #endif
        }
    }
    private var workspaceAccessDenied = false {
        didSet {
            #if os(iOS)
            scheduleWidgetSnapshot()
            #endif
        }
    }
    #if os(iOS)
    @ObservationIgnored var widgetSnapshotTask: Task<Void, Never>?
    var widgetWorkspaceScope: String? { displayedWorkspaceScope }
    var widgetAccessDenied: Bool { workspaceAccessDenied }
    var isActiveForWidgets: Bool {
        isDemoMode ? demoOwner?.demoStore === self : demoStore == nil
    }
    #endif
    private enum SharingSyncControl: Error { case readOnly }
    var isReadOnlyWorkspace: Bool {
        guard !isDemoMode else { return false }
        if workspaceAccessDenied || backend.workspaceAccessRole == "viewer" { return true }
        if backend.currentWorkspaceID != nil && displayedWorkspaceScope != backend.accountScope { return true }
        return displayedWorkspaceScope?.contains("|workspace:") == true && displayedWorkspaceScope != backend.accountScope
    }
    var pendingSyncReview: WorkspaceSyncCheckpoint?
    private(set) var syncReviewBase: WorkspaceState?
    private(set) var syncReviewLocal: WorkspaceState?
    var automaticSync: Bool {
        get { !isDemoMode && UserDefaults.standard.bool(forKey: "automaticWorkspaceSync") }
        set {
            guard !isDemoMode else { return }
            UserDefaults.standard.set(newValue, forKey: "automaticWorkspaceSync")
            if newValue {
                scheduleSync()
            } else {
                syncTask?.cancel()
                syncTask = nil
            }
            #if os(iOS)
            WorkspaceBackgroundSync.updateSchedule(for: self)
            #endif
        }
    }
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let repository: SwiftDataRepository
    @ObservationIgnored private var recordIndex: WorkspaceRecordIndex?
    @ObservationIgnored private var visibleKindCache: [ItemKind: [WorkspaceRecord]] = [:]
    @ObservationIgnored private var archivedKindCache: [ItemKind: [WorkspaceRecord]] = [:]
    @ObservationIgnored private var actionCache: [WorkspaceRecord]?
    @ObservationIgnored private var projectGroupCache: [WorkspaceRecord]?
    @ObservationIgnored private var homeCache: (pending: [WorkspaceRecord], nearest: [WorkspaceRecord], preparedAt: Date)?
    @ObservationIgnored private var memberCache: [UUID: [WorkspaceRecord]] = [:]
    @ObservationIgnored private var interactionPrepared = false
    @ObservationIgnored private var interactionPreparation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var queryGeneration = 0

    /// Contains only immutable value snapshots; no context, model, or UI object crosses actors.
    struct PreparedRecordQueries: @unchecked Sendable {
        let source: [WorkspaceRecord]
        let index: WorkspaceRecordIndex
        let actions: [WorkspaceRecord]
        let groups: [WorkspaceRecord]
        let deadlines: [WorkspaceRecord]
        let homePending: [WorkspaceRecord]
        let homeNearest: [WorkspaceRecord]
        let preparedAt: Date
    }
    nonisolated static func prepareRecordQueries(_ records: [WorkspaceRecord]) async throws -> PreparedRecordQueries {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let index = WorkspaceRecordIndex(records)
            let now = Date()
            let deadlines = index.records(.deadline)
            let actions = index.actionRecords
            let result = PreparedRecordQueries(source: records, index: index, actions: actions,
                groups: index.projectGroupRecords, deadlines: deadlines,
                homePending: HomePresentationOrder.pending(actions + deadlines, now: now),
                homeNearest: Array(HomePresentationOrder.nearestDeadlines(deadlines).prefix(3)), preparedAt: now)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    init(repository: SwiftDataRepository, isDemoMode: Bool = false,
         preparedSession: BackendService.PreparedSession? = nil, preparedQueries: PreparedRecordQueries? = nil) throws {
        self.repository = repository; self.isDemoMode = isDemoMode
        preferenceStorage = WorkspacePreferenceStorage(persists: !isDemoMode)
        notifications = NotificationCoordinator(isDemoMode: isDemoMode)
        backend = BackendService(isDemoMode: isDemoMode, preparedSession: preparedSession)
        courses = CourseLibraryService(backend: backend, repository: repository, isDemoMode: isDemoMode)
        #if os(iOS)
        liveActivity = DeadlineLiveActivityCoordinator(isDemoMode: isDemoMode)
        #endif
        state = try repository.load()
        displayedWorkspaceScope = try repository.syncCheckpoint()?.scope
        // The SwiftData checkpoint is the durable visible workspace. Recover
        // selection after a crash between changing preferences and saving data.
        if let identity = backend.accountIdentityScope,
           let displayedWorkspaceScope, displayedWorkspaceScope.hasPrefix(identity + "|workspace:") {
            let id = String(displayedWorkspaceScope.dropFirst((identity + "|workspace:").count))
            if backend.currentWorkspaceID != id { backend.selectWorkspace(id: id, role: "viewer") }
        } else if backend.currentWorkspaceID != nil {
            backend.selectWorkspace(id: nil, role: "owner")
        }
        notifications.store = self
        if let preparedQueries, preparedQueries.source == state.records { install(preparedQueries) }
        // Recurrence expansion and system refresh run after the first frame via
        // refresh(), rather than writing the same workspace during app init.
    }
    /// A separate object graph keeps delayed editor/import tasks tied to the
    /// discarded demo, even after the real workspace becomes visible again.
    func beginDemo() throws {
        guard !isDemoMode, demoStore == nil else { return }
        let demo = try WorkspaceStore(repository: SwiftDataRepository(inMemory: true), isDemoMode: true)
        demo.demoOwner = self
        demo.demoAppearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        demo.demoColorTheme = UserDefaults.standard.string(forKey: "colorTheme") ?? "blue"
        demo.demoHapticsEnabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
        demo.demoPlaysLaunchAnimation = UserDefaults.standard.bool(forKey: WorkspaceLaunchPreferences.repeatsKey)
        demo.preferences = preferences
        #if os(iOS)
        demo.demoWidgetSharingEnabled = WorkspaceWidgetStorage.isSharingEnabled
        #endif
        #if os(iOS)
        liveActivity.suspend()
        #endif
        do { try demo.resetDemo() }
        catch {
            #if os(iOS)
            liveActivity.resume(in: state)
            #endif
            throw error
        }
        syncTask?.cancel(); syncTask = nil
        demoStore = demo
        #if os(iOS)
        demo.publishWidgetSnapshot()
        #endif
    }
    func resetDemo() throws {
        guard isDemoMode else { return }
        let fresh = WorkspaceDemo.make()
        #if os(iOS)
        liveActivity.end()
        #endif
        try commit { $0 = fresh }
        openedRecordID = nil; createKind = nil; pendingImport = nil
        errorMessage = nil; information = nil
    }
    func endDemo() {
        guard isDemoMode, let owner = demoOwner, owner.demoStore === self else { return }
        // The detached store remains a sandbox for any already-running task.
        #if os(iOS)
        liveActivity.retireDemoSession()
        #endif
        owner.demoStore = nil
        #if os(iOS)
        owner.liveActivity.resume(in: owner.state)
        owner.publishWidgetSnapshot()
        #endif
        owner.scheduleSync()
    }
    private func invalidateRecordQueries() {
        cancelInteractionPreparation()
        recordIndex = nil
        visibleKindCache.removeAll(keepingCapacity: true)
        archivedKindCache.removeAll(keepingCapacity: true)
        actionCache = nil; projectGroupCache = nil; homeCache = nil
        memberCache.removeAll(keepingCapacity: true)
        interactionPrepared = false
        queryGeneration &+= 1
    }
    private var indexedRecords: WorkspaceRecordIndex {
        // Always read observed state, including cache hits, so SwiftUI continues
        // to invalidate a list when a commit replaces its records.
        let records = state.records
        if let recordIndex { return recordIndex }
        let index = WorkspaceRecordIndex(records)
        recordIndex = index
        return index
    }
    func record(_ id: UUID) -> WorkspaceRecord? { indexedRecords.byID[id] }
    func isVisibleRecord(_ id: UUID) -> Bool { indexedRecords.isVisible(id) }
    func records(_ kind: ItemKind, includeArchived: Bool = false) -> [WorkspaceRecord] {
        let index = indexedRecords
        if let cached = includeArchived ? archivedKindCache[kind] : visibleKindCache[kind] { return cached }
        let result = index.records(kind, includeArchived: includeArchived)
        if includeArchived { archivedKindCache[kind] = result } else { visibleKindCache[kind] = result }
        return result
    }
    var actionRecords: [WorkspaceRecord] {
        let index = indexedRecords
        if let actionCache { return actionCache }
        let result = index.actionRecords; actionCache = result
        return result
    }
    var projectGroupRecords: [WorkspaceRecord] {
        let index = indexedRecords
        if let projectGroupCache { return projectGroupCache }
        let result = index.projectGroupRecords; projectGroupCache = result
        return result
    }
    /// Preparation supplies this snapshot before home becomes interactive. Routine
    /// SwiftUI invalidations then reuse the ordering instead of sorting every row.
    var homePresentation: (pending: [WorkspaceRecord], nearest: [WorkspaceRecord]) {
        _ = state.records // Retain Observation tracking even on a cache hit.
        let now = Date()
        if let homeCache, abs(now.timeIntervalSince(homeCache.preparedAt)) < 60 {
            return (homeCache.pending, homeCache.nearest)
        }
        let deadlines = records(.deadline)
        let value = (HomePresentationOrder.pending(actionRecords + deadlines, now: now),
            Array(HomePresentationOrder.nearestDeadlines(deadlines).prefix(3)), now)
        homeCache = value
        return (value.0, value.1)
    }
    func members(of group: WorkspaceRecord) -> [WorkspaceRecord] {
        let index = indexedRecords
        if let cached = memberCache[group.id] { return cached }
        let result = index.members(of: group); memberCache[group.id] = result
        return result
    }
    private func install(_ prepared: PreparedRecordQueries) {
        recordIndex = prepared.index
        actionCache = prepared.actions
        projectGroupCache = prepared.groups
        visibleKindCache[.deadline] = prepared.deadlines
        homeCache = (prepared.homePending, prepared.homeNearest, prepared.preparedAt)
    }
    func cancelInteractionPreparation() {
        interactionPreparation?.task.cancel()
        interactionPreparation = nil
    }
    /// Shared by startup, settings and welcome pages. Sorting runs on a worker;
    /// publish only if the original workspace generation is still current.
    func prepareForInteraction() async {
        guard !Task.isCancelled else { return }
        if interactionPrepared, let homeCache, abs(Date().timeIntervalSince(homeCache.preparedAt)) < 60 { return }
        if let interactionPreparation { await interactionPreparation.task.value; return }
        let generation = queryGeneration
        let records = state.records
        let avatar = state.profile.avatar
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            defer { if self?.interactionPreparation?.id == id { self?.interactionPreparation = nil } }
            guard let self else { return }
            do {
                if self.actionCache == nil || self.projectGroupCache == nil || self.visibleKindCache[.deadline] == nil
                    || self.homeCache == nil || abs(Date().timeIntervalSince(self.homeCache?.preparedAt ?? .distantPast)) >= 60 {
                    let prepared = try await Self.prepareRecordQueries(records)
                    guard !Task.isCancelled, generation == self.queryGeneration else { return }
                    self.install(prepared)
                }
                _ = await AvatarImageCache.shared.image(for: avatar)
                guard !Task.isCancelled, generation == self.queryGeneration else { return }
                self.interactionPrepared = true
            } catch { /* Changed or discarded workspaces leave preparation for a later request. */ }
        }
        interactionPreparation = (id, task)
        await task.value
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
    var canAutomaticallySync: Bool {
        automaticSyncCheckpoint() != nil
    }
    var hasAccountSyncBaseline: Bool {
        guard !isDemoMode, let scope = backend.accountScope else { return false }
        return (try? repository.syncCheckpoint())?.scope == scope
    }
    func accountSessionChanged() {
        #if os(iOS)
        scheduleWidgetSnapshot()
        #endif
        syncTask?.cancel()
        syncTask = nil
        if let review = pendingSyncReview, review.scope != backend.accountScope { cancelSyncReview() }
    }
    /// Signing in authorizes the first merge. A missing or different-account
    /// checkpoint uses a nil base, so local-only and cloud-only records survive.
    func completeAccountSignIn() async throws {
        guard !syncing else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("同步正在进行，请稍后重试。")) }
        guard let scope = backend.accountScope else { throw NativeBackendError.configuration }
        accountSessionChanged()
        if pendingSyncReview?.scope == scope {
            automaticSync = true
            syncStatusKey = "请比较并解决同步冲突"
            return
        }
        if displayedWorkspaceScope?.contains("|workspace:") == true && displayedWorkspaceScope != scope {
            try await selectLinkedWorkspace(id: backend.currentWorkspaceID, role: backend.workspaceAccessRole)
        } else {
            try await synchronize(bindAccount: true)
        }
        if pendingSyncReview == nil { information = WorkspaceLocalization.string("已登录，并合并本机与云端内容。自动同步已开启。") }
    }
    func shouldAutomaticallySync(remoteRevision: Int) -> Bool {
        guard let checkpoint = automaticSyncCheckpoint() else { return false }
        return checkpoint.remote.revision < remoteRevision
    }
    private func automaticSyncCheckpoint() -> WorkspaceSyncCheckpoint? {
        guard !isDemoMode, demoStore == nil, automaticSync, pendingSyncReview == nil, let scope = backend.accountScope else { return nil }
        let checkpoint: WorkspaceSyncCheckpoint?
        do { checkpoint = try repository.syncCheckpoint() }
        catch { return nil }
        return checkpoint?.scope == scope ? checkpoint : nil
    }
    @discardableResult func commit(debounceNotifications: Bool = true, _ update: (inout WorkspaceState) throws -> Void) throws -> Bool {
        guard !isReadOnlyWorkspace else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("当前共享空间为只读，请切换到个人空间或联系共享者修改权限。")) }
        var draft = state
        try update(&draft)
        guard draft != state else { return false }
        try WorkspaceLogic.validate(draft)
        try repository.save(draft)
        state = draft
        notifications.reschedule(draft, debounce: debounceNotifications)
        #if os(iOS)
        liveActivity.synchronize(draft)
        #endif
        scheduleSync()
        return true
    }
    func scheduleSync() {
        guard !syncing, canAutomaticallySync else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.canAutomaticallySync else { return }
            do { try await self.synchronize() }
            catch { self.syncStatusKey = error.localizedDescription }
        }
    }
    /// Joining never merges the invitee's personal data into the owner's space.
    /// Fetch first, and keep a separate durable cache before changing visible data.
    func selectLinkedWorkspace(id: String?, role: String) async throws {
        guard !isDemoMode, demoStore == nil, backend.signedIn else { throw NativeBackendError.configuration }
        guard !syncing else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("同步正在进行，请稍后重试。")) }
        syncTask?.cancel(); syncTask = nil
        let oldID = backend.currentWorkspaceID, oldRole = backend.workspaceAccessRole
        let oldScope = backend.accountScope
        let displayed = displayedWorkspaceScope ?? oldScope
        let checkpoint = try repository.syncCheckpoint()
        if let displayed {
            try repository.cacheWorkspace(scope: displayed, state: state,
                checkpoint: checkpoint?.scope == displayed ? checkpoint : nil)
        }
        backend.selectWorkspace(id: id, role: role)
        guard let scope = backend.accountScope else { throw NativeBackendError.configuration }
        syncing = true
        do {
            let remote = try await backend.downloadForSync(scope: scope)
            guard backend.accountScope == scope else { throw WorkspaceSyncError.accountChanged }
            let cached = try repository.cachedWorkspace(scope: scope)
            // A read-only member always displays the server snapshot exactly.
            let local: WorkspaceState
            if backend.workspaceAccessRole == "viewer" { local = remote.snapshot }
            else if let cached, cached.checkpoint == nil {
                local = try await WorkspaceSyncDriver.reconcileInBackground(base: nil, local: cached.state, remote: remote.snapshot)
            } else { local = cached?.state ?? remote.snapshot }
            try Task.checkCancellation()
            guard backend.accountScope == scope else { throw WorkspaceSyncError.accountChanged }
            let baseline = cached?.checkpoint ?? WorkspaceSyncCheckpoint(scope: scope, remote: remote)
            try repository.save(local, checkpoint: backend.workspaceAccessRole == "viewer" ? WorkspaceSyncCheckpoint(scope: scope, remote: remote) : baseline)
            state = local; displayedWorkspaceScope = scope; workspaceAccessDenied = false
            cancelSyncReview(); openedRecordID = nil; createKind = nil
            notifications.reschedule(local)
            #if os(iOS)
            liveActivity.synchronize(local)
            #endif
            backend.acknowledgeSync(remote)
            syncStatusKey = "已切换工作空间"; syncNeedsRetry = false
            syncing = false
            automaticSync = true
            scheduleSync()
        } catch {
            if backend.accountScope == scope { backend.selectWorkspace(id: oldID, role: oldRole) }
            syncing = false
            throw error
        }
    }
    func synchronize(bindAccount: Bool = false) async throws {
        guard !isDemoMode, demoStore == nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("演示模式不连接云端。")) }
        guard !syncing else { return }
        if (displayedWorkspaceScope?.contains("|workspace:") == true || backend.currentWorkspaceID != nil) && displayedWorkspaceScope != backend.accountScope {
            try await selectLinkedWorkspace(id: backend.currentWorkspaceID, role: backend.workspaceAccessRole)
            return
        }
        guard let scope = backend.accountScope else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请重新登录以确认同步账号。")) }
        if let review = pendingSyncReview, review.scope != scope { cancelSyncReview() }
        guard pendingSyncReview == nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先完成或取消冲突比较。")) }
        let saved = try repository.syncCheckpoint()
        let base = saved?.scope == scope ? saved?.remote.snapshot : nil
        syncing = true; syncStatusKey = "正在合并本机与云端…"; syncNeedsRetry = false
        if bindAccount || saved?.scope != scope { automaticSync = true }
        defer { syncing = false }
        var latestRemote: VersionedWorkspace?
        do {
            try await WorkspaceSyncDriver.run(base: base,
                readLocal: { self.state }, isCurrentAccount: { self.backend.accountScope == scope },
                download: {
                    let remote = try await self.backend.downloadForSync(scope: scope)
                    latestRemote = remote
                    if self.backend.workspaceAccessRole == "viewer" { throw SharingSyncControl.readOnly }
                    return remote
                },
                upload: { snapshot, revision in
                    let remote = try await self.backend.uploadForSync(snapshot, revision: revision, scope: scope)
                    latestRemote = remote
                    return remote
                },
                apply: { current, remote in
                    try self.repository.save(current, checkpoint: WorkspaceSyncCheckpoint(scope: scope, remote: remote))
                    self.displayedWorkspaceScope = scope
                    if self.state != current { self.state = current }
                    self.notifications.reschedule(current)
                    #if os(iOS)
                    self.liveActivity.synchronize(current)
                    #endif
                    self.backend.acknowledgeSync(remote)
                })
            syncStatusKey = "已同步"
            #if os(iOS)
            WorkspaceBackgroundSync.updateSchedule(for: self)
            #endif
        } catch SharingSyncControl.readOnly {
            guard backend.accountScope == scope, let remote = latestRemote else { throw WorkspaceSyncError.accountChanged }
            if state != remote.snapshot {
                try repository.cacheWorkspace(scope: "retained-edits:" + scope, state: state, checkpoint: saved)
            }
            try repository.save(remote.snapshot, checkpoint: WorkspaceSyncCheckpoint(scope: scope, remote: remote))
            state = remote.snapshot; displayedWorkspaceScope = scope
            notifications.reschedule(state)
            #if os(iOS)
            liveActivity.synchronize(state)
            #endif
            backend.acknowledgeSync(remote)
            syncStatusKey = "已同步 · 只读"
        } catch {
            if case NativeBackendError.status(403) = error, backend.currentWorkspaceID != nil {
                workspaceAccessDenied = true
                syncStatusKey = "共享权限已变更，请在关联账户中重新选择空间。"
                syncNeedsRetry = true
                throw error
            }
            guard backend.accountScope == scope else {
                syncStatusKey = "账号已更改，请重新同步。"
                throw WorkspaceSyncError.accountChanged
            }
            // Only a resolvable three-way conflict opens comparison. Transport,
            // authentication and invalid-data errors remain retryable failures.
            if let remote = latestRemote, error is WorkspaceFailure {
                let captured = state
                let requiresReview = try await WorkspaceSyncDriver.requiresReviewInBackground(
                    base: base, local: captured, remote: remote.snapshot)
                try Task.checkCancellation()
                guard backend.accountScope == scope else { throw WorkspaceSyncError.accountChanged }
                // An edit made during the probe must never be shown as if it
                // belonged to the captured comparison. Leave it pending for retry.
                if state == captured, requiresReview {
                    presentSyncReview(remote, scope: scope, base: base)
                    syncStatusKey = "发现同步冲突，请比较后选择。双方内容均已保留。"
                    return
                }
            }
            syncStatusKey = error.localizedDescription
            syncNeedsRetry = true
            throw error
        }
    }
    func reviewSyncConflicts() async throws {
        guard !syncing, let scope = backend.accountScope else { throw NativeBackendError.configuration }
        syncing = true; syncTask?.cancel()
        defer { syncing = false }
        let remote = try await backend.downloadForSync(scope: scope)
        guard backend.accountScope == scope else { throw WorkspaceSyncError.accountChanged }
        let saved = try repository.syncCheckpoint()
        presentSyncReview(remote, scope: scope, base: saved?.scope == scope ? saved?.remote.snapshot : nil)
    }
    private func presentSyncReview(_ remote: VersionedWorkspace, scope: String, base: WorkspaceState?) {
        syncReviewBase = base
        syncReviewLocal = state
        pendingSyncReview = WorkspaceSyncCheckpoint(scope: scope, remote: remote)
        importDescription = WorkspaceLocalization.string("比较本机与服务器的冲突版本")
        pendingImport = remote.snapshot
        syncTask?.cancel()
    }
    func cancelSyncReview() {
        pendingSyncReview = nil; syncReviewBase = nil; syncReviewLocal = nil; pendingImport = nil
    }
    func resolveSyncReview(_ resolution: WorkspaceSyncResolution) throws {
        guard !isReadOnlyWorkspace else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("当前共享空间为只读。")) }
        guard let checkpoint = pendingSyncReview, let local = syncReviewLocal else { throw NativeBackendError.configuration }
        guard backend.accountScope == checkpoint.scope else { throw WorkspaceSyncError.accountChanged }
        guard state == local else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("比较期间本机资料发生变化，请重新打开冲突比较。")) }
        var result = try WorkspaceSyncMerge.reconcile(base: syncReviewBase, local: local, remote: checkpoint.remote.snapshot, resolution: resolution)
        RecurrenceEngine.materialize(&result)
        try WorkspaceLogic.validate(result)
        try repository.save(result, checkpoint: checkpoint)
        if state != result { state = result }
        notifications.reschedule(result)
        #if os(iOS)
        liveActivity.synchronize(result)
        #endif
        pendingSyncReview = nil; syncReviewBase = nil; syncReviewLocal = nil
        pendingImport = nil
        feedbackSequence += 1
        syncStatusKey = "冲突已解决，等待同步"
        scheduleSync()
    }
    private func log(_ record: WorkspaceRecord, _ message: String, in draft: inout WorkspaceState) {
        draft.activities.append(ActivityEntry(entityID: record.id, projectID: record.kind == .project ? record.id : record.projectID,
            title: record.title, message: message))
    }
    func save(_ value: WorkspaceRecord, expectedVersion: Int?, confirmRemaining: Bool = false, recurrenceRule: RecurrenceRule? = nil) throws {
        var value = value
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请填写标题。")) }
        if value.kind == .deadline && value.dueDate == nil { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请选择截止日期。")) }
        if value.kind == .project && value.status == "COMPLETED" && record(value.id)?.status != "COMPLETED" && !confirmRemaining {
            let count = state.records.filter { $0.kind.isItem && $0.projectID == value.id && $0.isLive && !$0.isFinished }.count
            if count > 0 { throw WorkspaceFailure.remainingTasks(count) }
        }
        try commit { draft in
            if let parent = value.projectID, !draft.records.contains(where: { $0.id == parent && $0.kind == .project && $0.isLive }) {
                throw WorkspaceFailure.missingParent
            }
            let index = draft.records.firstIndex { $0.id == value.id }
            let previousKind = index.map { draft.records[$0].kind }
            if let index {
                guard draft.records[index].version == expectedVersion else { throw WorkspaceFailure.conflict }
                guard draft.records[index].archivedAt == nil && draft.records[index].deletedAt == nil else {
                    throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先恢复归档或回收站中的记录。"))
                }
                if draft.records[index].dueDate != value.dueDate || draft.records[index].remindAt != value.remindAt ||
                    draft.records[index].scheduledAt != value.scheduledAt || draft.records[index].dateOnly != value.dateOnly {
                    value.snoozedUntil = nil
                }
                value.version = draft.records[index].version + 1; value.createdAt = draft.records[index].createdAt
                if value.recurrenceSeriesID != nil { value.isException = true }
                value.updatedAt = Date()
                if value.kind == .knowledge {
                    draft.revisions.append(KnowledgeRevision(record: draft.records[index], action: "修改前"))
                }
                draft.records[index] = value
            } else {
                guard expectedVersion == nil else { throw WorkspaceFailure.conflict }
                if value.recurrenceSeriesID != nil {
                    _ = try projectedOccurrence(value, in: draft)
                    // Viewing a far-away date is free; only an actual edit or
                    // completion makes that instance a persistent exception.
                    value.isException = true
                }
                value.version = 1; value.createdAt = Date(); value.updatedAt = value.createdAt
                draft.records.append(value)
            }
            if let index = draft.records.firstIndex(where: { $0.id == value.id }) {
                if ["DONE", "COMPLETED"].contains(value.status) { draft.records[index].completedAt = value.completedAt ?? Date() }
                else { draft.records[index].completedAt = nil }
                draft.records[index].cancelledAt = value.status == "CANCELLED" ? value.cancelledAt ?? Date() : nil
            }
            let action = index == nil ? "创建" : previousKind != value.kind ? "转为" : "修改"
            log(value, action + value.kind.title, in: &draft)
            if let recurrenceRule {
                try RecurrenceEngine.start(value.id, rule: recurrenceRule, in: &draft)
                log(value, "设置重复：\(recurrenceRule.label)", in: &draft)
            }
        }
        feedbackSequence += 1
    }
    func toggleKeyItem(_ id: UUID) throws {
        guard var value = record(id), WorkspaceLogic.visible(value, in: state) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先恢复此记录或所属项目组的归档状态。"))
        }
        value.pinned.toggle()
        try save(value, expectedVersion: value.version)
    }
    @discardableResult
    func moveRecords(_ ids: Set<UUID>, to groupID: UUID?) throws -> Bool {
        let changed = try commit { draft in
            let previous = Dictionary(draft.records.filter { ids.contains($0.id) }.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            guard try WorkspaceLogic.regroup(ids, to: groupID, in: &draft) else { return }
            let destination = groupID.flatMap { id in draft.records.first { $0.id == id } }
            let message = destination.map { "移至项目组：\($0.title)" } ?? "移出项目组"
            for record in draft.records where ids.contains(record.id) && previous[record.id] != record {
                log(record, message, in: &draft)
            }
        }
        if changed { feedbackSequence += 1 }
        return changed
    }
    func setStatus(_ id: UUID, _ status: String) throws {
        guard var value = record(id) else { return }
        guard WorkspaceLogic.visible(value, in: state) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先恢复此记录或所属项目组的归档状态。"))
        }
        value.status = status
        try save(value, expectedVersion: value.version)
    }
    func archive(_ id: UUID, restore: Bool = false) throws {
        try commit { draft in
            guard let index = draft.records.firstIndex(where: { $0.id == id }) else { return }
            draft.records[index].archivedAt = restore ? nil : Date()
            draft.records[index].version += 1; draft.records[index].updatedAt = Date()
            log(draft.records[index], restore ? "恢复归档" : "归档", in: &draft)
        }
        feedbackSequence += 1
    }
    func deletionPreview(_ id: UUID, scope: RecurrenceDeletionScope = .occurrence) throws -> DeletionPreview {
        try deletionPreview([id], scope: scope)
    }
    func deletionPreview(_ ids: Set<UUID>, scope: RecurrenceDeletionScope = .occurrence,
                         projectedRecords: [WorkspaceRecord] = []) throws -> DeletionPreview {
        var draft = state
        var projected: [WorkspaceRecord] = []
        for record in projectedRecords where !draft.records.contains(where: { $0.id == record.id }) {
            let expected = try projectedOccurrence(record, in: draft)
            guard expected == record else { throw WorkspaceFailure.stalePreview }
            draft.records.append(expected); projected.append(expected)
        }
        var preview = try WorkspaceLogic.preview(ids, scope: scope, in: draft)
        preview.projectedRecords = projected
        return preview
    }
    func deletionPreview(_ projected: WorkspaceRecord, scope: RecurrenceDeletionScope = .occurrence) throws -> DeletionPreview {
        try deletionPreview([projected.id], scope: scope, projectedRecords: [projected])
    }
    private func projectedOccurrence(_ record: WorkspaceRecord, in state: WorkspaceState) throws -> WorkspaceRecord {
        guard let key = record.occurrenceDate, let seriesID = record.recurrenceSeriesID,
              let series = state.series.first(where: { $0.id == seriesID && $0.stoppedAt == nil && $0.deletedAt == nil }) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("重复规则已经改变，请返回日历重新选择。"))
        }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = series.template.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              WorkspaceDates.dayKey(day, timezone: series.template.timezone) == key,
              let expected = RecurrenceEngine.projectedRecords(in: state, from: day, through: day)
                .first(where: { $0.id == record.id && $0.recurrenceSeriesID == seriesID && $0.occurrenceDate == key }),
              expected.isLive else { throw WorkspaceFailure.stalePreview }
        return expected
    }
    func delete(_ preview: DeletionPreview) throws {
        try commit { draft in
            for record in preview.projectedRecords where !draft.records.contains(where: { $0.id == record.id }) {
                guard try projectedOccurrence(record, in: draft) == record else { throw WorkspaceFailure.stalePreview }
                draft.records.append(record)
            }
            if preview.root.kind == .knowledge { draft.revisions.append(KnowledgeRevision(record: preview.root, action: "移入回收站前")) }
            try WorkspaceLogic.delete(preview, from: &draft)
            log(preview.root, "移入回收站（\(preview.records.count) 项）" +
                (preview.affectedSeries.isEmpty ? "" : " · \(preview.recurrenceScope.title)"), in: &draft)
        }
        feedbackSequence += 1
    }
    func restore(_ batch: TrashBatch) throws {
        try commit { draft in
            try WorkspaceLogic.restore(batch, in: &draft)
            if let root = draft.records.first(where: { $0.id == batch.rootID }) { log(root, "从回收站恢复", in: &draft) }
        }
        feedbackSequence += 1
    }
    func createRecurrence(_ id: UUID, rule: RecurrenceRule) throws {
        try commit { draft in
            try RecurrenceEngine.start(id, rule: rule, in: &draft)
            if let record = draft.records.first(where: { $0.id == id }) { log(record, "设置重复：\(rule.label)", in: &draft) }
        }
        feedbackSequence += 1
    }
    func stopRecurrence(_ seriesID: UUID) throws {
        try commit { draft in
            let changed = RecurrenceEngine.stop(seriesID, in: &draft)
            for id in changed {
                if let record = draft.records.first(where: { $0.id == id }) { log(record, "停止后续重复", in: &draft) }
            }
        }
        feedbackSequence += 1
    }
    func restoreRevision(_ revision: KnowledgeRevision) throws {
        guard var current = record(revision.record.id) else { return }
        current.title = revision.record.title; current.body = revision.record.body
        current.summary = revision.record.summary; current.category = revision.record.category
        current.tags = revision.record.tags; current.pinned = revision.record.pinned
        try save(current, expectedVersion: current.version)
    }
    func attachPDF(_ url: URL, to id: UUID) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 10 * 1024 * 1024, PDFDocument(data: bytes) != nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请选择有效的 PDF 文件。")) }
        try commit { draft in
            guard draft.records.contains(where: { $0.id == id && $0.kind == .knowledge && $0.deletedAt == nil }) else { throw WorkspaceFailure.missingParent }
            draft.assets.append(WorkspaceAsset(ownerID: id, name: url.lastPathComponent, data: bytes))
        }
        feedbackSequence += 1
    }
    func importState(_ incoming: WorkspaceState, preferIncoming: Bool) throws {
        try WorkspaceLogic.validate(incoming)
        try commit { draft in
            var records = Dictionary(uniqueKeysWithValues: draft.records.map { ($0.id, $0) })
            for record in incoming.records where records[record.id] == nil || preferIncoming { records[record.id] = record }
            draft.records = Array(records.values)
            func merge<T: Identifiable>(_ old: [T], _ new: [T]) -> [T] where T.ID == UUID {
                var map = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
                for value in new where map[value.id] == nil || preferIncoming { map[value.id] = value }
                return Array(map.values)
            }
            draft.assets = merge(draft.assets, incoming.assets)
            draft.series = merge(draft.series, incoming.series)
            draft.revisions = merge(draft.revisions, incoming.revisions)
            draft.activities = merge(draft.activities, incoming.activities)
            draft.trash = merge(draft.trash, incoming.trash)
            if preferIncoming { draft.profile = incoming.profile }
            // A batch restored on either device must not retain an unrelated stale batch.
            draft.trash = draft.trash.filter { batch in draft.records.contains { $0.trashBatchID == batch.id } }
            WorkspaceLogic.reconcileRecurrenceDeletions(in: &draft)
            RecurrenceEngine.materialize(&draft)
        }
    }
    func refresh() {
        #if os(iOS)
        defer { scheduleWidgetSnapshot() }
        #endif
        perform {
            let changed: Bool
            if isReadOnlyWorkspace { changed = false }
            else { changed = try commit(debounceNotifications: false) { RecurrenceEngine.materialize(&$0) } }
            if !changed {
                // System permissions and wall-clock eligibility can change even
                // when the saved records do not. Keep those refreshes explicit.
                notifications.reschedule(state)
                #if os(iOS)
                liveActivity.synchronize(state)
                #endif
            }
        }
        if RemotePushBridge.isEnabled && backend.signedIn {
            do { try RemotePushBridge.registerWithApple() } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Foreground maintenance uses a value snapshot so recurrence expansion does
    /// not occupy the UI actor. Never overwrite an edit made while it was running.
    func refreshForInteraction() async {
        let generation = queryGeneration
        let baseline = state
        let readOnly = isReadOnlyWorkspace
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var result = baseline
            if !readOnly { RecurrenceEngine.materialize(&result) }
            if result != baseline { try WorkspaceLogic.validate(result) }
            try Task.checkCancellation()
            return result
        }
        do {
            let refreshed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, generation == queryGeneration, readOnly == isReadOnlyWorkspace else { return }
            if refreshed != state {
                try repository.save(refreshed)
                state = refreshed
                scheduleSync()
            }
            notifications.reschedule(state)
            #if os(iOS)
            liveActivity.synchronize(state)
            scheduleWidgetSnapshot()
            #endif
            if RemotePushBridge.isEnabled && backend.signedIn {
                try RemotePushBridge.registerWithApple()
            }
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}

#if DEBUG
extension WorkspaceStore {
    /// Opt-in, in-memory regression for the home snapshot used by launch. It
    /// exercises visibility and cache invalidation without touching user data.
    static func verifyStartupHomePreparation() async throws {
        let group = WorkspaceRecord(kind: .project, title: "Home cache fixture")
        var child = WorkspaceRecord(kind: .task, title: "Visible child")
        child.projectID = group.id
        let other = WorkspaceRecord(kind: .task, title: "Independent item")
        let initial = WorkspaceState(records: [group, child, other])
        let repository = try SwiftDataRepository(inMemory: true)
        try repository.save(initial)
        let prepared = try await prepareRecordQueries(initial.records)
        let fixture = try WorkspaceStore(repository: repository, isDemoMode: true, preparedQueries: prepared)
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw WorkspaceFailure.invalid(message) }
        }
        try check(Set(fixture.homePresentation.pending.map(\.id)) == [child.id, other.id], "Home preload lost visible items")
        var hidden = initial
        hidden.records[0].deletedAt = Date()
        fixture.state = hidden
        try check(fixture.homePresentation.pending.map(\.id) == [other.id], "Home retained a hidden parent's child")
        fixture.state = initial
        await fixture.prepareForInteraction()
        try check(Set(fixture.homePresentation.pending.map(\.id)) == [child.id, other.id], "Home restore reused a stale snapshot")
    }

    /// Runs only in the explicit, isolated recurrence simulator smoke launch.
    func verifyProjectedOccurrenceActions() throws {
        let repository = try SwiftDataRepository(inMemory: true)
        let test = try WorkspaceStore(repository: repository, isDemoMode: true)
        let now = Date(), calendar = WorkspaceDates.calendar()
        var item = WorkspaceRecord(kind: .task, title: "仅用于重复日程验证")
        item.scheduledAt = now
        try test.save(item, expectedVersion: nil, recurrenceRule: RecurrenceRule(frequency: .daily))
        let original = test.state
        let farDay = calendar.date(byAdding: .day, value: 90, to: now)!
        func occurrence(on day: Date) throws -> WorkspaceRecord {
            guard let record = RecurrenceEngine.projectedRecords(in: test.state, from: day, through: day)
                .first(where: { $0.occurrenceDate == WorkspaceDates.dayKey(day, timezone: item.timezone) }) else {
                throw WorkspaceFailure.invalid("Missing projected occurrence")
            }
            return record
        }
        let virtual = try occurrence(on: farDay)
        let preview = try test.deletionPreview(virtual)
        let whole = try test.deletionPreview([virtual.id], scope: .series, projectedRecords: preview.projectedRecords)
        guard test.state == original, whole.records.count == original.records.count + 1,
              Set(try repository.load().records) == Set(original.records) else {
            throw WorkspaceFailure.invalid("Preview unexpectedly changed storage")
        }
        try test.delete(preview)
        guard test.record(virtual.id)?.deletedAt != nil,
              test.state.series[0].rule == original.series[0].rule else {
            throw WorkspaceFailure.invalid("Projected single deletion changed the rule")
        }
        try test.restore(test.state.trash[0])
        var edited = try occurrence(on: calendar.date(byAdding: .day, value: 91, to: now)!)
        edited.title = "只修改这一次"
        try test.save(edited, expectedVersion: nil)
        guard test.record(edited.id)?.isException == true, test.record(edited.id)?.title == edited.title,
              Set(try repository.load().records) == Set(test.state.records) else {
            throw WorkspaceFailure.invalid("Projected edit did not persist")
        }
        var completed = try occurrence(on: calendar.date(byAdding: .day, value: 92, to: now)!)
        completed.status = "DONE"
        try test.save(completed, expectedVersion: nil)
        guard test.record(completed.id)?.completedAt != nil else {
            throw WorkspaceFailure.invalid("Projected completion did not persist")
        }
        var stopped = try occurrence(on: calendar.date(byAdding: .day, value: 93, to: now)!)
        try test.stopRecurrence(test.state.series[0].id)
        let before = test.state
        stopped.status = "DONE"
        do {
            try test.save(stopped, expectedVersion: nil)
            throw WorkspaceFailure.invalid("Stopped series was revived")
        } catch {
            guard test.state == before else { throw error }
        }
    }
    /// Only invoked by the dedicated in-memory simulator smoke launch.
    func verifyDemoIsolation() async throws {
        let original = state
        let persisted = try repository.load()
        let checkpoint = try repository.syncCheckpoint()
        let syncPreference = UserDefaults.standard.object(forKey: "automaticWorkspaceSync") as? Bool
        let notificationPreference = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool
        let credentials = SecureCredentials.read("session")
        guard let demo = demoStore else { throw WorkspaceFailure.invalid("Missing demo store") }
        precondition(demo !== self && demo.isDemoMode && !demo.backend.signedIn)
        precondition(!demo.canAutomaticallySync && demo.backend.accountScope == nil)
        let test = WorkspaceRecord(kind: .task, title: "隔离验证：只存在于演示")
        try demo.save(test, expectedVersion: nil)
        try demo.setStatus(test.id, "DONE")
        try demo.archive(test.id)
        try demo.archive(test.id, restore: true)
        let deletion = try demo.deletionPreview(test.id)
        try demo.delete(deletion)
        try demo.restore(demo.state.trash.first { $0.rootID == test.id }!)
        try demo.commit { $0.profile.name = "演示修改" }
        demo.automaticSync = true
        try await demo.notifications.requestAuthorization()
        try await demo.notifications.sendTest()
        try await demo.backend.signOut()
        do { try await demo.synchronize(); preconditionFailure("Demo synchronized") }
        catch { /* Expected: offline sandbox. */ }
        do { try await demo.backend.signIn(email: "demo@example.com", password: "demo-only"); preconditionFailure("Demo signed in") }
        catch { /* Expected: transport blocked before credential lookup. */ }
        let afterEdits = try repository.load()
        let checkpointAfter = try repository.syncCheckpoint()
        precondition(state == original && afterEdits == persisted)
        let checkpointBeforeBytes = try JSONEncoder().encode(checkpoint)
        let checkpointAfterBytes = try JSONEncoder().encode(checkpointAfter)
        precondition(checkpointBeforeBytes == checkpointAfterBytes)
        precondition(UserDefaults.standard.object(forKey: "automaticWorkspaceSync") as? Bool == syncPreference)
        precondition(UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool == notificationPreference)
        precondition(SecureCredentials.read("session") == credentials)
        try demo.resetDemo()
        precondition(demo.record(test.id) == nil)
        demo.endDemo()
        precondition(demoStore == nil && activeStore === self && state == original)
        // Simulate an editor/photo/import task completing after exit.
        try demo.save(test, expectedVersion: nil)
        let afterLateEdit = try repository.load()
        precondition(record(test.id) == nil && afterLateEdit == persisted)
        try beginDemo()
        precondition(demoStore !== demo && demoStore?.record(test.id) == nil)
        demo.endDemo() // A stale demo cannot close a newer session.
        precondition(demoStore != nil)
    }
}
#endif
