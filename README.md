# sharing-instant

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS-blue.svg)](https://developer.apple.com)

Real-time, local-first state management for Swift apps using [InstantDB](https://instantdb.com) and 
Point-Free's [Sharing](https://github.com/pointfreeco/swift-sharing) library.

## Demo

[![SharingInstant Demo](https://img.youtube.com/vi/wuGd6pt1reA/0.jpg)](https://www.youtube.com/watch?v=wuGd6pt1reA)

> **Note:** This library depends on [instant-ios-sdk PR #6](https://github.com/instantdb/instant-ios-sdk/pull/6) 
> which adds presence support and threading fixes.

> **⚠️ Demo Status (December 19, 2025 1:00 PM EST):** The demos are a little flaky right now. 
> I'm actively working on fixing them.

  * [Overview](#overview)
  * [Quick example](#quick-example)
  * [Getting started](#getting-started)
  * [Modeling data](#modeling-data)
  * [Permissions](#permissions)
  * [Sync](#sync)
  * [Presence](#presence)
  * [Schema codegen](#schema-codegen)
  * [Demos](#demos)
  * [Documentation](#documentation)
  * [Installation](#installation)
  * [License](#license)

## Overview

`sharing-instant` brings InstantDB's real-time sync to Swift using the familiar `@Shared` property 
wrapper from Point-Free's Sharing library. It provides:

- **`@Shared(.instantSync(...))`** – Bidirectional sync with optimistic updates
- **`@Shared(.instantPresence(...))`** – Real-time presence (who's online, typing indicators, cursors)
- **Schema codegen** – Generate type-safe Swift structs from your TypeScript schema
- **Offline support** – Works offline, syncs when back online
- **Full type safety** – No `[String: Any]`, everything is generic and `Codable`

## Quick example

Get started in seconds with the sample command. This generates a sample schema and Swift types 
you can use immediately:

```bash
# Generate sample schema and Swift types
swift run instant-schema sample --to Sources/Generated/
```

This creates:
- `instant.schema.ts` – A sample TypeScript schema with a `todos` entity
- `Sources/Generated/` – Swift types (`Todo`, `Schema.todos`, etc.)

Then copy this into your app. **Run on multiple simulators or devices to watch changes sync instantly!**

```swift
// TodoApp.swift
import SharingInstant
import SwiftUI

@main
struct TodoApp: App {
  init() {
    // Get your App ID at: https://instantdb.com/dash/new
    // Then push the schema: npx instant-cli@latest push schema --app YOUR_APP_ID
    prepareDependencies {
      $0.defaultInstant = InstantClient(appId: "YOUR_APP_ID")
    }
  }
  
  var body: some Scene {
    WindowGroup {
      TodoListView()
    }
  }
}
```

```swift
// TodoListView.swift
import IdentifiedCollections
import SharingInstant
import SwiftUI

struct TodoListView: View {
  // Uses generated Schema.todos and Todo types
  @Shared(.instantSync(Schema.todos))
  private var todos: IdentifiedArrayOf<Todo> = []
  
  @State private var newTitle = ""
  
  var body: some View {
    NavigationStack {
      List {
        // Add new todo
        HStack {
          TextField("What needs to be done?", text: $newTitle)
            .onSubmit { addTodo() }
          Button(action: addTodo) {
            Image(systemName: "plus.circle.fill")
          }
          .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        
        // Todo list
        ForEach(todos) { todo in
          HStack {
            Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(todo.done ? .green : .secondary)
              .onTapGesture { toggleTodo(todo) }
            Text(todo.title)
              .strikethrough(todo.done)
            Spacer()
          }
        }
        .onDelete { indexSet in
          $todos.withLock { $0.remove(atOffsets: indexSet) }
        }
      }
      .navigationTitle("Todos (\(todos.count))")
    }
  }
  
  private func addTodo() {
    let title = newTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    
    let todo = Todo(
      title: title,
      done: false,
      createdAt: Date().timeIntervalSince1970
    )
    $todos.withLock { $0.append(todo) }
    newTitle = ""
  }
  
  private func toggleTodo(_ todo: Todo) {
    $todos.withLock { $0[id: todo.id]?.done.toggle() }
  }
}
```

When you call `$todos.withLock { ... }`, the change is applied locally immediately (optimistic UI), 
sent to InstantDB, and synced to all other devices in real-time.

## Getting started

This guide walks you through creating an InstantDB project, defining your schema, generating Swift 
types, and building your first synced view.

### 1. Create an InstantDB project

Go to **[instantdb.com/dash/new](https://www.instantdb.com/dash/new)** and create a new project. 
Copy your **App ID** – you'll need it to configure the client.

### 2. Define your schema

Create an `instant.schema.ts` file in your project. This TypeScript file defines your data model 
and is the source of truth for both your backend and Swift types.

See [Modeling Data](https://instantdb.com/docs/modeling-data) for the full schema reference.

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
  // See: https://instantdb.com/docs/presence-and-topics
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

Use the [Instant CLI](https://instantdb.com/docs/cli) to push your schema to the server:

```bash
# Login to InstantDB (first time only)
npx instant-cli@latest login

# Push your schema
npx instant-cli@latest push schema --app YOUR_APP_ID
```

### 4. Generate Swift types

`sharing-instant` includes a schema codegen tool that generates type-safe Swift structs from your 
TypeScript schema.

> **Important:** The generator requires a **clean git workspace** so that generated changes can 
> always be traced back to a specific commit.

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

### 6. Use in your views

Now you can use `@Shared(.instantSync(...))` in any SwiftUI view with the generated types:

```swift
import SharingInstant

struct TodoListView: View {
  // Type-safe sync using generated Schema and Todo types
  @Shared(.instantSync(Schema.todos.orderBy(\.createdAt, .desc)))
  private var todos: IdentifiedArrayOf<Todo> = []
  
  // ... your view code
}
```

## Modeling data

InstantDB uses a **schema-first** approach. Your `instant.schema.ts` file defines:

- **Entities** – Your data types (like tables)
- **Links** – Relationships between entities
- **Rooms** – Real-time presence channels

### Entities

```typescript
entities: {
  todos: i.entity({
    title: i.string(),
    done: i.boolean(),
    createdAt: i.number().indexed(),  // .indexed() for faster queries
    priority: i.string().optional(),   // .optional() for nullable fields
  }),
  
  users: i.entity({
    email: i.string().unique().indexed(),  // .unique() for uniqueness constraint
    displayName: i.string(),
  }),
}
```

### Links (Relationships)

```typescript
links: {
  // One user has many todos
  userTodos: {
    forward: { on: "todos", has: "one", label: "owner" },
    reverse: { on: "users", has: "many", label: "todos" },
  },
}
```

### Rooms (Presence)

```typescript
rooms: {
  chat: {
    presence: i.entity({
      name: i.string(),
      isTyping: i.boolean(),
    }),
  },
}
```

📚 **Learn more:** [Modeling Data](https://instantdb.com/docs/modeling-data)

## Permissions

InstantDB uses a **CEL-based rule language** to secure your data. Define permissions in 
`instant.perms.ts`:

```typescript
// instant.perms.ts
import type { InstantRules } from "@instantdb/react";

const rules = {
  todos: {
    allow: {
      // Anyone can view todos
      view: "true",
      // Only the owner can create/update/delete
      create: "isOwner",
      update: "isOwner",
      delete: "isOwner",
    },
    bind: [
      "isOwner", "auth.id != null && auth.id == data.ownerId"
    ]
  },
  
  // Lock down creating new attributes in production
  attrs: {
    allow: {
      create: "false"
    }
  }
} satisfies InstantRules;

export default rules;
```

Push permissions with the CLI:

```bash
npx instant-cli@latest push perms --app YOUR_APP_ID
```

### Key concepts

- **`auth`** – The authenticated user (`auth.id`, `auth.email`)
- **`data`** – The entity being accessed
- **`newData`** – The entity after an update (for `update` rules)
- **`ref()`** – Traverse relationships: `data.ref('owner.id')`
- **`bind`** – Reusable rule aliases

📚 **Learn more:** [Permissions](https://instantdb.com/docs/permissions)

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

📚 **Learn more:** [Reading Data](https://instantdb.com/docs/instaql) | [Writing Data](https://instantdb.com/docs/instaml)

## Presence

The `@Shared(.instantPresence(...))` property wrapper provides real-time presence – know who's 
online and share ephemeral state like typing indicators and cursor positions.

### How it works

The generic type `T` in `RoomPresence<T>` is inferred from your schema's room definition. When you 
define a room in `instant.schema.ts`:

```typescript
rooms: {
  chat: {
    presence: i.entity({
      name: i.string(),
      color: i.string(),
      isTyping: i.boolean(),
    }),
  },
}
```

The codegen produces `ChatPresence` and `Schema.Rooms.chat`, which you use with `@Shared`:

```swift
@Shared(.instantPresence(
  Schema.Rooms.chat,           // RoomKey<ChatPresence> - determines the generic T
  roomId: "room-123",
  initialPresence: ChatPresence(name: "", color: "", isTyping: false)
))
private var presence: RoomPresence<ChatPresence>  // T = ChatPresence, inferred from RoomKey
```

### Basic usage

```swift
struct ChatView: View {
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

📚 **Learn more:** [Presence, Cursors, and Activity](https://instantdb.com/docs/presence-and-topics)

## Schema codegen

`sharing-instant` includes a powerful schema codegen tool that generates type-safe Swift code from 
your InstantDB TypeScript schema.

### Quick start with sample

The fastest way to get started is the `sample` command:

```bash
# Generate sample schema and Swift types (no git requirements)
swift run instant-schema sample --to Sources/Generated/
```

This creates a sample `instant.schema.ts` and generates Swift types you can use immediately.

### CLI usage

```bash
# Generate Swift types from a schema file (requires clean git workspace)
swift run instant-schema generate \
  --from path/to/instant.schema.ts \
  --to Sources/Generated

# Pull schema from InstantDB and generate
swift run instant-schema generate \
  --app YOUR_APP_ID \
  --to Sources/Generated
```

> **Note:** The `generate` command requires a **clean git workspace** for full traceability. 
> The `sample` command has no git requirements – use it for quick experimentation.

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

#### Where to place `instant.schema.ts`

The plugin looks for `instant.schema.ts` in your target's source directory. Here are example 
project structures:

**Single-target app:**
```
MyApp/
├── Package.swift
├── Sources/
│   └── MyApp/
│       ├── instant.schema.ts    ← Place schema here
│       ├── MyApp.swift
│       └── ContentView.swift
```

**Multi-target workspace:**
```
MyProject/
├── Package.swift
├── Sources/
│   ├── Shared/                  ← Shared code target
│   │   ├── instant.schema.ts    ← Schema in shared target
│   │   └── Generated/           ← Generated types here
│   ├── iOSApp/
│   │   └── iOSApp.swift
│   └── macOSApp/
│       └── macOSApp.swift
```

**Xcode project with SPM:**
```
MyApp.xcodeproj/
MyApp/
├── instant.schema.ts            ← In your main app folder
├── Generated/
├── AppDelegate.swift
└── ContentView.swift
```

> **Note:** You only need the schema in **one** target. Other targets can import the generated 
> types from that target. You don't need to duplicate the schema for each platform.

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

### InstantDB

- **[Getting Started](https://instantdb.com/docs)** – Official InstantDB documentation
- **[Modeling Data](https://instantdb.com/docs/modeling-data)** – Schema design guide
- **[Permissions](https://instantdb.com/docs/permissions)** – CEL-based rule language
- **[Instant CLI](https://instantdb.com/docs/cli)** – Push schema and permissions
- **[Presence & Topics](https://instantdb.com/docs/presence-and-topics)** – Real-time presence
- **[Patterns](https://instantdb.com/docs/patterns)** – Common recipes

### Swift

- **[Swift Sharing](https://swiftpackageindex.com/pointfreeco/swift-sharing/main/documentation/sharing)** – Point-Free's Sharing library docs
- **[Schema Codegen](./Sources/InstantSchemaCodegen/Documentation.docc/SchemaCodegen.md)** – Schema codegen documentation

## Installation

You can add `sharing-instant` to your project using **either** Swift Package Manager **or** Xcode's 
package manager UI. Choose whichever method you prefer – you only need to do one.

### Option A: Swift Package Manager

Add `sharing-instant` to your `Package.swift`:

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

### Option B: Xcode

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
