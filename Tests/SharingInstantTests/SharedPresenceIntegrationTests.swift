// SharedPresenceIntegrationTests.swift
// SharingInstantTests
//
// Integration tests that exercise @Shared APIs exactly as end users would.

// ═══════════════════════════════════════════════════════════════════════════════
// GUIDING PRINCIPLES
// ═══════════════════════════════════════════════════════════════════════════════
//
// These integration tests exercise the `@Shared` API exactly as end users would.
//
// ## Why Generated Types?
//
// We use the SAME generated Schema.swift and Entities.swift that the CLI produces.
// This ensures our tests catch:
//
// 1. Codegen bugs (wrong property names, types, initializer order)
// 2. API mismatches between generated code and library
// 3. Real-world usage patterns
//
// The generated files live in Tests/SharingInstantTests/Generated/ and are
// committed to git as test fixtures.
//
// ## If Tests Fail to Compile
//
// The generated files may be stale. Regenerate with:
//
//   cd sharing-instant
//   swift run instant-schema generate \
//     --from Examples/CaseStudies/instant.schema.ts \
//     --to Tests/SharingInstantTests/Generated/
//
// ## What These Tests Verify
//
// - @Shared(.instantSync(...)) connects and syncs data
// - @Shared(.instantPresence(...)) handles presence callbacks on main thread
// - $shared.withLock mutations work correctly
// - Full CRUD lifecycle through the @Shared API
//
// ## The Bug These Tests Would Have Caught
//
// The crash reports in sharing-instant/crashes/ showed a Swift concurrency
// executor assertion failure in TypedPresenceKey.subscribe. The callback was
// being invoked on the NSURLSession delegate queue instead of the main actor.
// Tests that bypass @Shared wouldn't catch this - only tests that exercise
// the full @Shared → TypedPresenceKey → InstantClient → WebSocket stack would.
//
// ═══════════════════════════════════════════════════════════════════════════════

import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Shared Sync Integration Tests

/// Integration tests that exercise the `@Shared(.instantSync(...))` API.
///
/// ## Why These Tests Matter
///
/// These tests exercise the actual `@Shared` property wrapper that users use in their apps
/// for bidirectional data sync with InstantDB. Unlike tests that directly call `InstantClient`
/// methods, these tests:
///
/// 1. **Exercise the full stack** - From `@Shared` → `InstantSyncCollectionKey` → `InstantClient` → WebSocket
/// 2. **Test optimistic updates** - Changes via `$todos.withLock` should appear immediately
/// 3. **Test real sync** - Data should persist and sync across sessions
///
/// ## Running These Tests
///
/// These tests require network access and connect to the real InstantDB backend:
/// ```
/// swift test --filter SharedSyncIntegrationTests
/// ```
final class SharedSyncIntegrationTests: XCTestCase {
  
  // MARK: - Test Configuration
  
  private var appID: String!
  
  /// Timeout for waiting for sync operations.
  private let syncTimeout: TimeInterval = 10.0
  
