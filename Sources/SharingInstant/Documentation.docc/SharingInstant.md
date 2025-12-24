# ``SharingInstant``

A Swift Sharing integration for InstantDB's real-time database.

## Overview

SharingInstant is a lightweight wrapper for InstantDB that integrates with the Sharing library, providing local-first, optimistic updates with automatic synchronization across iOS 15, macOS 10.15, tvOS 15, watchOS 7 and newer.

@Row {
  @Column {
    ```swift
    // SharingInstant
    @Shared(
      .instantSync(
        configuration: .init(
          namespace: "todos",
          orderBy: .desc("createdAt")
        )
      )
    )
    var todos: IdentifiedArrayOf<Todo> = []
    ```
  }
  @Column {
    ```swift
    // InstantDB
    try client.subscribe(
      client.query(Todo.self)
        .order(by: "createdAt", .desc)
    ) { result in
      // Handle data updates manually
    }
    ```
  }
}

Both examples fetch todos from InstantDB, but SharingInstant automatically observes changes, applies optimistic updates, and re-renders views when data changes. It works seamlessly with SwiftUI, UIKit, and `@Observable` models.

> Note: SharingInstant provides both querying (read-only) and syncing (read-write) capabilities. See <doc:Querying> and <doc:Syncing> for more information.

## Quick Start

Before SharingInstant's property wrappers can interact with InstantDB, you need to provide the default InstantClient at runtime. This is typically done as early as possible in your app's lifetime:

```swift
import SharingInstant
import SwiftUI

@main
struct MyApp: App {
  init() {
    prepareDependencies {
      $0.defaultInstant = InstantClient(appID: "your-app-id")
    }
  }
  
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
```

> Note: For more information on preparing InstantDB, see <doc:PreparingInstant>.

This `defaultInstant` client is used implicitly by SharingInstant's strategies, like [`instantQuery`](<doc:Sharing/SharedReaderKey/instantQuery(configuration:client:)>) for read-only access:

```swift
@SharedReader(
  .instantQuery(
    configuration: .init(
      namespace: "facts",
      orderBy: .desc("count"),
      limit: 10
    )
  )
)
private var facts: IdentifiedArrayOf<Fact> = []
```

And [`instantSync`](<doc:Sharing/SharedReaderKey/instantSync(configuration:client:)>) for read-write access with optimistic updates:

```swift
@Shared(
  .instantSync(
    configuration: .init(
      namespace: "todos",
      orderBy: .desc("createdAt")
    )
  )
)
private var todos: IdentifiedArrayOf<Todo> = []
```

Access the InstantDB client anywhere using the dependency system:

```swift
@Dependency(\.defaultInstant) var instant

try instant.transact([
  instant.tx.todos[newId()].update(["title": "New todo", "done": false])
])
```

## Defining Your Models

Your model types should conform to ``EntityIdentifiable``, which combines InstantDB's `InstantEntity` with Swift's `Identifiable`:

```swift
struct Todo: Codable, EntityIdentifiable, Sendable {
  static var namespace: String { "todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
}
```

The `namespace` property tells InstantDB which collection this entity belongs to, and the `id` property is used as the entity's unique identifier in the triple store.

## Optimistic Updates

When you modify a `@Shared` value, changes are applied immediately to the UI (optimistic update) while being sent to the server in the background:

```swift
// This shows immediately in the UI
$todos.withLock { todos in
  todos.append(Todo(
    id: UUID().uuidString.lowercased(),
    title: "Buy groceries",
    done: false,
    createdAt: Date()
  ))
}
// Server sync happens automatically
```

If the server rejects the change, the optimistic update is rolled back.

## What is Sharing?

[Sharing](https://github.com/pointfreeco/swift-sharing) is a universal and extensible solution for sharing your app's model data across features and with external systems. This library builds upon Sharing's tools to enable querying and syncing data with InstantDB.

To learn more about Sharing, check out [the Sharing documentation](https://swiftpackageindex.com/pointfreeco/swift-sharing/main/documentation/sharing/).

## What is InstantDB?

[InstantDB](https://www.instantdb.com) is a real-time database that provides:

- **Real-time sync**: Changes propagate instantly across all connected clients
- **Offline support**: Data is available offline with automatic sync when reconnected
- **Triple store**: All data is stored as triples `[entityId, attributeId, value, createdAt]`
- **Optimistic updates**: Changes appear immediately in the UI
- **Last-Write-Wins**: Conflict resolution using timestamps

SharingInstant leverages InstantDB's WebSocket connection and triple store to keep `@Shared` and `@SharedReader` property wrappers in sync with the database.

## Topics

### Essentials

- <doc:Querying>
- <doc:Syncing>
- <doc:Storage>
- <doc:PreparingInstant>
- <doc:Debugging>

### Real-Time Collaboration

- <doc:Presence>
- <doc:Topics>

### Database Configuration

- ``Dependencies/DependencyValues/defaultInstant``

### Query Strategies

- ``Sharing/SharedReaderKey/instantQuery(_:client:)``
- ``Sharing/SharedReaderKey/instantQuery(configuration:client:)``

### Sync Strategies

- ``Sharing/SharedReaderKey/instantSync(_:client:)``
- ``Sharing/SharedReaderKey/instantSync(configuration:client:)``

### Presence Types

- ``RoomPresence``
- ``Peer``
- ``RoomKey``

### Topic Types

- ``TopicChannel``
- ``TopicEvent``
- ``TopicKey``

### Configuration Types

- ``SharingInstantSync``
- ``SharingInstantQuery``
- ``OrderBy``

### Protocols

- ``EntityIdentifiable``
