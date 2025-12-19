import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - CaseStudies Integration Tests

/// Integration tests that exercise the actual CaseStudies functionality against InstantDB.
///
/// These tests verify that the demos in CaseStudies work correctly with the real backend:
/// - Connection and authentication
/// - Presence (Avatar Stack, Cursors, Typing Indicators)
/// - Topics (real-time messaging)
/// - Queries and Sync (Todo lists)
///
/// ## Running These Tests
///
/// These tests require network access and will connect to the real InstantDB backend.
/// Run with:
/// ```
/// swift test --filter CaseStudiesIntegrationTests
/// ```
///
/// Or run the full integration suite:
/// ```
/// swift run IntegrationRunner
/// ```
///
/// ## Test App Configuration
///
/// Uses test app: b9319949-2f2d-410b-8f8a-6990177c1d44
/// Schema defined in: Examples/CaseStudies/instant.schema.ts
final class CaseStudiesIntegrationTests: XCTestCase {
  
  /// The test InstantDB app ID
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  /// Connection timeout in seconds
  static let connectionTimeout: TimeInterval = 10.0
  
  /// Query timeout in seconds
  static let queryTimeout: TimeInterval = 15.0
  
  var client: InstantClient!
  
  // MARK: - Setup / Teardown
  
  @MainActor
  override func setUp() async throws {
    try await super.setUp()
    
    // Create client and wait for authentication
    client = InstantClient(appID: Self.testAppID)
    client.connect()
    
    // Wait for authentication with timeout
    let deadline = Date().addingTimeInterval(Self.connectionTimeout)
    while client.connectionState != .authenticated && Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    
    guard client.connectionState == .authenticated else {
      XCTFail("Client failed to authenticate within \(Self.connectionTimeout)s. State: \(client.connectionState)")
      return
    }
  }
  
  @MainActor
  override func tearDown() async throws {
    client?.disconnect()
    client = nil
    try await super.tearDown()
  }
  
  // MARK: - Connection Tests
  
  @MainActor
  func testClientConnectsAndAuthenticates() async throws {
    // Client should already be authenticated from setUp
    XCTAssertEqual(client.connectionState, .authenticated)
    XCTAssertEqual(client.appID, Self.testAppID)
  }
  
  // MARK: - Presence Tests (Avatar Stack Demo)
  
  @MainActor
  func testAvatarStackPresence() async throws {
    // Simulate what AvatarStackDemo does:
    // 1. Join a room with presence
    // 2. Set user presence (name, color)
    // 3. Verify presence is received
    
    let roomId = "avatarStack-test-\(UUID().uuidString.prefix(8))"
    let testPresence: [String: Any] = [
      "name": "TestUser",
      "color": "#FF5733"
    ]
    
    var receivedPresence = false
    var presenceSlice: PresenceSlice?
    
    // Subscribe to presence
    let unsubscribe = client.presence.subscribePresence(
      roomId: roomId,
      initialPresence: testPresence
    ) { slice in
      if !slice.isLoading {
        receivedPresence = true
        presenceSlice = slice
      }
    }
    
    // Join room
    let leaveRoom = client.presence.joinRoom(roomId, initialPresence: testPresence)
    
    // Wait for presence update
    let deadline = Date().addingTimeInterval(5.0)
    while !receivedPresence && Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    // Verify
    XCTAssertTrue(receivedPresence, "Should receive presence update")
    XCTAssertNotNil(presenceSlice)
    XCTAssertEqual(presenceSlice?.user["name"] as? String, "TestUser")
    XCTAssertEqual(presenceSlice?.user["color"] as? String, "#FF5733")
    
    // Cleanup
    unsubscribe()
    leaveRoom()
  }
  
  // MARK: - Two-Client Presence Sync
  
