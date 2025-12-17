import Combine
import Dependencies
import Foundation
import InstantDB
import os.log
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "Auth")

// MARK: - InstantAuth

/// A coordinator for InstantDB authentication with an ergonomic SwiftUI API.
///
/// `InstantAuth` provides a clean, reactive interface for authentication that
/// integrates naturally with SwiftUI views.
///
/// ## Basic Usage
///
/// ```swift
/// struct ContentView: View {
///   @StateObject private var auth = InstantAuth()
///
///   var body: some View {
///     switch auth.state {
///     case .loading:
///       ProgressView()
///     case .unauthenticated:
///       LoginView(auth: auth)
///     case .guest(let user):
///       MainContent(user: user)
///     case .authenticated(let user):
///       MainContent(user: user)
///     }
///   }
/// }
/// ```
///
/// ## Sign In Methods
///
/// ```swift
/// // Sign in as guest
/// try await auth.signInAsGuest()
///
/// // Magic code (email)
/// try await auth.sendMagicCode(to: "user@example.com")
/// try await auth.verifyMagicCode(email: "user@example.com", code: "123456")
///
/// // Sign in with Apple
/// try await auth.signInWithApple(presentationAnchor: window)
///
/// // Sign out
/// try await auth.signOut()
/// ```
@MainActor
public final class InstantAuth: ObservableObject {
  /// The current authentication state
  @Published public private(set) var state: AuthState = .loading
  
  /// The current user, if signed in
  public var user: User? {
    state.user
  }
  
  /// Whether a user is signed in (guest or authenticated)
  public var isSignedIn: Bool {
    state.isSignedIn
  }
  
  /// Whether the user is fully authenticated (not guest)
  public var isAuthenticated: Bool {
    state.isAuthenticated
  }
  
  /// Whether the user is a guest
  public var isGuest: Bool {
    state.isGuest
  }
  
  private let appID: String
  private var client: InstantClient?
  private var cancellables = Set<AnyCancellable>()
  
  /// Creates an InstantAuth coordinator.
  ///
  /// - Parameter appID: Optional app ID. Uses the default if not specified.
  public init(appID: String? = nil) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
    
    Task {
      await setup()
    }
  }
  
  private func setup() async {
    let client = InstantClientFactory.makeClient(appID: appID)
    self.client = client
    
    // Observe auth state from the client's auth manager
    client.authManager.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] newState in
        self?.state = newState
      }
      .store(in: &cancellables)
    
    logger.debug("InstantAuth initialized for app: \(self.appID)")
  }
  
  // MARK: - Guest Auth
  
  /// Signs in as a guest user.
  ///
  /// Guest users have a unique ID but no email. They can be upgraded
  /// to full accounts later.
  ///
  /// - Returns: The guest user
  /// - Throws: If sign-in fails
  @discardableResult
  public func signInAsGuest() async throws -> User {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Signing in as guest")
    let user = try await client.authManager.signInAsGuest()
    logger.info("Signed in as guest: \(user.id)")
    return user
  }
  
  // MARK: - Magic Code Auth
  
  /// Sends a magic code to the specified email address.
  ///
  /// After calling this, prompt the user to enter the code they received
  /// and call ``verifyMagicCode(email:code:)``.
  ///
  /// - Parameter email: The email address to send the code to
  /// - Throws: If sending fails
  public func sendMagicCode(to email: String) async throws {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Sending magic code to: \(email)")
    try await client.authManager.sendMagicCode(email: email)
    logger.info("Magic code sent to: \(email)")
  }
  
  /// Verifies a magic code and signs in the user.
  ///
  /// - Parameters:
  ///   - email: The email address the code was sent to
  ///   - code: The code the user received
  /// - Returns: The authenticated user
  /// - Throws: If verification fails
  @discardableResult
  public func verifyMagicCode(email: String, code: String) async throws -> User {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Verifying magic code for: \(email)")
    let user = try await client.authManager.signInWithMagicCode(email: email, code: code)
    logger.info("Signed in with magic code: \(user.email ?? "unknown")")
    return user
  }
  
  // MARK: - OAuth
  
  /// Signs in with an OAuth code.
  ///
  /// Use this after completing an OAuth flow to exchange the code for a token.
  ///
  /// - Parameters:
  ///   - code: The OAuth authorization code
  ///   - codeVerifier: Optional PKCE code verifier
  /// - Returns: The authenticated user
  /// - Throws: If sign-in fails
  @discardableResult
  public func signInWithOAuth(code: String, codeVerifier: String? = nil) async throws -> User {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Signing in with OAuth code")
    let user = try await client.authManager.signInWithOAuth(code: code, codeVerifier: codeVerifier)
    logger.info("Signed in with OAuth: \(user.email ?? "unknown")")
    return user
  }
  
  /// Signs in with an ID token from a native OAuth provider.
  ///
  /// Use this for native sign-in flows like Sign in with Apple or Google.
  ///
  /// - Parameters:
  ///   - clientName: The OAuth client name (e.g., "apple", "google")
  ///   - idToken: The ID token from the provider
  ///   - nonce: Optional nonce for verification
  /// - Returns: The authenticated user
  /// - Throws: If sign-in fails
  @discardableResult
  public func signInWithIdToken(
    clientName: String,
    idToken: String,
    nonce: String? = nil
  ) async throws -> User {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Signing in with ID token from: \(clientName)")
    let user = try await client.authManager.signInWithIdToken(
      clientName: clientName,
      idToken: idToken,
      nonce: nonce
    )
    logger.info("Signed in with \(clientName): \(user.email ?? "unknown")")
    return user
  }
  
  #if canImport(AuthenticationServices)
  /// Signs in with Apple using the native Sign in with Apple flow.
  ///
  /// This handles the entire Sign in with Apple flow, including presenting
  /// the authorization UI.
  ///
  /// - Parameter presentationAnchor: The window to present the sign-in UI in
  /// - Returns: The authenticated user
  /// - Throws: If sign-in fails or is cancelled
  @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
  @discardableResult
  public func signInWithApple(presentationAnchor: ASPresentationAnchor) async throws -> User {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Starting Sign in with Apple flow")
    
    let appleSignIn = SignInWithApple()
    let (idToken, nonce) = try await appleSignIn.signIn(presentationAnchor: presentationAnchor)
    
    let user = try await client.authManager.signInWithIdToken(
      clientName: "apple",
      idToken: idToken,
      nonce: nonce
    )
    
    logger.info("Signed in with Apple: \(user.email ?? "unknown")")
    return user
  }
  #endif
  
  // MARK: - Sign Out
  
  /// Signs out the current user.
  ///
  /// After signing out, the state will be `.unauthenticated`.
  ///
  /// - Throws: If sign-out fails
  public func signOut() async throws {
    guard let client = client else {
      throw InstantError.notConnected
    }
    
    logger.info("Signing out")
    try await client.authManager.signOut()
    logger.info("Signed out successfully")
  }
}

