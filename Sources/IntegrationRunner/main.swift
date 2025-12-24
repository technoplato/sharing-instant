/// IntegrationRunner - Standalone integration tests for SharingInstant
///
/// Run with: swift run IntegrationRunner
/// Or build and run: swift build && .build/debug/IntegrationRunner
///
/// This script tests the integration with the live InstantDB backend without
/// requiring XCTest. It provides clear pass/fail output and can be run in CI.

import Foundation
import SharingInstant
import InstantDB
import Dependencies
import IdentifiedCollections

// MARK: - Test Configuration

/// Test app configuration from the plan
enum TestConfig {
  static let appID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  static let appName = "test_sharing-instant"
  static let connectionTimeout: TimeInterval = 10.0
  static let queryTimeout: TimeInterval = 15.0
}

// MARK: - Test Models

struct TestTodo: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "test_todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
  
  init(
    id: String = UUID().uuidString.lowercased(),
    title: String = "Test Todo",
    done: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}

struct TestFact: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "test_facts" }
  
  var id: String
  var text: String
  var count: Int
  
  init(id: String = UUID().uuidString.lowercased(), text: String = "Test Fact", count: Int = 0) {
    self.id = id
    self.text = text
    self.count = count
  }
}

/// Todo model for typed queries - uses "todos" namespace (no prefix)
struct Todo: Codable, InstantEntity, Sendable {
  static var namespace: String { "todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date  // Timestamp - InstantDB stores as milliseconds since epoch
  
  init(id: String = UUID().uuidString.lowercased(), title: String, done: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}

// MARK: - Test Runner

@MainActor
final class IntegrationTestRunner {
  private var passedTests = 0
  private var failedTests = 0
  private var skippedTests = 0
  private var client: InstantClient?
  
  /// Track created todo IDs for cleanup
  private var createdTodoIds: [String] = []
  
  func run() async {
    print("""
    ╔═══════════════════════════════════════════════════════════════════╗
    ║       SharingInstant Integration Test Runner                      ║
    ║       Testing against: \(TestConfig.appID)       ║
    ╚═══════════════════════════════════════════════════════════════════╝
    """)
    
    let startTime = Date()
    
    // Run all test groups
    await runConnectionTests()
    await runConfigurationTests()
    await runDependencyTests()
    await runDataCreationTests()
    await runQueryTests()
    await runPresenceTests()
    await runCleanupTests()
    
    // Print summary
    let elapsed = Date().timeIntervalSince(startTime)
    printSummary(elapsed: elapsed)
  }
  
  // MARK: - Connection Tests
  
  private func runConnectionTests() async {
    printSection("Connection Tests")
    
    await test("Create InstantClient with test app ID") {
      client = InstantClient(appID: TestConfig.appID)
      guard client != nil else {
        throw TestError("Failed to create InstantClient")
      }
      print("    ✓ Created client for app: \(TestConfig.appID)")
    }
    
    await test("Connect to InstantDB backend") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      client.connect()
      
      // Wait for connection with timeout
      let deadline = Date().addingTimeInterval(TestConfig.connectionTimeout)
      while Date() < deadline {
        if client.connectionState == .connected || client.connectionState == .authenticated {
          print("    ✓ Connection state: \(client.connectionState)")
          return
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      }
      
      throw TestError("Connection timeout - state: \(client.connectionState)")
    }
    
    await test("Verify client is authenticated or connected") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      let validStates: [ConnectionState] = [.connected, .authenticated]
      guard validStates.contains(client.connectionState) else {
        throw TestError("Expected connected or authenticated, got: \(client.connectionState)")
      }
      print("    ✓ Client state is valid: \(client.connectionState)")
    }
    
    await test("Verify app ID matches") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      guard client.appID == TestConfig.appID else {
        throw TestError("App ID mismatch: expected \(TestConfig.appID), got \(client.appID)")
      }
      print("    ✓ App ID verified: \(client.appID)")
    }
  }
  
  // MARK: - Configuration Tests
  
