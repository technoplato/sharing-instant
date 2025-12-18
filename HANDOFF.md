# SharingInstant Handoff Document

## Status: Core Sync Working ✅ | Presence & Auth Need Work 🚧

**Date**: December 17, 2025  
**Main Plan**: `.cursor/plans/sharinginstant_library_bed8ba6c.plan.md`

---

## What's Done

SharingInstant is a Swift Sharing wrapper around InstantDB's iOS SDK. The core sync functionality is **complete and working**:

### ✅ Working Features

1. **Bidirectional Sync** (`@Shared(.instantSync(...))`)
   - Real-time subscription to InstantDB collections
   - Optimistic updates with automatic sync
   - Uses `TransactionChunk` API for proper attribute UUID resolution
   - Client caching by appID for connection reuse

2. **Read-Only Queries** (`@SharedReader(.instantQuery(...))`)
   - One-way subscription for read-only data

3. **Dynamic Filtering**
   - Local filtering on shared state
   - Search and filter demos working

4. **Schema Codegen** (complete)
   - TypeScript → Swift generation
   - Swift → TypeScript generation
   - SPM build plugin

5. **Example App** (CaseStudies)
   - SwiftUI Sync Demo
   - Dynamic Filter Demo
   - Observable Model Demo
   - iOS, macOS, tvOS, watchOS support

### 📍 Key Files

| File | Purpose |
|------|---------|
| `sharing-instant/Sources/SharingInstant/InstantSyncKey.swift` | Main sync implementation |
| `sharing-instant/Sources/SharingInstant/DefaultInstant.swift` | Client factory with caching |
| `sharing-instant/Examples/CaseStudies/` | Demo app |
| `instant-ios-sdk/Sources/InstantDB/Presence/PresenceManager.swift` | Presence (needs integration) |
| `instant-ios-sdk/Sources/InstantDB/Auth/AuthManager.swift` | Auth (needs ergonomic wrapper) |

---

## What Needs Work

### 🚧 1. Presence Integration (HIGH PRIORITY)

**Problem**: `PresenceManager` exists in `instant-ios-sdk` but is NOT wired up to `InstantClient`.

**Location**: `instant-ios-sdk/Sources/InstantDB/Presence/PresenceManager.swift`

**Current State**:
- `PresenceManager` is a complete implementation (596 lines)
- Has `sendMessage` callback that needs to be connected to WebSocket
- Handles: `joinRoom`, `leaveRoom`, `publishPresence`, `subscribePresence`, `publishTopic`, `subscribeTopic`
- Server message handlers: `handleJoinRoomOk`, `handleRefreshPresence`, `handlePatchPresence`, `handleServerBroadcast`, `handleRoomError`

**What Needs to Be Done**:

1. **In `InstantClient.swift`**:
   ```swift
   // Add property
   public let presence: PresenceManager
   
   // In init():
   self.presence = PresenceManager()
   presence.sendMessage = { [weak self] id, message in
     self?.connection.send(message)
   }
   
   // In setupMessageHandlers():
   messageHandlers["join-room-ok"] = { [weak self] message in
     guard let roomId = message.data?["room-id"] as? String else { return }
     self?.presence.handleJoinRoomOk(roomId: roomId, data: message.data)
   }
   // ... similar for refresh-presence, patch-presence, server-broadcast, room-error
   
   // Update sessionID when received:
   // In handleInitOk:
   presence.sessionId = sessionID
   
   // On reconnect:
   // Call presence.resendRoomJoins()
   ```

2. **Create SharingInstant wrappers** (in `sharing-instant/Sources/SharingInstant/`):
   ```swift
   // InstantPresenceKey.swift - for @Shared presence state
   // InstantRoomKey.swift - for room management
   ```

