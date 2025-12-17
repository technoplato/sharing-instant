import Dependencies
import Dispatch
import IdentifiedCollections
import InstantDB
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

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
  ///   - client: The InstantDB client to use. A value of `nil` will use the
  ///     ``Dependencies/DependencyValues/defaultInstant``.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  public static func instantSync<Records: RangeReplaceableCollection & Sendable>(
    _ request: some SharingInstantSync.KeyCollectionRequest<Records.Element>,
    appID: String? = nil
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
  ///   - client: The InstantDB client to use. A value of `nil` will use the
  ///     ``Dependencies/DependencyValues/defaultInstant``.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  public static func instantSync<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantSync.CollectionConfiguration<Value>,
    appID: String? = nil
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
  ///   - client: The InstantDB client to use. A value of `nil` will use the
  ///     ``Dependencies/DependencyValues/defaultInstant``.
  /// - Returns: A key that can be passed to the `@Shared` property wrapper.
  public static func instantSync<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantSync.CollectionConfiguration<Value>,
    appID: String? = nil
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
      withResume {
        continuation.resumeReturningInitialValue()
      }
      return
    }
    
    // Handle testing mode
    guard !isTesting else {
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
    
    Task { @MainActor in
      do {
        // Create client on main actor
        let client = InstantClientFactory.makeClient(appID: appID)
        
        // Build the typed query with ordering
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        
        // Subscribe to query and get initial results
        var receivedInitial = false
        let _ = try client.subscribe(query) { result in
          guard !receivedInitial else { return }
          
          if result.isLoading {
            return
          }
          
          receivedInitial = true
          
          if let error = result.error {
            self.withResume {
              continuation.resume(throwing: error)
            }
          } else {
            self.withResume {
              continuation.resume(returning: Value(result.data))
            }
          }
        }
      } catch {
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
      return SharedSubscription {}
    }
    
    // Handle testing mode
    guard !isTesting else {
      if let testingValue = configuration.testingValue {
        withResume {
          subscriber.yield(Value(testingValue))
        }
      }
      return SharedSubscription {}
    }
    
    let task = Task { @MainActor in
      do {
        // Create client on main actor
        let client = InstantClientFactory.makeClient(appID: appID)
        
        // Build the typed query with ordering
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        
        let token = try client.subscribe(query) { result in
          if result.isLoading {
            return
          }
          
          if let error = result.error {
            self.withResume {
              subscriber.yield(throwing: error)
            }
          } else {
            self.withResume {
              subscriber.yield(Value(result.data))
            }
          }
        }
        
        // Keep the subscription alive
        try? await Task.sleep(nanoseconds: .max)
        _ = token  // Prevent deallocation
      } catch {
        self.withResume {
          subscriber.yield(throwing: error)
        }
      }
    }
    
    return SharedSubscription {
      task.cancel()
    }
  }
  
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
    guard let configuration = request.configuration else {
      continuation.resume()
      return
    }
    
    // Handle testing mode
    guard !isTesting else {
      continuation.resume()
      return
    }
    
    Task { @MainActor in
      do {
        // Create client on main actor
        let client = InstantClientFactory.makeClient(appID: appID)
        
        // Get current server state to diff against
        // For now, we'll send all items as updates
        // A more sophisticated implementation would track changes
        
        let namespace = configuration.namespace
        
        // Build transaction chunks for all items
        var txSteps: [[Any]] = []
        
        for item in value {
          // Encode the item to get its properties
          let encoder = JSONEncoder()
          let data = try encoder.encode(item)
          guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
          }
          
          // Create update transaction for each property
          for (key, propValue) in dict where key != "id" {
            // Format: ["add-triple", entityId, attrIdent, value]
            // For now, use the namespace/key format for attribute ident
            txSteps.append(["add-triple", item.id, "\(namespace)/\(key)", propValue])
          }
        }
        
        if !txSteps.isEmpty {
          try client.transact(txSteps)
        }
        
        withResume {
          continuation.resume()
        }
      } catch {
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

