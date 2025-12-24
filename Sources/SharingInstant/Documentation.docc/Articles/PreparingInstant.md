# Preparing InstantDB

Configure the InstantDB client for use with SharingInstant.

## Overview

Before using `@Shared(.instantSync(...))` or `@SharedReader(.instantQuery(...))`, you must configure the default InstantDB client that SharingInstant will use.

## Setting Up the Default Client

Use `prepareDependencies` to configure the client as early as possible in your app's lifetime:

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

> Important: You can only prepare the client once in your app's lifetime. Attempting to do so multiple times will produce a runtime warning.

## Getting Your App ID

Your InstantDB App ID can be found in the [InstantDB Dashboard](https://www.instantdb.com/dash). Create a new app or select an existing one to find your App ID.

## Custom Server URL

For self-hosted InstantDB instances or development servers, you can specify a custom base URL:

```swift
prepareDependencies {
  $0.defaultInstant = InstantClient(
    appID: "your-app-id",
    baseURL: "wss://your-custom-server.com"
  )
}
```

## Accessing the Client Directly

Once configured, you can access the InstantDB client anywhere using the `@Dependency` property wrapper:

```swift
struct TodoService {
  @Dependency(\.defaultInstant) var instant
  
  func createTodo(title: String) throws {
    try instant.transact([
      instant.tx.todos[UUID().uuidString.lowercased()].update([
        "title": title,
        "done": false,
        "createdAt": Date()
      ])
    ])
  }
}
```

## SwiftUI Previews

For SwiftUI previews, configure the client in the preview itself:

```swift
#Preview {
  let _ = prepareDependencies {
    $0.defaultInstant = InstantClient(appID: "preview-app-id")
  }
  
  ContentView()
}
```

## Debugging

If you are diagnosing connection, schema, or link-resolution issues, enable verbose logging in the
underlying InstantDB Swift SDK:

- `INSTANTDB_LOG_LEVEL=info` for high-signal connection events
- `INSTANTDB_LOG_LEVEL=debug` (or `INSTANTDB_DEBUG=1`) for verbose protocol tracing

SharingInstant also provides <doc:Debugging> for a full breakdown of logging layers and common
failure modes.

## Testing

In tests, you can either use a real client with a test app ID, or provide test data directly through the configuration:

```swift
func testTodoList() {
  let testTodos = [
    Todo(id: "1", title: "Test Todo", done: false, createdAt: Date())
  ]
  
  @Shared(
    .instantSync(
      configuration: .init(
        namespace: "todos",
        testingValue: testTodos
      )
    )
  )
  var todos: IdentifiedArrayOf<Todo> = []
  
  // In test context, todos will use testingValue
}
```






