import Dependencies
import Dispatch
import IdentifiedCollections
import InstantDB
import IssueReporting
import os.log
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "Sync")

/// Helper to log with file/line info
private func logDebug(
  _ message: String,
  file: String = #file,
  line: Int = #line
) {
  let fileName = (file as NSString).lastPathComponent
  logger.debug("[\(fileName):\(line)] \(message)")
}

private func logInfo(
  _ message: String,
  file: String = #file,
  line: Int = #line
) {
  let fileName = (file as NSString).lastPathComponent
  logger.info("[\(fileName):\(line)] \(message)")
}

private func logError(
  _ message: String,
  error: Error? = nil,
  file: String = #file,
  line: Int = #line
) {
  let fileName = (file as NSString).lastPathComponent
  if let error = error {
    logger.error("[\(fileName):\(line)] \(message): \(error.localizedDescription)")
  } else {
    logger.error("[\(fileName):\(line)] \(message)")
  }
}

// MARK: - ID Tracking for Deletion Detection

/// Actor that tracks known IDs for each subscription to detect deletions.
///
/// ## Why This Exists
///
/// When a user calls `$items.withLock { $0.remove(id:) }`, the `save()` method
/// only receives the NEW collection state - it doesn't know what was removed.
/// This actor tracks the previous set of IDs so we can compute the difference
/// and generate delete operations.
///
/// ## How It Works
///
/// 1. When `subscribe()` receives data from the server, it updates `knownIDs`
/// 2. When `save()` is called, it compares current IDs with `knownIDs`
/// 3. IDs in `knownIDs` but not in current = deleted by user → send delete ops
/// 4. After save, `knownIDs` is updated to match current state
///
/// ## Thread Safety
///
/// This is an actor to ensure thread-safe access from multiple subscriptions.
private actor IDTracker {
    /// Known IDs per subscription key, keyed by the key's string ID
    private var knownIDsByKey: [String: Set<String>] = [:]
    
    /// IDs that were deleted locally and should not be re-added if server sends them back
    /// This prevents the "re-add after dashboard delete" bug
    private var locallyDeletedIDs: [String: Set<String>] = [:]
    
    /// Update known IDs when server sends data
    func updateFromServer(keyID: String, ids: Set<String>) {
        // Remove any locally deleted IDs that the server has now confirmed as deleted
        // (i.e., they're no longer in the server response)
        if var deleted = locallyDeletedIDs[keyID] {
            deleted = deleted.intersection(ids) // Keep only IDs still on server
            if deleted.isEmpty {
                locallyDeletedIDs.removeValue(forKey: keyID)
            } else {
                locallyDeletedIDs[keyID] = deleted
            }
        }
        
        knownIDsByKey[keyID] = ids
    }
    
    /// Get IDs that were removed (for deletion detection)
    /// Returns: (idsToDelete, updatedKnownIDs)
    func computeDeletedIDs(keyID: String, currentIDs: Set<String>) -> Set<String> {
        let knownIDs = knownIDsByKey[keyID] ?? []
        
        // IDs that were in known set but not in current = deleted by user
        let deletedIDs = knownIDs.subtracting(currentIDs)
        
        // Update known IDs to current state
        knownIDsByKey[keyID] = currentIDs
        
        // Track these as locally deleted so we don't re-add them
        if !deletedIDs.isEmpty {
            var existing = locallyDeletedIDs[keyID] ?? []
            existing.formUnion(deletedIDs)
            locallyDeletedIDs[keyID] = existing
        }
        
        return deletedIDs
    }
    
    /// Check if an ID was locally deleted (to prevent re-adding)
    func wasLocallyDeleted(keyID: String, id: String) -> Bool {
        return locallyDeletedIDs[keyID]?.contains(id) ?? false
    }
    
    /// Filter out locally deleted IDs from a set of IDs
    func filterLocallyDeleted(keyID: String, ids: [String]) -> [String] {
        guard let deleted = locallyDeletedIDs[keyID], !deleted.isEmpty else {
            return ids
        }
        return ids.filter { !deleted.contains($0.lowercased()) && !deleted.contains($0) }
    }
    
    /// Clear tracking for a key (e.g., when subscription ends)
    func clear(keyID: String) {
        knownIDsByKey.removeValue(forKey: keyID)
        locallyDeletedIDs.removeValue(forKey: keyID)
    }
}

