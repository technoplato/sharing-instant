import Dependencies
import InstantDB

// MARK: - App ID Dependency

extension DependencyValues {
  /// The InstantDB app ID used by `instantSync` and `instantQuery`.
  ///
  /// Configure this as early as possible in your app's lifetime, like the app entry point in
  /// SwiftUI, using `prepareDependencies`:
  ///
  /// ```swift
  /// import SharingInstant
  /// import SwiftUI
  ///
  /// @main
  /// struct MyApp: App {
  ///   init() {
  ///     prepareDependencies {
  ///       $0.instantAppID = "your-app-id"
  ///     }
  ///   }
  ///   // ...
  /// }
  /// ```
  ///
  /// > Note: You can only prepare the app ID a single time in the lifetime of your app.
  /// > Attempting to do so more than once will produce a runtime warning.
  public var instantAppID: String {
    get { self[InstantAppIDKey.self] }
    set { self[InstantAppIDKey.self] = newValue }
  }
}

private enum InstantAppIDKey: DependencyKey {
  static let liveValue: String = {
    reportIssue("""
      A blank, unconfigured InstantDB app ID is being used. To set the app ID that is used by \
      'SharingInstant', use the 'prepareDependencies' tool as early as possible in the lifetime \
      of your app:

          @main
          struct MyApp: App {
            init() {
              prepareDependencies {
                $0.instantAppID = "your-app-id"
              }
            }

            // ...
          }
      """)
    return "unconfigured-app-id"
  }()
  
  static let testValue: String = "test-app-id"
}

// MARK: - Client Options

extension DependencyValues {
  /// Controls whether the underlying Instant iOS SDK enables local persistence.
  ///
  /// ## Why This Exists
  /// InstantDB's local persistence provides a great offline UX, but it can be undesirable in
  /// certain environments:
  ///
  /// - **Tests**: cached emissions can mask server round-trips and make assertions flaky.
  /// - **Debug sessions**: when diagnosing schema/link issues, it is useful to ensure every
  ///   query reflects a server refresh rather than a cached snapshot.
  ///
  /// SharingInstant defaults this to `true` in live apps, and `false` in tests.
  ///
  /// If you change this value at runtime for the same `instantAppID`, call
  /// ``InstantClientFactory/clearCache()`` to ensure a new client is constructed.
  public var instantEnableLocalPersistence: Bool {
    get { self[InstantEnableLocalPersistenceKey.self] }
    set { self[InstantEnableLocalPersistenceKey.self] = newValue }
  }
}

private enum InstantEnableLocalPersistenceKey: DependencyKey {
  static let liveValue: Bool = true
  static let testValue: Bool = false
}

// MARK: - Client Instance ID

extension DependencyValues {
  /// A logical identifier used to isolate `InstantClient` instances for the same InstantDB app.
  ///
  /// ## Why This Exists
  /// SharingInstant caches `InstantClient` instances so that subscriptions, presence, and writes
  /// share a single underlying WebSocket connection (which is the right default for apps).
  ///
  /// However, this caching makes it impossible to simulate multiple independent clients to the
  /// *same* app ID inside a single process (e.g. integration tests that model "Client A" and
  /// "Client B" with separate stores). Without a distinct cache key, all test clients end up
  /// sharing one WebSocket session, which hides real multi-client behavior and can produce
  /// misleading failures.
  ///
  /// Set this to a unique value (like `"A"` / `"B"`) to create truly independent client
  /// instances in the same process.
  public var instantClientInstanceID: String {
    get { self[InstantClientInstanceIDKey.self] }
    set { self[InstantClientInstanceIDKey.self] = newValue }
  }
}

private enum InstantClientInstanceIDKey: DependencyKey {
  static let liveValue: String = "default"
  static let testValue: String = "test"
}

// MARK: - Client Factory

/// Factory for creating and caching InstantDB clients.
///
/// This is used internally by SharingInstant to create clients on the main actor.
/// Clients are cached by appID so that the same connected client is reused across
/// all operations (subscribe, save, etc.).
public enum InstantClientFactory {
  private struct ClientCacheKey: Hashable {
    let appID: String
    let instanceID: String
  }

  /// Cache of clients by appID to ensure we reuse connected clients
  @MainActor
  private static var clientCache: [ClientCacheKey: InstantClient] = [:]
  
  /// Creates or returns a cached InstantDB client for the configured app ID.
  ///
  /// Must be called from the main actor.
  @MainActor
  public static func makeClient() -> InstantClient {
    @Dependency(\.instantAppID) var appID
    @Dependency(\.instantClientInstanceID) var instanceID
    return makeClient(appID: appID, instanceID: instanceID)
  }
  
  /// Creates or returns a cached InstantDB client for a specific app ID.
  ///
  /// The client is cached so that subsequent calls with the same appID return
  /// the same connected client instance. This ensures that save operations
  /// can use an already-authenticated client.
  ///
  /// Must be called from the main actor.
  @MainActor
  public static func makeClient(appID: String) -> InstantClient {
    @Dependency(\.instantClientInstanceID) var instanceID
    return makeClient(appID: appID, instanceID: instanceID)
  }

  /// Creates or returns a cached InstantDB client for a specific app ID and client instance ID.
  ///
  /// This is primarily intended for tests that need multiple independent clients in-process.
  ///
  /// Must be called from the main actor.
  @MainActor
  public static func makeClient(appID: String, instanceID: String) -> InstantClient {
    @Dependency(\.instantEnableLocalPersistence) var enableLocalPersistence

    let cacheKey = ClientCacheKey(appID: appID, instanceID: instanceID)
    if let cached = clientCache[cacheKey] {
      return cached
    }
    let client = InstantClient(appID: appID, enableLocalPersistence: enableLocalPersistence)
    clientCache[cacheKey] = client
    return client
  }
  
  /// Clears the client cache. Useful for testing or when switching accounts.
  @MainActor
  public static func clearCache() {
    clientCache.removeAll()
  }
  
  /// Removes a specific client from the cache.
  @MainActor
  public static func removeClient(appID: String, instanceID: String) {
    clientCache.removeValue(forKey: ClientCacheKey(appID: appID, instanceID: instanceID))
  }

  /// Removes all clients for a specific app ID (across all instance IDs).
  @MainActor
  public static func removeAllClients(appID: String) {
    clientCache.keys
      .filter { $0.appID == appID }
      .forEach { clientCache.removeValue(forKey: $0) }
  }
}