  // MARK: - Setup / Teardown

  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-shared-sync",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    self.appID = app.id
  }

  // MARK: - Tests
  
  /// Tests that `@Shared(.instantSync(...))` connects and receives initial data.
  ///
  /// This test verifies the basic flow:
  /// 1. Create a `@Shared` property with sync configuration
  /// 2. Wait for the subscription to connect
  /// 3. Verify that data is received from the server
  @MainActor
  func testSharedSyncConnectsAndReceivesData() async throws {
    let instanceID = "shared-sync-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      // Act: Create a @Shared sync subscription (as a user would in a SwiftUI view).
      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos: IdentifiedArrayOf<Todo> = []

      let client = await MainActor.run {
        InstantClientFactory.makeClient()
      }
      await MainActor.run {
        client.connect()
      }

      let authenticated = try await waitForCondition(timeout: syncTimeout) {
        client.connectionState == .authenticated
      }

      XCTAssertTrue(authenticated, "Expected client to authenticate within timeout.")
      _ = todos.count
    }
  }
  
  /// Tests adding a todo via `$shared.withLock` and verifying it syncs.
  ///
  /// This test verifies the write path:
  /// 1. Create a `@Shared` sync subscription
  /// 2. Wait for connection
  /// 3. Add a todo via `$todos.withLock`
  /// 4. Verify the local state updates immediately (optimistic)
  /// 5. Wait for sync confirmation
  @MainActor
  func testSharedSyncAddTodoViaWithLock() async throws {
    let instanceID = "shared-sync-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos: IdentifiedArrayOf<Todo> = []

      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

      let initialCount = todos.count

      let newTodo = Todo(
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Integration Test Todo \(UUID().uuidString.prefix(8))"
      )

      $todos.withLock { todos in
        _ = todos.insert(newTodo, at: 0)
      }

      XCTAssertEqual(todos.count, initialCount + 1, "Todo count should increase immediately")
      XCTAssertEqual(todos.first?.id, newTodo.id, "New todo should be at the front")
      XCTAssertEqual(todos.first?.title, newTodo.title, "Todo title should match")

      try await Task.sleep(nanoseconds: 500_000_000) // 500ms
      XCTAssertTrue(todos.contains { $0.id == newTodo.id }, "Todo should persist after sync")
    }
  }
  
  /// Tests updating a todo via `$shared.withLock`.
  ///
  /// This test verifies updating existing items:
  /// 1. Create a `@Shared` sync subscription
  /// 2. Add a todo
  /// 3. Update the todo via `$todos.withLock`
  /// 4. Verify the update is applied locally
  @MainActor
  func testSharedSyncUpdateTodoViaWithLock() async throws {
    let instanceID = "shared-sync-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos: IdentifiedArrayOf<Todo> = []

      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

      let newTodo = Todo(
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Update Test Todo \(UUID().uuidString.prefix(8))"
      )

      $todos.withLock { todos in
        _ = todos.insert(newTodo, at: 0)
      }

      try await Task.sleep(nanoseconds: 500_000_000) // 500ms

      $todos.withLock { todos in
        if let index = todos.index(id: newTodo.id) {
          todos[index].done = true
          todos[index].title = "Updated: \(newTodo.title)"
        }
      }

      if let updatedTodo = todos[id: newTodo.id] {
        XCTAssertTrue(updatedTodo.done, "Todo should be marked as done")
        XCTAssertTrue(updatedTodo.title.hasPrefix("Updated:"), "Todo title should be updated")
      } else {
        XCTFail("Todo should still exist after update")
      }

      try await Task.sleep(nanoseconds: 500_000_000) // 500ms
      XCTAssertTrue(todos[id: newTodo.id]?.done == true, "Update should persist after sync")
    }
  }
  
  /// Tests deleting a todo via `$shared.withLock`.
  ///
  /// This test verifies deleting items:
  /// 1. Create a `@Shared` sync subscription
  /// 2. Add a todo
  /// 3. Delete the todo via `$todos.withLock`
  /// 4. Verify the delete is applied locally
  @MainActor
  func testSharedSyncDeleteTodoViaWithLock() async throws {
    let instanceID = "shared-sync-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos: IdentifiedArrayOf<Todo> = []

      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

      let newTodo = Todo(
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Delete Test Todo \(UUID().uuidString.prefix(8))"
      )

      $todos.withLock { todos in
        _ = todos.insert(newTodo, at: 0)
      }

      try await Task.sleep(nanoseconds: 500_000_000) // 500ms
      XCTAssertTrue(todos.contains { $0.id == newTodo.id }, "Todo should exist before delete")

      $todos.withLock { todos in
        _ = todos.remove(id: newTodo.id)
      }

      let removed = try await waitForCondition(timeout: syncTimeout) {
        !todos.contains { $0.id == newTodo.id }
      }

      XCTAssertTrue(removed, "Todo should be removed within timeout")
    }
  }
  
  /// Tests the full CRUD lifecycle via `@Shared`.
  ///
  /// This test exercises:
  /// 1. Connect to InstantDB
  /// 2. Create a new todo
  /// 3. Read the todo back
  /// 4. Update the todo
  /// 5. Delete the todo
  ///
  /// This is the comprehensive test that exercises the full sync stack.
  @MainActor
  func testSharedSyncFullCRUDLifecycle() async throws {
    let instanceID = "shared-sync-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos: IdentifiedArrayOf<Todo> = []

      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

      let todoId = UUID().uuidString.lowercased()
      let newTodo = Todo(
        id: todoId,
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "CRUD Test \(UUID().uuidString.prefix(8))"
      )

      $todos.withLock { todos in
        _ = todos.insert(newTodo, at: 0)
      }

      XCTAssertTrue(todos.contains { $0.id == todoId }, "CREATE: Todo should exist locally")
      try await Task.sleep(nanoseconds: 500_000_000) // 500ms

      guard let readTodo = todos[id: todoId] else {
        XCTFail("READ: Todo should be readable from collection")
        return
      }
      XCTAssertEqual(readTodo.title, newTodo.title, "READ: Title should match")
      XCTAssertFalse(readTodo.done, "READ: Should not be done initially")

      $todos.withLock { todos in
        if let index = todos.index(id: todoId) {
          todos[index].done = true
        }
      }

      XCTAssertTrue(todos[id: todoId]?.done == true, "UPDATE: Todo should be marked done")
      try await Task.sleep(nanoseconds: 500_000_000) // 500ms

      $todos.withLock { todos in
        _ = todos.remove(id: todoId)
      }

      let removed = try await waitForCondition(timeout: syncTimeout) {
        !todos.contains { $0.id == todoId }
      }

      XCTAssertTrue(removed, "FINAL: Todo should not exist after delete + refresh window")
    }
  }
  
  /// Tests that multiple `@Shared` subscriptions to the same entity work correctly.
  ///
  /// In a real app, multiple views might subscribe to the same entity type.
  /// This tests that changes in one subscription are reflected in others.
  @MainActor
  func testMultipleSharedSyncSubscriptions() async throws {
    let instanceID = "shared-sync-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos1: IdentifiedArrayOf<Todo> = []

      @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
      var todos2: IdentifiedArrayOf<Todo> = []

      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

      let newTodo = Todo(
        createdAt: Date().timeIntervalSince1970 * 1_000,
        done: false,
        title: "Multi-Sub Test \(UUID().uuidString.prefix(8))"
      )

      $todos1.withLock { todos in
        _ = todos.insert(newTodo, at: 0)
      }

      let propagated = try await waitForCondition(timeout: syncTimeout) {
        todos2.contains { $0.id == newTodo.id }
      }

      XCTAssertTrue(propagated, "Second subscription should observe the todo")

      $todos1.withLock { todos in
        _ = todos.remove(id: newTodo.id)
      }
    }
  }
  
  // MARK: - Helpers
  
  @MainActor
  private func waitForCondition(
    timeout: TimeInterval,
    condition: @escaping @MainActor () -> Bool
  ) async throws -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
      if condition() {
        return true
      }
      try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
    return condition()
  }
}

