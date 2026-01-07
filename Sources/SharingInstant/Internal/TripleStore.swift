import Foundation
import InstantDB

/// Adapted from: instant-client/src/instant/store.ts
///
/// A wrapper around InstantDB.TripleStore that adds Observation capabilities.
public final class SharedTripleStore: @unchecked Sendable {
    // Backing SDK Store
    public let inner: InstantDB.TripleStore = InstantDB.TripleStore()
    public let attrsStore: AttrsStore = AttrsStore()
    
    // Observers [EntityID: [Token: Callback]]
    private var observers: [String: [UUID: @Sendable () -> Void]] = [:]
    private let lock = NSRecursiveLock()

    public init() {}
    
    // MARK: - Primitives
    
    public func updateAttributes(_ attributes: [Attribute]) {
        for attr in attributes {
            attrsStore.addAttr(attr)
        }
    }
    
    public func addTriple(_ triple: Triple, hasCardinalityOne: Bool, isRef: Bool) {
        inner.addTriple(triple, hasCardinalityOne: hasCardinalityOne, isRef: isRef)
        var changedIDs: Set<String> = [triple.entityId]
        // For ref triples, also notify the target entity so reverse link views update.
        if isRef, case .ref(let targetId) = triple.value {
            changedIDs.insert(targetId)
        }
        notifyObservers(for: changedIDs)
    }
    
    public func addTriples(_ triples: [Triple]) {
        var changedIDs: Set<String> = []
        for triple in triples {
            let attr = attrsStore.getAttr(triple.attributeId)
            let hasCardinalityOne = attr?.cardinality == .one
            let isRef = attr?.valueType == .ref
            inner.addTriple(triple, hasCardinalityOne: hasCardinalityOne, isRef: isRef)
            changedIDs.insert(triple.entityId)

            // For ref triples, also notify the target entity so reverse link views update.
            // When a ref triple [subject, refAttr, target] is added, the target entity's
            // "resolved view" changes (it now has an inbound link from subject).
            // Without this, subscriptions driven by reverse links (e.g., media.transcriptionRuns)
            // won't see new links until a server refresh.
            if isRef, case .ref(let targetId) = triple.value {
                changedIDs.insert(targetId)
            }
        }
        notifyObservers(for: changedIDs)
    }
    
    public func retractTriple(_ triple: Triple, isRef: Bool) {
        inner.retractTriple(triple, isRef: isRef)
        var changedIDs: Set<String> = [triple.entityId]
        // For ref triples, also notify the target entity so reverse link views update.
        if isRef, case .ref(let targetId) = triple.value {
            changedIDs.insert(targetId)
        }
        notifyObservers(for: changedIDs)
    }
    
    public func deleteEntity(id: String) {
        var idsChanged: Set<String> = [id]
        
        // 1. Delete forward attributes and links (triples where this entity is the subject)
        let triples = inner.getTriples(entity: id)
        for triple in triples {
             let attr = attrsStore.getAttr(triple.attributeId)
             let isRef = attr?.valueType == .ref
             inner.retractTriple(triple, isRef: isRef)
        }
        
        // 2. Delete reverse links (triples where this entity is the VALUE/target of a ref)
        // This matches the TypeScript SDK behavior in store.ts deleteEntity()
        // Without this, the VAE index retains stale references to the deleted entity,
        // causing "ghost" entities to appear when resolving reverse links.
        let reverseTriples = inner.getReverseRefs(entityId: id)
        for triple in reverseTriples {
            let attr = attrsStore.getAttr(triple.attributeId)
            let isRef = attr?.valueType == .ref
            inner.retractTriple(triple, isRef: isRef)
            // Also notify the entity that had the forward link
            idsChanged.insert(triple.entityId)
        }
        
        notifyObservers(for: idsChanged)
    }
    
    // MARK: - Legacy / Helper Support
    
    /// Merges dictionaries (from Server Tree).
    /// Used by legacy Reactor calls or if manual merging is needed.
    func merge(dictionaries: [[String: Any]]) {
        var changedIDs: Set<String> = []
        for dict in dictionaries {
            guard let id = dict["id"] as? String else { continue }
            changedIDs.insert(id)
        }
        notifyObservers(for: changedIDs)
    }
    
    // MARK: - Data Access
    
    public func get<T: Decodable>(id: String) -> T? {
        return inner.get(id: id, attrsStore: attrsStore)
    }

    // MARK: - Observation

    @discardableResult
    func addObserver(id: String, onChange: @escaping @Sendable () -> Void) -> UUID {
        lock.withLock {
            let token = UUID()
            if observers[id] == nil {
                observers[id] = [:]
            }
            observers[id]?[token] = onChange
            return token
        }
    }

    func removeObserver(id: String, token: UUID) {
        lock.withLock {
            observers[id]?.removeValue(forKey: token)
            if observers[id]?.isEmpty == true {
                observers[id] = nil
            }
        }
    }

    private func notifyObservers(for ids: Set<String>) {
        if ids.isEmpty { return }
        
        // Snapshot callbacks synchronously to avoid data races
        let snapshot: [@Sendable () -> Void] = lock.withLock {
            var callbacks: [@Sendable () -> Void] = []
            for id in ids {
                if let tokens = observers[id] {
                    callbacks.append(contentsOf: tokens.values)
                }
            }
            return callbacks
        }
        
        if snapshot.isEmpty { return }

        // Execute callbacks asynchronously
        Task {
            for callback in snapshot {
                callback()
            }
        }
    }
}
