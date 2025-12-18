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

private let logger = Logger(subsystem: "SharingInstant", category: "Query")

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
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  public static func instantQuery<Records: RangeReplaceableCollection & Sendable>(
    _ request: some SharingInstantQuery.KeyRequest<Records.Element>
  ) -> Self
  where Self == InstantQueryKey<Records>.Default, Records.Element: EntityIdentifiable {
    Self[InstantQueryKey(request: request, appID: nil), default: Value()]
  }
  
  /// A key that can query for a collection of data in InstantDB for a specific app.
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
  ///   - request: A request describing the data to query.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantQuery<Records: RangeReplaceableCollection & Sendable>(
    _ request: some SharingInstantQuery.KeyRequest<Records.Element>,
    appID: String
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
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  public static func instantQuery<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantQuery.Configuration<Value>
  ) -> Self
  where Self == InstantQueryKey<IdentifiedArrayOf<Value>>.Default {
    Self[
      InstantQueryKey(
        request: QueryConfigurationRequest(configuration: configuration),
        appID: nil
      ),
      default: []
    ]
  }
  
  /// A key that can query for a collection of data in InstantDB for a specific app.
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
  ///   - configuration: A configuration describing the data to query.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantQuery<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantQuery.Configuration<Value>,
    appID: String
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
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  public static func instantQuery<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantQuery.Configuration<Value>
  ) -> Self
  where Self == InstantQueryKey<[Value]>.Default {
    Self[
      InstantQueryKey(
        request: QueryConfigurationRequest(configuration: configuration),
        appID: nil
      ),
      default: []
    ]
  }
  
  /// A key that can query for a collection of data in InstantDB (Array version) for a specific app.
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
  ///   - configuration: A configuration describing the data to query.
  ///   - appID: The app ID to use.
  /// - Returns: A key that can be passed to the `@SharedReader` property wrapper.
  @available(*, deprecated, message: "Multi-app support is untested. Remove appID parameter to use the default app ID configured via prepareDependencies.")
  public static func instantQuery<Value: EntityIdentifiable & Sendable>(
    configuration: SharingInstantQuery.Configuration<Value>,
    appID: String
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
        
        // Build the typed query with ordering, limit, and where clause
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
        }
        if let limit = configuration.limit {
          query = query.limit(limit)
        }
        if let whereClause = configuration.whereClause {
          query = query.where(whereClause)
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
      logDebug("Query: no configuration provided, returning empty subscription")
      return SharedSubscription {}
    }
    
    // Handle testing mode
    @Dependency(\.context) var dependencyContext
    guard dependencyContext != .test else {
      logDebug("Query: testing mode, using testing value")
      if let testingValue = configuration.testingValue {
        withResume {
          subscriber.yield(Value(testingValue))
        }
      }
      return SharedSubscription {}
    }
    
    logInfo("Query: starting subscription for namespace: \(configuration.namespace)")
    
    let task = Task { @MainActor in
      do {
        // Create client on main actor
        let client = InstantClientFactory.makeClient(appID: appID)
        logDebug("Query: created InstantClient for app: \(self.appID)")
        
        // Connect if not already connected
        if client.connectionState == .disconnected {
          logInfo("Query: client disconnected, initiating connection...")
          client.connect()
        }
        
        // Wait for authentication with timeout
        // InstantDB uses automatic guest auth - server sends init-ok on connect
        // This should be very fast (typically < 2s)
        let timeout: UInt64 = 5_000_000_000 // 5 seconds
        let startTime = DispatchTime.now()
        var lastLoggedState: String = ""
        
        while client.connectionState != .authenticated {
          let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
          if elapsed > timeout {
            let error = InstantError.notAuthenticated
            logError("Query: authentication timeout after 5s, state: \(String(describing: client.connectionState))")
            reportIssue("InstantDB authentication timeout during query. State: \(client.connectionState)")
            self.withResume {
              subscriber.yield(throwing: error)
            }
            return
          }
          
          // Check for error state
          if case .error(let connectionError) = client.connectionState {
            logError("Query: connection error", error: connectionError)
            reportIssue(connectionError)
            self.withResume {
              subscriber.yield(throwing: connectionError)
            }
            return
          }
          
          // Only log state changes to reduce noise
          let currentState = String(describing: client.connectionState)
          if currentState != lastLoggedState {
            logDebug("Query: waiting for auth, state changed to: \(currentState)")
            lastLoggedState = currentState
          }
          
          try await Task.sleep(nanoseconds: 50_000_000) // 50ms (faster polling)
        }
        
        logInfo("Query: client authenticated (guest), subscribing to query for \(Element.namespace)...")
        
        // Build the typed query with ordering, limit, and where clause
        var query = client.query(Element.self)
        if let orderBy = configuration.orderBy {
          query = query.order(by: orderBy.field, orderBy.isDescending ? .desc : .asc)
          logDebug("Query: ordered by \(orderBy.field) \(orderBy.isDescending ? "DESC" : "ASC")")
        }
        if let whereClause = configuration.whereClause {
          query = query.where(whereClause)
          logDebug("Query: with where clause: \(whereClause)")
        }
        if let limit = configuration.limit {
          query = query.limit(limit)
          logDebug("Query: limited to \(limit) results")
        }
        
        let token = try client.subscribe(query) { result in
          if result.isLoading {
            logDebug("Query: loading...")
            return
          }
          
          if let error = result.error {
            logError("Query: error", error: error)
            reportIssue(error)
            self.withResume {
              subscriber.yield(throwing: error)
            }
          } else {
            logInfo("Query: returned \(result.data.count) items from \(Element.namespace)")
            self.withResume {
              subscriber.yield(Value(result.data))
            }
          }
        }
        
        logDebug("Query: subscription established, keeping alive...")
        
        // Keep the subscription alive
        try? await Task.sleep(nanoseconds: .max)
        _ = token  // Prevent deallocation
      } catch {
        logError("Query: subscribe failed", error: error)
        reportIssue(error)
        self.withResume {
          subscriber.yield(throwing: error)
        }
      }
    }
    
    return SharedSubscription {
      logDebug("Query: subscription cancelled for \(configuration.namespace)")
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

