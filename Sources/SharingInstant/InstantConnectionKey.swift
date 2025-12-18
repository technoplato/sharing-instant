// InstantConnectionKey.swift
// SharingInstant
//
// A SharedReaderKey for observing InstantDB connection status.

import Combine
import Dependencies
import Foundation
import InstantDB
import Sharing

// MARK: - Connection Status Types

/// The overall status of the InstantDB connection.
///
/// This enum represents the complete state of the connection, with associated
/// data embedded in each case to make illegal states unrepresentable.
///
/// ## State Transitions
///
/// ```
/// ┌─────────────┐
/// │ disconnected│◄────────────────────────────────┐
/// └──────┬──────┘                                 │
///        │ connect()                              │
///        ▼                                        │
/// ┌─────────────┐                                 │
/// │ connecting  │─────────────────────────────────┤
/// └──────┬──────┘  error (network, SSL, etc.)     │
///        │ WebSocket opens                        │
///        ▼                                        │
/// ┌─────────────┐                                 │
/// │  connected  │─────────────────────────────────┤
/// └──────┬──────┘  error (auth failed, etc.)      │
///        │ init-ok received                       │
///        ▼                                        │
/// ┌─────────────┐                                 │
/// │authenticated│─────────────────────────────────┘
/// └─────────────┘  disconnect() or connection lost
/// ```
///
/// ## Why Each State Exists
///
/// - **disconnected**: No active connection. Either never connected, or
///   disconnected intentionally via `disconnect()`. The SDK will not
///   attempt to reconnect from this state.
///
/// - **connecting**: WebSocket connection is being established. This includes
///   DNS resolution, TCP handshake, TLS negotiation, and WebSocket upgrade.
///   If you're stuck here, check network connectivity or SSL/TLS issues.
///
/// - **connected**: WebSocket is open but not yet authenticated. The SDK is
///   waiting for the server's `init-ok` message with session info.
///
/// - **authenticated**: Fully connected and ready to send queries/mutations.
///   The associated `Session` contains user and schema information.
///
/// - **error**: Something went wrong. The associated `ConnectionError` has
///   details about what failed and how to fix it. The SDK will automatically
///   retry with exponential backoff.
public enum InstantConnectionState: Equatable, Sendable {
  
  /// Not connected to InstantDB.
  ///
  /// This is the initial state, or the state after calling `disconnect()`.
  /// The SDK will not attempt to reconnect from this state.
  case disconnected
  
  /// Establishing connection to InstantDB.
  ///
  /// The WebSocket is being opened. This includes:
  /// - DNS resolution
  /// - TCP connection
  /// - TLS handshake (where SSL errors occur)
  /// - WebSocket upgrade
  ///
  /// If stuck in this state, check:
  /// - Network connectivity
  /// - VPN/proxy settings (Zscaler, etc.)
  /// - Firewall rules
  case connecting
  
  /// WebSocket is open, waiting for authentication.
  ///
  /// The connection is established but the server hasn't confirmed
  /// our session yet. This is usually very brief.
  case connected
  
  /// Fully connected and authenticated.
  ///
  /// Queries and mutations can be sent. The associated `Session`
  /// contains information about the current user and loaded schema.
  case authenticated(Session)
  
  /// Connection failed with an error.
  ///
  /// The associated `ConnectionError` contains details about what
  /// went wrong and suggestions for fixing it. The SDK will
  /// automatically retry with exponential backoff.
  case error(ConnectionError)
  
  // MARK: - Session Info (available when authenticated)
  
  /// Information about the current session when authenticated.
  public struct Session: Equatable, Sendable {
    /// The session ID assigned by the server.
    public let sessionID: String
    
    /// The current authentication state.
    public let auth: AuthState
    
    /// Schema attributes loaded from the server.
    ///
    /// These define the shape of your data (namespaces, fields, types).
    /// If empty, the schema hasn't loaded yet or doesn't exist.
    public let attributes: [Attribute]
    