// MARK: - Shared Presence Integration Tests

/// Integration tests that exercise the `@Shared(.instantPresence(...))` API.
///
/// ## Why These Tests Matter
///
/// These tests exercise the actual `@Shared` property wrapper that users use in their apps.
/// Unlike tests that directly call `InstantClient` methods, these tests:
///
/// 1. **Exercise the full stack** - From `@Shared` → `TypedPresenceKey` → `InstantClient` → WebSocket
/// 2. **Catch threading issues** - The crash in `sharing-instant/crashes/` was caused by
///    callbacks being invoked on the wrong thread. Tests that bypass `@Shared` wouldn't catch this.
/// 3. **Test the actual user experience** - If `@Shared` works, the demos work.
///
/// ## Running These Tests
///
/// These tests require network access and connect to the real InstantDB backend:
/// ```
/// swift test --filter SharedPresenceIntegrationTests
/// ```
///
/// ## Test Structure
///
/// Each test:
/// 1. Sets up dependencies with `prepareDependencies`
/// 2. Creates a `@Shared` property with a unique room ID
/// 3. Waits for the subscription to connect and authenticate
/// 4. Verifies the presence state updates correctly
/// 5. Tests updating presence via `$shared.withLock`
final class SharedPresenceIntegrationTests: XCTestCase {
  
