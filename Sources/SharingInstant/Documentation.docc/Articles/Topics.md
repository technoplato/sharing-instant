# Fire-and-Forget Topics

Broadcast ephemeral events like emoji reactions or notifications using type-safe topics.

## Overview

Topics are fire-and-forget events that don't persist to the database. They're ideal for:
- Emoji reactions
- Sound effects
- Notifications
- Cursor clicks
- Any ephemeral broadcast

Unlike presence (which maintains state), topics are one-shot events that are received by all peers in a room.

## Defining Topics in Your Schema

Define topics within rooms in your `instant.schema.ts`:

```typescript
const _schema = i.schema({
  entities: { /* ... */ },
  rooms: {
    reactions: {
      presence: i.entity({
        name: i.string(),
      }),
      topics: {
        emoji: i.entity({
          name: i.string(),
          directionAngle: i.number(),
          rotationAngle: i.number(),
        }),
        sound: i.entity({
          effect: i.string(),
          volume: i.number(),
        }),
      },
    },
  },
});
```

The schema codegen generates:

```swift
// Generated: EmojiTopic, SoundTopic structs
// Generated: Schema.Topics.emoji, Schema.Topics.sound keys
```

## Subscribing to Topics

Use `@Shared(.instantTopic(...))` to subscribe to topic events:

```swift
struct ReactionsView: View {
  @Shared(.instantTopic(
    Schema.Topics.emoji,
    roomId: "room-123"
  ))
  var emojiChannel: TopicChannel<EmojiTopic>
  
  var body: some View {
    ZStack {
      // Render animations for received events
      ForEach(animations) { animation in
        EmojiAnimation(animation)
      }
    }
    .onChange(of: emojiChannel.latestEvent) { _, event in
      guard let event = event else { return }
      // Handle events from OTHER peers
      animateEmoji(event.data)
    }
  }
}
```

## Publishing Topic Events

Publish events using the `publish` method on the projected value:

```swift
$emojiChannel.publish(
  EmojiTopic(
    name: "fire",
    directionAngle: Double.random(in: 0...1),
    rotationAngle: Double.random(in: 0...1)
  ),
  onAttempt: { payload in
    // Called immediately - handle locally
    animateEmoji(payload)
  },
  onError: { error in
    // Called if publish fails
    showError(error)
  },
  onSettled: {
    // Called when complete (success or failure)
  }
)
```

### Callback Parameters

| Callback | When Called | Use Case |
|----------|-------------|----------|
| `onAttempt` | Immediately, before network | Local/optimistic handling |
| `onError` | If publish fails | Error handling |
| `onSettled` | After completion | Cleanup |

## TopicChannel Properties

The `TopicChannel<T>` type provides:

| Property | Type | Description |
|----------|------|-------------|
| `events` | `[TopicEvent<T>]` | Buffered events from peers |
| `latestEvent` | `TopicEvent<T>?` | Most recent event |
| `isConnected` | `Bool` | Whether connected to room |
| `maxEvents` | `Int` | Buffer size (default 50) |

## TopicEvent Properties

Each `TopicEvent<T>` contains:

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Unique event identifier |
| `peerId` | `String` | Sender's session ID |
| `data` | `T` | The payload data |
| `timestamp` | `Date` | When received |

## Example: Emoji Reactions

```swift
struct EmojiReactions: View {
  let emojis = ["🔥", "👋", "🎉", "❤️"]
  
  @Shared(.instantTopic(
    Schema.Topics.emoji,
    roomId: "demo"
  ))
  var channel: TopicChannel<EmojiTopic>
  
  @State private var animations: [EmojiAnimation] = []
  
  var body: some View {
    ZStack {
      // Animated emojis
      ForEach(animations) { anim in
        Text(anim.emoji)
          .offset(anim.offset)
          .opacity(anim.opacity)
      }
      
      // Emoji buttons
      HStack {
        ForEach(emojis, id: \.self) { emoji in
          Button(emoji) {
            publishEmoji(emoji)
          }
        }
      }
    }
    .onChange(of: channel.latestEvent) { _, event in
      guard let event = event else { return }
      let emoji = emojiForName(event.data.name)
      animate(emoji: emoji, event: event.data)
    }
  }
  
  func publishEmoji(_ emoji: String) {
    let payload = EmojiTopic(
      name: nameForEmoji(emoji),
      directionAngle: .random(in: 0...1),
      rotationAngle: .random(in: 0...1)
    )
    
    $channel.publish(payload) { payload in
      // Animate locally immediately
      animate(emoji: emoji, event: payload)
    }
  }
}
```

## Combining with Presence

Topics and presence work together. A common pattern is to use presence for "who's in the room" and topics for events:

```swift
struct CollaborativeRoom: View {
  // Who's in the room
  @Shared(.instantPresence(
    Schema.Rooms.reactions,
    roomId: roomId,
    initialPresence: ReactionsPresence(name: myName)
  ))
  var presence: RoomPresence<ReactionsPresence>
  
  // Emoji events
  @Shared(.instantTopic(
    Schema.Topics.emoji,
    roomId: roomId
  ))
  var emojiChannel: TopicChannel<EmojiTopic>
  
  var body: some View {
    VStack {
      // Show who's here
      Text("\(presence.totalCount) people in room")
      
      // Emoji reactions
      EmojiBar { emoji in
        $emojiChannel.publish(emoji)
      }
    }
  }
}
```

## Without Schema Codegen

Define topic types manually if not using codegen:

```swift
struct MyTopicPayload: Codable, Sendable, Equatable {
  var message: String
  var timestamp: Date
}

@Shared(.instantTopic(
  roomType: "my-room",
  topic: "notifications",
  roomId: "room-123"
))
var channel: TopicChannel<MyTopicPayload>
```

## See Also

- ``TopicChannel``
- ``TopicEvent``
- ``TopicKey``
- <doc:Presence>

