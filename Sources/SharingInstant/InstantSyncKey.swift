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

// MARK: - StateTracker REMOVED (TypeScript Parity)
//
// ## Why StateTracker Was Removed
//
// The StateTracker attempted to infer CHANGES from state by comparing the current
// collection value against tracked server state. This required a fragile 50% heuristic
// for deletion detection that could:
// - Fail to detect real deletions (if overlap < 50%)
// - Incorrectly detect deletions (if overlap >= 50% but items weren't in the view)
//
// ## TypeScript SDK Approach (Reactor.js)
//
// The TypeScript SDK NEVER uses diff-based deletion detection. Instead:
// - Every mutation is explicit: `tx.todos[id].delete()`
// - Mutations are stored with explicit tx-steps: `["delete", "todos", "id123"]`
// - No inference of intent from state changes
//
// ## Migration Path
//
// Instead of using `$todos.withLock { $0.remove(todo) }`, use the generated
// mutation methods:
//
// ```swift
// // OLD (no longer syncs to server):
// $todos.withLock { $0.remove(todo) }
//
// // NEW (explicit mutation, TypeScript parity):
// try await $todos.delete(id: todo.id)
// ```
//
// The `withLock` API still works for local UI state manipulation, but changes
// made via `withLock` are NOT automatically sent to the server. Only explicit
// mutation methods (`create`, `update`, `delete`, `link`, `unlink`) will sync.
//
// ## Reference
// - TypeScript Reactor.js: Lines 1348-1370 (pushOps stores EXPLICIT mutation)
// - Plan: Phase 4 "Remove StateTracker, Only Support Explicit Mutations"

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
            // Yield server data directly - no filtering or state tracking needed
            // Deletions are handled explicitly via $collection.delete(id:) which
            // calls Reactor.transact() with explicit delete operations
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
  
  /// `save()` is a NO-OP - use explicit mutation methods instead.
  ///
  /// ## Why This Is A No-Op (TypeScript Parity)
  ///
  /// The TypeScript SDK never infers mutations from state changes. Every mutation
  /// is explicit: `tx.todos[id].update({...})`, `tx.todos[id].delete()`.
  ///
  /// The previous implementation used a `StateTracker` with a 50% heuristic for
  /// deletion detection, which was fragile and didn't match TypeScript behavior.
  ///
  /// ## Migration
  ///
  /// Instead of relying on `save()` being called automatically when you use
  /// `$todos.withLock { ... }`, use the generated explicit mutation methods:
  ///
  /// ```swift
  /// // OLD (no longer syncs to server):
  /// $todos.withLock { $0.append(newTodo) }
  /// $todos.withLock { $0.remove(todo) }
  ///
  /// // NEW (explicit mutations, TypeScript parity):
  /// try await $todos.create(newTodo)
  /// try await $todos.delete(id: todo.id)
  /// try await $todos.update(id: todo.id) { $0.title = "New Title" }
  /// ```
  ///
  /// The `withLock` API still works for LOCAL state manipulation (e.g., UI
  /// optimistic updates), but those changes are NOT automatically sent to
  /// the server. Only explicit mutation methods sync with InstantDB.
  ///
  /// ## Reference
  /// - TypeScript Reactor.js: Lines 1348-1370 (explicit tx-steps only)
  /// - Plan: Phase 4 "Remove StateTracker, Only Support Explicit Mutations"
  public func save(
    _ value: Value,
    context: SaveContext,
    continuation: SaveContinuation
  ) {
    // No-op: Changes made via withLock are NOT sent to the server.
    // Use explicit mutation methods ($collection.create, .update, .delete) instead.
    //
    // This matches TypeScript SDK behavior where mutations are always explicit.
    continuation.resume()
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