  @MainActor
  func testTwoClientPresenceSync() async throws {
    // Create two clients to test presence sync (like two users in Avatar Stack)
    let client1 = InstantClient(appID: Self.testAppID)
    let client2 = InstantClient(appID: Self.testAppID)
    
    client1.connect()
    client2.connect()
    
    // Wait for both to authenticate
    let authDeadline = Date().addingTimeInterval(Self.connectionTimeout)
    while (client1.connectionState != .authenticated || client2.connectionState != .authenticated)
          && Date() < authDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    XCTAssertEqual(client1.connectionState, .authenticated, "Client 1 should authenticate")
    XCTAssertEqual(client2.connectionState, .authenticated, "Client 2 should authenticate")
    
    let roomId = "presence-sync-\(UUID().uuidString.prefix(8))"
    
    var client1SawClient2 = false
    var client2SawClient1 = false
    
    // Client 1 joins with presence
    let unsub1 = client1.presence.subscribePresence(
      roomId: roomId,
      initialPresence: ["name": "Alice", "color": "#FF0000"]
    ) { slice in
      for (_, peerData) in slice.peers {
        if peerData["name"] as? String == "Bob" {
          client1SawClient2 = true
        }
      }
    }
    let leave1 = client1.presence.joinRoom(roomId, initialPresence: ["name": "Alice", "color": "#FF0000"])
    
    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    
    // Client 2 joins with presence
    let unsub2 = client2.presence.subscribePresence(
      roomId: roomId,
      initialPresence: ["name": "Bob", "color": "#00FF00"]
    ) { slice in
      for (_, peerData) in slice.peers {
        if peerData["name"] as? String == "Alice" {
          client2SawClient1 = true
        }
      }
    }
    let leave2 = client2.presence.joinRoom(roomId, initialPresence: ["name": "Bob", "color": "#00FF00"])
    
    // Wait for presence sync
    let syncDeadline = Date().addingTimeInterval(10.0)
    while (!client1SawClient2 || !client2SawClient1) && Date() < syncDeadline {
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    
    // Verify
    XCTAssertTrue(client1SawClient2, "Client 1 should see Client 2's presence")
    XCTAssertTrue(client2SawClient1, "Client 2 should see Client 1's presence")
    
    // Cleanup
    unsub1()
    unsub2()
    leave1()
    leave2()
    client1.disconnect()
    client2.disconnect()
  }
  
  // MARK: - Typing Indicator Tests
  
  @MainActor
  func testTypingIndicatorPresence() async throws {
    // Simulate TypingIndicatorDemo: set isTyping in presence
    let roomId = "typing-\(UUID().uuidString.prefix(8))"
    
    var receivedTypingState = false
    var isTyping = false
    
    let unsubscribe = client.presence.subscribePresence(
      roomId: roomId,
      initialPresence: ["name": "TestUser", "isTyping": false]
    ) { slice in
      if !slice.isLoading {
        receivedTypingState = true
        isTyping = slice.user["isTyping"] as? Bool ?? false
      }
    }
    
    let leaveRoom = client.presence.joinRoom(roomId, initialPresence: ["name": "TestUser", "isTyping": false])
    
    // Wait for initial presence
    let deadline = Date().addingTimeInterval(5.0)
    while !receivedTypingState && Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    XCTAssertTrue(receivedTypingState)
    XCTAssertFalse(isTyping)
    
    // Update typing state
    receivedTypingState = false
    client.presence.publishPresence(roomId: roomId, data: ["isTyping": true])
    
    // Wait for update
    let updateDeadline = Date().addingTimeInterval(5.0)
    while !receivedTypingState && Date() < updateDeadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    XCTAssertTrue(isTyping, "Typing state should update to true")
    
    // Cleanup
    unsubscribe()
    leaveRoom()
  }
  
  // MARK: - Cursor Tests
  
  @MainActor
  func testCursorPositionUpdates() async throws {
    // Simulate CursorsDemo: track cursor position in presence
    let roomId = "cursors-\(UUID().uuidString.prefix(8))"
    
    var receivedCursor = false
    var cursorX: Double = 0
    var cursorY: Double = 0
    
    let unsubscribe = client.presence.subscribePresence(
      roomId: roomId,
      initialPresence: ["cursor": ["x": 0, "y": 0]]
    ) { slice in
      if !slice.isLoading {
        if let cursor = slice.user["cursor"] as? [String: Any] {
          cursorX = cursor["x"] as? Double ?? 0
          cursorY = cursor["y"] as? Double ?? 0
          receivedCursor = true
        }
      }
    }
    
    let leaveRoom = client.presence.joinRoom(roomId, initialPresence: ["cursor": ["x": 0, "y": 0]])
    
    // Wait for initial presence
    let deadline = Date().addingTimeInterval(5.0)
    while !receivedCursor && Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    XCTAssertTrue(receivedCursor)
    
    // Update cursor position
    receivedCursor = false
    client.presence.publishPresence(roomId: roomId, data: ["cursor": ["x": 100.5, "y": 200.5]])
    
    // Wait for update
    let updateDeadline = Date().addingTimeInterval(5.0)
    while !receivedCursor && Date() < updateDeadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    XCTAssertEqual(cursorX, 100.5, accuracy: 0.1)
    XCTAssertEqual(cursorY, 200.5, accuracy: 0.1)
    
    // Cleanup
    unsubscribe()
    leaveRoom()
  }
  
  // MARK: - Topics Tests (Fire-and-Forget Messaging)
  
  @MainActor
  func testTopicsPublishAndSubscribe() async throws {
    // Test topics functionality used in TopicsDemo
    // Note: A client typically doesn't receive its own topic messages,
    // so we test with two clients
    
    let client1 = InstantClient(appID: Self.testAppID)
    let client2 = InstantClient(appID: Self.testAppID)
    
    client1.connect()
    client2.connect()
    
    // Wait for authentication
    let authDeadline = Date().addingTimeInterval(Self.connectionTimeout)
    while (client1.connectionState != .authenticated || client2.connectionState != .authenticated)
          && Date() < authDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    XCTAssertEqual(client1.connectionState, .authenticated)
    XCTAssertEqual(client2.connectionState, .authenticated)
    
    let roomId = "topics-\(UUID().uuidString.prefix(8))"
    var receivedMessage = false
    var receivedData: [String: Any]?
    
    // Client 2 subscribes to topic
    let leave2 = client2.presence.joinRoom(roomId)
    let unsubTopic = client2.presence.subscribeTopic(roomId: roomId, topic: "chat") { message in
      receivedMessage = true
      receivedData = message.data
    }
    
    try await Task.sleep(nanoseconds: 2_000_000_000) // Wait for room to be ready
    
    // Client 1 joins and publishes
    let leave1 = client1.presence.joinRoom(roomId)
    
    try await Task.sleep(nanoseconds: 1_000_000_000)
    
    client1.presence.publishTopic(roomId: roomId, topic: "chat", data: [
      "text": "Hello from Client 1!",
      "timestamp": Date().timeIntervalSince1970
    ])
    
    // Wait for message
    let messageDeadline = Date().addingTimeInterval(5.0)
    while !receivedMessage && Date() < messageDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    XCTAssertTrue(receivedMessage, "Client 2 should receive the topic message")
    XCTAssertEqual(receivedData?["text"] as? String, "Hello from Client 1!")
    
    // Cleanup
    unsubTopic()
    leave1()
    leave2()
    client1.disconnect()
    client2.disconnect()
  }
  
  // MARK: - Query Tests (Todo Demo)
  
  @MainActor
  func testQueryTodos() async throws {
    // Test querying todos like in SwiftUISyncDemo
    var receivedData = false
    var todoCount = 0
    
    let query = client.query(CaseStudyTodo.self)
    
    let token = try client.subscribe(query) { result in
      if result.isLoading { return }
      receivedData = true
      todoCount = result.data.count
    }
    
    // Wait for query result
    let deadline = Date().addingTimeInterval(Self.queryTimeout)
    while !receivedData && Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    token.cancel()
    
    XCTAssertTrue(receivedData, "Should receive query result")
    // Don't assert on count - it depends on database state
    print("Found \(todoCount) todos in database")
  }
  
  // MARK: - CRUD Operations (Todo Demo)
  
  @MainActor
  func testCreateAndDeleteTodo() async throws {
    // Test creating and deleting a todo
    let todoId = UUID().uuidString.lowercased()
    let todoTitle = "Integration Test Todo - \(Date())"
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    
    // Create todo
    let createChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [["create", "todos", todoId, [
        "title": todoTitle,
        "done": false,
        "createdAt": timestamp
      ] as [String: Any]]]
    )
    
    try client.transact(createChunk)
    
    // Wait for transaction to process
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    // Verify todo exists by querying
    var foundTodo = false
    let query = client.query(CaseStudyTodo.self)
    
    let token = try client.subscribe(query) { result in
      if result.isLoading { return }
      foundTodo = result.data.contains { $0.id == todoId }
    }
    
    let queryDeadline = Date().addingTimeInterval(5.0)
    while !foundTodo && Date() < queryDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    token.cancel()
    
    XCTAssertTrue(foundTodo, "Created todo should be found in query")
    
    // Delete the todo
    let deleteChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [["delete", "todos", todoId]]
    )
    