**React API to Port** (from user's examples):

```typescript
// React patterns we need Swift equivalents for:
const room = db.room('room-type', 'room-id');

// Presence
db.rooms.useSyncPresence(room, { name: userId, color: randomColor });
const presence = db.rooms.usePresence(room);
// presence.user - your presence
// presence.peers - others' presence

// Topics (ephemeral events)
const publishEmoji = db.rooms.usePublishTopic(room, 'emoji');
db.rooms.useTopicEffect(room, 'emoji', (data) => { /* handle */ });

// Typing indicators
const { active, inputProps } = db.rooms.useTypingIndicator(room, 'chat-input');

// Cursors (built-in component)
<Cursors room={room} userCursorColor={color} />
```

**Desired Swift API**:

```swift
// Option A: Property wrapper approach
@SharedPresence(room: "document-123")
private var presence: PresenceSlice

// Option B: Explicit subscription
let room = InstantRoom(type: "cursors", id: "123")
room.syncPresence(["name": "Alice", "color": "#ff0000"])
let unsub = room.subscribePresence { slice in
  print("Me: \(slice.user)")
  print("Peers: \(slice.peers)")
}

// Topics
room.publishTopic("emoji", data: ["name": "fire"])
room.subscribeTopic("emoji") { message in
  animateEmoji(message.data)
}

// SwiftUI View for cursors (like React's <Cursors>)
CursorsView(room: room, userColor: .random)
```

---

### 🚧 2. Authentication Story (HIGH PRIORITY)

**Problem**: Current auth API is imperative and verbose. Need ergonomic Swift Sharing integration.

**Current API** (from `InstantDBViewModel.swift` - "gross"):

```swift
@EnvironmentObject var authManager: AuthManager
@StateObject private var viewModel = InstantDBViewModel()

// Manual setup
viewModel.setup(db: db, authManager: authManager)

// Manual state observation
authManager.$state
  .sink { state in
    switch state {
    case .loading: // ...
    case .unauthenticated: // ...
    case .guest(let user): // ...
    case .authenticated(let user): // ...
    }
  }

// Manual sign-in flow
let appleSignIn = SignInWithApple()
let (idToken, nonce) = try await appleSignIn.signIn(presentationAnchor: window)
try await authManager.signInWithIdToken(
  clientName: "apple",
  idToken: idToken,
  nonce: nonce
)
```

**Available Auth Methods** (from `AuthManager.swift`):

| Method | Description |
|--------|-------------|
| `signInAsGuest()` | Anonymous guest user |
| `sendMagicCode(email:)` | Send email magic code |
| `signInWithMagicCode(email:code:)` | Verify magic code |
| `signInWithOAuth(code:codeVerifier:)` | OAuth code exchange |
| `signInWithIdToken(clientName:idToken:nonce:)` | Native OAuth (Apple, Google) |
| `signOut()` | Sign out |

**AuthState** (from `AuthState.swift`):

```swift
public enum AuthState: Equatable {
  case loading
  case guest(User)
  case authenticated(User)
  case unauthenticated
  
  var user: User?
  var isSignedIn: Bool
  var isAuthenticated: Bool
  var isGuest: Bool
}
```

**Desired Swift API**:

```swift
// Option A: @SharedAuth property wrapper
struct ContentView: View {
  @SharedAuth private var auth: InstantAuth
  
  var body: some View {
    switch auth.state {
    case .loading:
      ProgressView()
    case .unauthenticated:
      LoginView()
    case .guest(let user):
      GuestBanner(user: user)
      MainContent()
    case .authenticated(let user):
      UserBadge(user: user)
      MainContent()
    }
  }
}

// Option B: Environment-based (like SwiftUI's auth)
@Environment(\.instantAuth) private var auth

// Clean sign-in API
Button("Sign in with Apple") {
  await auth.signInWithApple()  // Handles window anchor internally
}

Button("Sign in with Email") {
  await auth.sendMagicCode(to: email)
  // Then in another view:
  await auth.verifyMagicCode(email: email, code: code)
}

// Sign out
Button("Sign Out") {
  await auth.signOut()
}

// Reactive user info
if let user = auth.user {
  Text("Hello, \(user.email ?? "Guest")")
}
```

**Option C: Declarative Auth View (like React's pattern)**:

```swift
// Similar to how React InstantDB does it
InstantAuthView { state in
  switch state {
  case .loading:
    ProgressView()
  case .unauthenticated:
    // Show login options
    SignInWithAppleButton { result in
      // Handled automatically
    }
    MagicCodeForm()
  case .signedIn(let user):
    MainContent()
  }
}
```

---

## Implementation Guidance

### For Presence Integration

1. **Start with `InstantClient.swift`** (`instant-ios-sdk/Sources/InstantDB/Core/InstantClient.swift`)
   - Add `public let presence: PresenceManager` property
   - Wire up `sendMessage` callback in `init()`
   - Add message handlers for room operations

2. **Study the React implementation**:
   - `instant/client/packages/react/src/index.ts` - `usePresence`, `useSyncPresence`, `useTopicEffect`
   - `instant/client/packages/core/src/Reactor.js` - Lines 2136-2339 (presence handling)

3. **Create SharingInstant wrappers**:
   - `InstantPresenceKey.swift` - SharedKey for presence state
   - `InstantRoom.swift` - Room abstraction
   - `CursorsView.swift` - SwiftUI cursor overlay

### For Authentication

1. **Study Point-Free patterns**:
   - Look at how `swift-sharing` handles async state
   - Consider `@Shared` for auth state

2. **Create ergonomic wrappers**:
   - `InstantAuth.swift` - Main auth coordinator
   - `SignInWithAppleButton.swift` - One-tap Apple sign-in
   - `MagicCodeView.swift` - Email magic code flow

3. **Environment integration**:
   - `InstantAuthEnvironmentKey` - For `@Environment(\.instantAuth)`

---

## Test App

- **App ID**: `b9319949-2f2d-410b-8f8a-6990177c1d44`
- **App Name**: `test_sharing-instant`
- **Dashboard**: https://www.instantdb.com/dash?app=b9319949-2f2d-410b-8f8a-6990177c1d44
- **Admin Key**: `10c2aaea-5942-4e64-b105-3db598c14409`

---

## Running Tests

```bash
# instant-ios-sdk tests (42 tests)
cd instant-ios-sdk
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-swift-testing

# sharing-instant tests (17 tests)
cd sharing-instant
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-swift-testing

# Run example app
cd sharing-instant/Examples
open -a Xcode Examples.xcodeproj
```

---

## Quality Standards

Follow Point-Free standards:
- Every public API has doc comments with examples
- Use `/// - Note:`, `/// - Warning:`, `/// - Important:` markers
- Include "See Also" references
- Comprehensive error handling
- Type-safe APIs (no stringly-typed parameters where possible)

---

## Commits

Make frequent, focused commits with detailed messages:

```
feat(presence): Wire up PresenceManager to InstantClient

- Add presence property to InstantClient
- Connect sendMessage callback to WebSocket
- Add message handlers for join-room-ok, refresh-presence, etc.
- Update sessionId on init-ok
- Call resendRoomJoins on reconnect

Tested: Manual verification with presence subscription
```

---

## Questions?

The main plan document has extensive context:
`.cursor/plans/sharinginstant_library_bed8ba6c.plan.md`

Key sections:
- Phase 1.6: Presence System (lines ~438-470)
- React API examples in user's original message
- Testing strategy

---

## Summary of Next Steps

1. **Presence** (modify `instant-ios-sdk`):
   - Wire `PresenceManager` to `InstantClient`
   - Handle all room-related server messages
   - Test with manual subscription

2. **Presence** (create in `sharing-instant`):
   - `InstantPresenceKey` for `@Shared` integration
   - `InstantRoom` abstraction
   - `CursorsView` SwiftUI component

3. **Auth** (create in `sharing-instant`):
   - `InstantAuth` coordinator
   - `@SharedAuth` or `@Environment` integration
   - `SignInWithAppleButton` component
   - `MagicCodeView` component

4. **Examples**:
   - Cursors demo
   - Typing indicator demo
   - Avatar stack demo
   - Emoji reactions (topics) demo
   - Tile game demo
   - Auth flow demo