/// Shared ID tracker instance
private let idTracker = IDTracker()

extension SharedReaderKey {
  
  /// A key that can sync collection data with InstantDB.
  ///
  /// This key takes a ``SharingInstantSync/KeyCollectionRequest`` conformance, which you define yourself.
  /// It has a single requirement that describes syncing a value from InstantDB.
  ///
  /// ```swift
  /// private struct Todos: SharingInstantSync.KeyCollectionRequest {
  ///   typealias Value = Todo
  ///   let configuration: SharingInstantSync.CollectionConfiguration<Value>? = .init(
  ///     namespace: "todos",
  ///     orderBy: .desc("createdAt"),
  ///     animation: .default
  ///   )
  /// }
  /// ```
  ///
  /// And one can sync this data by wrapping the request in this key and provide it to the
  /// `@Shared` property wrapper:
  ///
  /// ```swift
  /// @Shared(.instantSync(Todos())) var todos: IdentifiedArrayOf<Todo>
  /// ```
  ///
  /// For simpler syncing needs, you can skip the ceremony of defining a ``SharingInstantSync/KeyCollectionRequest`` and
  /// use a direct configuration with ``Sharing/SharedReaderKey/instantSync(configuration:client:)-swift.type.method``.
  ///
  /// - Parameters:
  ///   - request: A request describing the data to sync.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  public static func instantSync<Records: RangeReplaceableCollection & Sendable>(
    _ request: some SharingInstantSync.KeyCollectionRequest<Records.Element>
  ) -> Self
  where Self == InstantSyncCollectionKey<Records>.Default {
    Self[InstantSyncCollectionKey(request: request, appID: nil), default: Value()]
  }
  
  /// A key that can sync collection data with InstantDB for a specific app.
  ///
  /// ## Multi-App Support (Untested)
  ///
  /// This overload exists to support connecting to multiple InstantDB apps
  /// simultaneously. Each app ID creates a separate cached `InstantClient`.
  ///
  /// **This feature has not been tested.** If you need multi-app support,
  /// please test thoroughly and report any issues.
  ///
  /// - Parameters:
  ///   - request: A request describing the data to sync.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantSync<Records: RangeReplaceableCollection & Sendable>(
    _ request: some SharingInstantSync.KeyCollectionRequest<Records.Element>,
    appID: String
  ) -> Self
  where Self == InstantSyncCollectionKey<Records>.Default {
    Self[InstantSyncCollectionKey(request: request, appID: appID), default: Value()]
  }
  
  /// A key that can sync collection data with InstantDB.
  ///
  /// ```swift
  /// @Shared(
  ///   .instantSync(
  ///     configuration: .init(
  ///       namespace: "todos",
  ///       orderBy: .desc("createdAt"),
  ///       animation: .default
  ///     )
  ///   )
  /// )
  /// private var todos: IdentifiedArrayOf<Todo>
  /// ```
  ///
  /// For more flexible syncing needs, see ``Sharing/SharedReaderKey/instantSync(_:client:)-swift.type.method``.
  ///
  /// - Parameters:
  ///   - configuration: A configuration describing the data to sync.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  public static func instantSync<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantSync.CollectionConfiguration<Value>
  ) -> Self
  where Self == InstantSyncCollectionKey<IdentifiedArrayOf<Value>>.Default {
    Self[
      InstantSyncCollectionKey(
        request: SyncCollectionConfigurationRequest(configuration: configuration),
        appID: nil
      ),
      default: []
    ]
  }
  
  /// A key that can sync collection data with InstantDB for a specific app.
  ///
  /// ## Multi-App Support (Untested)
  ///
  /// This overload exists to support connecting to multiple InstantDB apps
  /// simultaneously. Each app ID creates a separate cached `InstantClient`.
  ///
  /// **This feature has not been tested.** If you need multi-app support,
  /// please test thoroughly and report any issues.
  ///
  /// - Parameters:
  ///   - configuration: A configuration describing the data to sync.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantSync<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantSync.CollectionConfiguration<Value>,
    appID: String
  ) -> Self
  where Self == InstantSyncCollectionKey<IdentifiedArrayOf<Value>>.Default {
    Self[
      InstantSyncCollectionKey(
        request: SyncCollectionConfigurationRequest(configuration: configuration),
        appID: appID
      ),
      default: []
    ]
  }
  
  /// A key that can sync collection data with InstantDB (Array version).
  ///
  /// ```swift
  /// @Shared(
  ///   .instantSync(
  ///     configuration: .init(
  ///       namespace: "todos",
  ///       orderBy: .desc("createdAt")
  ///     )
  ///   )
  /// )
  /// private var todos: [Todo]
  /// ```
  ///
  /// - Parameters:
  ///   - configuration: A configuration describing the data to sync.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  public static func instantSync<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantSync.CollectionConfiguration<Value>
  ) -> Self
  where Self == InstantSyncCollectionKey<[Value]>.Default {
    Self[
      InstantSyncCollectionKey(
        request: SyncCollectionConfigurationRequest(configuration: configuration),
        appID: nil
      ),
      default: []
    ]
  }
  
  /// A key that can sync collection data with InstantDB (Array version) for a specific app.
  ///
  /// ## Multi-App Support (Untested)
  ///
  /// This overload exists to support connecting to multiple InstantDB apps
  /// simultaneously. Each app ID creates a separate cached `InstantClient`.
  ///
  /// **This feature has not been tested.** If you need multi-app support,
  /// please test thoroughly and report any issues.
  ///
  /// - Parameters:
  ///   - configuration: A configuration describing the data to sync.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantSync<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantSync.CollectionConfiguration<Value>,
    appID: String
  ) -> Self
  where Self == InstantSyncCollectionKey<[Value]>.Default {
    Self[
      InstantSyncCollectionKey(
        request: SyncCollectionConfigurationRequest(configuration: configuration),
        appID: appID
      ),
      default: []
    ]
  }
}