    /// Whether the schema has been loaded from the server.
    public var isSchemaLoaded: Bool {
      !attributes.isEmpty
    }
    
    /// The number of attributes in the schema.
    public var attributeCount: Int {
      attributes.count
    }
    
    /// The current user, if signed in.
    public var user: User? {
      auth.user
    }
    
    /// Whether the user is authenticated (not guest).
    public var isAuthenticated: Bool {
      auth.isAuthenticated
    }
    
    /// Whether the user is a guest.
    public var isGuest: Bool {
      auth.isGuest
    }
  }
  
  // MARK: - Connection Error
  
  /// Details about a connection failure.
  public struct ConnectionError: Equatable, Sendable {
    /// The underlying error.
    public let error: InstantError
    
    /// A human-readable description of what went wrong.
    public var localizedDescription: String {
      error.localizedDescription ?? "Unknown error"
    }
    
    /// Whether this is an SSL/TLS trust failure.
    ///
    /// If true, this is likely caused by corporate VPN software
    /// (Zscaler, Netskope, etc.) intercepting HTTPS traffic.
    public var isSSLError: Bool {
      error.isSSLTrustFailure
    }
    
    /// A suggestion for how to fix the error.
    public var recoverySuggestion: String? {
      error.recoverySuggestion
    }
  }
  
  // MARK: - Convenience Properties
  
  /// Whether the connection is in the disconnected state.
  public var isDisconnected: Bool {
    if case .disconnected = self { return true }
    return false
  }
  
  /// Whether the connection is currently being established.
  public var isConnecting: Bool {
    if case .connecting = self { return true }
    return false
  }
  
  /// Whether the WebSocket is connected (but not yet authenticated).
  public var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
  
  /// Whether fully authenticated and ready to use.
  public var isAuthenticated: Bool {
    if case .authenticated = self { return true }
    return false
  }
  
  /// Whether in an error state.
  public var isError: Bool {
    if case .error = self { return true }
    return false
  }
  
  /// The session info, if authenticated.
  public var session: Session? {
    if case .authenticated(let session) = self { return session }
    return nil
  }
  
  /// The error, if in error state.
  public var connectionError: ConnectionError? {
    if case .error(let error) = self { return error }
    return nil
  }
  
  /// A visual emoji indicator for the connection state.
  ///
  /// - ⚫️ disconnected
  /// - 🟡 connecting
  /// - 🟢 connected
  /// - ✅ authenticated
  /// - 🔴 error
  public var statusEmoji: String {
    switch self {
    case .disconnected: return "⚫️"
    case .connecting: return "🟡"
    case .connected: return "🟢"
    case .authenticated: return "✅"
    case .error: return "🔴"
    }
  }
  
  /// A human-readable status text.
  public var statusText: String {
    switch self {
    case .disconnected:
      return "Disconnected"
    case .connecting:
      return "Connecting..."
    case .connected:
      return "Connected"
    case .authenticated(let session):
      if session.isAuthenticated {
        return "Authenticated"
      } else if session.isGuest {
        return "Connected as Guest"
      } else {
        return "Connected"
      }
    case .error(let error):
      if error.isSSLError {
        return "SSL/TLS Error"
      }
      return "Connection Error"
    }
  }
}

// MARK: - SharedReaderKey Extension

extension SharedReaderKey {
  