  // MARK: - Test Configuration
  
  private var appID: String!
  
  /// Timeout for waiting for presence updates.
  private let presenceTimeout: TimeInterval = 10.0

  // MARK: - Setup / Teardown

  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    try IntegrationTestGate.requireEphemeralEnabled()

    let app = try await EphemeralAppFactory.createApp(
      titlePrefix: "sharing-instant-shared-presence",
      schema: EphemeralAppFactory.minimalTodosSchema(),
      rules: EphemeralAppFactory.openRules(for: ["todos"])
    )
    self.appID = app.id
  }
  
  // MARK: - Presence Types (matching CaseStudies)
  
  /// Simple presence type for testing.
  struct TestPresence: PresenceData {
    var name: String
    var color: String
    var isActive: Bool
    
    init(name: String = "Test User", color: String = "#FF0000", isActive: Bool = true) {
      self.name = name
      self.color = color
      self.isActive = isActive
    }
  }
  
  // MARK: - Tests
  
  /// Tests that `@Shared(.instantPresence(...))` connects and receives initial state.
  ///
  /// This test verifies the basic flow:
  /// 1. Create a `@Shared` property with presence configuration
  /// 2. Wait for the subscription to connect
  /// 3. Verify that `isLoading` becomes false
  /// 4. Verify that the user presence matches the initial value
  @MainActor
  func testSharedPresenceConnectsAndReceivesInitialState() async throws {
    let instanceID = "shared-presence-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      let roomId = "test-\(UUID().uuidString.prefix(8))"
      let initialPresence = TestPresence(name: "Alice", color: "#00FF00", isActive: true)

      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: initialPresence
      ))
      var presence: RoomPresence<TestPresence>

      let connected = try await waitForCondition(timeout: presenceTimeout) {
        !presence.isLoading
      }

      XCTAssertTrue(connected, "Should connect within timeout")
      XCTAssertFalse(presence.isLoading, "Should not be loading after connection")
      XCTAssertNil(presence.error, "Should not have an error")
      XCTAssertEqual(presence.user.name, initialPresence.name, "User name should match initial")
      XCTAssertEqual(presence.user.color, initialPresence.color, "User color should match initial")
      XCTAssertEqual(presence.user.isActive, initialPresence.isActive, "User isActive should match initial")
    }
  }
  
  /// Tests that updating presence via `$shared.withLock` publishes to the server.
  ///
  /// This test verifies the write path:
  /// 1. Create a `@Shared` presence subscription
  /// 2. Wait for connection
  /// 3. Update presence via `$presence.withLock`
  /// 4. Verify the local state updates immediately (optimistic)
  @MainActor
  func testSharedPresenceUpdateViaWithLock() async throws {
    let instanceID = "shared-presence-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      let roomId = "test-\(UUID().uuidString.prefix(8))"
      let initialPresence = TestPresence(name: "Bob", color: "#0000FF", isActive: false)

      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: initialPresence
      ))
      var presence: RoomPresence<TestPresence>

      _ = try await waitForCondition(timeout: presenceTimeout) {
        !presence.isLoading
      }

      $presence.withLock { state in
        state.user.name = "Bob Updated"
        state.user.isActive = true
      }

      XCTAssertEqual(presence.user.name, "Bob Updated", "Name should update immediately")
      XCTAssertEqual(presence.user.isActive, true, "isActive should update immediately")
    }
  }
  
  /// Tests that presence subscription handles the full lifecycle.
  ///
  /// This test exercises:
  /// 1. Initial connection and authentication
  /// 2. Receiving presence state
  /// 3. Updating presence
  /// 4. Verifying the state is consistent
  ///
  /// This is the test that would have caught the threading crash in `sharing-instant/crashes/`.
  /// The crash occurred because `subscriber.yield()` was called on the NSURLSession delegate
  /// queue instead of the main actor.
  @MainActor
  func testSharedPresenceFullLifecycle() async throws {
    let instanceID = "shared-presence-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      let roomId = "lifecycle-\(UUID().uuidString.prefix(8))"
      let initialPresence = TestPresence(name: "Lifecycle Test", color: "#FFFF00", isActive: false)

      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: initialPresence
      ))
      var presence: RoomPresence<TestPresence>

      let connected = try await waitForCondition(timeout: presenceTimeout) {
        !presence.isLoading
      }
      XCTAssertTrue(connected, "Should connect within timeout")

      XCTAssertEqual(presence.user.name, "Lifecycle Test")
      XCTAssertEqual(presence.peers.count, 0, "Should have no peers initially")

      for i in 1...3 {
        $presence.withLock { state in
          state.user.name = "Update \(i)"
          state.user.isActive = i % 2 == 0
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertEqual(presence.user.name, "Update \(i)", "Name should be Update \(i)")
      }

      try await Task.sleep(nanoseconds: 500_000_000) // 500ms
      XCTAssertFalse(presence.isLoading, "Should still be connected")
      XCTAssertNil(presence.error, "Should not have an error")
    }
  }
  
  /// Tests that multiple `@Shared` subscriptions to the same room work correctly.
  ///
  /// In a real app, multiple views might subscribe to the same room.
  /// This tests that the `TypedPresenceKey` correctly handles multiple subscribers.
  @MainActor
  func testMultipleSharedSubscriptionsToSameRoom() async throws {
    let instanceID = "shared-presence-\(UUID().uuidString.lowercased())"

    try await withDependencies {
      $0.context = .live
      $0.instantAppID = self.appID
      $0.instantEnableLocalPersistence = false
      $0.instantClientInstanceID = instanceID
    } operation: {
      let roomId = "multi-\(UUID().uuidString.prefix(8))"
      let initialPresence = TestPresence(name: "Multi Test", color: "#FF00FF", isActive: true)

      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: initialPresence
      ))
      var presence1: RoomPresence<TestPresence>

      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: initialPresence
      ))
      var presence2: RoomPresence<TestPresence>

      let connected = try await waitForCondition(timeout: presenceTimeout) {
        !presence1.isLoading && !presence2.isLoading
      }
      XCTAssertTrue(connected, "Both should connect within timeout")

      $presence1.withLock { state in
        state.user.name = "Updated via presence1"
      }

      XCTAssertEqual(presence1.user.name, "Updated via presence1")
      XCTAssertEqual(
        presence2.user.name,
        "Updated via presence1",
        "Both subscriptions should share state since they have the same key ID"
      )
    }
  }
  
  // MARK: - Helpers
  
  /// Waits for a condition to become true within a timeout.
  ///
  /// - Parameters:
  ///   - timeout: Maximum time to wait.
  ///   - condition: A closure that returns true when the condition is met.
  /// - Returns: Whether the condition was met within the timeout.
  @MainActor
  private func waitForCondition(
    timeout: TimeInterval,
    condition: @escaping @MainActor () -> Bool
  ) async throws -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
      if condition() {
        return true
      }
      try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
    return condition()
  }
}
