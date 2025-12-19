import Dependencies
import DependenciesTestSupport
import IdentifiedCollections
import Sharing
import XCTest

@testable import SharingInstant

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
  
  // MARK: - Presence Types (matching CaseStudies)
  
  /// Simple presence type for testing.
  struct TestPresence: Codable, Sendable, Equatable {
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
    // Arrange: Set up dependencies
    prepareDependencies {
      $0.instantAppID = testAppID
    }
    
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
    // Arrange
    prepareDependencies {
      $0.instantAppID = testAppID
    }
    
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
    // Arrange
    prepareDependencies {
      $0.instantAppID = testAppID
    }
    
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
    // Arrange
    prepareDependencies {
      $0.instantAppID = testAppID
    }
    
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