  /// A key that observes the InstantDB connection status.
  ///
  /// Use this to reactively display connection state in your UI.
  ///
  /// ```swift
  /// @SharedReader(.instantConnection) var connection: InstantConnectionState
  ///
  /// var body: some View {
  ///   switch connection {
  ///   case .disconnected:
  ///     Text("Not connected")
  ///   case .connecting:
  ///     ProgressView("Connecting...")
  ///   case .connected:
  ///     Text("Authenticating...")
  ///   case .authenticated(let session):
  ///     Text("Welcome, \(session.user?.email ?? "Guest")")
  ///     Text("\(session.attributeCount) attributes loaded")
  ///   case .error(let error):
  ///     if error.isSSLError {
  ///       SSLErrorView()
  ///     } else {
  ///       Text(error.localizedDescription)
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// Or use the convenience properties:
  ///
  /// ```swift
  /// if connection.isError, let error = connection.connectionError {
  ///   ErrorView(error: error)
  /// }
  ///
  /// if connection.isAuthenticated, let session = connection.session {
  ///   Text("Schema loaded: \(session.attributeCount) attributes")
  /// }
  /// ```
  ///
  /// - Parameter appID: Optional app ID. Uses the default if not specified.
  /// - Returns: A key that can be passed to `@SharedReader`.
  public static func instantConnection(
    appID: String? = nil
  ) -> Self where Self == InstantConnectionKey.Default {
    Self[InstantConnectionKey(appID: appID), default: .disconnected]
  }
}

// MARK: - InstantConnectionKey

/// A `SharedReaderKey` that observes InstantDB connection status.
///
/// This key subscribes to the `InstantClient`'s published properties
/// and combines them into a single `InstantConnectionState` value.
public struct InstantConnectionKey: SharedReaderKey {
  public typealias Value = InstantConnectionState
  
  private let appID: String?
  
  public init(appID: String? = nil) {
    self.appID = appID
  }
  
  public var id: some Hashable {
    InstantConnectionKeyID(appID: appID ?? "default")
  }
  
  public func subscribe(
    initialValue: InstantConnectionState?,
    didSet: @escaping @Sendable (InstantConnectionState?) -> Void
  ) -> SharedSubscription {
    let cancellable = LockIsolated<AnyCancellable?>(nil)
    
    Task { @MainActor in
      InstantLogger.debug("Starting connection subscription")
      
      @Dependency(\.instantAppID) var defaultAppID
      let resolvedAppID = appID ?? defaultAppID
      let client = InstantClientFactory.makeClient(appID: resolvedAppID)
      
      // Combine all the relevant publishers
      let subscription = Publishers.CombineLatest4(
        client.$connectionState,
        client.$sessionID,
        client.$attributes,
        client.authManager.$state
      )
      .receive(on: DispatchQueue.main)
      .sink { connectionState, sessionID, attributes, authState in
        let state = Self.mapToConnectionState(
          connectionState: connectionState,
          sessionID: sessionID,
          attributes: attributes,
          authState: authState
        )
        
        InstantLogger.connectionStateChanged(state)
        didSet(state)
      }
      
      cancellable.withValue { $0 = subscription }
    }
    
    return SharedSubscription {
      Task { @MainActor in
        InstantLogger.debug("Ending connection subscription")
      }
      cancellable.withValue { $0?.cancel() }
    }
  }
  
  // MARK: - State Mapping
  
  /// Maps the client's individual published values to our unified state.
  private static func mapToConnectionState(
    connectionState: ConnectionState,
    sessionID: String?,
    attributes: [Attribute],
    authState: AuthState
  ) -> InstantConnectionState {
    switch connectionState {
    case .disconnected:
      return .disconnected
      
    case .connecting:
      return .connecting
      
    case .connected:
      return .connected
      
    case .authenticated:
      // Build the session info
      let session = InstantConnectionState.Session(
        sessionID: sessionID ?? "unknown",
        auth: authState,
        attributes: attributes
      )
      return .authenticated(session)
      
    case .error(let error):
      let connectionError = InstantConnectionState.ConnectionError(error: error)
      return .error(connectionError)
    }
  }
}

// MARK: - Key ID

private struct InstantConnectionKeyID: Hashable {
  let appID: String
}

// MARK: - LockIsolated Helper

/// A simple lock-isolated wrapper for thread-safe access.
private final class LockIsolated<Value>: @unchecked Sendable {
  private var _value: Value
  private let lock = NSLock()
  
  init(_ value: Value) {
    self._value = value
  }
  
  func withValue<T>(_ operation: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation(&_value)
  }
}

