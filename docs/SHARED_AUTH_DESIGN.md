# @Shared Auth API Design

## Overview

This document outlines the design for `@Shared(.instantAuth)` - a declarative, reactive authentication API that follows the same patterns as presence and topics.

## Goals

1. **Consistency** - Same `@Shared` pattern as presence, topics, and sync
2. **No local state management** - All state lives in `AuthSession`
3. **Reactive** - UI automatically updates when auth state changes
4. **Ergonomic** - Simple method calls, optional callbacks
5. **Type-safe** - Full Swift type safety throughout

## Current Pattern (What We're Replacing)

```swift
// Old: Uses @StateObject, requires local state management
struct AuthDemo: View {
  @StateObject private var auth = InstantAuth()
  @State private var isLoading = false  // ❌ Local state
  @State private var error: String?     // ❌ Local state
  
  var body: some View {
    Button("Sign In") {
      isLoading = true
      Task {
        do {
          try await auth.signInAsGuest()
        } catch {
          self.error = error.localizedDescription
        }
        isLoading = false
      }
    }
    .disabled(isLoading)
  }
}
```

## New Pattern

```swift
// New: Uses @Shared, all state in AuthSession
struct AuthDemo: View {
  @Shared(.instantAuth)
  private var auth: AuthSession
  
  var body: some View {
    Button("Sign In") {
      $auth.signInAsGuest()
    }
    .disabled(auth.isLoading)
    
    if let error = auth.error {
      Text(error.localizedDescription)
    }
  }
}
```

## AuthSession Type

```swift
/// The complete authentication state for an InstantDB app.
///
/// This type is returned by `@Shared(.instantAuth)` and contains
/// the authentication state, operation status, and any errors.
public struct AuthSession: Sendable, Equatable {
  
  // MARK: - Core Auth State
  
  /// The current authentication state from the server.
  ///
  /// This updates automatically when:
  /// - Initial auth check completes
  /// - User signs in (guest, magic code, OAuth, etc.)
  /// - User signs out
  /// - Token refreshes
  public var state: AuthState
  
  // MARK: - Operation State
  
  /// The status of the current/last auth operation.
  ///
  /// Use this to show loading indicators and determine
  /// if an operation is in progress.
  public var operationStatus: OperationStatus
  
  /// The error from the last failed operation, if any.
  ///
  /// This is cleared when a new operation starts.
  public var error: (any Error)?
  
  // MARK: - Convenience Accessors
  
  /// Whether an auth operation is currently in progress.
  ///
  /// Use this to disable buttons during sign-in/sign-out.
  public var isLoading: Bool {
    operationStatus == .pending
  }
  
  /// Whether the last operation resulted in an error.
  public var isError: Bool {
    error != nil
  }
  
  /// Whether the operation completed successfully.
  public var isSuccess: Bool {
    operationStatus == .success
  }
  
  /// Whether no operation has been attempted yet.
  public var isIdle: Bool {
    operationStatus == .idle
  }
  
  /// The current user, if signed in (guest or authenticated).
  public var user: User? {
    state.user
  }
  
  /// Whether a user is signed in (guest or authenticated).
  public var isSignedIn: Bool {
    state.isSignedIn
  }
  
  /// Whether the user is fully authenticated (not guest).
  public var isAuthenticated: Bool {
    state.isAuthenticated
  }
  
  /// Whether the user is a guest.
  public var isGuest: Bool {
    state.isGuest
  }
}

/// The status of an auth operation.
public enum OperationStatus: String, Sendable, Equatable, CaseIterable {
  /// No operation in progress or attempted.
  case idle
  
  /// An operation is currently in progress.
  case pending
  
  /// The last operation completed successfully.
  case success
  
  /// The last operation failed.
  case error
}
```

## Methods on Projected Value

Methods are called on `$auth` (the projected value), not `auth`:

