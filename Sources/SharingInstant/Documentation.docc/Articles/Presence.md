# Real-Time Presence

Share ephemeral user state like "who's online" or "who's typing" using type-safe presence.

## Overview

Presence allows you to share ephemeral state between users in a room. Unlike data sync, presence is:
- **Ephemeral**: Not persisted to the database
- **Per-session**: Each browser tab/device has its own presence
- **Real-time**: Updates propagate instantly to all peers

Common use cases include:
- Avatar stacks showing who's online
- Typing indicators
- Cursor positions
- User activity status

## Defining Presence in Your Schema

Define rooms with presence shapes in your `instant.schema.ts`:

```typescript
const _schema = i.schema({
  entities: { /* ... */ },
  rooms: {
    chat: {
      presence: i.entity({
        name: i.string(),
        color: i.string(),
        isTyping: i.boolean(),
      }),
    },
    cursors: {
      presence: i.entity({
        name: i.string(),
        cursorX: i.number(),
        cursorY: i.number(),
      }),
    },
  },
});
```

The schema codegen generates type-safe Swift types:

```swift
// Generated: ChatPresence, CursorsPresence structs
// Generated: Schema.Rooms.chat, Schema.Rooms.cursors keys
```

## Subscribing to Presence

Use `@Shared(.instantPresence(...))` to subscribe to presence in a room:

```swift
struct ChatView: View {
  @Shared(.instantPresence(
    Schema.Rooms.chat,
    roomId: "room-123",
    initialPresence: ChatPresence(name: "Alice", color: "#FF0000", isTyping: false)
  ))
  var presence: RoomPresence<ChatPresence>
  
  var body: some View {
    VStack {
      // Your presence
      Text("You: \(presence.user.name)")
      
      // Peer presence
      ForEach(presence.peers) { peer in
        Text("\(peer.data.name): \(peer.data.isTyping ? "typing..." : "idle")")
      }
    }
  }
}
```

## Updating Your Presence

Update your presence using `withLock`:

```swift
// Update typing status
$presence.withLock { state in
  state.user.isTyping = true
}

// Update cursor position
$presence.withLock { state in
  state.user.cursorX = location.x
  state.user.cursorY = location.y
}
```

The update is automatically published to all peers in the room.

## RoomPresence Properties

The `RoomPresence<T>` type provides:

| Property | Type | Description |
|----------|------|-------------|
| `user` | `T` | Your own presence data |
| `peers` | `IdentifiedArrayOf<Peer<T>>` | All other users' presence |
| `isLoading` | `Bool` | Whether still connecting |
| `error` | `(any Error)?` | Connection error if any |
| `totalCount` | `Int` | Total users (you + peers) |
| `hasPeers` | `Bool` | Whether anyone else is in the room |

## Example: Avatar Stack

```swift
struct AvatarStack: View {
  @Shared(.instantPresence(
    Schema.Rooms.avatars,
    roomId: "demo",
    initialPresence: AvatarsPresence(name: myName, color: myColor)
  ))
  var presence: RoomPresence<AvatarsPresence>
  
  var body: some View {
    HStack(spacing: -12) {
      // Your avatar
      Avatar(name: presence.user.name, color: presence.user.color)
        .overlay(Badge("You"))
      
      // Peer avatars
      ForEach(presence.peers) { peer in
        Avatar(name: peer.data.name, color: peer.data.color)
      }
    }
  }
}
```

## Example: Typing Indicator

```swift
struct TypingIndicator: View {
  @Shared(.instantPresence(
    Schema.Rooms.chat,
    roomId: roomId,
    initialPresence: ChatPresence(name: myName, color: myColor, isTyping: false)
  ))
  var presence: RoomPresence<ChatPresence>
  
  @State private var message = ""
  
  var body: some View {
    VStack {
      // Show who's typing
      let typers = presence.peers.filter { $0.data.isTyping }
      if !typers.isEmpty {
        Text(typingText(for: typers))
          .font(.caption)
      }
      
      // Input field
      TextField("Message", text: $message)
        .onChange(of: message) { _, newValue in
          $presence.withLock { $0.user.isTyping = !newValue.isEmpty }
        }
    }
  }
  
  func typingText(for typers: [Peer<ChatPresence>]) -> String {
    switch typers.count {
    case 1: return "\(typers[0].data.name) is typing..."
    case 2: return "\(typers[0].data.name) and \(typers[1].data.name) are typing..."
    default: return "\(typers[0].data.name) and \(typers.count - 1) others are typing..."
    }
  }
}
```

## Without Schema Codegen

If you're not using schema codegen, you can define presence types manually:

```swift
struct MyPresence: Codable, Sendable, Equatable {
  var name: String
  var status: String
}

@Shared(.instantPresence(
  roomType: "my-room",
  roomId: "room-123",
  initialPresence: MyPresence(name: "Alice", status: "online")
))
var presence: RoomPresence<MyPresence>
```

## See Also

- ``RoomPresence``
- ``Peer``
- ``RoomKey``
- <doc:Topics>







