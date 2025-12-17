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

/// Factory for creating InstantDB clients.
///
/// This is used internally by SharingInstant to create clients on the main actor.
public enum InstantClientFactory {
  /// Creates an InstantDB client for the configured app ID.
  ///
  /// Must be called from the main actor.
  @MainActor
  public static func makeClient() -> InstantClient {
    @Dependency(\.instantAppID) var appID
    return InstantClient(appID: appID)
  }
  
  /// Creates an InstantDB client for a specific app ID.
  ///
  /// Must be called from the main actor.
  @MainActor
  public static func makeClient(appID: String) -> InstantClient {
    InstantClient(appID: appID)
  }
}
