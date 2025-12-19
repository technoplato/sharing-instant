# SharingInstant

## Demo

[youtube](https://www.youtube.com/watch?v=wuGd6pt1reA)

## [wip] 

Depends on landing https://github.com/tornikegomareli/instant-ios-sdk/pull/6

## Overview

A Swift Sharing integration for InstantDB, providing local-first reactive state management.

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS-blue.svg)](https://developer.apple.com)

SharingInstant brings InstantDB's real-time, local-first database to Swift using Point-Free's [Sharing](https://github.com/pointfreeco/swift-sharing) library. It provides:

- **`@Shared(.instantSync(...))`** - Bidirectional sync with optimistic updates
- **`@SharedReader(.instantQuery(...))`** - Read-only reactive queries
- **Offline support** - Works offline, syncs when back online
- **Real-time collaboration** - See changes from other users instantly
- **Presence** - Know who's online and share ephemeral state

## Installation

Add SharingInstant to your Swift package:

```swift
dependencies: [
  .package(url: "https://github.com/instantdb/sharing-instant", from: "0.1.0")
]
```

## Quick Start

### 1. Configure InstantDB

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

### 2. Define Your Model

```swift
import InstantDB

@InstantEntity
struct Todo: Identifiable, Codable {
  static let namespace = "todos"
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
}
```

### 3. Use in SwiftUI

```swift
import SharingInstant
import SwiftUI

struct TodoListView: View {
  @Shared(
    .instantSync(
      configuration: .init(
        namespace: "todos",
        orderBy: .desc("createdAt")
      )
    )
  )
  private var todos: IdentifiedArrayOf<Todo> = []
  
  var body: some View {
    List {
      ForEach(todos) { todo in
        HStack {
          Text(todo.title)
          Spacer()
          if todo.done {
            Image(systemName: "checkmark")
          }
        }
        .onTapGesture {
          // Optimistic update - UI updates immediately
          $todos.withLock { todos in
            todos[id: todo.id]?.done.toggle()
          }
        }
      }
      .onDelete { indexSet in
        $todos.withLock { todos in
          todos.remove(atOffsets: indexSet)
        }
      }
    }
  }
  
  func addTodo(title: String) {
    $todos.withLock { todos in
      todos.append(Todo(
        id: UUID().uuidString,
        title: title,
        done: false,
        createdAt: Date()
      ))
    }
  }
}
```

## How It Works

### Optimistic Updates

When you modify data using `$todos.withLock { ... }`, the change is:

1. Applied locally immediately (optimistic UI)
2. Sent to the InstantDB server
3. Confirmed or rejected by the server
4. If rejected, rolled back locally

This gives instant feedback while maintaining data consistency.

### Offline Support

SharingInstant persists data locally using SQLite (via GRDB). When offline:

1. Queries return cached data
2. Mutations are queued locally
3. When back online, mutations sync to server
4. Conflicts resolved using Last-Write-Wins

### Conflict Resolution

InstantDB uses Last-Write-Wins (LWW) based on timestamps:

- Every change has a `createdAt` timestamp
- When conflicts occur, the latest timestamp wins
- Server is the source of truth

## Read-Only Queries

For data you only need to read (not modify), use `@SharedReader`:

```swift
@SharedReader(
  .instantQuery(
    configuration: .init(
      namespace: "todos",
      where: { $0.done == false },
      limit: 10
    )
  )
)
private var activeTodos: [Todo] = []
```

## Presence

Share ephemeral state like cursor positions:

```swift
@Shared(.instantPresence(roomId: "document-123"))
private var presence: PresenceSlice?

// Update your presence
$presence.withLock { presence in
  presence?.user["cursor"] = ["x": 100, "y": 200]
}
```

## Requirements

- iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+
- Swift 6.0+
- Xcode 16+

## Documentation

- [Getting Started](Sources/SharingInstant/Documentation.docc/Articles/GettingStarted.md)
- [Optimistic Updates](Sources/SharingInstant/Documentation.docc/Articles/OptimisticUpdates.md)
- [Offline Mode](Sources/SharingInstant/Documentation.docc/Articles/OfflineMode.md)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Credits

- [InstantDB](https://instantdb.com) - The real-time database
- [Swift Sharing](https://github.com/pointfreeco/swift-sharing) - The reactive state library
- [Point-Free](https://www.pointfree.co) - For the amazing Swift libraries
