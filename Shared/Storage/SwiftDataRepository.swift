import Foundation
import SwiftData

@Model final class StoredRecord {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}
@Model final class StoredAsset {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var name: String
    var createdAt: Date
    @Attribute(.externalStorage) var bytes: Data
    init(_ asset: WorkspaceAsset) {
        id = asset.id; ownerID = asset.ownerID; name = asset.name; createdAt = asset.createdAt; bytes = asset.data
    }
}
@Model final class StoredMetadata {
    @Attribute(.unique) var key: String
    var payload: Data
    init(payload: Data, key: String = "workspace") { self.key = key; self.payload = payload }
}
@MainActor protocol WorkspaceRepository {
    func load() throws -> WorkspaceState
    func save(_ state: WorkspaceState) throws
}

@MainActor final class SwiftDataRepository: WorkspaceRepository {
    /// Only the framework's thread-safe container and immutable value snapshots
    /// cross executors. The worker's ModelContext and fetched models stay there.
    struct PreparedStartup: @unchecked Sendable {
        let container: ModelContainer
        let state: WorkspaceState
        let checkpoint: WorkspaceSyncCheckpoint?
    }

    let container: ModelContainer
    private var initialSnapshot: WorkspaceState?
    private var lastPersistedState: WorkspaceState?
    private var cachedCheckpoint: WorkspaceSyncCheckpoint?
    private var checkpointLoaded = false
    init(inMemory: Bool = false) throws {
        container = try Self.makeContainer(inMemory: inMemory)
    }
    init(preparedStartup: PreparedStartup) {
        container = preparedStartup.container
        initialSnapshot = preparedStartup.state
        lastPersistedState = preparedStartup.state
        cachedCheckpoint = preparedStartup.checkpoint
        checkpointLoaded = true
    }
    nonisolated static func prepareStartup(inMemory: Bool = false) async throws -> PreparedStartup {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let container = try makeContainer(inMemory: inMemory)
            return try readPreparedStartup(container: container)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
    /// Reuses an isolated test container without moving its contexts or models.
    nonisolated static func prepareStartup(container: ModelContainer) async throws -> PreparedStartup {
        let worker = Task.detached(priority: .userInitiated) {
            try readPreparedStartup(container: container)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
    nonisolated private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([StoredRecord.self, StoredAsset.self, StoredMetadata.self])
        let configuration = ModelConfiguration("WorkSpace", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
    nonisolated private static func readPreparedStartup(container: ModelContainer) throws -> PreparedStartup {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let state = try readState(in: context)
        try Task.checkCancellation()
        let checkpoint = try readCheckpoint(in: context)
        try Task.checkCancellation()
        return PreparedStartup(container: container, state: state, checkpoint: checkpoint)
    }
    nonisolated private static func readState(in context: ModelContext) throws -> WorkspaceState {
        let metadata = try fetchMetadataRow("workspace", in: context)
        let decoder = JSONDecoder()
        var state = try metadata.map { try decoder.decode(WorkspaceState.self, from: $0.payload) } ?? WorkspaceState()
        state.records = try context.fetch(FetchDescriptor<StoredRecord>()).map { try decoder.decode(WorkspaceRecord.self, from: $0.payload) }
        state.assets = try context.fetch(FetchDescriptor<StoredAsset>()).map {
            WorkspaceAsset(id: $0.id, ownerID: $0.ownerID, name: $0.name, data: $0.bytes, createdAt: $0.createdAt)
        }
        try WorkspaceLogic.validate(state)
        return state
    }
    nonisolated private static func readCheckpoint(in context: ModelContext) throws -> WorkspaceSyncCheckpoint? {
        try fetchMetadataRow("sync-checkpoint", in: context).map {
            try JSONDecoder().decode(WorkspaceSyncCheckpoint.self, from: $0.payload)
        }
    }
    func load() throws -> WorkspaceState {
        if let initialSnapshot {
            self.initialSnapshot = nil
            lastPersistedState = initialSnapshot
            return initialSnapshot
        }
        let context = ModelContext(container)
        let state = try Self.readState(in: context)
        lastPersistedState = state
        // load() is also the explicit disk reload path. Do not retain a baseline
        // that might predate data fetched by that reload.
        checkpointLoaded = false; cachedCheckpoint = nil
        return state
    }
    func save(_ state: WorkspaceState) throws { try save(state, checkpoint: nil) }
    func syncCheckpoint() throws -> WorkspaceSyncCheckpoint? {
        if checkpointLoaded { return cachedCheckpoint }
        let context = ModelContext(container)
        let checkpoint = try Self.readCheckpoint(in: context)
        cachedCheckpoint = checkpoint; checkpointLoaded = true
        return checkpoint
    }
    func save(_ state: WorkspaceState, checkpoint: WorkspaceSyncCheckpoint?) throws {
        guard state != lastPersistedState || checkpoint != nil else { return }
        // A write before the first load supersedes the prepared snapshot. Failed
        // writes must also retry from disk rather than revive an old preload.
        initialSnapshot = nil
        // A fresh context keeps failed edits out of the observable working state.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            if state.records != lastPersistedState?.records {
                let existing = try context.fetch(FetchDescriptor<StoredRecord>())
                let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                let previous = Dictionary(uniqueKeysWithValues: (lastPersistedState?.records ?? []).map { ($0.id, $0) })
                let liveIDs = Set(state.records.map(\.id))
                for record in state.records where previous[record.id] != record {
                    let payload = try encoder.encode(record)
                    if let stored = byID[record.id] {
                        if stored.payload != payload { stored.payload = payload }
                    } else { context.insert(StoredRecord(id: record.id, payload: payload)) }
                }
                for removed in existing where !liveIDs.contains(removed.id) { context.delete(removed) }
            }
            if state.assets != lastPersistedState?.assets {
                let assets = try context.fetch(FetchDescriptor<StoredAsset>())
                let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
                let previous = Dictionary(uniqueKeysWithValues: (lastPersistedState?.assets ?? []).map { ($0.id, $0) })
                let assetIDs = Set(state.assets.map(\.id))
                for asset in state.assets where previous[asset.id] != asset {
                    if let stored = assetByID[asset.id] {
                        stored.name = asset.name; stored.ownerID = asset.ownerID; stored.createdAt = asset.createdAt
                        if stored.bytes != asset.data { stored.bytes = asset.data }
                    } else { context.insert(StoredAsset(asset)) }
                }
                for removed in assets where !assetIDs.contains(removed.id) { context.delete(removed) }
            }
            func metadataOnly(_ source: WorkspaceState) -> WorkspaceState {
                var metadata = source
                metadata.records = []; metadata.assets = []
                return metadata
            }
            let metadataState = metadataOnly(state)
            if metadataState != lastPersistedState.map(metadataOnly) {
                let payload = try encoder.encode(metadataState)
                if let metadata = try metadataRow("workspace", in: context) { metadata.payload = payload }
                else { context.insert(StoredMetadata(payload: payload)) }
            }
            if let checkpoint {
                let encoded = try encoder.encode(checkpoint)
                if let row = try metadataRow("sync-checkpoint", in: context) { row.payload = encoded }
                else { context.insert(StoredMetadata(payload: encoded, key: "sync-checkpoint")) }
            }
            try context.save()
        } catch {
            // Publish neither state nor checkpoint until the one transaction
            // succeeds. Retry from disk if the persistence layer rejects a write.
            lastPersistedState = nil; cachedCheckpoint = nil; checkpointLoaded = false
            throw error
        }
        lastPersistedState = state
        if let checkpoint { cachedCheckpoint = checkpoint; checkpointLoaded = true }
    }
    struct CachedWorkspace: Codable {
        var state: WorkspaceState
        var checkpoint: WorkspaceSyncCheckpoint?
    }
    /// Separate caches prevent another person's records from becoming the local
    /// input to a personal-workspace merge. They also retain offline edits.
    func cacheWorkspace(scope: String, state: WorkspaceState, checkpoint: WorkspaceSyncCheckpoint?) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let key = "workspace-cache:" + scope
        let bytes = try JSONEncoder().encode(CachedWorkspace(state: state, checkpoint: checkpoint))
        if let row = try metadataRow(key, in: context) { row.payload = bytes }
        else { context.insert(StoredMetadata(payload: bytes, key: key)) }
        try context.save()
    }
    func cachedWorkspace(scope: String) throws -> CachedWorkspace? {
        let context = ModelContext(container)
        return try metadataRow("workspace-cache:" + scope, in: context).map {
            try JSONDecoder().decode(CachedWorkspace.self, from: $0.payload)
        }
    }
    /// Supplemental libraries use independent, account-scoped rows rather than
    /// changing the legacy workspace archive or its three-way merge protocol.
    func loadSupplement<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try loadSupplementData(key: key).map { try WorkspaceCoding.decoder().decode(type, from: $0) }
    }
    /// Return value bytes only; large libraries can decode outside the main actor
    /// without moving a SwiftData context or model across actor boundaries.
    func loadSupplementData(key: String) throws -> Data? {
        let context = ModelContext(container)
        return try metadataRow(key, in: context)?.payload
    }
    func saveSupplement<T: Encodable>(_ value: T, key: String) throws {
        try saveSupplements([key: WorkspaceCoding.encoder().encode(value)])
    }
    /// A progress change and its retry queue must either both reach disk or neither.
    func saveSupplements(_ payloads: [String: Data]) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for (key, payload) in payloads {
            if let row = try metadataRow(key, in: context) { row.payload = payload }
            else { context.insert(StoredMetadata(payload: payload, key: key)) }
        }
        try context.save()
    }
    private func metadataRow(_ key: String, in context: ModelContext) throws -> StoredMetadata? {
        try Self.fetchMetadataRow(key, in: context)
    }
    nonisolated private static func fetchMetadataRow(_ key: String, in context: ModelContext) throws -> StoredMetadata? {
        var request = FetchDescriptor<StoredMetadata>(predicate: #Predicate { $0.key == key })
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}