// MARK: - InstantSyncCollectionKey

/// A type defining a bidirectional sync with InstantDB collections.
///
/// You typically do not refer to this type directly, and will use
/// ``Sharing/SharedReaderKey/instantSync(_:client:)-swift.type.method`` or
/// ``Sharing/SharedReaderKey/instantSync(configuration:client:)-swift.type.method`` to create instances.
public struct InstantSyncCollectionKey<Value: RangeReplaceableCollection & Sendable>: SharedKey
where Value.Element: EntityIdentifiable & Sendable {
  typealias Element = Value.Element
  let appID: String
  let request: any SharingInstantSync.KeyCollectionRequest<Element>
  
  public typealias ID = UniqueRequestKeyID
  
  public var id: ID {
    let configuration = request.configuration
    return ID(
      appID: appID,
      namespace: configuration?.namespace ?? "",
      orderBy: configuration?.orderBy,
      whereClause: configuration?.whereClause,
      includedLinks: configuration?.includedLinks ?? [],
      linkTree: configuration?.linkTree ?? []
    )
  }
  
  init(
    request: some SharingInstantSync.KeyCollectionRequest<Element>,
    appID: String? = nil
  ) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
    self.request = request
  }
  
  #if canImport(SwiftUI)
  func withResume(_ action: () -> Void) {
    withAnimation(request.configuration?.animation) {
      action()
    }
  }
  #else
  func withResume(_ action: () -> Void) {
    action()
  }
  #endif
  
  public func load(context: LoadContext<Value>, continuation: LoadContinuation<Value>) {
    @Dependency(\.instantReactor) var reactor
    guard case .userInitiated = context, let configuration = request.configuration else {
      logDebug("Load: non-userInitiated context or no configuration, returning initial value")
      withResume {
        continuation.resumeReturningInitialValue()
      }
      return
    }
    
    // Handle testing mode
    guard !isTesting else {
      logDebug("Load: testing mode")
      if let testingValue = configuration.testingValue {
        withResume {
          continuation.resume(returning: Value(testingValue))
        }
      } else {
        withResume {
          continuation.resumeReturningInitialValue()
        }
      }
      return
    }
    
    logInfo("Load: fetching data for namespace: \(configuration.namespace)")
    
    let loadId = UUID().uuidString.prefix(8)
    logDebug("Load[\(loadId)]: starting load task via Reactor")
    
    Task { @MainActor in
        let stream = await reactor.subscribe(appID: appID, configuration: configuration)
        for await data in stream {
            withResume {
                continuation.resume(returning: Value(data))
            }
            break // One-shot
        }
    }
  }
  
  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    @Dependency(\.instantReactor) var reactor
    
    guard let configuration = request.configuration else {
      logDebug("Subscribe: no configuration provided, returning empty subscription")
      return SharedSubscription {}
    }
    
    // Handle testing mode
    guard !isTesting else {
      logDebug("Subscribe: testing mode, using testing value")
      if let testingValue = configuration.testingValue {
        withResume {
          subscriber.yield(Value(testingValue))
        }
      }
      return SharedSubscription {}
    }
    
    logInfo("Subscribe: starting subscription for namespace: \(configuration.namespace)")
    
    let subscriptionId = UUID().uuidString.prefix(8)
    logDebug("Subscribe[\(subscriptionId)]: creating new subscription task via Reactor")
    
    // Capture subscriber identity for debugging - use address of the subscriber struct
    let subscriberIdentity = withUnsafePointer(to: subscriber) { String(format: "%p", $0) }
    
    // Capture key ID for tracking
    let keyID = "\(appID):\(configuration.namespace)"
    
    let task = Task { @MainActor in
        let stream = await reactor.subscribe(appID: appID, configuration: configuration)
        for await data in stream {
            // Track IDs from server for deletion detection
            let serverIDs = Set(data.map { $0.id.lowercased() })
            await idTracker.updateFromServer(keyID: keyID, ids: serverIDs)
            
            // Filter out any IDs that were locally deleted
            // This prevents re-adding items deleted from the dashboard
            let filteredData = await {
                var result: [Element] = []
                for item in data {
                    let wasDeleted = await idTracker.wasLocallyDeleted(keyID: keyID, id: item.id.lowercased())
                    if !wasDeleted {
                        result.append(item)
                    }
                }
                return result
            }()
            
            withResume {
                subscriber.yield(Value(filteredData))
            }
        }
    }
    
    return SharedSubscription {
      logDebug("Subscribe[\(subscriptionId)]: SharedSubscription cancelled for \(configuration.namespace)")
      task.cancel()
      // Clear tracking when subscription ends
      Task {
          await idTracker.clear(keyID: keyID)
      }
    }
  }
  
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.instantReactor) var reactor
    guard let configuration = request.configuration else {
      logDebug("Save: no configuration, skipping")
      continuation.resume()
      return
    }
    
    // Handle testing mode
    guard !isTesting else {
      logDebug("Save: testing mode, skipping")
      continuation.resume()
      return
    }
    
    logInfo("Save: saving \(value.count) items to \(configuration.namespace)")
    
    // Capture key ID for deletion tracking
    let keyID = "\(appID):\(configuration.namespace)"
    let namespace = configuration.namespace
    
    Task { @MainActor in
      do {
        // Collect chunks
        // We'll collect all chunks (ops) from the entire graph here
        var allChunks: [TransactionChunk] = []
        
        // --- DELETION DETECTION ---
        // Compare current IDs with known IDs to find deletions
        let currentIDs = Set(value.map { item -> String in
            // Extract ID using Mirror since we can't easily cast to EntityIdentifiable
            let mirror = Mirror(reflecting: item)
            for child in mirror.children {
                if child.label == "id", let idVal = child.value as? String {
                    return idVal.lowercased()
                }
            }
            return ""
        }.filter { !$0.isEmpty })
        
        let deletedIDs = await idTracker.computeDeletedIDs(keyID: keyID, currentIDs: currentIDs)
        
        // Generate delete operations for removed items
        if !deletedIDs.isEmpty {
            logInfo("Save: detected \(deletedIDs.count) deletions: \(deletedIDs)")
            for deletedID in deletedIDs {
                let deleteChunk = TransactionChunk(
                    namespace: namespace,
                    id: deletedID,
                    ops: [["delete", namespace, deletedID]]
                )
                allChunks.append(deleteChunk)
            }
        }
        
        // --- UPDATE/INSERT OPERATIONS ---
        // Helper to traverse and collect operations
        // Returns the ID of the entity processed
        func traverse(value: Any, namespace: String) throws -> String? {
          // Identify the entity ID and properties
          // We use Mirror to inspect properties
          let mirror = Mirror(reflecting: value)
          
          // Must identify 'id' property
          // We can't rely on EntityIdentifiable casting easily for `Any` value without existential opening,
          // so we look for "id" property via Mirror.
          var id: String?
          for child in mirror.children {
            if child.label == "id", let idVal = child.value as? String {
              id = idVal
              break
            }
          }
          
          guard let entityId = id else {
            logDebug("Save: could not find 'id' property on value of type \(type(of: value))")
            return nil
          }
          
          var dataFields: [String: Any] = [:]
          var linkFields: [String: Any] = [:]
          
          for child in mirror.children {
            guard let label = child.label, label != "id" else { continue }
            
            let childValue = child.value
            let childMirror = Mirror(reflecting: childValue)
            
            // Unwrap Optional
            let actualValue: Any
            let isOptional: Bool
            if childMirror.displayStyle == .optional {
              isOptional = true
              if childMirror.children.isEmpty {
                // nil value
                continue 
              } else {
                actualValue = childMirror.children.first!.value
              }
            } else {
              isOptional = false
              actualValue = childValue
            }
            
            // Check if it's an Entity (nested object)
            // We use getNamespace as the primary check for Entity-ness
            if let namespace = getNamespace(for: actualValue),
               let nestedId = try? traverse(value: actualValue, namespace: namespace) {
              // It's a single link
              linkFields[label] = ["id": nestedId, "namespace": namespace]
            }
            // Check if it's a Collection of Entities
            else if let collection = actualValue as? [Any], !collection.isEmpty {
               // Try to traverse first element to see if it's an entity
               // If yes, traverse all and link many
               var ids: [String] = []
               var isEntityCollection = false
               
               // Check first item to determine if this is a collection of entities
               if let firstItem = collection.first, let _ = getNamespace(for: firstItem) {
                 isEntityCollection = true
                 var linkDicts: [[String: String]] = []
                 for item in collection {
                   if let namespace = getNamespace(for: item),
                      let nestedId = try? traverse(value: item, namespace: namespace) {
                     linkDicts.append(["id": nestedId, "namespace": namespace])
                   }
                 }
                 if isEntityCollection {
                   linkFields[label] = linkDicts
                 }
               } else {
                  // Regular array data
                  dataFields[label] = actualValue
               }
            }
            else {
              // Regular property
              // Check for encodable? For now we trust JSONSerialization will handle or fail
               dataFields[label] = actualValue
            }
          }
           
           // Create ops for this entity
           var ops: [[Any]] = []
           
           // 1. Update (create/update)
           if !dataFields.isEmpty {
             let safeData = sanitizeData(dataFields)
             ops.append(["update", namespace, entityId, safeData])
           } else {
             ops.append(["update", namespace, entityId, [:] as [String: Any]])
           }
           
           // 2. Links
           if !linkFields.isEmpty {
             ops.append(["link", namespace, entityId, linkFields])
           }
           
           let chunk = TransactionChunk(namespace: namespace, id: entityId, ops: ops)
           allChunks.append(chunk)
           
           return entityId
        }
        
        // Helper to get namespace
        func getNamespace(for value: Any) -> String? {
           if let entity = value as? any EntityIdentifiable {
             return type(of: entity).namespace
           }
           return nil
        }
        
        func sanitizeData(_ dict: [String: Any]) -> [String: Any] {
          var res = dict
          for (k, v) in dict {
            if let date = v as? Date {
               res[k] = date.timeIntervalSince1970 * 1000 // ms
            } else if let subDict = v as? [String: Any] {
               res[k] = sanitizeData(subDict)
            } else if let array = v as? [Any] {
               // Handle arrays - convert any Encodable elements to dictionaries
               res[k] = sanitizeArray(array)
            } else if shouldConvertToJSON(v) {
               // Convert Encodable structs to JSON-compatible dictionaries
               if let converted = convertToJSONCompatible(v) {
                 res[k] = converted
               }
            }
          }
          return res
        }
        
        func sanitizeArray(_ array: [Any]) -> [Any] {
          return array.map { element in
            if let date = element as? Date {
              return date.timeIntervalSince1970 * 1000
            } else if let subDict = element as? [String: Any] {
              return sanitizeData(subDict)
            } else if let subArray = element as? [Any] {
              return sanitizeArray(subArray)
            } else if shouldConvertToJSON(element) {
              return convertToJSONCompatible(element) ?? element
            }
            return element
          }
        }
        
        func shouldConvertToJSON(_ value: Any) -> Bool {
          // Check if this is a custom struct/class that needs JSON conversion
          // Primitives and dictionaries are already handled
          let mirror = Mirror(reflecting: value)
          return mirror.displayStyle == .struct || mirror.displayStyle == .class
        }
        
        func convertToJSONCompatible(_ value: Any) -> Any? {
          // Try to convert Encodable values to JSON-compatible dictionaries
          guard let encodable = value as? Encodable else { return nil }
          
          do {
            let data = try JSONEncoder().encode(AnyEncodable(encodable))
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            return json
          } catch {
            logDebug("Save: failed to convert \(type(of: value)) to JSON: \(error)")
            return nil
          }
        }

        // --- Execution ---
        
        for item in value {
           _ = try traverse(value: item, namespace: namespace)
        }
        
        if !allChunks.isEmpty {
          logDebug("Save: sending \(allChunks.count) transactions (including \(deletedIDs.count) deletes) via Reactor")
          
          // Delegate to Reactor
          try await reactor.transact(appID: appID, chunks: allChunks)
          
          logInfo("Save: transaction sent successfully")
        } else {
          logDebug("Save: no transactions to send")
        }
        
        withResume {
          continuation.resume()
        }

      } catch {
        logError("Save: failed", error: error)
        reportIssue(error)
        withResume {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  
}

// MARK: - Private Request Types

private struct SyncCollectionConfigurationRequest<
  Element: EntityIdentifiable & Sendable
>: SharingInstantSync.KeyCollectionRequest {
  let configuration: SharingInstantSync.CollectionConfiguration<Element>?
  
  init(configuration: SharingInstantSync.CollectionConfiguration<Element>) {
    self.configuration = configuration
  }
}

// MARK: - Testing Support

private var isTesting: Bool {
  @Dependency(\.context) var context
  return context == .test
}

// MARK: - AnyEncodable Helper

/// Type-erased wrapper for Encodable values.
/// Used to encode arbitrary Encodable structs (like Word) to JSON dictionaries.
private struct AnyEncodable: Encodable {
  private let _encode: (Encoder) throws -> Void
  
  init<T: Encodable>(_ wrapped: T) {
    _encode = wrapped.encode
  }
  
  func encode(to encoder: Encoder) throws {
    try _encode(encoder)
  }
}
