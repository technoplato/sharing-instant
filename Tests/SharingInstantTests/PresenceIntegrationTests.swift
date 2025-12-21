import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import InstantDB
import Sharing
import XCTest

@testable import SharingInstant

// MARK: - Presence Integration Tests

/// Integration tests for type-safe presence functionality.
///
/// These tests verify:
/// - RoomPresence type creation and encoding
/// - Peer type handling
/// - withLock mutations
/// - Two-client presence sync (requires network)
final class PresenceIntegrationTests: XCTestCase {
  
  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  
  // MARK: - RoomPresence Type Tests
  
  func testRoomPresenceCreation() {
    let presence = RoomPresence(
      user: TestPresence(name: "Alice", color: "#FF0000"),
      peers: [],
      isLoading: false
    )
    
    XCTAssertEqual(presence.user.name, "Alice")
    XCTAssertEqual(presence.user.color, "#FF0000")
    XCTAssertTrue(presence.peers.isEmpty)
    XCTAssertFalse(presence.isLoading)
    XCTAssertNil(presence.error)
  }
  
  func testRoomPresenceWithPeers() {
    var presence = RoomPresence(
      user: TestPresence(name: "Alice", color: "#FF0000"),
      peers: [],
      isLoading: false
    )
    
    // Add peers
    let peer1 = Peer(id: "session-1", data: TestPresence(name: "Bob", color: "#00FF00"))
    let peer2 = Peer(id: "session-2", data: TestPresence(name: "Charlie", color: "#0000FF"))
    
    presence.peers.append(peer1)
    presence.peers.append(peer2)
    
    XCTAssertEqual(presence.peers.count, 2)
    XCTAssertEqual(presence.totalCount, 3) // 1 user + 2 peers
    XCTAssertTrue(presence.hasPeers)
    XCTAssertEqual(presence.peersList.count, 2)
  }
  
  func testRoomPresenceEquality() {
    let presence1 = RoomPresence(
      user: TestPresence(name: "Alice", color: "#FF0000"),
      peers: [],
      isLoading: false
    )
    
    let presence2 = RoomPresence(
      user: TestPresence(name: "Alice", color: "#FF0000"),
      peers: [],
      isLoading: false
    )
    
    XCTAssertEqual(presence1, presence2)
    
    var presence3 = presence1
    presence3.user.name = "Bob"
    XCTAssertNotEqual(presence1, presence3)
  }
  
  // MARK: - Peer Type Tests
  
  func testPeerCreation() {
    let peer = Peer(id: "session-123", data: TestPresence(name: "Bob", color: "#00FF00"))
    
    XCTAssertEqual(peer.id, "session-123")
    XCTAssertEqual(peer.data.name, "Bob")
    XCTAssertEqual(peer.data.color, "#00FF00")
  }
  
  func testPeerEquality() {
    let peer1 = Peer(id: "session-123", data: TestPresence(name: "Bob", color: "#00FF00"))
    let peer2 = Peer(id: "session-123", data: TestPresence(name: "Bob", color: "#00FF00"))
    
    XCTAssertEqual(peer1, peer2)
    
    let peer3 = Peer(id: "session-456", data: TestPresence(name: "Bob", color: "#00FF00"))
    XCTAssertNotEqual(peer1, peer3) // Different ID
  }
  
  // MARK: - RoomKey Tests
  
  func testRoomKeyCreation() {
    let roomKey = RoomKey<TestPresence>(type: "test-room")
    
    XCTAssertEqual(roomKey.type, "test-room")
  }
  
  func testRoomKeyEquality() {
    let key1 = RoomKey<TestPresence>(type: "test-room")
    let key2 = RoomKey<TestPresence>(type: "test-room")
    let key3 = RoomKey<TestPresence>(type: "other-room")
    
    XCTAssertEqual(key1, key2)
    XCTAssertNotEqual(key1, key3)
  }
  
  // MARK: - Presence Encoding Tests
  
  func testPresenceEncoding() throws {
    let presence = TestPresence(name: "Alice", color: "#FF0000")
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(presence)
    let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    
    XCTAssertNotNil(dict)
    XCTAssertEqual(dict?["name"] as? String, "Alice")
    XCTAssertEqual(dict?["color"] as? String, "#FF0000")
  }
  
  func testPresenceDecoding() throws {
    let dict: [String: Any] = ["name": "Alice", "color": "#FF0000"]
    let data = try JSONSerialization.data(withJSONObject: dict)
    
    let decoder = JSONDecoder()
    let presence = try decoder.decode(TestPresence.self, from: data)
    
    XCTAssertEqual(presence.name, "Alice")
    XCTAssertEqual(presence.color, "#FF0000")
  }
  
  // MARK: - TypedPresenceKey Tests
  
  func testTypedPresenceKeyID() {
    let key1 = TypedPresenceKey<TestPresence>(
      roomType: "test",
      roomId: "room-123",
      initialPresence: TestPresence(name: "Alice", color: "#FF0000"),
      appID: Self.testAppID
    )
    
    let key2 = TypedPresenceKey<TestPresence>(
      roomType: "test",
      roomId: "room-123",
      initialPresence: TestPresence(name: "Bob", color: "#00FF00"),
      appID: Self.testAppID
    )
    
    // Same room should have same ID regardless of initial presence
    XCTAssertEqual(key1.id, key2.id)
    
    let key3 = TypedPresenceKey<TestPresence>(
      roomType: "test",
      roomId: "room-456",
      initialPresence: TestPresence(name: "Alice", color: "#FF0000"),
      appID: Self.testAppID
    )
    
    // Different room should have different ID
    XCTAssertNotEqual(key1.id, key3.id)
  }
}

// MARK: - Test Models

/// Test presence type for unit tests
struct TestPresence: PresenceData {
  var name: String
  var color: String
  
  init(name: String, color: String) {
    self.name = name
    self.color = color
  }
}




