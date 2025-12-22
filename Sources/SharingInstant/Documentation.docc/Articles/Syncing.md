# Syncing Data

Bidirectional sync with InstantDB including optimistic updates.

## Overview

Use `@Shared` with `.instantSync(...)` for bidirectional synchronization with InstantDB. Changes you make are applied optimistically (shown immediately in the UI) while being sent to the server in the background.

## Basic Sync

```swift
struct TodosView: View {
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
        TodoRow(todo: todo)
      }
      .onDelete { indexSet in
        $todos.withLock { todos in
          todos.remove(atOffsets: indexSet)
        }
      }
    }
  }
}
```

## Optimistic Updates

When you modify the shared value, changes appear immediately:

```swift
// Add a new todo - shows immediately in UI
$todos.withLock { todos in
  todos.append(Todo(
    id: UUID().uuidString,
    title: "New todo",
    done: false,
    createdAt: Date()
  ))
}

// Toggle completion - shows immediately in UI
$todos.withLock { todos in
  if let index = todos.firstIndex(where: { $0.id == todoId }) {
    todos[index].done.toggle()
  }
}

// Delete - shows immediately in UI
$todos.withLock { todos in
  todos.removeAll { $0.id == todoId }
}
```

## How Optimistic Updates Work

1. You make a change via `$todos.withLock { ... }`
2. The change is applied immediately to the local store
3. The UI updates instantly
4. The change is sent to the server via WebSocket
5. Server confirms with `transact-ok` or returns an error
6. If error, the optimistic change is rolled back

## Ordering

Specify how results should be ordered:

```swift
@Shared(
  .instantSync(
    configuration: .init(
      namespace: "messages",
      orderBy: .asc("timestamp")  // Oldest first
    )
  )
)
private var messages: IdentifiedArrayOf<Message> = []
```

## Custom Sync Requests

For complex sync configurations, define a custom request:

```swift
struct MyTodos: SharingInstantSync.KeyCollectionRequest {
  typealias Value = Todo
  
  let configuration: SharingInstantSync.CollectionConfiguration<Value>? = .init(
    namespace: "todos",
    orderBy: .desc("createdAt"),
    animation: .spring()
  )
}

// Usage
@Shared(.instantSync(MyTodos()))
private var todos: IdentifiedArrayOf<Todo> = []
```

## Animation

Animate changes when data syncs:

```swift
@Shared(
  .instantSync(
    configuration: .init(
      namespace: "todos",
      animation: .default
    )
  )
)
private var todos: IdentifiedArrayOf<Todo> = []
```

## Working with Bindings

Create bindings to individual items for editing:

```swift
struct TodoRow: View {
  @Binding var todo: Todo
  
  var body: some View {
    Toggle(todo.title, isOn: $todo.done)
  }
}

// In parent view
ForEach($todos) { $todo in
  TodoRow(todo: $todo)
}
```

## Conflict Resolution

InstantDB uses Last-Write-Wins (LWW) conflict resolution:

- Every change has a timestamp
- When conflicts occur, the change with the highest timestamp wins
- Optimistic updates use a multiplied timestamp to appear "newer" locally
- The server is the source of truth and resolves conflicts

## Offline Support

Changes made while offline are:
1. Applied optimistically to the local store
2. Queued as pending mutations
3. Sent to the server when connection is restored
4. Confirmed or rolled back based on server response

## See Also

- <doc:Querying>
- ``SharingInstantSync``
- ``EntityIdentifiable``








