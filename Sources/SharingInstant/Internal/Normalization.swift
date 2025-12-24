import Foundation
import InstantDB

// Adapted from: instant-client/src/normalizer.ts
enum Normalization {
    
    /// Normalizes a tree of data into a flat list of triples.
    ///
    /// - Parameters:
    ///   - data: The entity data as a dictionary.
    ///   - namespace: The namespace of the entity (e.g., "profiles").
    ///   - attrsStore: The schema definition.
    /// - Returns: An array of triples.
    static func normalize(
        data: [String: Any],
        namespace: String,
        attrsStore: AttrsStore,
        createdAt: Int64 = 0
    ) -> [Triple] {
        var triples: [Triple] = []
        
        // Entity must have an ID
        guard let entityId = data["id"] as? String else { return [] }
        
        let timestamp = createdAt
        
        for (key, value) in data {
            if key == "id" { continue }
            
            // 1. Check Forward Attributes
            if let attr = attrsStore.getAttrByForwardIdent(entityType: namespace, label: key) {
                if attr.valueType == .ref {
                    // Handle Links (Forward) 
                    // Wait, forwardIdentity is [id, namespace, label]. 
                    // No, for Ref it is [id, sourceNS, label]. 
                    // Where is targetNS? 
                    // In `checkedDataType`? Or we need to infer from Ref Identity?
                    // Actually `attr.reverseIdentity` has [id, targetNS, reverseLabel].
                    // So targetNS = attr.reverseIdentity[1].
                    
                    guard let revIdent = attr.reverseIdentity, revIdent.count >= 2 else { continue }
                    let targetNamespace = revIdent[1]
                    
                    let children = asArray(value)
                    for child in children {
                        guard let childDict = child as? [String: Any],
                              let childId = childDict["id"] as? String else {
                             // Maybe just ID string?
                             if let childId = child as? String {
                                 triples.append(Triple(entityId: entityId, attributeId: attr.id, value: .ref(childId), createdAt: timestamp))
                             }
                             continue
                        }
                        
                        // Recursive normalize child
                        triples.append(contentsOf: normalize(
                            data: childDict,
                            namespace: targetNamespace,
                            attrsStore: attrsStore,
                            createdAt: createdAt
                        ))
                        
                        // Create Link Triple
                        triples.append(Triple(entityId: entityId, attributeId: attr.id, value: .ref(childId), createdAt: timestamp))
                    }
                } else {
                    // Handle Primitive/Blob
                    // value could be Array if cardinality many
                    if attr.cardinality == .many {
                         let items = asArray(value)
                         for item in items {
                             let tripleVal = TripleValue(fromAny: item)
                             triples.append(Triple(entityId: entityId, attributeId: attr.id, value: tripleVal, createdAt: timestamp))
                         }
                    } else {
                         let tripleVal = TripleValue(fromAny: value)
                         triples.append(Triple(entityId: entityId, attributeId: attr.id, value: tripleVal, createdAt: timestamp))
                    }
                }
            }
            // 2. Check Reverse Attributes
            else if let attr = attrsStore.getAttrByReverseIdent(entityType: namespace, label: key) {
                // Reverse Link: We are at Target. Relation is Source -> Target.
                // Attribute belongs to Source.
                // Triple is (SourceID, AttrID, TargetID).
                
                // Forward Identity of this attr: [id, sourceNS, label]
                // We are in TargetNS (namespace).
                // So SourceNS = attr.forwardIdentity[1].
                let sourceNamespace = attr.forwardIdentity.count > 1 ? attr.forwardIdentity[1] : ""
                
                let parents = asArray(value)
                for parent in parents {
                    guard let parentDict = parent as? [String: Any],
                          let parentId = parentDict["id"] as? String else {
                         if let parentId = parent as? String {
                             triples.append(Triple(entityId: parentId, attributeId: attr.id, value: .ref(entityId), createdAt: timestamp))
                         }
                         continue
                    }
                    
                    // Recursive normalize parent
                    triples.append(contentsOf: normalize(
                        data: parentDict,
                        namespace: sourceNamespace,
                        attrsStore: attrsStore,
                        createdAt: createdAt
                    ))
                    
                    // Create Link Triple (Source -> Target)
                    triples.append(Triple(entityId: parentId, attributeId: attr.id, value: .ref(entityId), createdAt: timestamp))
                }
            }
        }
        
        return triples
    }
    
    private static func asArray(_ value: Any) -> [Any] {
        if let array = value as? [Any] {
            return array
        }
        return [value]
    }
}
