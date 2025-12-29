# Querying Data

Fetch read-only data from InstantDB with automatic updates.

## Overview

Use `@SharedReader` with `.instantQuery(...)` to fetch data from InstantDB. The query automatically subscribes to real-time updates, so your UI stays in sync with the database.

## Basic Query

The simplest way to query data is with a configuration:

```swift
struct FactsView: View {
  @SharedReader(
    .instantQuery(
      configuration: .init(
        namespace: "facts",
        orderBy: .desc("count")
      )
    )
  )
  private var facts: IdentifiedArrayOf<Fact> = []
  
  var body: some View {
    List(facts) { fact in
      Text(fact.text)
    }
  }
}
```

## Ordering Results

Use ``OrderBy`` to sort your results:

```swift
// Ascending order
.instantQuery(configuration: .init(
  namespace: "todos",
  orderBy: .asc("title")
))

// Descending order
.instantQuery(configuration: .init(
  namespace: "todos",
  orderBy: .desc("createdAt")
))
```

## Limiting Results

Limit the number of results returned:

```swift
@SharedReader(
  .instantQuery(
    configuration: .init(
      namespace: "leaderboard",
      orderBy: .desc("score"),
      limit: 10
    )
  )
)
private var topScores: IdentifiedArrayOf<Score> = []
```

## Custom Query Requests

For more complex queries, define a custom request type:

```swift
struct ActiveTodos: SharingInstantQuery.KeyRequest {
  typealias Value = Todo
  
  let configuration: SharingInstantQuery.Configuration<Value>? = .init(
    namespace: "todos",
    orderBy: .asc("createdAt")
  )
}

// Usage
@SharedReader(.instantQuery(ActiveTodos()))
private var activeTodos: IdentifiedArrayOf<Todo> = []
```

## Array vs IdentifiedArray

You can use either `[Element]` or `IdentifiedArrayOf<Element>`:

```swift
// Using Array
@SharedReader(
  .instantQuery(configuration: .init(namespace: "todos"))
)
private var todos: [Todo] = []

// Using IdentifiedArray (recommended for SwiftUI)
@SharedReader(
  .instantQuery(configuration: .init(namespace: "todos"))
)
private var todos: IdentifiedArrayOf<Todo> = []
```

`IdentifiedArrayOf` is recommended for SwiftUI as it provides stable identity for list animations.

## Animation

Animate changes when data updates:

```swift
@SharedReader(
  .instantQuery(
    configuration: .init(
      namespace: "todos",
      animation: .default
    )
  )
)
private var todos: IdentifiedArrayOf<Todo> = []
```

## Loading State

Handle loading states by checking if the array is empty on initial load:

```swift
var body: some View {
  if todos.isEmpty {
    ProgressView("Loading...")
  } else {
    List(todos) { todo in
      TodoRow(todo: todo)
    }
  }
}
```

## See Also

- <doc:Syncing>
- ``SharingInstantQuery``
- ``OrderBy``









