import Dependencies
import Dispatch
import IdentifiedCollections
import InstantDB
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

extension SharedReaderKey {
  
  /// A key that can query for a collection of data in InstantDB.
  ///
  /// This key takes a ``SharingInstantQuery/KeyRequest`` conformance, which you define yourself.
  /// It has a single requirement that describes querying data from InstantDB.
  ///
  /// ```swift
  /// private struct TopFacts: SharingInstantQuery.KeyRequest {
  ///   typealias Value = Fact
  ///   let configuration: SharingInstantQuery.Configuration<Value>? = .init(
  ///     namespace: "facts",
  ///     orderBy: .desc("count"),
  ///     limit: 10
  ///   )
  /// }
  /// ```
  ///
  /// And one can query for this data by wrapping the request in this key and provide it to the
  /// `@SharedReader` property wrapper:
  ///
  /// ```swift
  /// @SharedReader(.instantQuery(TopFacts())) var facts: IdentifiedArrayOf<Fact>
  /// ```
  ///
  /// For simpler querying needs, you can skip the ceremony of defining a ``SharingInstantQuery/KeyRequest`` and
  /// use a direct configuration with ``Sharing/SharedReaderKey/instantQuery(configuration:client:)-swift.type.method``.
  ///
  /// - Parameters:
  ///   - request: A request describing the data to query.
  ///   - client: The InstantDB client to use. A value of `nil` will use the
  ///     ``Dependencies/DependencyValues/defaultInstant``.
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  public static func instantQuery<Records: RangeReplaceableCollection & Sendable>(
    _ request: some SharingInstantQuery.KeyRequest<Records.Element>,
    appID: String? = nil
  ) -> Self
  where Self == InstantQueryKey<Records>.Default, Records.Element: EntityIdentifiable {
    Self[InstantQueryKey(request: request, appID: appID), default: Value()]
  }
  
  /// A key that can query for a collection of data in InstantDB.
  ///
  /// ```swift
  /// @SharedReader(
  ///   .instantQuery(
  ///     configuration: .init(
  ///       namespace: "facts",
  ///       orderBy: .desc("count"),
  ///       animation: .default
  ///     )
  ///   )
  /// )
  /// private var facts: IdentifiedArrayOf<Fact>
  /// ```
  ///
  /// For more complex querying needs, see ``Sharing/SharedReaderKey/instantQuery(_:client:)-swift.type.method``.
  ///
  /// - Parameters:
  ///   - configuration: A configuration describing the data to query.
  ///   - client: The InstantDB client to use. A value of `nil` will use the
  ///     ``Dependencies/DependencyValues/defaultInstant``.
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  public static func instantQuery<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantQuery.Configuration<Value>,
    appID: String? = nil
  ) -> Self
  where Self == InstantQueryKey<IdentifiedArrayOf<Value>>.Default {
    Self[
      InstantQueryKey(
        request: QueryConfigurationRequest(configuration: configuration),
        appID: appID
      ),
      default: []
    ]
  }
  
  /// A key that can query for a collection of data in InstantDB (Array version).
  ///
  /// ```swift
  /// @SharedReader(
  ///   .instantQuery(
  ///     configuration: .init(
  ///       namespace: "facts",
  ///       orderBy: .desc("count")
  ///     )
  ///   )
  /// )
  /// private var facts: [Fact]
  /// ```
  ///
  /// - Parameters:
  ///   - configuration: A configuration describing the data to query.
  ///   - client: The InstantDB client to use. A value of `nil` will use the
  ///     ``Dependencies/DependencyValues/defaultInstant``.
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  public static func instantQuery<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantQuery.Configuration<Value>,
    appID: String? = nil
  ) -> Self
  where Self == InstantQueryKey<[Value]>.Default {
    Self[
      InstantQueryKey(
        request: QueryConfigurationRequest(configuration: configuration),
        appID: appID
      ),
      default: []
    ]
  }
}

// MARK: - InstantQueryKey

/// A type defining a read-only query to InstantDB.
///
/// You typically do not refer to this type directly, and will use
/// ``Sharing/SharedReaderKey/instantQuery(_:client:)-swift.type.method`` or
/// ``Sharing/SharedReaderKey/instantQuery(configuration:client:)-swift.type.method`` to create instances.
public struct InstantQueryKey<Value: RangeReplaceableCollection & Sendable>: SharedReaderKey
where Value.Element: EntityIdentifiable & Sendable {
  typealias Element = Value.Element
  let appID: String
  let request: any SharingInstantQuery.KeyRequest<Element>
  
  public typealias ID = UniqueRequestKeyID
  
  public var id: ID {
    ID(
      appID: appID,
      namespace: request.configuration?.namespace ?? "",
      orderBy: request.configuration?.orderBy
    )
  }
  
  init(
    request: some SharingInstantQuery.KeyRequest<Element>,
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
    @Dependency(\.context) var dependencyContext
    guard dependencyContext != .test else {
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
        
        // Build the typed query with ordering and limit
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        if let limit = configuration.limit {
          query = query.limit(limit)
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
    @Dependency(\.context) var dependencyContext
    guard dependencyContext != .test else {
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
        
        // Build the typed query with ordering and limit
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        if let limit = configuration.limit {
          query = query.limit(limit)
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
}

// MARK: - Private Request Types

private struct QueryConfigurationRequest<
  Element: EntityIdentifiable & Sendable
>: SharingInstantQuery.KeyRequest {
  let configuration: SharingInstantQuery.Configuration<Element>?
  
  init(configuration: SharingInstantQuery.Configuration<Element>) {
    self.configuration = configuration
  }
}

