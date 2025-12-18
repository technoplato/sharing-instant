import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Topics Integration Tests

/// Integration tests for type-safe topics functionality.
///
/// These tests verify:
/// - TopicChannel type creation
/// - TopicEvent handling
/// - Event buffering
/// - TopicKey creation
final class TopicsIntegrationTests: XCTestCase {
  
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  // MARK: - TopicChannel Tests
  
  func testTopicChannelCreation() {
    let channel = TopicChannel<TestTopicPayload>()
    
    XCTAssertTrue(channel.events.isEmpty)
    XCTAssertNil(channel.latestEvent)
    XCTAssertFalse(channel.isConnected)
    XCTAssertEqual(channel.maxEvents, 50)
  }
  
  func testTopicChannelWithEvents() {
    var channel = TopicChannel<TestTopicPayload>(isConnected: true)
    
    let event1 = TopicEvent(
      peerId: "peer-1",
      data: TestTopicPayload(message: "Hello", count: 1)
    )
    let event2 = TopicEvent(
      peerId: "peer-2",
      data: TestTopicPayload(message: "World", count: 2)
    )
    
    channel.addEvent(event1)
    channel.addEvent(event2)
    
    XCTAssertEqual(channel.events.count, 2)
    XCTAssertEqual(channel.latestEvent?.data.message, "World")
    XCTAssertEqual(channel.latestEvent?.data.count, 2)
  }
  
  func testTopicChannelEventBuffering() {
    var channel = TopicChannel<TestTopicPayload>(maxEvents: 3)
    
    // Add more events than the max
    for i in 1...5 {
      let event = TopicEvent(
        peerId: "peer-\(i)",
        data: TestTopicPayload(message: "Message \(i)", count: i)
      )
      channel.addEvent(event)
    }
    
    // Should only keep the last 3 events
    XCTAssertEqual(channel.events.count, 3)
    XCTAssertEqual(channel.events.first?.data.message, "Message 3")
    XCTAssertEqual(channel.latestEvent?.data.message, "Message 5")
  }
  
  func testTopicChannelClearEvents() {
    var channel = TopicChannel<TestTopicPayload>(isConnected: true)
    
    channel.addEvent(TopicEvent(
      peerId: "peer-1",
      data: TestTopicPayload(message: "Hello", count: 1)
    ))
    
    XCTAssertFalse(channel.events.isEmpty)
    
    channel.clearEvents()
    
    XCTAssertTrue(channel.events.isEmpty)
    XCTAssertNil(channel.latestEvent)
  }
  
  // MARK: - TopicEvent Tests
  
  func testTopicEventCreation() {
    let event = TopicEvent(
      peerId: "session-123",
      data: TestTopicPayload(message: "Test", count: 42)
    )
    
    XCTAssertEqual(event.peerId, "session-123")
    XCTAssertEqual(event.data.message, "Test")
    XCTAssertEqual(event.data.count, 42)
    XCTAssertNotNil(event.id)
    XCTAssertNotNil(event.timestamp)
  }
  
  func testTopicEventEquality() {
    let id = UUID()
    let timestamp = Date()
    
    let event1 = TopicEvent(
      id: id,
      peerId: "peer-1",
      data: TestTopicPayload(message: "Test", count: 1),
      timestamp: timestamp
    )
    
    let event2 = TopicEvent(
      id: id,
      peerId: "peer-1",
      data: TestTopicPayload(message: "Test", count: 1),
      timestamp: timestamp
    )
    
    XCTAssertEqual(event1, event2)
    
    let event3 = TopicEvent(
      peerId: "peer-1",
      data: TestTopicPayload(message: "Different", count: 1)
    )
    
    XCTAssertNotEqual(event1, event3)
  }
  
  // MARK: - TopicKey Tests
  
  func testTopicKeyCreation() {
    let topicKey = TopicKey<TestTopicPayload>(roomType: "reactions", topic: "emoji")
    
    XCTAssertEqual(topicKey.roomType, "reactions")
    XCTAssertEqual(topicKey.topic, "emoji")
  }
  
  func testTopicKeyEquality() {
    let key1 = TopicKey<TestTopicPayload>(roomType: "reactions", topic: "emoji")
    let key2 = TopicKey<TestTopicPayload>(roomType: "reactions", topic: "emoji")
    let key3 = TopicKey<TestTopicPayload>(roomType: "reactions", topic: "like")
    
    XCTAssertEqual(key1, key2)
    XCTAssertNotEqual(key1, key3)
  }
  
  // MARK: - InstantTopicKey Tests
  
  func testInstantTopicKeyID() {
    let key1 = InstantTopicKey<TestTopicPayload>(
      roomType: "reactions",
      topic: "emoji",
      roomId: "room-123",
      appID: Self.testAppID
    )
    
    let key2 = InstantTopicKey<TestTopicPayload>(
      roomType: "reactions",
      topic: "emoji",
      roomId: "room-123",
      appID: Self.testAppID
    )
    
    // Same room/topic should have same ID
    XCTAssertEqual(key1.id, key2.id)
    
    let key3 = InstantTopicKey<TestTopicPayload>(
      roomType: "reactions",
      topic: "like",
      roomId: "room-123",
      appID: Self.testAppID
    )
    
    // Different topic should have different ID
    XCTAssertNotEqual(key1.id, key3.id)
  }
  
  // MARK: - Payload Encoding Tests
  
  func testTopicPayloadEncoding() throws {
    let payload = TestTopicPayload(message: "Hello", count: 42)
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(payload)
    let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    
    XCTAssertNotNil(dict)
    XCTAssertEqual(dict?["message"] as? String, "Hello")
    XCTAssertEqual(dict?["count"] as? Int, 42)
  }
  
  func testTopicPayloadDecoding() throws {
    let dict: [String: Any] = ["message": "Hello", "count": 42]
    let data = try JSONSerialization.data(withJSONObject: dict)
    
    let decoder = JSONDecoder()
    let payload = try decoder.decode(TestTopicPayload.self, from: data)
    
    XCTAssertEqual(payload.message, "Hello")
    XCTAssertEqual(payload.count, 42)
  }
  
  // MARK: - TopicPublishResult Tests
  
  func testTopicPublishResultSuccess() {
    let result = TopicPublishResult.success
    
    XCTAssertTrue(result.success)
    XCTAssertNil(result.error)
  }
  
  func testTopicPublishResultFailure() {
    let error = NSError(domain: "test", code: 1, userInfo: nil)
    let result = TopicPublishResult.failure(error)
    
    XCTAssertFalse(result.success)
    XCTAssertNotNil(result.error)
  }
}

// MARK: - Test Models

/// Test topic payload type for unit tests
struct TestTopicPayload: Codable, Sendable, Equatable {
  var message: String
  var count: Int
  
  init(message: String, count: Int) {
    self.message = message
    self.count = count
  }
}