// MARK: - Environment Key

#if canImport(SwiftUI)
/// Environment key for accessing InstantAuth
private struct InstantAuthKey: EnvironmentKey {
  static let defaultValue: InstantAuth? = nil
}

extension EnvironmentValues {
  /// The InstantAuth coordinator for the current environment.
  ///
  /// Use this to access authentication state and methods from any view.
  ///
  /// ```swift
  /// struct MyView: View {
  ///   @Environment(\.instantAuth) private var auth
  ///
  ///   var body: some View {
  ///     if let auth = auth, auth.isSignedIn {
  ///       Text("Welcome!")
  ///     }
  ///   }
  /// }
  /// ```
  public var instantAuth: InstantAuth? {
    get { self[InstantAuthKey.self] }
    set { self[InstantAuthKey.self] = newValue }
  }
}

extension View {
  /// Provides an InstantAuth coordinator to the view hierarchy.
  ///
  /// ```swift
  /// @main
  /// struct MyApp: App {
  ///   @StateObject private var auth = InstantAuth()
  ///
  ///   var body: some Scene {
  ///     WindowGroup {
  ///       ContentView()
  ///         .instantAuth(auth)
  ///     }
  ///   }
  /// }
  /// ```
  public func instantAuth(_ auth: InstantAuth) -> some View {
    environment(\.instantAuth, auth)
  }
}
#endif

// MARK: - SharedKey for Auth State

extension SharedReaderKey {
  /// A key that provides the current authentication state.
  ///
  /// Use this to reactively observe authentication state changes.
  ///
  /// ```swift
  /// @SharedReader(.instantAuthState())
  /// private var authState: AuthState
  ///
  /// var body: some View {
  ///   if authState.isSignedIn {
  ///     Text("Welcome, \(authState.user?.email ?? "Guest")!")
  ///   }
  /// }
  /// ```
  public static func instantAuthState(
    appID: String? = nil
  ) -> Self where Self == InstantAuthStateKey.Default {
    Self[InstantAuthStateKey(appID: appID), default: .loading]
  }
}

/// A SharedReaderKey for observing authentication state.
public struct InstantAuthStateKey: SharedKey {
  public typealias Value = AuthState
  
  let appID: String
  
  public var id: String {
    "auth-\(appID)"
  }
  
  init(appID: String?) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
  }
  
  public func load(
    context: LoadContext<Value>,
    continuation: LoadContinuation<Value>
  ) {
    Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      continuation.resume(returning: client.authManager.state)
    }
  }
  
  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      
      var cancellable: AnyCancellable?
      cancellable = client.authManager.$state
        .sink { state in
          subscriber.yield(state)
        }
      
      // Keep subscription alive
      try? await Task.sleep(nanoseconds: .max)
      cancellable?.cancel()
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
    // Auth state is read-only through this key
    continuation.resume()
  }
}

#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

