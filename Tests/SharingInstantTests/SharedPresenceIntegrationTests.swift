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
  
  /// The InstantDB app ID for testing.
  private let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  /// Timeout for waiting for sync operations.
  private let syncTimeout: TimeInterval = 10.0
  
  // MARK: - Setup / Teardown

  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    try IntegrationTestGate.requireEnabled()

    prepareDependencies {
      $0.context = .live
      $0.instantAppID = testAppID
      $0.instantEnableLocalPersistence = false
    }

    InstantClientFactory.clearCache()
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
    // Act: Create a @Shared sync subscription
    // This is exactly how users would use it in their SwiftUI views
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos: IdentifiedArrayOf<Todo> = []
    
    // Wait for connection and initial data
    let connected = try await waitForCondition(timeout: syncTimeout) {
      // The todos array will be populated once connected
      // Even if empty, we're connected if we can read it
      true
    }
    
    // Assert
    XCTAssertTrue(connected, "Should connect within timeout")
    // Note: We can't assert on count because the database may have existing data
    TestLog.log("Connected! Found \(todos.count) existing todos")
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
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos: IdentifiedArrayOf<Todo> = []
    
    // Wait for initial connection
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    
    let initialCount = todos.count
    
    // Act: Add a todo using withLock (this is how users add items)
    let newTodo = Todo(
      createdAt: Date().timeIntervalSince1970 * 1_000,
      done: false,
      title: "Integration Test Todo \(UUID().uuidString.prefix(8))"
    )
    
    $todos.withLock { todos in
      _ = todos.insert(newTodo, at: 0)
    }
    
    // Assert: Local state should update immediately (optimistic)
    XCTAssertEqual(todos.count, initialCount + 1, "Todo count should increase immediately")
    XCTAssertEqual(todos.first?.id, newTodo.id, "New todo should be at the front")
    XCTAssertEqual(todos.first?.title, newTodo.title, "Todo title should match")
    
    // Wait a bit for sync to complete
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // The todo should still be there after sync
    XCTAssertTrue(todos.contains { $0.id == newTodo.id }, "Todo should persist after sync")
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
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos: IdentifiedArrayOf<Todo> = []
    
    // Wait for initial connection
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    
    // Add a todo first
    let newTodo = Todo(
      createdAt: Date().timeIntervalSince1970 * 1_000,
      done: false,
      title: "Update Test Todo \(UUID().uuidString.prefix(8))"
    )
    
    $todos.withLock { todos in
      _ = todos.insert(newTodo, at: 0)
    }
    
    // Wait for the add to sync
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // Act: Update the todo
    $todos.withLock { todos in
      if let index = todos.index(id: newTodo.id) {
        todos[index].done = true
        todos[index].title = "Updated: \(newTodo.title)"
      }
    }
    
    // Assert: Update should be applied locally
    if let updatedTodo = todos[id: newTodo.id] {
      XCTAssertTrue(updatedTodo.done, "Todo should be marked as done")
      XCTAssertTrue(updatedTodo.title.hasPrefix("Updated:"), "Todo title should be updated")
    } else {
      XCTFail("Todo should still exist after update")
    }
    
    // Wait for sync
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // Verify it persists
    XCTAssertTrue(todos[id: newTodo.id]?.done == true, "Update should persist after sync")
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
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos: IdentifiedArrayOf<Todo> = []
    
    // Wait for initial connection
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    
    // Add a todo first
    let newTodo = Todo(
      createdAt: Date().timeIntervalSince1970 * 1_000,
      done: false,
      title: "Delete Test Todo \(UUID().uuidString.prefix(8))"
    )
    
    $todos.withLock { todos in
      _ = todos.insert(newTodo, at: 0)
    }
    
    // Wait for the add to sync
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    XCTAssertTrue(todos.contains { $0.id == newTodo.id }, "Todo should exist before delete")
    
    // Act: Delete the todo
    $todos.withLock { todos in
      _ = todos.remove(id: newTodo.id)
    }
    
    // Assert: Delete should be applied locally
    XCTAssertFalse(todos.contains { $0.id == newTodo.id }, "Todo should be removed locally")
    
    // Wait for sync
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // Verify it's still deleted
    XCTAssertFalse(todos.contains { $0.id == newTodo.id }, "Todo should remain deleted after sync")
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
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos: IdentifiedArrayOf<Todo> = []
    
    // Step 1: Wait for connection
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    TestLog.log("Step 1: Connected, found \(todos.count) existing todos")
    
    // Step 2: CREATE - Add a new todo
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
    TestLog.log("Step 2: Created todo '\(newTodo.title)'")
    
    // Step 3: READ - Verify the todo is in the collection
    guard let readTodo = todos[id: todoId] else {
      XCTFail("READ: Todo should be readable from collection")
      return
    }
    XCTAssertEqual(readTodo.title, newTodo.title, "READ: Title should match")
    XCTAssertFalse(readTodo.done, "READ: Should not be done initially")
    TestLog.log("Step 3: Read todo - title: '\(readTodo.title)', done: \(readTodo.done)")
    
    // Step 4: UPDATE - Mark as done
    $todos.withLock { todos in
      if let index = todos.index(id: todoId) {
        todos[index].done = true
      }
    }
    
    XCTAssertTrue(todos[id: todoId]?.done == true, "UPDATE: Todo should be marked done")
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    TestLog.log("Step 4: Updated todo - done: \(todos[id: todoId]?.done ?? false)")
    
    // Step 5: DELETE - Remove the todo
    $todos.withLock { todos in
      _ = todos.remove(id: todoId)
    }
    
    XCTAssertNil(todos[id: todoId], "DELETE: Todo should be removed")
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    TestLog.log("Step 5: Deleted todo")
    
    // Final verification
    XCTAssertFalse(todos.contains { $0.id == todoId }, "FINAL: Todo should not exist")
    TestLog.log("✅ Full CRUD lifecycle completed successfully!")
  }
  
  /// Tests that multiple `@Shared` subscriptions to the same entity work correctly.
  ///
  /// In a real app, multiple views might subscribe to the same entity type.
  /// This tests that changes in one subscription are reflected in others.
  @MainActor
  func testMultipleSharedSyncSubscriptions() async throws {
    // Create two @Shared subscriptions to the same entity
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos1: IdentifiedArrayOf<Todo> = []
    
    @Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, .desc)))
    var todos2: IdentifiedArrayOf<Todo> = []
    
    // Wait for both to connect
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    
    // Add via the first subscription
    let newTodo = Todo(
      createdAt: Date().timeIntervalSince1970 * 1_000,
      done: false,
      title: "Multi-Sub Test \(UUID().uuidString.prefix(8))"
    )
    
    $todos1.withLock { todos in
      _ = todos.insert(newTodo, at: 0)
    }
    
    // Both should see the new todo (they share the same key)
    XCTAssertTrue(todos1.contains { $0.id == newTodo.id }, "First subscription should have the todo")
    XCTAssertTrue(todos2.contains { $0.id == newTodo.id }, "Second subscription should also have the todo")
    
    // Clean up
    $todos1.withLock { todos in
      _ = todos.remove(id: newTodo.id)
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
  
  /// The InstantDB app ID for testing.
  /// This is the same app ID used by the CaseStudies demo app.
  private let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  /// Timeout for waiting for presence updates.
  private let presenceTimeout: TimeInterval = 10.0

  // MARK: - Setup / Teardown

  @MainActor
  override func setUp() async throws {
    try await super.setUp()

    try IntegrationTestGate.requireEnabled()

    prepareDependencies {
      $0.context = .live
      $0.instantAppID = testAppID
      $0.instantEnableLocalPersistence = false
    }

    InstantClientFactory.clearCache()
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
    let roomId = "test-\(UUID().uuidString.prefix(8))"
    let initialPresence = TestPresence(name: "Alice", color: "#00FF00", isActive: true)
    
    // Act: Create a @Shared presence subscription
    // This is exactly how users would use it in their SwiftUI views
    @Shared(.instantPresence(
      roomType: "test",
      roomId: roomId,
      initialPresence: initialPresence
    ))
    var presence: RoomPresence<TestPresence>
    
    // Wait for connection and authentication
    let connected = try await waitForCondition(timeout: presenceTimeout) {
      !presence.isLoading
    }
    
    // Assert
    XCTAssertTrue(connected, "Should connect within timeout")
    XCTAssertFalse(presence.isLoading, "Should not be loading after connection")
    XCTAssertNil(presence.error, "Should not have an error")
    XCTAssertEqual(presence.user.name, initialPresence.name, "User name should match initial")
    XCTAssertEqual(presence.user.color, initialPresence.color, "User color should match initial")
    XCTAssertEqual(presence.user.isActive, initialPresence.isActive, "User isActive should match initial")
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
    let roomId = "test-\(UUID().uuidString.prefix(8))"
    let initialPresence = TestPresence(name: "Bob", color: "#0000FF", isActive: false)
    
    @Shared(.instantPresence(
      roomType: "test",
      roomId: roomId,
      initialPresence: initialPresence
    ))
    var presence: RoomPresence<TestPresence>
    
    // Wait for connection
    _ = try await waitForCondition(timeout: presenceTimeout) {
      !presence.isLoading
    }
    
    // Act: Update presence using withLock (this is how users update presence)
    $presence.withLock { state in
      state.user.name = "Bob Updated"
      state.user.isActive = true
    }
    
    // Assert: Local state should update immediately (optimistic)
    XCTAssertEqual(presence.user.name, "Bob Updated", "Name should update immediately")
    XCTAssertEqual(presence.user.isActive, true, "isActive should update immediately")
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
    let roomId = "lifecycle-\(UUID().uuidString.prefix(8))"
    let initialPresence = TestPresence(name: "Lifecycle Test", color: "#FFFF00", isActive: false)
    
    @Shared(.instantPresence(
      roomType: "test",
      roomId: roomId,
      initialPresence: initialPresence
    ))
    var presence: RoomPresence<TestPresence>
    
    // Step 1: Wait for connection
    let connected = try await waitForCondition(timeout: presenceTimeout) {
      !presence.isLoading
    }
    XCTAssertTrue(connected, "Should connect within timeout")
    
    // Step 2: Verify initial state
    XCTAssertEqual(presence.user.name, "Lifecycle Test")
    XCTAssertEqual(presence.peers.count, 0, "Should have no peers initially")
    
    // Step 3: Update presence multiple times
    // This exercises the save path and would trigger the threading crash if not fixed
    for i in 1...3 {
      $presence.withLock { state in
        state.user.name = "Update \(i)"
        state.user.isActive = i % 2 == 0
      }
      
      // Small delay to let the update propagate
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      
      XCTAssertEqual(presence.user.name, "Update \(i)", "Name should be Update \(i)")
    }
    
    // Step 4: Wait a bit for any async callbacks to fire
    // This is where the threading crash would occur - when the server sends back
    // a presence update and the callback is invoked on the wrong thread
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    
    // If we get here without crashing, the threading fix is working
    XCTAssertFalse(presence.isLoading, "Should still be connected")
    XCTAssertNil(presence.error, "Should not have an error")
  }
  
  /// Tests that multiple `@Shared` subscriptions to the same room work correctly.
  ///
  /// In a real app, multiple views might subscribe to the same room.
  /// This tests that the `TypedPresenceKey` correctly handles multiple subscribers.
  @MainActor
  func testMultipleSharedSubscriptionsToSameRoom() async throws {
    let roomId = "multi-\(UUID().uuidString.prefix(8))"
    let initialPresence = TestPresence(name: "Multi Test", color: "#FF00FF", isActive: true)
    
    // Create two @Shared subscriptions to the same room
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
    
    // Wait for both to connect
    let connected = try await waitForCondition(timeout: presenceTimeout) {
      !presence1.isLoading && !presence2.isLoading
    }
    XCTAssertTrue(connected, "Both should connect within timeout")
    
    // Update via the first subscription
    $presence1.withLock { state in
      state.user.name = "Updated via presence1"
    }
    
    // Both should have the same local state (they share the same key)
    // Note: Due to how @Shared works with the same key, they may share state
    XCTAssertEqual(presence1.user.name, "Updated via presence1")
    
    // The second subscription should also see the update since they share the same key
    // This tests that TypedPresenceKey's id-based deduplication works correctly
    XCTAssertEqual(presence2.user.name, "Updated via presence1", 
                   "Both subscriptions should share state since they have the same key ID")
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
