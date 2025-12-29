
import Foundation
import InstantDB

extension InstantDB.TripleStore {
    
    /// Recursively resolves an entity into a dictionary, following references.
    /// This is used to hydrate `Codable` structs from the flat TripleStore.
    ///
    /// - Parameters:
    ///   - id: The entity ID to resolve.
    ///   - attrsStore: The store containing attribute definitions (schema).
    ///   - depth: Current recursion depth (to prevent infinite loops if circular).
    ///   - maxDepth: Maximum recursion depth.
    /// - Returns: A dictionary representation of the entity.
    public func resolve(id: String, attrsStore: AttrsStore, depth: Int = 0, maxDepth: Int = 10) -> [String: Any] {
        if depth > maxDepth { return ["id": id] }
        
        let triples = self.getTriples(entity: id)
        var obj: [String: Any] = ["id": id]
        
        // Group triples by Attribute ID
        let triplesByAttr = Dictionary(grouping: triples, by: { $0.attributeId })
        
        let entityType = triplesByAttr.keys.lazy
            .compactMap { attrId in
                attrsStore.getAttr(attrId)?.forwardIdentity.dropFirst().first
            }
            .first

        for (attrId, attrTriples) in triplesByAttr {
            guard let attr = attrsStore.getAttr(attrId) else { continue }
            
            // Determine the key name (label)
            // Forward identity: [id, namespace, label]
            // If the schema is incomplete, fall back to using the attribute ID as the label.
            let label = attr.forwardIdentity.last ?? attrId
            
            if attr.valueType == .ref {
                // Allow nested forward links up to maxDepth
                // Previously this was restricted to depth == 0, which prevented
                // nested links like Media.transcriptionRuns.words from being resolved
                if depth >= maxDepth {
                    continue
                }

                // Handle References (Links)
                var resolvedRefs: [Any] = []
                
                for triple in attrTriples {
                    if case .ref(let targetId) = triple.value {
                        let childObj = resolve(id: targetId, attrsStore: attrsStore, depth: depth + 1, maxDepth: maxDepth)
                        resolvedRefs.append(childObj)
                    } else if case .string(let targetId) = triple.value {
                         // Fallback if ref stored as string? Should satisfy TripleValue.ref though.
                        let childObj = resolve(id: targetId, attrsStore: attrsStore, depth: depth + 1, maxDepth: maxDepth)
                        resolvedRefs.append(childObj)
                    }
                }
                
                if attr.cardinality == .many {
                    obj[label] = resolvedRefs
                } else {
                    obj[label] = resolvedRefs.first
                }
                
            } else {
                // Handle Scalar Values
                if attr.cardinality == .many {
                    let values = attrTriples.map { $0.value.toAny() }
                    obj[label] = values
                } else {
                    // Start LWW or any? Triples should be essentially unique by LWW if store enforces it?
                    // Store.addTriple supports cardinality one overwriting.
                    // But getTriples returns all?
                    // SDK Store `addTriple` handles LWW overwrite for cardinality one.
                    // So we expect 1 triple.
                    if let triple = attrTriples.first {
                        obj[label] = triple.value.toAny()
                    }
                }
            }
        }

        if depth == 0, let entityType {
            let reverseAttrs = attrsStore.revIdents[entityType] ?? [:]

            for (reverseLabel, attr) in reverseAttrs {
                let reverseTriples = getReverseRefs(entityId: id, attributeId: attr.id)
                guard !reverseTriples.isEmpty else { continue }

                var resolvedParents: [[String: Any]] = []
                resolvedParents.reserveCapacity(reverseTriples.count)

                for triple in reverseTriples {
                    let parentObj = resolve(
                        id: triple.entityId,
                        attrsStore: attrsStore,
                        depth: depth + 1,
                        maxDepth: maxDepth
                    )
                    resolvedParents.append(parentObj)
                }

                let isReverseMany: Bool
                if attr.unique == true {
                    isReverseMany = false
                } else if attr.cardinality == .one {
                    isReverseMany = true
                } else {
                    isReverseMany = false
                }

                if isReverseMany {
                    obj[reverseLabel] = resolvedParents
                } else {
                    obj[reverseLabel] = resolvedParents.first
                }
            }
        }
        
        return obj
    }

    /// Decodes an entity from the store into a Swift type.
    public func get<T: Decodable>(id: String, attrsStore: AttrsStore) -> T? {
        let dict = resolve(id: id, attrsStore: attrsStore)
        
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            let decoder = JSONDecoder()
            // Configure decoder if needed (dates?)
            // InstantDB uses ISO8601 strings for dates usually, or Timestamps?
            // Types.swift says TripleValue.toAny() -> Date overrides to String ISO8601.
            decoder.dateDecodingStrategy = .iso8601 
            return try decoder.decode(T.self, from: data)
        } catch {
            SharingInstantInternalLog.debug("TripleStore decode failed for \(id): \(error)")
            return nil
        }
    }
}
