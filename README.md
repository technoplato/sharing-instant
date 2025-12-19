# SharingInstant

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS-blue.svg)](https://developer.apple.com)

Real-time, local-first state management for Swift apps using [InstantDB](https://instantdb.com) and 
Point-Free's [Sharing](https://github.com/pointfreeco/swift-sharing) library.

## Demo

[![SharingInstant Demo](https://img.youtube.com/vi/wuGd6pt1reA/0.jpg)](https://www.youtube.com/watch?v=wuGd6pt1reA)

> **Note:** This library depends on [instant-ios-sdk PR #6](https://github.com/instantdb/instant-ios-sdk/pull/6) 
> which adds presence support and threading fixes.

  * [Overview](#overview)
  * [Getting started](#getting-started)
  * [Sync](#sync)
  * [Presence](#presence)
  * [Schema codegen](#schema-codegen)
  * [Demos](#demos)
  * [Documentation](#documentation)
  * [Installation](#installation)
  * [License](#license)

## Overview

SharingInstant brings InstantDB's real-time sync to Swift using the familiar `@Shared` property 
wrapper from Point-Free's Sharing library. It provides:

- **`@Shared(.instantSync(...))`** – Bidirectional sync with optimistic updates
- **`@Shared(.instantPresence(...))`** – Real-time presence (who's online, typing indicators, cursors)
- **Schema codegen** – Generate type-safe Swift structs from your TypeScript schema
- **Offline support** – Works offline, syncs when back online
- **Full type safety** – No `[String: Any]`, everything is generic and `Codable`

As a simple example, you can have a SwiftUI view that syncs todos with InstantDB:

```swift
import SharingInstant
import SwiftUI

struct TodoListView: View {
  @Shared(.instantSync(Schema.todos)) 
  private var todos: IdentifiedArrayOf<Todo> = []
  
  var body: some View {
    List(todos) { todo in
      Text(todo.title)
    }
  }
  
  func addTodo(title: String) {
    $todos.withLock { todos in
      todos.append(Todo(title: title, done: false, createdAt: Date().timeIntervalSince1970))
    }
  }
}
```

When you call `$todos.withLock { ... }`, the change is applied locally immediately (optimistic UI), 
sent to InstantDB, and synced to all other devices in real-time.

## Getting started

This guide walks you through creating an InstantDB project, defining your schema, generating Swift 
types, and building your first synced view.

### 1. Create an InstantDB project

Go to [instantdb.com/dash/new](https://www.instantdb.com/dash/new) and create a new project. 
Copy your **App ID** – you'll need it to configure the client.

### 2. Define your schema

Create an `instant.schema.ts` file in your project. This TypeScript file defines your data model 
and is the source of truth for both your backend and Swift types:

```typescript
// instant.schema.ts
import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    todos: i.entity({
      title: i.string(),
      done: i.boolean(),
      createdAt: i.number().indexed(),
    }),
  },
  
  // Optional: Define rooms for presence features
  rooms: {
    chat: {
      presence: i.entity({
        name: i.string(),
        color: i.string(),
        isTyping: i.boolean(),
      }),
    },
  },
});

type _AppSchema = typeof _schema;
interface AppSchema extends _AppSchema {}
const schema: AppSchema = _schema;

export type { AppSchema };
export default schema;
```

### 3. Push your schema to InstantDB

Use the Instant CLI to push your schema to the server:

```bash
# Login to InstantDB (first time only)
npx instant-cli@latest login

# Push your schema
npx instant-cli@latest push schema --app YOUR_APP_ID
```

### 4. Generate Swift types

SharingInstant includes a schema codegen tool that generates type-safe Swift structs from your 
TypeScript schema:

```bash
# Generate Swift types
swift run instant-schema generate \
  --from instant.schema.ts \
  --to Sources/Generated
```

This generates:

- **`Entities.swift`** – Swift structs for each entity (`Todo`, etc.)
- **`Schema.swift`** – Type-safe `EntityKey` instances (`Schema.todos`, etc.)
- **`Rooms.swift`** – Presence types for rooms (`ChatPresence`, `Schema.Rooms.chat`, etc.)
- **`Links.swift`** – Link metadata for relationships

### 5. Configure the InstantDB client

In your app's entry point, configure the default InstantDB client with your App ID:

```swift
import SharingInstant
import SwiftUI

@main
struct MyApp: App {
  init() {
    prepareDependencies {
      $0.defaultInstant = InstantClient(appId: "YOUR_APP_ID")
    }
  }
  
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
```

### 6. Build your first synced view

Now you can use `@Shared(.instantSync(...))` in any SwiftUI view:

```swift
import IdentifiedCollections
import SharingInstant
import SwiftUI

struct TodoListView: View {
  // Type-safe sync using generated Schema and Todo types
  @Shared(.instantSync(Schema.todos.orderBy(\.createdAt, .desc)))
  private var todos: IdentifiedArrayOf<Todo> = []
  
  @State private var newTitle = ""
  
  var body: some View {
    NavigationStack {
      List {
        Section("Add Todo") {
          HStack {
            TextField("What needs to be done?", text: $newTitle)
            Button("Add") { addTodo() }
              .disabled(newTitle.isEmpty)
          }
        }
        
        Section("Todos (\(todos.count))") {
          ForEach(todos) { todo in
            HStack {
              Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(todo.done ? .green : .secondary)
                .onTapGesture { toggleTodo(todo) }
              
              Text(todo.title)
                .strikethrough(todo.done)
            }
          }
          .onDelete { indexSet in
            $todos.withLock { todos in
              todos.remove(atOffsets: indexSet)
            }
          }
        }
      }
      .navigationTitle("Todos")
    }
  }
  
  private func addTodo() {
    let todo = Todo(
      title: newTitle,
      done: false,
      createdAt: Date().timeIntervalSince1970
    )
    $todos.withLock { $0.append(todo) }
    newTitle = ""
  }
  
  private func toggleTodo(_ todo: Todo) {
    $todos.withLock { todos in
      todos[id: todo.id]?.done.toggle()
    }
  }
}
```

That's it! Your todos now sync in real-time across all devices. Open the app on multiple 
simulators or devices to see changes appear instantly.

## Sync

The `@Shared(.instantSync(...))` property wrapper provides bidirectional sync with InstantDB.

### Basic usage

```swift
// Sync all todos
@Shared(.instantSync(Schema.todos))
private var todos: IdentifiedArrayOf<Todo> = []

// With ordering
@Shared(.instantSync(Schema.todos.orderBy(\.createdAt, .desc)))
private var todos: IdentifiedArrayOf<Todo> = []

// With filtering
@Shared(.instantSync(Schema.todos.where(\.done, .eq(false))))
private var activeTodos: IdentifiedArrayOf<Todo> = []

// With limit
@Shared(.instantSync(Schema.todos.limit(10)))
private var recentTodos: IdentifiedArrayOf<Todo> = []
```

### Mutations with `withLock`

All mutations go through `$todos.withLock { ... }`, which:

1. Applies the change locally immediately (optimistic UI)
2. Sends the change to InstantDB
3. Receives confirmation or rollback from the server

```swift
// Create
$todos.withLock { todos in
  todos.append(Todo(title: "New todo", done: false, createdAt: Date().timeIntervalSince1970))
}

// Update
$todos.withLock { todos in
  todos[id: todo.id]?.done = true
}

// Delete
$todos.withLock { todos in
  todos.remove(id: todo.id)
}

// Batch operations
$todos.withLock { todos in
  for index in todos.indices {
    todos[index].done = true
  }
}
```

### Query modifiers

Chain modifiers for complex queries:

```swift
Schema.todos
  .where(\.done, .eq(false))      // Filter: only incomplete todos
  .orderBy(\.createdAt, .desc)    // Sort: newest first
  .limit(20)                       // Limit: first 20 results
```

## Presence

The `@Shared(.instantPresence(...))` property wrapper provides real-time presence – know who's 
online and share ephemeral state like typing indicators and cursor positions.

### Basic usage

```swift
struct ChatView: View {
  // Type-safe presence using generated room and presence types
  @Shared(.instantPresence(
    Schema.Rooms.chat,
    roomId: "room-123",
    initialPresence: ChatPresence(name: "", color: "", isTyping: false)
  ))
  private var presence: RoomPresence<ChatPresence>
  
  var body: some View {
    VStack {
      // Show who's online
      Text("Online: \(presence.totalCount)")
      
      // Your presence
      Text("You: \(presence.user.name)")
      
      // Other users
      ForEach(presence.peers) { peer in
        HStack {
          Text(peer.data.name)
          if peer.data.isTyping {
            Text("typing...")
          }
        }
      }
    }
  }
}
```

### Updating your presence

```swift
// Update a single field
$presence.withLock { state in
  state.user.isTyping = true
}

// Update multiple fields
$presence.withLock { state in
  state.user = ChatPresence(
    name: "Alice",
    color: "#FF0000",
    isTyping: false
  )
}
```

### Presence state

The `RoomPresence<T>` type provides:

- `user: T` – Your current presence data
- `peers: [Peer<T>]` – Other users in the room
- `totalCount: Int` – Total users including you
- `isLoading: Bool` – Whether the connection is being established
- `error: Error?` – Any connection error

## Schema codegen

SharingInstant includes a powerful schema codegen tool that generates type-safe Swift code from 
your InstantDB TypeScript schema.

### CLI usage

```bash
# Generate Swift types from a schema file
swift run instant-schema generate \
  --from path/to/instant.schema.ts \
  --to Sources/Generated

# Pull schema from InstantDB and generate
swift run instant-schema generate \
  --app YOUR_APP_ID \
  --to Sources/Generated
```

### Generated code

For a schema like:

```typescript
const _schema = i.schema({
  entities: {
    todos: i.entity({
      title: i.string(),
      done: i.boolean(),
      createdAt: i.number().indexed(),
    }),
  },
  rooms: {
    chat: {
      presence: i.entity({
        name: i.string(),
        isTyping: i.boolean(),
      }),
    },
  },
});
```

The codegen produces:

**Entities.swift:**
```swift
public struct Todo: EntityIdentifiable, Codable, Sendable {
  public static var namespace: String { "todos" }
  
  public var id: String
  public var title: String
  public var done: Bool
  public var createdAt: Double
  
  public init(
    id: String = UUID().uuidString,
    title: String,
    done: Bool,
    createdAt: Double
  ) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}
```

**Schema.swift:**
```swift
public enum Schema {
  public static let todos = EntityKey<Todo>(namespace: "todos")
}
```

**Rooms.swift:**
```swift
public struct ChatPresence: Codable, Sendable, Equatable {
  public var name: String
  public var isTyping: Bool
}

extension Schema {
  public enum Rooms {
    public static let chat = RoomKey<ChatPresence>(type: "chat")
  }
}
```

### SPM build plugin

For automatic codegen on every build, add the plugin to your target:

```swift
.target(
  name: "MyApp",
  dependencies: ["SharingInstant"],
  plugins: [
    .plugin(name: "InstantSchemaPlugin", package: "sharing-instant")
  ]
)
```

Place your `instant.schema.ts` in the target's source directory, and Swift types will be 
regenerated automatically whenever the schema changes.

## Demos

This repo includes several demos showing real-world usage patterns:

- **[Sync Demo](./Examples/CaseStudies/SwiftUISyncDemo.swift)** – Basic todo list with 
  bidirectional sync
- **[Typing Indicator](./Examples/CaseStudies/TypingIndicatorDemo.swift)** – Real-time typing 
  indicators using presence
- **[Avatar Stack](./Examples/CaseStudies/AvatarStackDemo.swift)** – Show who's online with 
  animated avatars
- **[Cursors](./Examples/CaseStudies/CursorsDemo.swift)** – Real-time cursor positions
- **[Tile Game](./Examples/CaseStudies/TileGameDemo.swift)** – Collaborative sliding puzzle game

Run the demos:

```bash
# Open the workspace in Xcode
open SharingInstant.xcworkspace

# Or build from command line
xcodebuild -workspace SharingInstant.xcworkspace \
  -scheme CaseStudies \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Documentation

- **[InstantDB Docs](https://instantdb.com/docs)** – Official InstantDB documentation
- **[Swift Sharing](https://swiftpackageindex.com/pointfreeco/swift-sharing/main/documentation/sharing)** – Point-Free's Sharing library docs
- **[Schema Codegen](./Sources/InstantSchemaCodegen/Documentation.docc/SchemaCodegen.md)** – Schema codegen documentation

## Installation

### Swift Package Manager

Add SharingInstant to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/instantdb/sharing-instant", from: "0.1.0")
]
```

Then add the product to your target:

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "SharingInstant", package: "sharing-instant"),
  ]
)
```

### Xcode

1. File → Add Package Dependencies...
2. Enter: `https://github.com/instantdb/sharing-instant`
3. Add `SharingInstant` to your target

### Requirements

- iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+
- Swift 6.0+
- Xcode 16+

## License

MIT License – see [LICENSE](LICENSE) for details.

## Credits

- [InstantDB](https://instantdb.com) – The real-time database
- [Swift Sharing](https://github.com/pointfreeco/swift-sharing) – The reactive state library
- [Point-Free](https://www.pointfree.co) – For the amazing Swift libraries
