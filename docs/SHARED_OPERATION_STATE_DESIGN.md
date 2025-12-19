# @Shared Operation State Design

## Overview

This document outlines the design for consistent operation state handling across all `@Shared` types in SharingInstant: Auth, Presence, Topics, and Sync.

## Design Principles

1. **All state in the @Shared value** - No local `@State` for loading/error
2. **Consistent status model** - Same `OperationStatus` enum everywhere
3. **Convenience accessors** - `isLoading`, `isError`, `isSuccess`, etc.
4. **Methods on projected value** - `$auth.signInAsGuest()`, `$channel.publish()`
5. **Optional callbacks** - For when you need to react to completion
6. **Error always accessible** - `value.error`, not just in callbacks

---

## Callback Model (Inspired by React Query's useMutation)

React Query's `useMutation` provides four callbacks that cover the full lifecycle of an async operation:

| Callback | When It Fires | Use Case |
|----------|---------------|----------|
| `onMutate` | **BEFORE** the operation starts | Optimistic updates, local animations |
| `onSuccess` | After operation **succeeds** | Show success toast, navigate away |
| `onError` | After operation **fails** | Show error toast, rollback optimistic update |
| `onSettled` | After success **OR** error (like `finally`) | Reset form, cleanup |

### Swift Naming

We'll use slightly more descriptive Swift names:

| React Query | Swift Name | Description |
|-------------|------------|-------------|
| `onMutate` | `onAttempt` | Called immediately when operation starts |
| `onSuccess` | `onSuccess` | Called when operation succeeds remotely |
| `onError` | `onError` | Called when operation fails |
| `onSettled` | `onSettled` | Called after success or error (always runs) |

### Why `onAttempt` Matters

Even for auth operations like `signInAsGuest()`, optimistic/immediate callbacks are useful:

```swift
// Example: Navigate optimistically before server confirms
$auth.signInAsGuest(
  onAttempt: {
    // Immediately show the next screen with a loading indicator
    // This feels faster to the user
    navigationPath.append(.home)
  },
  onSuccess: { user in
    // Server confirmed, update UI with actual user data
    print("Signed in as \(user.id)")
  },
  onError: { error in
    // Oops, go back and show error
    navigationPath.removeLast()
    showError(error)
  }
)
```

### `onSettled` for Cleanup

```swift
$auth.sendMagicCode(
  to: email,
  onSettled: { result in
    // Always runs - good for cleanup
    // result is Result<Data?, Error>
    isFormEnabled = true
    dismissKeyboard()
  }
)
```

---

## OperationStatus Enum (Shared)

```swift
/// The status of an async operation.
///
/// Used consistently across Auth, Topics, Sync, and Presence
/// to track the state of in-flight operations.
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

---

## 1. AuthSession

### Type Definition

```swift
public struct AuthSession: Sendable, Equatable {
  // Core state (from server subscription)
  public var state: AuthState
  
  // Operation state (for sign-in/sign-out operations)
  public var operationStatus: OperationStatus
  public var error: (any Error)?
  
  // Convenience accessors
  public var isLoading: Bool { operationStatus == .pending }
  public var isError: Bool { error != nil }
  public var isSuccess: Bool { operationStatus == .success }
  public var isIdle: Bool { operationStatus == .idle }
  
