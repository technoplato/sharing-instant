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
    
    let task = Task { @MainActor in
        let stream = await reactor.subscribe(appID: appID, configuration: configuration)
        for await data in stream {
            withResume {
                subscriber.yield(Value(data))
            }
        }
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
    
    Task { @MainActor in
      do {
        // Collect chunks
        // We'll collect all chunks (ops) from the entire graph here
        var allChunks: [TransactionChunk] = []
        
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
            }
          }
          return res
        }

        // --- Execution ---
        
        let namespace = configuration.namespace
        
        for item in value {
           _ = try traverse(value: item, namespace: namespace)
        }
        
        if !allChunks.isEmpty {
          logDebug("Save: sending \(allChunks.count) transactions (recursive) via Reactor")
          
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
