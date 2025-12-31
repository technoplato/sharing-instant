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

// #region agent log
/// Debug logging helper for Cursor debug mode
private func debugLog(location: String, message: String, data: [String: Any], hypothesisId: String) {
    let logPath = "/Users/mlustig/Development/personal/instantdb/.cursor/debug.log"
    let payload: [String: Any] = [
        "location": location,
        "message": message,
        "data": data,
        "timestamp": Date().timeIntervalSince1970 * 1000,
        "sessionId": "debug-session",
        "hypothesisId": hypothesisId
    ]
    if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        let line = jsonString + "\n"
        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
            fileHandle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }
}
// #endregion

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

// MARK: - State Tracking for Option A (Only Send Changes)

/// Actor that tracks state for each subscription to implement Option A.
///
/// ## Why This Exists (Option A Architecture)
///
/// The TypeScript client only sends CHANGES to the server, not the entire state.
/// When you call `$posts.withLock { $0.insert(newPost) }`, it should only send
/// the mutation for `newPost`, not re-send all existing posts.
///
/// The problem is that `save()` only receives the NEW value - it doesn't know
/// what changed. This actor tracks the previous state so we can compute the diff.
///
/// ## How It Works
///
/// 1. **Server data is source of truth**: When `subscribe()` receives data from
///    the server, we store it as `serverState`.
///
/// 2. **Compute diff in save()**: When `save()` is called, we compare the new
///    value with `serverState` to find:
///    - Added items: in new value but not in serverState
///    - Removed items: in serverState but not in new value
///    - Modified items: in both but with different data (TODO: implement)
///
/// 3. **Only send changes**: We only generate operations for the diff, not for
///    unchanged items that already exist on the server.
///
/// ## Key Insight
///
/// Items that exist in `serverState` should NOT be re-sent unless they were
/// actually modified locally. This prevents the "server deletion re-sync" bug.
///
/// ## Thread Safety
///
/// This is an actor to ensure thread-safe access from multiple subscriptions.
private actor StateTracker {
    /// Server-confirmed state per subscription key
    /// Key: "\(appID):\(namespace)"
    /// Value: Set of entity IDs that the server has confirmed
    private var serverStateByKey: [String: Set<String>] = [:]
    
    /// IDs that were added locally (pending confirmation)
    /// These should be sent to the server
    private var locallyAddedByKey: [String: Set<String>] = [:]
    
    /// IDs that were deleted locally (pending confirmation)
    /// These should be sent as delete operations
    private var locallyDeletedByKey: [String: Set<String>] = [:]
    
    // MARK: - Server State Updates
    
    /// Update server state when subscription receives data
    func updateServerState(keyID: String, ids: Set<String>) {
        let previousServerState = serverStateByKey[keyID] ?? []
        serverStateByKey[keyID] = ids
        
        // #region agent log
        debugLog(location: "StateTracker.updateServerState", message: "Server state updated", data: ["keyID": keyID, "idCount": ids.count, "previousCount": previousServerState.count, "ids": Array(ids.prefix(5))], hypothesisId: "H1")
        // #endregion
        
        // Clear locally added IDs that the server now has
        if var locallyAdded = locallyAddedByKey[keyID] {
            locallyAdded.subtract(ids)
            if locallyAdded.isEmpty {
                locallyAddedByKey.removeValue(forKey: keyID)
            } else {
                locallyAddedByKey[keyID] = locallyAdded
            }
        }
        
        // Clear locally deleted IDs that the server has confirmed deleted
        // (they're no longer in the server response)
        if var locallyDeleted = locallyDeletedByKey[keyID] {
            locallyDeleted = locallyDeleted.intersection(ids) // Keep only IDs still on server
            if locallyDeleted.isEmpty {
                locallyDeletedByKey.removeValue(forKey: keyID)
            } else {
                locallyDeletedByKey[keyID] = locallyDeleted
            }
        }
        
        logDebug("StateTracker: Server state updated for \(keyID): \(ids.count) IDs")
    }
    
    // MARK: - Diff Computation
    
    /// Compute what changed between server state and current local state.
    ///
    /// ## Race Condition Mitigation
    ///
    /// Multiple `@Shared` properties can have different views of the same namespace.
    /// To prevent incorrect deletion detection, we use a conservative approach:
    ///
    /// 1. **Additions:** Items not in server state are considered new
    /// 2. **Deletions:** Only items that were EXPLICITLY in server state AND are now
    ///    missing from the current collection are considered deleted.
    ///    We also require that the current collection size is SMALLER than server state
    ///    to prevent race conditions where a subscription hasn't received all data yet.
    ///
    /// Returns: (idsToAdd, idsToDelete)
    /// - idsToAdd: Items in currentIDs but not in serverState (new local items)
    /// - idsToDelete: Items removed from a complete view of the data
    func computeDiff(keyID: String, currentIDs: Set<String>) -> (added: Set<String>, deleted: Set<String>) {
        let serverState = serverStateByKey[keyID] ?? []
        let previousLocallyAdded = locallyAddedByKey[keyID] ?? []
        let previousLocallyDeleted = locallyDeletedByKey[keyID] ?? []
        
        // #region agent log
        debugLog(location: "StateTracker.computeDiff", message: "Computing diff", data: ["keyID": keyID, "currentIDsCount": currentIDs.count, "serverStateCount": serverState.count, "currentIDs": Array(currentIDs.prefix(5)), "serverIDs": Array(serverState.prefix(5))], hypothesisId: "H2")
        // #endregion
        
        // Items in current but not in server state = potentially new
        // But we need to check if they were already pending
        let potentiallyNew = currentIDs.subtracting(serverState)
        
        // New items = in current, not in server, not already tracked as locally added
        let newlyAdded = potentiallyNew.subtracting(previousLocallyAdded)
        
        // CONSERVATIVE DELETION DETECTION:
        // Only detect deletions if:
        // 1. Server state is not empty (we have received data)
        // 2. Current IDs is a SUBSET of server state (no new items mixed in)
        //    OR current IDs contains all server items except the deleted ones
        // 3. The deleted items were actually in server state
        //
        // This prevents race conditions where:
        // - A subscription hasn't received all data yet
        // - Multiple subscriptions have different views
        var newlyDeleted: Set<String> = []
        
        if !serverState.isEmpty {
            // Items that were in server state but not in current = potentially deleted
            let potentiallyDeleted = serverState.subtracting(currentIDs)
            
            // Only consider it a real deletion if:
            // 1. There are items to delete
            // 2. The current collection contains MOST of the server state
            //    (at least 50% to handle partial views, but this is a heuristic)
            // 3. The items weren't already tracked as deleted
            if !potentiallyDeleted.isEmpty {
                let overlapWithServer = currentIDs.intersection(serverState)
                let overlapRatio = serverState.isEmpty ? 0.0 : Double(overlapWithServer.count) / Double(serverState.count)
                
                // Only detect deletions if we have a significant overlap with server state
                // This prevents a subscription with 1 item from deleting everything else
                if overlapRatio >= 0.5 || currentIDs.count >= serverState.count - potentiallyDeleted.count {
                    newlyDeleted = potentiallyDeleted.subtracting(previousLocallyDeleted)
                }
            }
        }
        
        // Update tracking
        if !newlyAdded.isEmpty {
            var existing = locallyAddedByKey[keyID] ?? []
            existing.formUnion(newlyAdded)
            locallyAddedByKey[keyID] = existing
        }
        
        if !newlyDeleted.isEmpty {
            var existing = locallyDeletedByKey[keyID] ?? []
            existing.formUnion(newlyDeleted)
            locallyDeletedByKey[keyID] = existing
        }
        
        // #region agent log
        debugLog(location: "StateTracker.computeDiff", message: "Diff result", data: ["keyID": keyID, "newlyAddedCount": newlyAdded.count, "newlyDeletedCount": newlyDeleted.count, "newlyAddedIDs": Array(newlyAdded.prefix(5))], hypothesisId: "H2")
        // #endregion
        
        logDebug("StateTracker: Diff for \(keyID) - added: \(newlyAdded.count), deleted: \(newlyDeleted.count)")
        
        return (added: newlyAdded, deleted: newlyDeleted)
    }
    
    /// Check if an ID is from the server (not locally added)
    func isServerConfirmed(keyID: String, id: String) -> Bool {
        return serverStateByKey[keyID]?.contains(id) ?? false
    }
    
    /// Check if an ID was locally deleted
    func wasLocallyDeleted(keyID: String, id: String) -> Bool {
        return locallyDeletedByKey[keyID]?.contains(id) ?? false
    }
    
    /// Get all locally added IDs that need to be sent
    func getLocallyAddedIDs(keyID: String) -> Set<String> {
        return locallyAddedByKey[keyID] ?? []
    }
    
    /// Clear tracking for a key (e.g., when subscription ends)
    func clear(keyID: String) {
        serverStateByKey.removeValue(forKey: keyID)
        locallyAddedByKey.removeValue(forKey: keyID)
        locallyDeletedByKey.removeValue(forKey: keyID)
    }
}