    try client.transact(deleteChunk)
    
    // Wait for deletion
    try await Task.sleep(nanoseconds: 2_000_000_000)
    
    // Verify todo is deleted
    var todoDeleted = false
    let verifyToken = try client.subscribe(query) { result in
      if result.isLoading { return }
      todoDeleted = !result.data.contains { $0.id == todoId }
    }
    
    let deleteDeadline = Date().addingTimeInterval(5.0)
    while !todoDeleted && Date() < deleteDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    verifyToken.cancel()
    
    XCTAssertTrue(todoDeleted, "Todo should be deleted")
  }
  
  // MARK: - Real-Time Sync Test
  
  @MainActor
  func testRealTimeSyncBetweenClients() async throws {
    // Test that changes from one client appear in another client's subscription
    let client1 = InstantClient(appID: Self.testAppID)
    let client2 = InstantClient(appID: Self.testAppID)
    
    client1.connect()
    client2.connect()
    
    // Wait for authentication
    let authDeadline = Date().addingTimeInterval(Self.connectionTimeout)
    while (client1.connectionState != .authenticated || client2.connectionState != .authenticated)
          && Date() < authDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    XCTAssertEqual(client1.connectionState, .authenticated)
    XCTAssertEqual(client2.connectionState, .authenticated)
    
    // Client 2 subscribes to todos
    var initialCount = 0
    var updatedCount = 0
    var gotInitialData = false
    var gotUpdate = false
    
    let query = client2.query(CaseStudyTodo.self)
    
    let token = try client2.subscribe(query) { result in
      if result.isLoading { return }
      
      if !gotInitialData {
        gotInitialData = true
        initialCount = result.data.count
      } else if result.data.count > initialCount {
        gotUpdate = true
        updatedCount = result.data.count
      }
    }
    
    // Wait for initial data
    let initialDeadline = Date().addingTimeInterval(5.0)
    while !gotInitialData && Date() < initialDeadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    XCTAssertTrue(gotInitialData, "Should receive initial data")
    
    // Client 1 creates a new todo
    let todoId = UUID().uuidString.lowercased()
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    
    let chunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [["create", "todos", todoId, [
        "title": "Real-time sync test - \(Date())",
        "done": false,
        "createdAt": timestamp
      ] as [String: Any]]]
    )
    
    try client1.transact(chunk)
    
    // Wait for real-time update on client 2
    let updateDeadline = Date().addingTimeInterval(10.0)
    while !gotUpdate && Date() < updateDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    
    token.cancel()
    
    XCTAssertTrue(gotUpdate, "Client 2 should receive real-time update from Client 1's transaction")
    XCTAssertGreaterThan(updatedCount, initialCount)
    
    // Cleanup: delete the test todo
    let deleteChunk = TransactionChunk(
      namespace: "todos",
      id: todoId,
      ops: [["delete", "todos", todoId]]
    )
    try client1.transact(deleteChunk)
    
    client1.disconnect()
    client2.disconnect()
  }
}

// MARK: - Test Models

/// Todo model matching the CaseStudies schema
struct CaseStudyTodo: Codable, InstantEntity, Sendable {
  static var namespace: String { "todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
  
  init(id: String = UUID().uuidString, title: String, done: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}