  public var user: User? { state.user }
  public var isSignedIn: Bool { state.isSignedIn }
  public var isAuthenticated: Bool { state.isAuthenticated }
  public var isGuest: Bool { state.isGuest }
}
```

### Methods (Full Callback API)

```swift
extension Shared where Value == AuthSession {
  /// Signs in as a guest user.
  ///
  /// - Parameters:
  ///   - onAttempt: Called immediately when sign-in starts (optimistic)
  ///   - onSuccess: Called when sign-in succeeds with the User
  ///   - onError: Called if sign-in fails with the error
  ///   - onSettled: Called after success or error (always runs)
  func signInAsGuest(
    onAttempt: (() -> Void)? = nil,
    onSuccess: ((User) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil,
    onSettled: ((Result<User, any Error>) -> Void)? = nil
  )
  
  /// Sends a magic code to the given email.
  func sendMagicCode(
    to email: String,
    onAttempt: (() -> Void)? = nil,
    onSuccess: ((SendMagicCodeResponse) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil,
    onSettled: ((Result<SendMagicCodeResponse, any Error>) -> Void)? = nil
  )
  
  /// Verifies a magic code.
  func verifyMagicCode(
    email: String,
    code: String,
    onAttempt: (() -> Void)? = nil,
    onSuccess: ((User) -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil,
    onSettled: ((Result<User, any Error>) -> Void)? = nil
  )
  
  /// Signs out the current user.
  func signOut(
    onAttempt: (() -> Void)? = nil,
    onSuccess: (() -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil,
    onSettled: ((Result<Void, any Error>) -> Void)? = nil
  )
  
  /// Clears any error and resets status to idle.
  func reset()
}
```

### Usage Examples

```swift
@Shared(.instantAuth) private var auth: AuthSession

var body: some View {
  VStack {
    // Read state reactively
    switch auth.state {
    case .loading:
      ProgressView("Loading...")
    case .unauthenticated:
      signInButton
    case .guest(let user):
      Text("Welcome, Guest \(user.id)")
    case .authenticated(let user):
      Text("Welcome, \(user.email ?? "User")")
    }
    
    // Show operation-specific loading
    if auth.isLoading {
      ProgressView()
    }
    
    // Show errors
    if let error = auth.error {
      Text("Error: \(error.localizedDescription)")
        .foregroundStyle(.red)
      Button("Dismiss") { $auth.reset() }
    }
  }
}

var signInButton: some View {
  Button("Sign In as Guest") {
    $auth.signInAsGuest()
    // That's it! UI updates automatically via auth.state
  }
  .disabled(auth.isLoading)
}
```

---

## 2. TopicChannel

### Type Definition

```swift
public struct TopicChannel<T: Codable & Sendable & Equatable>: Sendable, Equatable {
  // Core state (from server subscription)
  public var latestEvent: TopicEvent<T>?
  public var isConnected: Bool
  
  // Operation state (for publish operations)
  public var publishStatus: OperationStatus
  public var error: (any Error)?
  
  // Connection state
  public var isLoading: Bool  // Still connecting
  
  // Convenience accessors
  public var isPublishing: Bool { publishStatus == .pending }
  public var isError: Bool { error != nil }
  public var hasEvent: Bool { latestEvent != nil }
}
```

### Methods (Full Callback API)

```swift
extension Shared where Value: TopicChannelProtocol {
  /// Publishes a payload to the topic.
  ///
  /// - Parameters:
  ///   - payload: The data to publish
  ///   - onAttempt: Called immediately with the payload (for optimistic UI)
  ///   - onSuccess: Called when publish is confirmed by server
  ///   - onError: Called if publish fails
  ///   - onSettled: Called after success or error
  func publish(
    _ payload: Value.Payload,
    onAttempt: ((Value.Payload) -> Void)? = nil,
    onSuccess: (() -> Void)? = nil,
    onError: ((any Error) -> Void)? = nil,
    onSettled: ((Result<Void, any Error>) -> Void)? = nil
  )
  
  /// Clears any error and resets publishStatus to idle.
  func reset()
}
```

### Usage Examples

```swift
@Shared(.instantTopic(Schema.Topics.emoji, roomId: "demo-123"))
private var channel: TopicChannel<EmojiTopic>

// Publish with optimistic animation
$channel.publish(EmojiPayload(emoji: "🎉")) { payload in
  // onAttempt: Called immediately
  animateEmoji(payload.emoji)
} onError: { error in
  // onError: Called if publish fails
  showToast("Failed to send emoji")
}

// Show connection errors
if let error = channel.error {
  Text("Topic error: \(error.localizedDescription)")
}
```

---

## 3. RoomPresence

### Type Definition

```swift
public struct RoomPresence<T: Codable & Sendable & Equatable>: Sendable, Equatable {
  // Core state (from server subscription)
  public var user: T
  public var peers: IdentifiedArrayOf<Peer<T>>
  
  // Connection state
  public var isLoading: Bool
  public var isConnected: Bool
  public var error: (any Error)?
  
  // Convenience accessors
  public var isError: Bool { error != nil }
  public var totalCount: Int { 1 + peers.count }
  public var hasPeers: Bool { !peers.isEmpty }
}
```

### Methods

Presence uses `withLock` for mutations (already implemented):

```swift
$presence.withLock { state in
  state.user.isTyping = true
}
```

### Usage

```swift
@Shared(.instantPresence(Schema.Rooms.chat, roomId: "demo-123", initialPresence: ...))
private var presence: RoomPresence<ChatPresence>

// Read state
let myName = presence.user.name
for peer in presence.peers { ... }
if presence.isLoading { ... }
if let error = presence.error { ... }

// Mutate
$presence.withLock { $0.user.isTyping = true }
```

---

## 4. Sync (IdentifiedArrayOf<T>)

Sync already works via `@Shared(Schema.todos)`. Operation state could be added:

### Enhanced Type (Optional)

```swift
// Could wrap the array with metadata
public struct SyncedCollection<T: EntityIdentifiable>: Sendable, Equatable {
  public var items: IdentifiedArrayOf<T>
  public var isLoading: Bool
  public var isSyncing: Bool  // Has pending changes
  public var error: (any Error)?
  public var lastSyncedAt: Date?
}
```

This is more complex and may not be needed initially.

---

## Comparison Table

| Type | Read | Mutate | Methods | Status |
|------|------|--------|---------|--------|
| `AuthSession` | `auth.state`, `auth.user` | N/A | `$auth.signInAsGuest()` | `operationStatus` |
| `TopicChannel<T>` | `channel.latestEvent` | N/A | `$channel.publish()` | `publishStatus` |
| `RoomPresence<T>` | `presence.user`, `presence.peers` | `$presence.withLock {}` | N/A | `isLoading` |
| `IdentifiedArrayOf<T>` | `todos[id]`, `todos.count` | `$todos.withLock {}` | N/A | (TBD) |

---

## Implementation Priority

1. **AuthSession** - Most impactful, replaces `@StateObject InstantAuth()`
2. **TopicChannel error state** - Quick win, add error tracking to existing type
3. **RoomPresence error state** - Already has `error`, ensure consistency
4. **Sync operation state** - Lower priority, current API works well

---

## Callback Execution Guarantees

### Thread Safety

All callbacks are `@MainActor` since they typically update UI:

```swift
func signInAsGuest(
  onAttempt: (@MainActor () -> Void)? = nil,
  onSuccess: (@MainActor (User) -> Void)? = nil,
  onError: (@MainActor (any Error) -> Void)? = nil,
  onSettled: (@MainActor (Result<User, any Error>) -> Void)? = nil
)
```

### Execution Order

1. `onAttempt` - Called synchronously, immediately when method is invoked
2. `onSuccess` OR `onError` - Called when operation completes (mutually exclusive)
3. `onSettled` - Always called last, after success or error

### Error State Persistence

- Error is stored in the value (`auth.error`, `channel.error`)
- Error persists until:
  - Next successful operation clears it
  - Explicit `$auth.reset()` / `$channel.reset()` is called
- This allows error UI to remain visible until user dismisses or retries

---

## Open Questions

1. **Should `OperationStatus` include the operation type?**
   ```swift
   enum OperationStatus {
     case idle
     case pending(operation: String)  // "signInAsGuest", "publish", etc.
     case success
     case error
   }
   ```
   
   **Thought:** Probably not needed. If you need to know which operation is pending,
   you can track that separately. Keeping `OperationStatus` simple is better.

2. **How to handle concurrent operations?**
   - Auth: Only one operation at a time (disable buttons via `isLoading`)
   - Topics: Multiple publishes could be in flight - track per-publish or just latest?
   - Presence: Continuous updates, no explicit operations

3. **Should we provide `mutateAsync` equivalent?**
   
   React Query provides both `mutate()` (callbacks) and `mutateAsync()` (async/await).
   We could provide both:
   
   ```swift
   // Callback style (recommended for UI)
   $auth.signInAsGuest(onSuccess: { user in ... })
   
   // Async style (for composition)
   let user = try await $auth.signInAsGuestAsync()
   ```
   
   **Thought:** Start with callback style only. Async can be added later if needed.

4. **Should callbacks receive the context/variables?**
   
   React Query passes `variables` to all callbacks. For us:
   
   ```swift
   // Could pass the email to callbacks
   $auth.sendMagicCode(to: email, onSuccess: { response, email in ... })
   ```
   
   **Thought:** Not needed for most cases. The caller already has the variables
   in scope. Keep callbacks simple.

---

## Migration Path

### Before (Old Pattern)

```swift
struct AuthDemo: View {
  @StateObject private var auth = InstantAuth()
  @State private var isLoading = false
  @State private var error: String?
  
  var body: some View {
    Button("Sign In") {
      isLoading = true
      Task {
        do {
          try await auth.signInAsGuest()
          // Navigate on success
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

### After (New Pattern)

```swift
struct AuthDemo: View {
  @Shared(.instantAuth) private var auth: AuthSession
  
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

**Key Improvements:**
- No `@State` for loading/error
- No `Task { }` / `async/await` at call site
- State flows reactively through `@Shared`
- Callbacks available when needed, but optional
