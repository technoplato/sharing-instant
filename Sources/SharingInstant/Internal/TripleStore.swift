import Foundation
import InstantDB

/// A shared store that holds normalized entities.
///
/// The TripleStore acts as the single source of truth for all data fetched from InstantDB.
/// It stores entities in a normalized format: `[EntityID: [Attribute: Value]]`.
actor TripleStore {
  /// The normalized data store: [EntityID: [Attribute: Value]]
  private var entities: [String: [String: Any]] = [:]
  
  /// Observers waiting for updates to specific entities
  /// [EntityID: [Token: Callback]]
  private var observers: [String: [UUID: () -> Void]] = [:]
  
  static let shared = TripleStore()
  
  init() {}
  
  // MARK: - Data Access
  
  /// Retrieves an entity by its ID and decodes it to the specified type.
  /// - Parameters:
  ///   - id: The ID of the entity.
  /// - Returns: The decoded entity, or nil if not found or decoding fails.
  func get<T: Decodable>(id: String) -> T? {
    guard let data = entities[id] else { return nil }
    
    // We need to convert [String: Any] back to T.
    // Since JSONSerialization expects [String: Any] to be JSON-compatible,
    // and our store might contain standard Swift types (Date, etc),
    // we might need custom handling.
    // For now, simple round-trip via JSONSerialization if possible.
    
    // Quick and dirty: Serialize to Data then Decode.
    // Optimization: Use a Decoder that reads directly from Dictionary (like DictionaryDecoder).
    // For this implementation, we'll try JSON roundtrip but handle Date strategies if needed.
    
    do {
      // Clean data for JSON serialization (handle Dates, etc if raw)
      // Assuming straightforward types for now.
      let jsonData = try JSONSerialization.data(withJSONObject: data)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601 // InstantDB standard?
      return try decoder.decode(T.self, from: jsonData)
    } catch {
      print("TripleStore: Failed to decode \(id) to \(T.self): \(error)")
      return nil
    }
  }
  
  /// Merges new data into the store.
  /// - Parameters:
  ///   - values: The codable values to merge.
  func merge<T: Encodable & EntityIdentifiable>(values: [T]) {
    var changedEntityIDs: Set<String> = []
    
    for value in values {
      // Encode to Dict
      guard let dict = try? value.asDictionary() else { continue }
      mergeEntity(id: value.id, data: dict, changedIDs: &changedEntityIDs)
    }
    
    notifyObservers(for: changedEntityIDs)
  }

  /// Merges raw dictionary data. Useful for optimistic updates where we don't have the typed object yet.
  func mergeUnsafe(id: String, data: [String: Any]) {
      var changedIDs: Set<String> = []
      mergeEntity(id: id, data: data, changedIDs: &changedIDs)
      notifyObservers(for: changedIDs)
  }

  func delete(id: String) {
      if entities[id] != nil {
          entities.removeValue(forKey: id)
           // Should we notify observers? Yes, so they get nil/removed.
           // However, 'get' currently returns T?.
           // If we notify, the observer calls 'get' and gets nil.
           // Works for now.
           notifyObservers(for: [id])
      }
  }
  
  private func mergeEntity(
    id: String,
    data: [String: Any],
    changedIDs: inout Set<String>
  ) {
    var currentEntity = entities[id] ?? ["id": id]
    var hasChanges = false
    
    for (key, value) in data {
        // Skip nil values if Encodable produced them (shouldn't typically with asDictionary)
        // Recursion for nested entities?
        // If T contains nested Entity objects, they are serialized into 'data'.
        // To truly normalize, we should detect them and extract them.
        // For V1, we store the aggregate. If partial updates come, we merge at top level attributes.
        
        // Simple equality check
        if let oldValue = currentEntity[key] {
             if !valuesAreEqual(oldValue, value) {
                 currentEntity[key] = value
                 hasChanges = true
             }
        } else {
             currentEntity[key] = value
             hasChanges = true
        }
    }
    
    if hasChanges {
      entities[id] = currentEntity
      changedIDs.insert(id)
    }
  }
  
  // MARK: - Observation
  
  func addObserver(id: String, onChange: @escaping () -> Void) -> UUID {
    let token = UUID()
    if observers[id] == nil {
      observers[id] = [:]
    }
    observers[id]?[token] = onChange
    return token
  }
  
  func removeObserver(id: String, token: UUID) {
    observers[id]?.removeValue(forKey: token)
    if observers[id]?.isEmpty == true {
      observers[id] = nil
    }
  }
  
  private func notifyObservers(for ids: Set<String>) {
    Task {
        // Notify on main actor? Or just call closures?
        // Closures usually capture context.
        for id in ids {
          if let entityObservers = observers[id] {
            for callback in entityObservers.values {
              callback()
            }
          }
        }
    }
  }
  
  // MARK: - Helpers
  
  private func valuesAreEqual(_ v1: Any, _ v2: Any) -> Bool {
    if let s1 = v1 as? String, let s2 = v2 as? String { return s1 == s2 }
    if let i1 = v1 as? Int, let i2 = v2 as? Int { return i1 == i2 }
    if let b1 = v1 as? Bool, let b2 = v2 as? Bool { return b1 == b2 }
    // Add more types...
    return false
  }
} // End TripleStore


// MARK: - Encodable Helper
extension Encodable {
  func asDictionary() throws -> [String: Any] {
    let data = try JSONEncoder().encode(self)
    guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
      throw NSError(domain: "TripleStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to cast to dictionary"])
    }
    return dictionary
  }
}