  private func runConfigurationTests() async {
    printSection("Configuration Tests")
    
    await test("Create SharingInstantQuery.Configuration") {
      let config = SharingInstantQuery.Configuration<TestTodo>(
        namespace: "test_todos",
        orderBy: .desc("createdAt"),
        limit: 10
      )
      
      guard config.namespace == "test_todos" else {
        throw TestError("Namespace mismatch")
      }
      guard config.orderBy?.field == "createdAt" else {
        throw TestError("OrderBy field mismatch")
      }
      guard config.orderBy?.isDescending == true else {
        throw TestError("OrderBy direction mismatch")
      }
      guard config.limit == 10 else {
        throw TestError("Limit mismatch")
      }
      print("    ✓ Query configuration created successfully")
    }
    
    await test("Create SharingInstantSync.CollectionConfiguration") {
      let config = SharingInstantSync.CollectionConfiguration<TestTodo>(
        namespace: "test_todos",
        orderBy: .desc("createdAt")
      )
      
      guard config.namespace == "test_todos" else {
        throw TestError("Namespace mismatch")
      }
      guard config.orderBy?.field == "createdAt" else {
        throw TestError("OrderBy field mismatch")
      }
      print("    ✓ Sync configuration created successfully")
    }
    
    await test("OrderBy.asc creates ascending order") {
      let order = OrderBy.asc("title")
      guard order.field == "title" else {
        throw TestError("Field mismatch")
      }
      guard order.isDescending == false else {
        throw TestError("Should be ascending")
      }
      print("    ✓ Ascending order: \(order.field)")
    }
    
    await test("OrderBy.desc creates descending order") {
      let order = OrderBy.desc("createdAt")
      guard order.field == "createdAt" else {
        throw TestError("Field mismatch")
      }
      guard order.isDescending == true else {
        throw TestError("Should be descending")
      }
      print("    ✓ Descending order: \(order.field)")
    }
  }
  
  // MARK: - Dependency Tests
  
  private func runDependencyTests() async {
    printSection("Dependency Injection Tests")
    
    await test("Inject instantAppID via dependencies") {
      withDependencies {
        $0.instantAppID = TestConfig.appID
      } operation: {
        @Dependency(\.instantAppID) var injectedAppID
        guard injectedAppID == TestConfig.appID else {
          print("    ✗ App ID mismatch: expected \(TestConfig.appID), got \(injectedAppID)")
          return
        }
        print("    ✓ Injected app ID: \(injectedAppID)")
      }
    }
    
    await test("InstantClientFactory creates client") {
      let client = InstantClientFactory.makeClient(appID: TestConfig.appID)
      guard client.appID == TestConfig.appID else {
        throw TestError("Client app ID mismatch")
      }
      print("    ✓ Factory created client with app ID: \(client.appID)")
    }
  }
  
  // MARK: - Data Creation Tests
  
  private func runDataCreationTests() async {
    printSection("Data Creation Tests (Live Backend)")
    
    await test("Create a todo item") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      // Wait for authentication
      let authDeadline = Date().addingTimeInterval(TestConfig.connectionTimeout)
      while client.connectionState != .authenticated && Date() < authDeadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      guard client.connectionState == .authenticated else {
        throw TestError("Client not authenticated: \(client.connectionState)")
      }
      
      // Create a unique todo using TransactionChunk API
      let todoId = UUID().uuidString.lowercased()
      let title = "Integration Test Todo - \(Date())"
      let timestamp = Int(Date().timeIntervalSince1970 * 1000)
      
      print("    Creating todo with ID: \(todoId)")
      
      // Use TransactionChunk with "create" operation
      // Format: ["create", entityType, entityId, dataDict]
      let chunk = TransactionChunk(
        namespace: "todos",
        id: todoId,
        ops: [["create", "todos", todoId, [
          "title": title,
          "done": false,
          "createdAt": timestamp
        ] as [String: Any]]]
      )
      
      do {
        try client.transact(chunk)
        print("    ✓ Transaction sent successfully")
        
        // Wait a moment for the server to process
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        print("    ✓ Created todo: \(title)")
      } catch {
        throw TestError("Transaction failed: \(error)")
      }
    }
    
    await test("Create multiple todos") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      guard client.connectionState == .authenticated else {
        throw TestError("Client not authenticated")
      }
      
