
import Foundation
import InstantDB

extension InstantDB.TripleStore {

    /// Recursively resolves an entity into a dictionary, following references.
    /// This is used to hydrate `Codable` structs from the flat TripleStore.
    ///
    /// ## Cycle Detection
    /// The `visited` parameter tracks entity IDs that are currently being resolved in the
    /// current resolution path. This prevents infinite loops when entities have circular
    /// references (e.g., A -> B -> A). When a cycle is detected, the function returns
    /// early with just `["id": id]` to break the cycle.
    ///
    /// The `defer { visited.remove(id) }` pattern allows the same entity to be visited
    /// in different branches of the resolution tree. For example, if entities A and B
    /// both link to C, C can be fully resolved for both A and B independently.
    ///
    /// - Parameters:
    ///   - id: The entity ID to resolve.
    ///   - attrsStore: The store containing attribute definitions (schema).
    ///   - depth: Current recursion depth (to prevent infinite loops if circular).
    ///   - maxDepth: Maximum recursion depth (default: 5, reduced from 10 for safety).
    ///   - includedLinks: Optional set of link names to resolve. If nil, all links are resolved.
    ///                    If empty set, no links are resolved. This matches the TypeScript SDK's
    ///                    query-driven link resolution behavior.
    ///   - visited: Set of entity IDs currently being resolved in this path for cycle detection.
    /// - Returns: A dictionary representation of the entity.
    public func resolve(
        id: String,
        attrsStore: AttrsStore,
        depth: Int = 0,
        maxDepth: Int = 5,
        includedLinks: Set<String>? = nil,
        visited: inout Set<String>
    ) -> [String: Any] {
        // Cycle detection: if we've already started resolving this entity in the current path,
        // return minimal representation to break the cycle
        if visited.contains(id) {
            return ["id": id]
        }

        // Mark this entity as being visited in the current resolution path
        visited.insert(id)
        defer { visited.remove(id) }  // Allow revisiting in different branches

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

                // Skip links not in includedLinks (if specified)
                // This matches the TypeScript SDK's query-driven link resolution:
                // only resolve links that were explicitly requested in the query.
                if let includedLinks = includedLinks, !includedLinks.contains(label) {
                    continue
                }

                // Handle References (Links)
                var resolvedRefs: [Any] = []

                for triple in attrTriples {
                    if case .ref(let targetId) = triple.value {
                        let childObj = resolve(id: targetId, attrsStore: attrsStore, depth: depth + 1, maxDepth: maxDepth, includedLinks: includedLinks, visited: &visited)
                        // Skip entities that have been deleted or not fully loaded (only have "id" field).
                        // This happens when a where clause references a linked entity (e.g., board.id)
                        // but the entity wasn't explicitly requested via .with(). Including such
                        // "ghost" entities would cause decode failures because required fields are missing.
                        // Also skips cycle-broken entities that return early with just ["id": id].
                        if childObj.count <= 1 {
                            continue
                        }
                        resolvedRefs.append(childObj)
                    } else if case .string(let targetId) = triple.value {
                         // Fallback if ref stored as string? Should satisfy TripleValue.ref though.
                        let childObj = resolve(id: targetId, attrsStore: attrsStore, depth: depth + 1, maxDepth: maxDepth, includedLinks: includedLinks, visited: &visited)
                        // Same guard for ghost entities and cycle-broken entities
                        if childObj.count <= 1 {
                            continue
                        }
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

        // Resolve reverse links at all depths (not just depth 0)
        // This enables nested queries like posts.with(\.comments) { $0.with(\.author) }
        // where Comment.author is a reverse link (Profile.comments is the forward direction)
        if depth < maxDepth, let entityType {
            let reverseAttrs = attrsStore.revIdents[entityType] ?? [:]

            for (reverseLabel, attr) in reverseAttrs {
                // Skip reverse links not in includedLinks (if specified)
                // This matches the TypeScript SDK's query-driven link resolution.
                if let includedLinks = includedLinks, !includedLinks.contains(reverseLabel) {
                    continue
                }

                let reverseTriples = getReverseRefs(entityId: id, attributeId: attr.id)
                guard !reverseTriples.isEmpty else { continue }

                var resolvedParents: [[String: Any]] = []
                resolvedParents.reserveCapacity(reverseTriples.count)

                for triple in reverseTriples {
                    let parentObj = resolve(
                        id: triple.entityId,
                        attrsStore: attrsStore,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        includedLinks: includedLinks,
                        visited: &visited
                    )

                    // Skip entities that have been deleted (only have "id" field)
                    // This happens when a linked entity is deleted from the store but
                    // the reverse reference triple still exists in VAE index.
                    // Including such "ghost" entities would cause decode failures.
                    // Also skips cycle-broken entities that return early with just ["id": id].
                    if parentObj.count <= 1 {
                        continue
                    }

                    resolvedParents.append(parentObj)
                }

                // Don't add empty arrays - this prevents decode issues when all
                // reverse-linked entities have been deleted
                guard !resolvedParents.isEmpty else { continue }

                // Determine reverse cardinality using the `unique` field.
                // Per InstantDB server encoding (schema.clj lines 199-200):
                // - `unique? = true` means reverse has "one" (singular)
                // - `unique? = false` or nil means reverse has "many" (array)
                //
                // See Types.swift Attribute documentation for full details.
                let isReverseSingular = attr.unique == true

                if isReverseSingular {
                    obj[reverseLabel] = resolvedParents.first
                } else {
                    obj[reverseLabel] = resolvedParents
                }
            }
        }
        
        return obj
    }

    /// Convenience overload that creates the visited set for cycle detection.
    /// This is the primary entry point for callers who don't need to manage the visited set.
    ///
    /// - Parameters:
    ///   - id: The entity ID to resolve.
    ///   - attrsStore: The store containing attribute definitions (schema).
    ///   - depth: Current recursion depth (to prevent infinite loops if circular).
    ///   - maxDepth: Maximum recursion depth (default: 5).
    ///   - includedLinks: Optional set of link names to resolve. If nil, all links are resolved.
    ///                    If empty set, no links are resolved.
    /// - Returns: A dictionary representation of the entity.
    public func resolve(
        id: String,
        attrsStore: AttrsStore,
        depth: Int = 0,
        maxDepth: Int = 5,
        includedLinks: Set<String>? = nil
    ) -> [String: Any] {
        var visited = Set<String>()
        return resolve(
            id: id,
            attrsStore: attrsStore,
            depth: depth,
            maxDepth: maxDepth,
            includedLinks: includedLinks,
            visited: &visited
        )
    }

    /// Decodes an entity from the store into a Swift type.
    ///
    /// - Parameters:
    ///   - id: The entity ID to decode.
    ///   - attrsStore: The store containing attribute definitions (schema).
    ///   - includedLinks: Optional set of link names to resolve. If nil, all links are resolved.
    ///                    If empty set, no links are resolved.
    /// - Returns: The decoded entity, or nil if decoding fails.
    public func get<T: Decodable>(id: String, attrsStore: AttrsStore, includedLinks: Set<String>? = nil) -> T? {
        let dict = resolve(id: id, attrsStore: attrsStore, includedLinks: includedLinks)
        
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
