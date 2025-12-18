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
    ID(
      appID: appID,
      namespace: request.configuration?.namespace ?? "",
      orderBy: request.configuration?.orderBy
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
    logDebug("Load[\(loadId)]: starting load task")
    
    Task { @MainActor in
      do {
        // Create client on main actor
        let client = InstantClientFactory.makeClient(appID: appID)
        logDebug("Load[\(loadId)]: created client for app: \(self.appID)")
        
        // Connect if not already connected
        if client.connectionState == .disconnected {
          logInfo("Load: client disconnected, initiating connection...")
          client.connect()
        }
        
        // Wait for authentication with timeout
        // InstantDB uses automatic guest auth - should be fast
        let timeout: UInt64 = 5_000_000_000 // 5 seconds
        let startTime = DispatchTime.now()
        
        while client.connectionState != .authenticated {
          let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
          if elapsed > timeout {
            let error = InstantError.notAuthenticated
            logError("Load: authentication timeout after 5s, state: \(String(describing: client.connectionState))")
            reportIssue("InstantDB authentication timeout. State: \(client.connectionState)")
            self.withResume {
              continuation.resume(throwing: error)
            }
            return
          }
          
          if case .error(let connectionError) = client.connectionState {
            logError("Load: connection error", error: connectionError)
            reportIssue(connectionError)
            self.withResume {
              continuation.resume(throwing: connectionError)
            }
            return
          }
          
          logDebug("Load: waiting for auth, state: \(String(describing: client.connectionState))")
          try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        
        logDebug("Load: client authenticated (guest), executing query...")
        
        // Build the typed query with ordering and where clause
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        if let whereClause = configuration.whereClause {
          query = query.where(whereClause)
        }
        
        logDebug("Load[\(loadId)]: subscribing to query for \(Element.namespace)")
        
        // Subscribe to query and get initial results
        var receivedInitial = false
        var continuationResumed = false
        let token = try client.subscribe(query) { result in
          guard !receivedInitial else {
            logDebug("Load[\(loadId)]: ignoring subsequent callback (already received initial)")
            return
          }
          
          if result.isLoading {
            logDebug("Load[\(loadId)]: query loading...")
            return
          }
          
          receivedInitial = true
          
          if let error = result.error {
            logError("Load[\(loadId)]: query error", error: error)
            reportIssue(error)
            if !continuationResumed {
              continuationResumed = true
              self.withResume {
                continuation.resume(throwing: error)
              }
            }
          } else {
            logInfo("Load[\(loadId)]: received \(result.data.count) items from \(Element.namespace)")
            if !continuationResumed {
              continuationResumed = true
              self.withResume {
                continuation.resume(returning: Value(result.data))
              }
            }
          }
        }
        
        // Wait a moment for the initial result, then clean up the subscription
        // The subscribe() method maintains the long-lived subscription for real-time updates
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // If we still haven't received data, the continuation will leak
        // This can happen if the task is cancelled before data arrives
        if !continuationResumed {
          logError("Load[\(loadId)]: timeout waiting for initial data, resuming with initial value")
          continuationResumed = true
          self.withResume {
            continuation.resumeReturningInitialValue()
          }
        }
        
        // Clean up the load subscription (subscribe() maintains its own)
        _ = token
      } catch {
        logError("Load[\(loadId)]: failed", error: error)
        reportIssue(error)
        withResume {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  
  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
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
    logDebug("Subscribe[\(subscriptionId)]: creating new subscription task")
    
    let task = Task { @MainActor in
      // Create client on main actor
      let client = InstantClientFactory.makeClient(appID: appID)
      logDebug("Subscribe[\(subscriptionId)]: created InstantClient for app: \(self.appID)")
      
      // Track if we've successfully subscribed at least once
      var token: SubscriptionToken?
      var hasLoggedError = false
      
      // Main subscription loop - survives connection failures and reconnects
      // This loop runs until the task is cancelled (when the @Shared goes away)
      while !Task.isCancelled {
        do {
          // Connect if not already connected
          if client.connectionState == .disconnected {
            logInfo("Subscribe: client disconnected, initiating connection...")
            client.connect()
          }
          
          // Wait for authentication (with no timeout - we'll wait for reconnection)
          // The WebSocketConnection handles automatic reconnection with backoff
          var lastLoggedState: String = ""
          
          while client.connectionState != .authenticated && !Task.isCancelled {
            // Log connection errors but don't give up - WebSocket will auto-reconnect
            if case .error(let connectionError) = client.connectionState {
              if !hasLoggedError {
                logError("Subscribe: connection error (waiting for reconnect)", error: connectionError)
                hasLoggedError = true
              }
              // Don't yield error to subscriber - just wait for reconnection
              // The UI will show stale data or loading state, which is better than an error
            }
            
            // Only log state changes to reduce noise
            let currentState = String(describing: client.connectionState)
            if currentState != lastLoggedState {
              logDebug("Subscribe: waiting for auth, state changed to: \(currentState)")
              lastLoggedState = currentState
              
              // Reset error logging flag when state changes (so we log new errors)
              if currentState != "error" {
                hasLoggedError = false
              }
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms polling
          }
          
          guard !Task.isCancelled else { break }
          
          logInfo("Subscribe: client authenticated (guest), subscribing to query for \(Element.namespace)...")
          
          // Build the typed query with ordering and where clause
          var query = client.query(Element.self)
          if let orderBy = configuration.orderBy {
            query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
            logDebug("Subscribe: query ordered by \(orderBy.field) \(orderBy.isDescending ? "DESC" : "ASC")")
          }
          if let whereClause = configuration.whereClause {
            query = query.where(whereClause)
            logDebug("Subscribe: query with where clause: \(whereClause)")
          }
          
          // Subscribe to the query
          token = try client.subscribe(query) { result in
            if result.isLoading {
              logDebug("Subscribe: query loading...")
              return
            }
            
            if let error = result.error {
              logError("Subscribe: query error", error: error)
              reportIssue(error)
              self.withResume {
                subscriber.yield(throwing: error)
              }
            } else {
              logInfo("Subscribe: query returned \(result.data.count) items from \(Element.namespace)")
              self.withResume {
                subscriber.yield(Value(result.data))
              }
            }
          }
          
          logDebug("Subscribe[\(subscriptionId)]: subscription established, keeping alive...")
          
          // Keep the subscription alive, monitoring for disconnection
          // If we disconnect, we'll loop back and wait for reconnection
          while !Task.isCancelled && client.connectionState == .authenticated {
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms check interval
          }
          
          // If we get here and aren't cancelled, connection dropped - loop back to reconnect
          if !Task.isCancelled {
            logInfo("Subscribe[\(subscriptionId)]: connection lost, waiting for reconnect...")
            // Token is still held, will be cleaned up when task ends or we get a new one
          }
          
        } catch {
          if Task.isCancelled {
            logDebug("Subscribe[\(subscriptionId)]: task was cancelled")
            break
          } else {
            logError("Subscribe[\(subscriptionId)]: error during subscription", error: error)
            // Wait a bit before retrying
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
          }
        }
      }
      
      logDebug("Subscribe[\(subscriptionId)]: task ending, cleaning up")
      _ = token  // Token cleanup happens here when task ends
    }
    
    return SharedSubscription {
      logDebug("Subscribe[\(subscriptionId)]: SharedSubscription cancelled for \(configuration.namespace)")
      task.cancel()
    }
  }
  
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
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
    
    Task { @MainActor in
      do {
        // Create client on main actor
        let client = InstantClientFactory.makeClient(appID: appID)
        logDebug("Save: created client for app: \(self.appID)")
        
        // Check connection state
        guard client.connectionState == .authenticated else {
          logError("Save: client not authenticated, state: \(String(describing: client.connectionState))")
          reportIssue("Cannot save: InstantDB client not authenticated. State: \(client.connectionState)")
          withResume {
            continuation.resume(throwing: InstantError.notAuthenticated)
          }
          return
        }
        
        let namespace = configuration.namespace
        
        // Build transaction chunks for all items using the proper TransactionChunk API
        // This ensures attribute UUIDs are resolved correctly by TransactionTransformer
        var chunks: [TransactionChunk] = []
        
        for item in value {
          // Encode the item to get its properties
          let encoder = JSONEncoder()
          // InstantDB stores dates as milliseconds since epoch
          encoder.dateEncodingStrategy = .millisecondsSince1970
          let data = try encoder.encode(item)
          guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logError("Save: failed to serialize item \(item.id) to dictionary")
            continue
          }
          
          // Remove the id from the data dict (it's used as the entity ID, not a property)
          dict.removeValue(forKey: "id")
          
          // Create an update transaction chunk for this item
          // Format: ["update", entityType, entityId, dataDict]
          let chunk = TransactionChunk(
            namespace: namespace,
            id: item.id,
            ops: [["update", namespace, item.id, dict]]
          )
          chunks.append(chunk)
        }
        
        if !chunks.isEmpty {
          logDebug("Save: sending \(chunks.count) update transactions")
          try client.transact(chunks)
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