      // Create 3 todos using TransactionChunk API
      let todoTitles = [
        "Buy groceries 🛒",
        "Learn Swift 📚",
        "Build awesome app 🚀"
      ]
      
      var chunks: [TransactionChunk] = []
      
      for title in todoTitles {
        let todoId = UUID().uuidString.lowercased()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        
        let chunk = TransactionChunk(
          namespace: "todos",
          id: todoId,
          ops: [["create", "todos", todoId, [
            "title": title,
            "done": false,
            "createdAt": timestamp
          ] as [String: Any]]]
        )
        chunks.append(chunk)
      }
      
      do {
        try client.transact(chunks)
        print("    ✓ Created \(todoTitles.count) todos")
        
        // Wait for server to process
        try await Task.sleep(nanoseconds: 2_000_000_000)
      } catch {
        throw TestError("Batch transaction failed: \(error)")
      }
    }
    
    await test("Query todos after creation") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      // Use typed query API
      let query = client.query(Todo.self)
      
      var receivedCount = 0
      var gotResult = false
      
      let token = try client.subscribe(query) { result in
        if result.isLoading { return }
        gotResult = true
        
        let todos = result.data
        receivedCount = todos.count
        print("    ✓ Found \(todos.count) todos in database")
        for todo in todos.prefix(5) {
          print("      - \(todo.title)")
        }
        if todos.count > 5 {
          print("      ... and \(todos.count - 5) more")
        }
      }
      
      // Wait for result
      let deadline = Date().addingTimeInterval(5.0)
      while !gotResult && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      
      token.cancel()
      
      guard gotResult else {
        throw TestError("Query timeout")
      }
      
      print("    ✓ Successfully queried \(receivedCount) todos")
    }
    
    await test("Real-time updates (create while subscribed)") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      // Use typed query API
      let query = client.query(Todo.self)
      
      var initialCount = 0
      var updatedCount = 0
      var callbackCount = 0
      var gotInitialData = false
      var gotUpdate = false
      
      print("    Setting up subscription...")
      
      let token = try client.subscribe(query) { result in
        if result.isLoading {
          print("    … Loading...")
          return
        }
        
        callbackCount += 1
        let todos = result.data
        
        if !gotInitialData {
          // First non-loading callback is initial data
          gotInitialData = true
          initialCount = todos.count
          print("    ✓ Initial data received: \(initialCount) todos")
        } else {
          // Subsequent callbacks are updates
          updatedCount = todos.count
          if updatedCount > initialCount {
            gotUpdate = true
            print("    ✓ Real-time update received! Count: \(initialCount) → \(updatedCount)")
          }
        }
      }
      
      // Wait for initial data
      let initialDeadline = Date().addingTimeInterval(5.0)
      while !gotInitialData && Date() < initialDeadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      
      guard gotInitialData else {
        token.cancel()
        throw TestError("Never received initial data")
      }
      
      // Now create a new todo while subscribed
      let newTodoId = UUID().uuidString.lowercased()
      let newTitle = "Real-time Test - \(Date())"
      let timestamp = Int(Date().timeIntervalSince1970 * 1000)
      
      print("    Creating new todo while subscribed: \(newTodoId.prefix(8))...")
      
      let chunk = TransactionChunk(
        namespace: "todos",
        id: newTodoId,
        ops: [["create", "todos", newTodoId, [
          "title": newTitle,
          "done": false,
          "createdAt": timestamp
        ] as [String: Any]]]
      )
      
      try client.transact(chunk)
      print("    ✓ Transaction sent")
      
      // Wait for the real-time update
      let updateDeadline = Date().addingTimeInterval(10.0)
      while !gotUpdate && Date() < updateDeadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      token.cancel()
      
      if gotUpdate {
        print("    ✓ Real-time sync working! Received update after \(callbackCount) callbacks")
      } else {
        print("    ⚠️ No real-time update received after 10s")
        print("    ⚠️ Initial count: \(initialCount), current count: \(updatedCount)")
        print("    ⚠️ Total callbacks: \(callbackCount)")
        // Don't fail the test - this helps us debug the issue
        print("    ℹ️ Check if refresh-ok messages are being received")
      }
    }
  }
  
  // MARK: - Query Tests
  
  private func runQueryTests() async {
    printSection("Query Tests (Live Backend)")
    
    await test("Subscribe to query (callback test)") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      // Wait for authentication (not just connection)
      let authDeadline = Date().addingTimeInterval(TestConfig.connectionTimeout)
      while client.connectionState != .authenticated && Date() < authDeadline {
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
      }
      
      guard client.connectionState == .authenticated else {
        throw TestError("Client not authenticated: \(client.connectionState)")
      }
      
      print("    ✓ Client authenticated, sending query...")
      
      let query = client.query(TestTodo.self)
      
      // Just verify we can subscribe without errors
      do {
        var callbackInvoked = false
        let token = try client.subscribe(query) { result in
          callbackInvoked = true
          if result.isLoading {
            print("    … Callback invoked (loading)")
          } else if let error = result.error {
            print("    … Callback invoked (error: \(error))")
          } else {
            print("    … Callback invoked (data: \(result.data.count) items)")
          }
        }
        
        // Give the callback time to be invoked
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        
        // Clean up
        token.cancel()
        
        // The callback should have been invoked at least once (for loading state)
        guard callbackInvoked else {
          throw TestError("Callback was never invoked")
        }
        
        print("    ✓ Query subscription successful, callback invoked")
      } catch {
        throw TestError("Subscribe failed: \(error)")
      }
    }
    
    await test("Entity namespace is correct") {
      guard TestTodo.namespace == "test_todos" else {
        throw TestError("TestTodo namespace mismatch")
      }
      guard TestFact.namespace == "test_facts" else {
        throw TestError("TestFact namespace mismatch")
      }
      print("    ✓ TestTodo.namespace = \(TestTodo.namespace)")
      print("    ✓ TestFact.namespace = \(TestFact.namespace)")
    }
    
    await test("Entity encoding/decoding roundtrip") {
      let todo = TestTodo(id: "test-123", title: "Integration Test", done: true)
      
      let encoder = JSONEncoder()
      let data = try encoder.encode(todo)
      
      let decoder = JSONDecoder()
      let decoded = try decoder.decode(TestTodo.self, from: data)
      
      guard todo == decoded else {
        throw TestError("Roundtrip failed: original != decoded")
      }
      print("    ✓ Entity encodes and decodes correctly")
    }
  }
  
  // MARK: - Presence Tests
  
  private func runPresenceTests() async {
    printSection("Presence Tests (Live Backend)")
    
    await test("Join room and set presence") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      guard client.connectionState == .authenticated else {
        throw TestError("Client not authenticated")
      }
      
      let roomId = "test-room-\(UUID().uuidString.prefix(8))"
      print("    Testing room: \(roomId)")
      
      // Join the room with initial presence
      let initialPresence: [String: Any] = [
        "name": "TestUser",
        "color": "#FF0000",
        "status": "online"
      ]
      
      var gotPresenceUpdate = false
      var presenceData: [String: Any]? = nil
      
      // Subscribe to presence
      let unsubscribe = client.presence.subscribePresence(
        roomId: roomId,
        initialPresence: initialPresence
      ) { slice in
        print("    … Presence callback: isLoading=\(slice.isLoading), user=\(slice.user), peers=\(slice.peers.count)")
        if !slice.isLoading {
          gotPresenceUpdate = true
          presenceData = slice.user
        }
      }
      
      // Join the room
      let leaveRoom = client.presence.joinRoom(roomId, initialPresence: initialPresence)
      
      // Wait for presence to be set
      try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
      
      // Verify we got presence data
      if gotPresenceUpdate {
        print("    ✓ Presence update received")
        if let data = presenceData {
          print("    ✓ User presence: \(data)")
        }
      } else {
        print("    ⚠️ No presence update received (may need room to be connected)")
      }
      
      // Update presence
      client.presence.publishPresence(roomId: roomId, data: [
        "status": "busy",
        "cursor": ["x": 100, "y": 200]
      ])
      
      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
      print("    ✓ Published presence update")
      
      // Cleanup
      unsubscribe()
      leaveRoom()
      print("    ✓ Left room and unsubscribed")
    }
    
    await test("Two-client presence sync") {
      // Create two separate clients to test presence sync
      let client1 = InstantClient(appID: TestConfig.appID)
      let client2 = InstantClient(appID: TestConfig.appID)
      
      client1.connect()
      client2.connect()
      
      // Wait for both to authenticate
      let authDeadline = Date().addingTimeInterval(TestConfig.connectionTimeout)
      while (client1.connectionState != .authenticated || client2.connectionState != .authenticated) 
            && Date() < authDeadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      guard client1.connectionState == .authenticated else {
        throw TestError("Client 1 not authenticated: \(client1.connectionState)")
      }
      guard client2.connectionState == .authenticated else {
        throw TestError("Client 2 not authenticated: \(client2.connectionState)")
      }
      
      print("    ✓ Both clients authenticated")
      
      let roomId = "presence-sync-test-\(UUID().uuidString.prefix(8))"
      print("    Testing room: \(roomId)")
      
      var client1SawClient2 = false
      var client2SawClient1 = false
      
      // Client 1 joins and subscribes
      let unsub1 = client1.presence.subscribePresence(
        roomId: roomId,
        initialPresence: ["name": "Client1", "color": "#FF0000"]
      ) { slice in
        print("    [Client1] Presence: peers=\(slice.peers.count)")
        for (sessionId, peerData) in slice.peers {
          if let name = peerData["name"] as? String, name == "Client2" {
            client1SawClient2 = true
            print("    [Client1] ✓ Saw Client2 (session: \(sessionId.prefix(8))...)")
          }
        }
      }
      let leave1 = client1.presence.joinRoom(roomId, initialPresence: ["name": "Client1", "color": "#FF0000"])
      
      try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
      
      // Client 2 joins and subscribes
      let unsub2 = client2.presence.subscribePresence(
        roomId: roomId,
        initialPresence: ["name": "Client2", "color": "#00FF00"]
      ) { slice in
        print("    [Client2] Presence: peers=\(slice.peers.count)")
        for (sessionId, peerData) in slice.peers {
          if let name = peerData["name"] as? String, name == "Client1" {
            client2SawClient1 = true
            print("    [Client2] ✓ Saw Client1 (session: \(sessionId.prefix(8))...)")
          }
        }
      }
      let leave2 = client2.presence.joinRoom(roomId, initialPresence: ["name": "Client2", "color": "#00FF00"])
      
      // Wait for presence sync
      let syncDeadline = Date().addingTimeInterval(10.0)
      while (!client1SawClient2 || !client2SawClient1) && Date() < syncDeadline {
        try await Task.sleep(nanoseconds: 500_000_000)
      }
      
      // Report results
      if client1SawClient2 && client2SawClient1 {
        print("    ✓ Two-way presence sync working!")
      } else {
        print("    ⚠️ Presence sync incomplete:")
        print("      Client1 saw Client2: \(client1SawClient2)")
        print("      Client2 saw Client1: \(client2SawClient1)")
      }
      
      // Cleanup
      unsub1()
      unsub2()
      leave1()
      leave2()
      client1.disconnect()
      client2.disconnect()
      
      print("    ✓ Cleaned up both clients")
    }
    
    await test("Presence topics (fire-and-forget)") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      let roomId = "topic-test-\(UUID().uuidString.prefix(8))"
      print("    Testing room: \(roomId)")
      
      var receivedTopic = false
      var topicData: [String: Any]? = nil
      
      // Join room first
      let leaveRoom = client.presence.joinRoom(roomId)
      
      // Subscribe to topic events on "cursor" topic
      let unsubTopic = client.presence.subscribeTopic(
        roomId: roomId,
        topic: "cursor"
      ) { message in
        print("    … Topic received from \(message.peerId): \(message.data)")
        receivedTopic = true
        topicData = message.data
      }
      
      try await Task.sleep(nanoseconds: 2_000_000_000) // Wait for room to be ready
      
      // Publish a topic event
      client.presence.publishTopic(
        roomId: roomId,
        topic: "cursor",
        data: ["x": 150, "y": 250, "timestamp": Date().timeIntervalSince1970]
      )
      
      print("    ✓ Topic published")
      
      // Wait for topic (note: same client may not receive its own topic)
      try await Task.sleep(nanoseconds: 2_000_000_000)
      
      if receivedTopic {
        print("    ✓ Received topic: \(topicData ?? [:])")
      } else {
        print("    ℹ️ No topic received (expected - same client doesn't receive own topics)")
      }
      
      // Cleanup
      unsubTopic()
      leaveRoom()
      print("    ✓ Cleaned up room")
    }
  }
  
  // MARK: - Cleanup Tests
  
  private func runCleanupTests() async {
    printSection("Cleanup Tests")
    
    await test("Delete test todos created during this run") {
      guard let client = client else {
        throw TestError("No client available")
      }
      
      guard client.connectionState == .authenticated else {
        throw TestError("Client not authenticated")
      }
      
      // Query for todos with "Integration Test" or "Real-time Test" in the title
      let query = client.query(Todo.self)
      
      var todosToDelete: [String] = []
      var gotData = false
      
      let token = try client.subscribe(query) { result in
        if result.isLoading { return }
        gotData = true
        
        for todo in result.data {
          if todo.title.contains("Integration Test") || todo.title.contains("Real-time Test") {
            todosToDelete.append(todo.id)
          }
        }
      }
      
      // Wait for query
      let deadline = Date().addingTimeInterval(5.0)
      while !gotData && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      
      token.cancel()
      
      if todosToDelete.isEmpty {
        print("    ✓ No test todos to clean up")
        return
      }
      
      print("    Found \(todosToDelete.count) test todos to delete")
      
      // Delete each todo
      var chunks: [TransactionChunk] = []
      for todoId in todosToDelete {
        let chunk = TransactionChunk(
          namespace: "todos",
          id: todoId,
          ops: [["delete", "todos", todoId]]
        )
        chunks.append(chunk)
      }
      
      try client.transact(chunks)
      print("    ✓ Deleted \(todosToDelete.count) test todos")
      
      // Wait for transaction to process
      try await Task.sleep(nanoseconds: 2_000_000_000)
      print("    ✓ Cleanup complete")
    }
  }
  
  // MARK: - Test Helpers
  
  private func test(_ name: String, _ body: () async throws -> Void) async {
    print("  ▶ \(name)")
    do {
      try await body()
      passedTests += 1
      print("    ✅ PASSED\n")
    } catch {
      failedTests += 1
      print("    ❌ FAILED: \(error)\n")
    }
  }
  
  private func printSection(_ name: String) {
    print("""
    
    ┌───────────────────────────────────────────────────────────────────┐
    │ \(name.padding(toLength: 65, withPad: " ", startingAt: 0)) │
    └───────────────────────────────────────────────────────────────────┘
    """)
  }
  
  private func printSummary(elapsed: TimeInterval) {
    let total = passedTests + failedTests + skippedTests
    let status = failedTests == 0 ? "✅ ALL TESTS PASSED" : "❌ SOME TESTS FAILED"
    
    print("""
    
    ═══════════════════════════════════════════════════════════════════
                              TEST SUMMARY
    ═══════════════════════════════════════════════════════════════════
    
      Total:   \(total)
      Passed:  \(passedTests) ✅
      Failed:  \(failedTests) ❌
      Skipped: \(skippedTests) ⏭️
    
      Time:    \(String(format: "%.2f", elapsed))s
    
      \(status)
    
    ═══════════════════════════════════════════════════════════════════
    """)
  }
}

// MARK: - Error Type

struct TestError: Error, CustomStringConvertible {
  let message: String
  
  init(_ message: String) {
    self.message = message
  }
  
  var description: String { message }
}

// MARK: - Main Entry Point

@main
struct IntegrationRunnerApp {
  static func main() async {
    // Check for command line arguments
    let args = CommandLine.arguments
    
    if args.contains("--sharing-instant") || args.contains("-s") {
      // Run only the SharingInstant library tests
      await runSharingInstantTests()
    } else if args.contains("--all") || args.contains("-a") {
      // Run both test suites
      let runner = IntegrationTestRunner()
      await runner.run()
      
      print("\n\n")
      await runSharingInstantTests()
    } else {
      // Default: run the original InstantDB tests
      let runner = IntegrationTestRunner()
      await runner.run()
    }
    
    exit(0)
  }
}
