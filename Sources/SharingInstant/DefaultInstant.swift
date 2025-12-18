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

// MARK: - Client Factory

/// Factory for creating and caching InstantDB clients.
///
/// This is used internally by SharingInstant to create clients on the main actor.
/// Clients are cached by appID so that the same connected client is reused across
/// all operations (subscribe, save, etc.).
public enum InstantClientFactory {
  /// Cache of clients by appID to ensure we reuse connected clients
  @MainActor
  private static var clientCache: [String: InstantClient] = [:]
  
  /// Creates or returns a cached InstantDB client for the configured app ID.
  ///
  /// Must be called from the main actor.
  @MainActor
  public static func makeClient() -> InstantClient {
    @Dependency(\.instantAppID) var appID
    return makeClient(appID: appID)
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
    if let cached = clientCache[appID] {
      return cached
    }
    let client = InstantClient(appID: appID)
    clientCache[appID] = client
    return client
  }
  
  /// Clears the client cache. Useful for testing or when switching accounts.
  @MainActor
  public static func clearCache() {
    clientCache.removeAll()
  }
  
  /// Removes a specific client from the cache.
  @MainActor
  public static func removeClient(appID: String) {
    clientCache.removeValue(forKey: appID)
  }
}
