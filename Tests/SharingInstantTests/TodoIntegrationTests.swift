import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Todo Model Wrapper

@MainActor
private final class TodoModelRefactored: ObservableObject {
  @Shared var todos: IdentifiedArrayOf<Todo>
  
  init(key: EntityKey<Todo> = Schema.todos.orderBy(\Todo.createdAt, EntityKeyOrderDirection.desc)) {
    _todos = Shared(.instantSync(key))
  }
  
  func addTodo(title: String) -> Todo {
    let todo = Todo(
      createdAt: Date().timeIntervalSince1970 * 1_000,
      done: false,
      title: title
    )
    _ = $todos.withLock { $0.insert(todo, at: 0) }
    return todo
  }
  
  func toggleDone(id: String) {
    $todos.withLock { todos in
      if let index = todos.firstIndex(where: { $0.id == id }) {
        todos[index].done.toggle()
      }
    }
  }
  
  func updateTitle(id: String, title: String) {
    $todos.withLock { todos in
      if let index = todos.firstIndex(where: { $0.id == id }) {
        todos[index].title = title
      }
    }
  }
}

// MARK: - Integration Tests

final class TodoIntegrationTests: XCTestCase {
  private struct TestHarnessError: Error {
    let message: String
  }
  
  private struct EphemeralAppResponse: Decodable {
    struct App: Decodable {
      let id: String
      let adminToken: String
      
      enum CodingKeys: String, CodingKey {
        case id
        case adminToken = "admin-token"
      }
    }
    
    let app: App
    let expiresMs: Int64
    
    enum CodingKeys: String, CodingKey {
      case app
      case expiresMs = "expires_ms"
    }
  }
  
  private struct EphemeralApp {
    let id: String
    let adminToken: String
  }
  
  @MainActor
  func testTodoUpdatePropagation() async throws {
    if ProcessInfo.processInfo.environment["INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS"] != "1" {
      throw XCTSkip(
        """
        Ephemeral backend integration tests are disabled.

        Set `INSTANT_RUN_EPHEMERAL_INTEGRATION_TESTS=1` to run tests that create a fresh \
        InstantDB app on each run via `/dash/apps/ephemeral`.
        """
      )
    }
    
    let app = try await Self.createEphemeralTodosApp()
    
    if let bundleID = Bundle.main.bundleIdentifier {
      UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }
    UserDefaults.standard.dictionaryRepresentation().keys.forEach { key in
      if key.contains("instant") {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    
    await MainActor.run {
      InstantClientFactory.clearCache()
    }
    
    let storeA = SharedTripleStore()
    let reactorA = Reactor(store: storeA, clientInstanceID: "todos-client-a")
    
    let storeB = SharedTripleStore()
    let reactorB = Reactor(store: storeB, clientInstanceID: "todos-client-b")
    
    let modelA = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorA
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      TodoModelRefactored()
    }
    
    let modelB = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorB
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      TodoModelRefactored()
    }
    
    // Warm subscriptions before performing writes.
    _ = modelA.todos.count
    _ = modelB.todos.count
    try await Task.sleep(nanoseconds: 1_000_000_000)
    
    let todo = modelA.addTodo(title: "Hello from A")
    
    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client B should see the todo created by A."
    ) {
      modelB.todos.contains(where: { $0.id == todo.id && $0.title == todo.title })
    }
    
    modelA.toggleDone(id: todo.id)
    
    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client B should see the done toggle performed by A."
    ) {
      modelB.todos.first(where: { $0.id == todo.id })?.done == true
    }
    
    modelA.updateTitle(id: todo.id, title: "Updated title")
    
    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Client B should see A's title update."
    ) {
      modelB.todos.first(where: { $0.id == todo.id })?.title == "Updated title"
    }

    let activeTodosKey = Schema.todos
      .orderBy(\Todo.createdAt, EntityKeyOrderDirection.desc)
      .where(\Todo.done, .eq(false))

    let activeModelB = withDependencies {
      $0.context = .live
      $0.instantReactor = reactorB
      $0.instantAppID = app.id
      $0.instantEnableLocalPersistence = false
    } operation: {
      TodoModelRefactored(key: activeTodosKey)
    }

    // Warm subscription to filtered query before asserting.
    _ = activeModelB.todos.count
    try await Task.sleep(nanoseconds: 1_000_000_000)

    try await Self.eventually(
      timeout: 20,
      pollInterval: 0.2,
      failureMessage: "Active-todos query should exclude done todos."
    ) {
      activeModelB.todos.first(where: { $0.id == todo.id }) == nil
    }
  }
  
  // MARK: - Ephemeral App Creation
  
  private static func createEphemeralTodosApp() async throws -> EphemeralApp {
    let apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"
    
    guard let url = URL(string: "\(apiOrigin)/dash/apps/ephemeral") else {
      throw XCTSkip("Invalid INSTANT_TEST_API_ORIGIN: \(apiOrigin)")
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let schema = minimalTodosSchema()
    let rules: [String: Any] = [
      "todos": [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ],
      ],
    ]
    
    let title = "sharing-instant-todos-\(UUID().uuidString.prefix(8))"
    let body: [String: Any] = [
      "title": title,
      "schema": schema,
      "rules": ["code": rules],
    ]
    
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
    
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TestHarnessError(message: "Ephemeral app creation returned a non-HTTP response.")
    }
    
    guard (200..<300).contains(httpResponse.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw TestHarnessError(
        message:
          """
          Failed to create ephemeral app.

          Status: \(httpResponse.statusCode)
          Body: \(raw)
          """
      )
    }
    
    let decoded = try JSONDecoder().decode(EphemeralAppResponse.self, from: data)
    return EphemeralApp(id: decoded.app.id, adminToken: decoded.app.adminToken)
  }
  
  private static func minimalTodosSchema() -> [String: Any] {
    func dataAttr(
      valueType: String,
      required: Bool,
      indexed: Bool = false,
      unique: Bool = false
    ) -> [String: Any] {
      [
        "valueType": valueType,
        "required": required,
        "isIndexed": indexed,
        "config": [
          "indexed": indexed,
          "unique": unique,
        ],
        "metadata": [:] as [String: Any],
      ]
    }
    
    func entityDef(attrs: [String: Any]) -> [String: Any] {
      [
        "attrs": attrs,
        "links": [:] as [String: Any],
      ]
    }
    
    return [
      "entities": [
        "todos": entityDef(
          attrs: [
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
            "done": dataAttr(valueType: "boolean", required: true),
            "title": dataAttr(valueType: "string", required: true),
          ]
        ),
      ],
      "links": [:] as [String: Any],
      "rooms": [:] as [String: Any],
    ]
  }
  
  // MARK: - Helpers
  
  @MainActor
  private static func eventually(
    timeout: TimeInterval,
    pollInterval: TimeInterval,
    failureMessage: String,
    _ predicate: @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() {
        return
      }
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    
    XCTFail(failureMessage)
    throw TestHarnessError(message: failureMessage)
  }
}