```swift
extension Shared where Value == AuthSession {
  
  // MARK: - Guest Auth
  
  /// Signs in as a guest user.
  ///
  /// Guest users have a unique ID but no email. They can be upgraded
  /// to full accounts later by signing in with email or OAuth.
  ///
  /// - Parameters:
  ///   - onSuccess: Called when sign-in succeeds, with the new User.
  ///   - onError: Called when sign-in fails, with the error.
  ///
  /// ## Example
  ///
  /// ```swift
  /// // Simple - just trigger sign in
  /// $auth.signInAsGuest()
  ///
  /// // With callbacks
  /// $auth.signInAsGuest { user in
  ///   print("Signed in as \(user.id)")
  /// } onError: { error in
  ///   print("Failed: \(error)")
  /// }
  /// ```
  func signInAsGuest(
    onSuccess: ((User) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil
  )
  
  // MARK: - Magic Code Auth
  
  /// Sends a magic code to the specified email address.
  ///
  /// After calling this, prompt the user to enter the code they received
  /// and call `verifyMagicCode(email:code:)`.
  ///
  /// - Parameters:
  ///   - email: The email address to send the code to.
  ///   - onSuccess: Called when the code is sent successfully.
  ///   - onError: Called when sending fails.
  func sendMagicCode(
    to email: String,
    onSuccess: (() -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil
  )
  
  /// Verifies a magic code and signs in the user.
  ///
  /// - Parameters:
  ///   - email: The email address the code was sent to.
  ///   - code: The code the user received.
  ///   - onSuccess: Called when verification succeeds, with the User.
  ///   - onError: Called when verification fails.
  func verifyMagicCode(
    email: String,
    code: String,
    onSuccess: ((User) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil
  )
  
  // MARK: - Sign Out
  
  /// Signs out the current user.
  ///
  /// After signing out, `auth.state` will be `.unauthenticated`.
  ///
  /// - Parameters:
  ///   - onSuccess: Called when sign-out succeeds.
  ///   - onError: Called when sign-out fails.
  func signOut(
    onSuccess: (() -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil
  )
  
  // MARK: - Clear Error
  
  /// Clears the current error state.
  ///
  /// Use this to dismiss error messages.
  func clearError()
}
```

## Usage Examples

### Basic Sign In

```swift
struct LoginView: View {
  @Shared(.instantAuth) private var auth: AuthSession
  
  var body: some View {
    VStack {
      Button("Continue as Guest") {
        $auth.signInAsGuest()
      }
      .disabled(auth.isLoading)
      
      if auth.isLoading {
        ProgressView()
      }
      
      if let error = auth.error {
        HStack {
          Text(error.localizedDescription)
          Button("Dismiss") {
            $auth.clearError()
          }
        }
        .foregroundStyle(.red)
      }
    }
  }
}
```

### Full Auth Flow

```swift
struct AuthDemo: View {
  @Shared(.instantAuth) private var auth: AuthSession
  
  var body: some View {
    switch auth.state {
    case .loading:
      ProgressView("Checking authentication...")
      
    case .unauthenticated:
      LoginView()
      
    case .guest(let user):
      MainContent(user: user, isGuest: true)
      
    case .authenticated(let user):
      MainContent(user: user, isGuest: false)
    }
  }
}

struct MainContent: View {
  let user: User
  let isGuest: Bool
  
  @Shared(.instantAuth) private var auth: AuthSession
  
  var body: some View {
    VStack {
      Text("Welcome, \(user.email ?? "Guest")!")
      
      Button("Sign Out") {
        $auth.signOut()
      }
      .disabled(auth.isLoading)
    }
  }
}
```

### Magic Code Flow

```swift
struct MagicCodeView: View {
  @Shared(.instantAuth) private var auth: AuthSession
  
  @State private var email = ""
  @State private var code = ""
  @State private var codeSent = false
  
  var body: some View {
    VStack {
      if !codeSent {
        // Step 1: Enter email
        TextField("Email", text: $email)
        
        Button("Send Code") {
          $auth.sendMagicCode(to: email) {
            codeSent = true
          }
        }
        .disabled(auth.isLoading || email.isEmpty)
        
      } else {
        // Step 2: Enter code
        TextField("Code", text: $code)
        
        Button("Verify") {
          $auth.verifyMagicCode(email: email, code: code)
        }
        .disabled(auth.isLoading || code.isEmpty)
      }
      
      if auth.isLoading {
        ProgressView()
      }
      
      if let error = auth.error {
        Text(error.localizedDescription)
          .foregroundStyle(.red)
      }
    }
  }
}
```

## Implementation Notes

### SharedKey Implementation

```swift
public struct InstantAuthKey: SharedKey {
  public typealias Value = AuthSession
  
  let appID: String
  
  public var id: String { "auth-\(appID)" }
  
  public func load(...) {
    // Return current auth state from InstantClient
  }
  
  public func subscribe(...) {
    // Subscribe to auth state changes from InstantClient.authManager
  }
  
  public func save(_ value: Value, ...) {
    // Auth state is managed by operations, not direct saves
    // This just resumes the continuation
  }
}
```

### Method Implementation Pattern

```swift
extension Shared where Value == AuthSession {
  func signInAsGuest(
    onSuccess: ((User) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil
  ) {
    // 1. Set operation status to pending
    withLock { $0.operationStatus = .pending; $0.error = nil }
    
    // 2. Get the client and perform the operation
    Task { @MainActor in
      do {
        let client = InstantClientFactory.makeClient(appID: /* from key */)
        let user = try await client.authManager.signInAsGuest()
        
        // 3. Update status on success
        withLock { $0.operationStatus = .success }
        onSuccess?(user)
        
      } catch {
        // 4. Update status on error
        withLock { $0.operationStatus = .error; $0.error = error }
        onError?(error)
      }
    }
  }
}
```

## Consistency with Other @Shared Types

| Type | Read State | Mutate | Methods |
|------|-----------|--------|---------|
| `@Shared(Schema.todos)` | `todos` | `$todos.withLock { ... }` | N/A |
| `@Shared(.instantPresence(...))` | `presence.user`, `presence.peers` | `$presence.withLock { ... }` | N/A |
| `@Shared(.instantTopic(...))` | `channel.latestEvent` | N/A | `$channel.publish(...)` |
| `@Shared(.instantAuth)` | `auth.state`, `auth.user` | N/A | `$auth.signInAsGuest()`, etc. |

## Migration Path

1. Keep `InstantAuth` class for backwards compatibility (deprecated)
2. Add `@Shared(.instantAuth)` as the new recommended API
3. Update all examples to use new pattern
4. Document migration in release notes

## Open Questions

1. **Should `OperationStatus` be shared across all @Shared types?** Could be useful for sync, query, etc.

2. **How to handle Sign in with Apple?** It requires a presentation anchor. Options:
   - Pass anchor as parameter: `$auth.signInWithApple(anchor: window)`
   - Use environment: `@Environment(\.presentationAnchor)`
   - Separate view component (current `InstantSignInWithAppleButton`)

3. **Should callbacks be `@MainActor`?** Probably yes for UI updates.

4. **Should we track which operation is pending?** e.g., `pendingOperation: AuthOperation?` where `AuthOperation` is an enum of all possible operations.






