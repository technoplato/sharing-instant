import Foundation
import InstantDB

// MARK: - GC Configuration

/// Configuration for TripleStore garbage collection.
public struct TripleStoreGCConfig: Sendable {
    public let maxTriples: Int
    public let maxAgeSeconds: TimeInterval
    public let maxEntities: Int
    public let gcIntervalSeconds: TimeInterval

    public static let `default` = TripleStoreGCConfig(
        maxTriples: 100_000,
        maxAgeSeconds: 60 * 60 * 24,
        maxEntities: 10_000,
        gcIntervalSeconds: 60
    )

    public static let aggressive = TripleStoreGCConfig(
        maxTriples: 10_000,
        maxAgeSeconds: 60 * 60,
        maxEntities: 1_000,
        gcIntervalSeconds: 30
    )

    public static let disabled = TripleStoreGCConfig(
        maxTriples: Int.max,
        maxAgeSeconds: TimeInterval.infinity,
        maxEntities: Int.max,
        gcIntervalSeconds: TimeInterval.infinity
    )

    public init(maxTriples: Int, maxAgeSeconds: TimeInterval, maxEntities: Int, gcIntervalSeconds: TimeInterval) {
        self.maxTriples = maxTriples
        self.maxAgeSeconds = maxAgeSeconds
        self.maxEntities = maxEntities
        self.gcIntervalSeconds = gcIntervalSeconds
    }
}

// MARK: - Entity Access Record

public struct EntityAccessRecord: Sendable {
    public let entityId: String
    public var lastAccessedAt: TimeInterval
    public var tripleCount: Int

    public init(entityId: String, lastAccessedAt: TimeInterval, tripleCount: Int) {
        self.entityId = entityId
        self.lastAccessedAt = lastAccessedAt
        self.tripleCount = tripleCount
    }
}

// MARK: - GC Result

public struct GCResult: Sendable, Equatable {
    public var orphanedRecordsRemoved: Int = 0
    public var agedOutEntities: Int = 0
    public var lruEvictedEntities: Int = 0
    public var sizeEvictedEntities: Int = 0
    public var totalEvicted: Int { agedOutEntities + lruEvictedEntities + sizeEvictedEntities }
    public init() {}
}

// MARK: - GC Diagnostics

public struct GCDiagnostics: Sendable {
    public let isRunning: Bool
    public let trackedEntities: Int
    public let estimatedTriples: Int
    public let sacredEntities: Int
    public let config: TripleStoreGCConfig
}

// MARK: - TripleStore GC

public actor TripleStoreGC {
    private let store: SharedTripleStore
    private let config: TripleStoreGCConfig
    private var entityAccess: [String: EntityAccessRecord] = [:]
    private var sacredEntities: Set<String> = []
    private var gcTask: Task<Void, Never>?
    private var isRunning: Bool = false
    private var sacredEntityRefreshCallback: (@Sendable () async -> Set<String>)?

    public init(store: SharedTripleStore, config: TripleStoreGCConfig = .default) {
        self.store = store
        self.config = config
    }

    public func setSacredEntityRefreshCallback(_ callback: @escaping @Sendable () async -> Set<String>) {
        sacredEntityRefreshCallback = callback
    }

    public func start() {
        guard gcTask == nil else { return }
        guard config.gcIntervalSeconds != .infinity else { return }
        isRunning = true
        gcTask = Task { [weak self] in
            while !Task.isCancelled {
                let intervalNs = UInt64((self?.config.gcIntervalSeconds ?? 60) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { break }
                _ = await self?.runGC()
            }
        }
    }

    public func stop() {
        gcTask?.cancel()
        gcTask = nil
        isRunning = false
    }

    public var isActive: Bool { isRunning && gcTask != nil && !gcTask!.isCancelled }

    public func markSacred(_ entityIds: Set<String>) { sacredEntities.formUnion(entityIds) }
    public func unmarkSacred(_ entityIds: Set<String>) { sacredEntities.subtract(entityIds) }
    public var currentSacredEntities: Set<String> { sacredEntities }

    public func recordAccess(entityId: String, tripleCount: Int = 1) {
        let now = Date().timeIntervalSince1970
        if var record = entityAccess[entityId] {
            record.lastAccessedAt = now
            if tripleCount > 0 { record.tripleCount = tripleCount }
            entityAccess[entityId] = record
        } else {
            entityAccess[entityId] = EntityAccessRecord(entityId: entityId, lastAccessedAt: now, tripleCount: tripleCount)
        }
    }

    public func recordAccess(entityIds: Set<String>) {
        let now = Date().timeIntervalSince1970
        for entityId in entityIds {
            if var record = entityAccess[entityId] {
                record.lastAccessedAt = now
                entityAccess[entityId] = record
            } else {
                entityAccess[entityId] = EntityAccessRecord(entityId: entityId, lastAccessedAt: now, tripleCount: 1)
            }
        }
    }

    public var trackedEntityCount: Int { entityAccess.count }
    public var estimatedTripleCount: Int { entityAccess.values.reduce(0) { $0 + $1.tripleCount } }

    @discardableResult
    public func runGC() async -> GCResult {
        if let callback = sacredEntityRefreshCallback {
            sacredEntities = await callback()
        }

        var result = GCResult()
        let now = Date().timeIntervalSince1970
        let storeEntityIds = store.getAllEntityIds()

        // Phase 1: Remove orphaned records
        for entityId in entityAccess.keys where !storeEntityIds.contains(entityId) {
            entityAccess.removeValue(forKey: entityId)
            result.orphanedRecordsRemoved += 1
        }

        // Phase 2: Age-based eviction
        for (entityId, record) in entityAccess where !sacredEntities.contains(entityId) {
            if record.lastAccessedAt < now - config.maxAgeSeconds {
                store.deleteEntity(id: entityId)
                entityAccess.removeValue(forKey: entityId)
                result.agedOutEntities += 1
            }
        }

        // Phase 3: Entity count limit
        if entityAccess.count > config.maxEntities {
            let sortedByAccess = entityAccess.values
                .filter { !sacredEntities.contains($0.entityId) }
                .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            let toRemoveCount = entityAccess.count - config.maxEntities
            for record in sortedByAccess.prefix(toRemoveCount) {
                store.deleteEntity(id: record.entityId)
                entityAccess.removeValue(forKey: record.entityId)
                result.lruEvictedEntities += 1
            }
        }

        // Phase 4: Triple count limit
        var totalTriples = entityAccess.values.reduce(0) { $0 + $1.tripleCount }
        if totalTriples > config.maxTriples {
            var sortedByAccess = entityAccess.values
                .filter { !sacredEntities.contains($0.entityId) }
                .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            while totalTriples > config.maxTriples && !sortedByAccess.isEmpty {
                let record = sortedByAccess.removeFirst()
                store.deleteEntity(id: record.entityId)
                entityAccess.removeValue(forKey: record.entityId)
                totalTriples -= record.tripleCount
                result.sizeEvictedEntities += 1
            }
        }

        return result
    }

    public func diagnostics() -> GCDiagnostics {
        GCDiagnostics(isRunning: isActive, trackedEntities: entityAccess.count, estimatedTriples: estimatedTripleCount, sacredEntities: sacredEntities.count, config: config)
    }
}