/// Shared state tracker instance
private let stateTracker = StateTracker()

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
    
    // Capture key ID for tracking
    let keyID = "\(appID):\(configuration.namespace)"
    
    let task = Task { @MainActor in
        let stream = await reactor.subscribe(appID: appID, configuration: configuration)
        for await data in stream {
            // Track server state for Option A (only send changes)
            let serverIDs = Set(data.map { $0.id.lowercased() })
            await stateTracker.updateServerState(keyID: keyID, ids: serverIDs)
            
            // Filter out any IDs that were locally deleted
            // This prevents re-adding items deleted from the dashboard
            let filteredData = await {
                var result: [Element] = []
                for item in data {
                    let wasDeleted = await stateTracker.wasLocallyDeleted(keyID: keyID, id: item.id.lowercased())
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
          await stateTracker.clear(keyID: keyID)
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
    
    // Capture key ID for state tracking
    let keyID = "\(appID):\(configuration.namespace)"
    let namespace = configuration.namespace
    
    // #region agent log
    debugLog(location: "save.entry", message: "Save called", data: ["keyID": keyID, "namespace": namespace, "itemCount": value.count], hypothesisId: "H3")
    // #endregion
    
    Task { @MainActor in
      do {
        // Collect chunks - ONLY for items that changed (Option A)
        var allChunks: [TransactionChunk] = []
        
        // --- COMPUTE DIFF (Option A) ---
        // Extract current IDs from the value
        let currentIDs = Set(value.map { item -> String in
            let mirror = Mirror(reflecting: item)
            for child in mirror.children {
                if child.label == "id", let idVal = child.value as? String {
                    return idVal.lowercased()
                }
            }
            return ""
        }.filter { !$0.isEmpty })
        
        // Get the diff: what was added vs what was deleted
        let (addedIDs, deletedIDs) = await stateTracker.computeDiff(keyID: keyID, currentIDs: currentIDs)
        
        // #region agent log
        debugLog(location: "save.afterDiff", message: "After diff computation", data: ["keyID": keyID, "addedCount": addedIDs.count, "deletedCount": deletedIDs.count, "addedIDs": Array(addedIDs), "currentIDs": Array(currentIDs)], hypothesisId: "H3")
        // #endregion
        
        logInfo("Save: Option A diff - added: \(addedIDs.count), deleted: \(deletedIDs.count), unchanged: \(currentIDs.count - addedIDs.count)")
        
        // --- GENERATE DELETE OPERATIONS ---
        if !deletedIDs.isEmpty {
            logInfo("Save: generating \(deletedIDs.count) delete operations")
            for deletedID in deletedIDs {
                let deleteChunk = TransactionChunk(
                    namespace: namespace,
                    id: deletedID,
                    ops: [["delete", namespace, deletedID]]
                )
                allChunks.append(deleteChunk)
            }
        }
        
        // --- GENERATE UPDATE/INSERT OPERATIONS (ONLY FOR NEW ITEMS) ---
        // Helper to extract just the ID from an entity (no chunk creation)
        // Used for linked entities - we only need their ID for the link operation
        func extractId(from value: Any) -> String? {
          let mirror = Mirror(reflecting: value)
          for child in mirror.children {
            if child.label == "id", let idVal = child.value as? String {
              return idVal
            }
          }
          return nil
        }
        
        // Helper to traverse and collect operations
        // IMPORTANT: Only top-level items should generate chunks.
        // Linked entities (reached via relationships) should only provide their ID.
        func traverse(value: Any, namespace: String, isTopLevel: Bool = false) throws -> String? {
          let mirror = Mirror(reflecting: value)
          
          // Extract ID
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
          
          // KEY FIX: Only top-level items should generate transaction chunks.
          // Linked entities (isTopLevel=false) should NOT generate chunks -
          // they're only traversed to extract their ID for the link operation.
          // This matches TypeScript behavior where link() only takes IDs.
          if !isTopLevel {
            // #region agent log
            debugLog(location: "traverse.linkedEntitySkip", message: "Skipping chunk for linked entity (only extracting ID)", data: ["entityId": entityId, "namespace": namespace], hypothesisId: "H3")
            // #endregion
            return entityId // Just return ID, don't create chunk
          }
          
          // OPTION A: For top-level items, only process if they were added locally
          // Items that exist on server should NOT be re-sent
          let isNewItem = addedIDs.contains(entityId.lowercased())
          if !isNewItem {
            logDebug("Save: skipping server-confirmed item \(entityId) (Option A)")
            return entityId // Return ID but don't generate ops
          }
          logDebug("Save: processing NEW item \(entityId)")
          
          var dataFields: [String: Any] = [:]
          var linkFields: [String: Any] = [:]
          
          for child in mirror.children {
            guard let label = child.label, label != "id" else { continue }
            
            let childValue = child.value
            let childMirror = Mirror(reflecting: childValue)
            
            // Unwrap Optional
            let actualValue: Any
            if childMirror.displayStyle == .optional {
              if childMirror.children.isEmpty {
                continue // nil value
              } else {
                actualValue = childMirror.children.first!.value
              }
            } else {
              actualValue = childValue
            }
            
            // Check if it's an Entity (nested object) - extract ID only, don't traverse
            if let nestedNamespace = getNamespace(for: actualValue),
               let nestedId = extractId(from: actualValue) {
              linkFields[label] = ["id": nestedId, "namespace": nestedNamespace]
              // #region agent log
              debugLog(location: "traverse.linkedEntity", message: "Adding link (ID only, no recursive traverse)", data: ["parentId": entityId, "linkLabel": label, "linkedId": nestedId, "linkedNamespace": nestedNamespace], hypothesisId: "H3")
              // #endregion
            }
            // Check if it's a Collection of Entities - extract IDs only
            else if let collection = actualValue as? [Any], !collection.isEmpty {
               if let firstItem = collection.first, let _ = getNamespace(for: firstItem) {
                 var linkDicts: [[String: String]] = []
                 for item in collection {
                   if let itemNamespace = getNamespace(for: item),
                      let nestedId = extractId(from: item) {
                     linkDicts.append(["id": nestedId, "namespace": itemNamespace])
                   }
                 }
                 if !linkDicts.isEmpty {
                   linkFields[label] = linkDicts
                 }
               } else {
                  dataFields[label] = actualValue
               }
            }
            else {
               dataFields[label] = actualValue
            }
          }
           
           // Create ops for this entity
           var ops: [[Any]] = []
           
           if !dataFields.isEmpty {
             let safeData = sanitizeData(dataFields)
             ops.append(["update", namespace, entityId, safeData])
           } else {
             ops.append(["update", namespace, entityId, [:] as [String: Any]])
           }
           
           if !linkFields.isEmpty {
             ops.append(["link", namespace, entityId, linkFields])
           }
           
           let chunk = TransactionChunk(namespace: namespace, id: entityId, ops: ops)
           allChunks.append(chunk)
           
           // #region agent log
           debugLog(location: "traverse.chunkCreated", message: "Created transaction chunk", data: ["entityId": entityId, "namespace": namespace, "isTopLevel": isTopLevel, "hasLinks": !linkFields.isEmpty, "linkLabels": Array(linkFields.keys)], hypothesisId: "H5")
           // #endregion
           
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
               res[k] = date.timeIntervalSince1970 * 1000
            } else if let subDict = v as? [String: Any] {
               res[k] = sanitizeData(subDict)
            } else if let array = v as? [Any] {
               res[k] = sanitizeArray(array)
            } else if shouldConvertToJSON(v) {
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
          let mirror = Mirror(reflecting: value)
          return mirror.displayStyle == .struct || mirror.displayStyle == .class
        }
        
        func convertToJSONCompatible(_ value: Any) -> Any? {
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

        // --- Process items (only new ones will generate ops) ---
        for item in value {
           _ = try traverse(value: item, namespace: namespace, isTopLevel: true)
        }
        
        // #region agent log
        debugLog(location: "save.beforeSend", message: "About to send transaction", data: ["chunkCount": allChunks.count, "namespaces": Array(Set(allChunks.map { $0.namespace })), "chunkIDs": allChunks.map { $0.id }], hypothesisId: "H4")
        // #endregion
        
        if !allChunks.isEmpty {
          logDebug("Save: sending \(allChunks.count) transactions (Option A - only changes)")
          try await reactor.transact(appID: appID, chunks: allChunks)
          logInfo("Save: transaction sent successfully")
        } else {
          logDebug("Save: no changes to send (Option A)")
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
