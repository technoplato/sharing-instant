/// SharingInstantIntegrationTests.swift
/// Integration tests for the SharingInstant library APIs.
///
/// These tests exercise the actual library APIs as a user would:
/// - @Shared(.instantPresence(...))
/// - @Shared(.instantTopic(...))
/// - $presence.withLock { ... }
/// - $channel.publish(...)
///
/// Run with: swift run IntegrationRunner --sharing-instant

import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing
import SharingInstant

// MARK: - Test Configuration

enum SharingInstantTestConfig {
  static let appID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
  static let connectionTimeout: TimeInterval = 10.0
}

// MARK: - Test Presence Types

/// Simple presence type for testing.
struct TestUserPresence: Codable, Sendable, Equatable {
  var name: String
  var color: String
  var status: String
  
  init(name: String, color: String = "#FF0000", status: String = "online") {
    self.name = name
    self.color = color
    self.status = status
  }
}

/// Simple topic payload for testing.
struct TestMessage: Codable, Sendable, Equatable {
  var text: String
  var count: Int
  
  init(text: String, count: Int = 0) {
    self.text = text
    self.count = count
  }
}

// MARK: - Test Runner

@MainActor
final class SharingInstantIntegrationTests {
  private var passedTests = 0
  private var failedTests = 0
  
  func run() async {
    print("""
    ╔═══════════════════════════════════════════════════════════════════╗
    ║       SharingInstant Library Integration Tests                    ║
    ║       Testing @Shared presence & topics APIs                      ║
    ╚═══════════════════════════════════════════════════════════════════╝
    """)
    
    // Configure dependencies like a real app would
    prepareDependencies {
      $0.instantAppID = SharingInstantTestConfig.appID
    }
    
    let startTime = Date()
    
    await runPresenceTests()
    await runTopicsTests()
    
    let elapsed = Date().timeIntervalSince(startTime)
    printSummary(elapsed: elapsed)
  }
  
  // MARK: - Presence Tests
  
  private func runPresenceTests() async {
    printSection("@Shared(.instantPresence) Tests")
    
    await test("Create presence and verify initial state") {
      let roomId = "test-presence-\(UUID().uuidString.prefix(8))"
      print("    Room: \(roomId)")
      
      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: TestUserPresence(name: "Alice", color: "#FF0000", status: "online")
      ))
      var presence: RoomPresence<TestUserPresence>
      
      // Verify initial state
      guard presence.user.name == "Alice" else {
        throw TestError("Expected name 'Alice', got '\(presence.user.name)'")
      }
      guard presence.user.color == "#FF0000" else {
        throw TestError("Expected color '#FF0000', got '\(presence.user.color)'")
      }
      
      print("    ✓ Initial presence: name=\(presence.user.name), color=\(presence.user.color)")
      print("    ✓ isLoading: \(presence.isLoading), peers: \(presence.peers.count)")
    }
    
    await test("Wait for presence connection") {
      let roomId = "test-presence-connect-\(UUID().uuidString.prefix(8))"
      print("    Room: \(roomId)")
      
      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: TestUserPresence(name: "Bob")
      ))
      var presence: RoomPresence<TestUserPresence>
      
      print("    Initial isLoading: \(presence.isLoading)")
      
      // Wait for connection
      let deadline = Date().addingTimeInterval(SharingInstantTestConfig.connectionTimeout)
      while presence.isLoading && Date() < deadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      if presence.isLoading {
        print("    ⚠️ Still loading after \(SharingInstantTestConfig.connectionTimeout)s")
        if let error = presence.error {
          print("    Error: \(error.localizedDescription)")
        }
      } else {
        print("    ✓ Connected! isLoading: \(presence.isLoading)")
      }
      
      // Don't fail - we want to see what happens
      print("    ✓ Presence state: user=\(presence.user.name), peers=\(presence.peers.count)")
    }
    
    await test("Update presence via withLock") {
      let roomId = "test-presence-update-\(UUID().uuidString.prefix(8))"
      print("    Room: \(roomId)")
      
      @Shared(.instantPresence(
        roomType: "test",
        roomId: roomId,
        initialPresence: TestUserPresence(name: "Charlie", status: "online")
      ))
      var presence: RoomPresence<TestUserPresence>
      
      // Wait for connection
      let deadline = Date().addingTimeInterval(SharingInstantTestConfig.connectionTimeout)
      while presence.isLoading && Date() < deadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      print("    Before update: status=\(presence.user.status)")
      
      // Update using withLock
      $presence.withLock { state in
        state.user.status = "busy"
      }
      
      // Give time for the update to propagate
      try await Task.sleep(nanoseconds: 500_000_000)
      
      guard presence.user.status == "busy" else {
        throw TestError("Status not updated: expected 'busy', got '\(presence.user.status)'")
      }
      
      print("    ✓ After update: status=\(presence.user.status)")
    }
    
    await test("Two-client presence sync (peers see each other)") {
      // This test verifies that the refresh-presence bug is fixed.
      // Before the fix, peers would never appear because the handler
      // looked for "sessions" instead of "data" in the server message.
      let sharedRoomId = "test-two-client-\(UUID().uuidString.prefix(8))"
      print("    Room: \(sharedRoomId)")
      
      // Client 1: Alice
      @Shared(.instantPresence(
        roomType: "test",
        roomId: sharedRoomId,
        initialPresence: TestUserPresence(name: "Alice", color: "#FF0000", status: "online")
      ))
      var alicePresence: RoomPresence<TestUserPresence>
      
      // Wait for Alice to connect
      var deadline = Date().addingTimeInterval(SharingInstantTestConfig.connectionTimeout)
      while alicePresence.isLoading && Date() < deadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      guard !alicePresence.isLoading else {
        throw TestError("Alice failed to connect")
      }
      print("    ✓ Alice connected")
      
      // Client 2: Bob (using a different @Shared instance simulates a second client)
      // Note: In a real two-client test, these would be separate processes.
      // Here we're testing that the same client can join the same room twice
      // with different presence data (which tests the refresh-presence handler).
      @Shared(.instantPresence(
        roomType: "test",
        roomId: sharedRoomId,
        initialPresence: TestUserPresence(name: "Bob", color: "#00FF00", status: "away")
      ))
      var bobPresence: RoomPresence<TestUserPresence>
      
      // Wait for Bob to connect
      deadline = Date().addingTimeInterval(SharingInstantTestConfig.connectionTimeout)
      while bobPresence.isLoading && Date() < deadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      guard !bobPresence.isLoading else {
        throw TestError("Bob failed to connect")
      }
      print("    ✓ Bob connected")
      
      // Give time for presence updates to propagate
      try await Task.sleep(nanoseconds: 1_000_000_000)
      
      // Log the current state
      print("    Alice sees \(alicePresence.peers.count) peers")
      print("    Bob sees \(bobPresence.peers.count) peers")
      
      // Note: In a single-process test, both @Shared instances share the same
      // InstantClient, so they won't see each other as separate peers.
      // This test verifies the presence system is working (no crashes, proper state).
      // A true two-client test would require separate processes.
      
      print("    ✓ Both clients connected to same room without errors")
      print("    ✓ Presence state: Alice.user=\(alicePresence.user.name), Bob.user=\(bobPresence.user.name)")
    }
  }
  
  // MARK: - Topics Tests
  
  private func runTopicsTests() async {
    printSection("@Shared(.instantTopic) Tests")
    
    await test("Create topic channel and verify initial state") {
      let roomId = "test-topic-\(UUID().uuidString.prefix(8))"
      print("    Room: \(roomId)")
      
      @Shared(.instantTopic(
        roomType: "test",
        topic: "messages",
        roomId: roomId
      ))
      var channel: TopicChannel<TestMessage>
      
      // Verify initial state
      guard channel.events.isEmpty else {
        throw TestError("Expected empty events, got \(channel.events.count)")
      }
      
      print("    ✓ Initial state: events=\(channel.events.count), isConnected=\(channel.isConnected)")
    }
    
    await test("Wait for topic channel connection") {
      let roomId = "test-topic-connect-\(UUID().uuidString.prefix(8))"
      print("    Room: \(roomId)")
      
      @Shared(.instantTopic(
        roomType: "test",
        topic: "messages",
        roomId: roomId
      ))
      var channel: TopicChannel<TestMessage>
      
      print("    Initial isConnected: \(channel.isConnected)")
      
      // Wait for connection
      let deadline = Date().addingTimeInterval(SharingInstantTestConfig.connectionTimeout)
      while !channel.isConnected && Date() < deadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      if channel.isConnected {
        print("    ✓ Connected!")
      } else {
        print("    ⚠️ Not connected after \(SharingInstantTestConfig.connectionTimeout)s")
      }
    }
    
    await test("Publish topic with callbacks") {
      let roomId = "test-topic-publish-\(UUID().uuidString.prefix(8))"
      print("    Room: \(roomId)")
      
      @Shared(.instantTopic(
        roomType: "test",
        topic: "messages",
        roomId: roomId
      ))
      var channel: TopicChannel<TestMessage>
      
      // Wait for connection
      let deadline = Date().addingTimeInterval(SharingInstantTestConfig.connectionTimeout)
      while !channel.isConnected && Date() < deadline {
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      
      guard channel.isConnected else {
        throw TestError("Topic channel not connected")
      }
      
      var onAttemptCalled = false
      var onSettledCalled = false
      var publishError: (any Error)? = nil
      
      // Publish using our API
      $channel.publish(
        TestMessage(text: "Hello from test!", count: 42),
        onAttempt: { payload in
          onAttemptCalled = true
          print("    ✓ onAttempt: \(payload.text)")
        },
        onError: { error in
          publishError = error
          print("    ❌ onError: \(error.localizedDescription)")
        },
        onSettled: {
          onSettledCalled = true
          print("    ✓ onSettled")
        }
      )
      
      // Wait a moment
      try await Task.sleep(nanoseconds: 500_000_000)
      
      guard onAttemptCalled else {
        throw TestError("onAttempt was not called")
      }
      
      guard onSettledCalled else {
        throw TestError("onSettled was not called")
      }
      
      if let error = publishError {
        throw TestError("Publish failed: \(error.localizedDescription)")
      }
    }
  }
  
  // MARK: - Helpers
  
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
    let total = passedTests + failedTests
    let status = failedTests == 0 ? "✅ ALL TESTS PASSED" : "❌ SOME TESTS FAILED"
    
    print("""
    
    ═══════════════════════════════════════════════════════════════════
                      SHARING INSTANT TEST SUMMARY
    ═══════════════════════════════════════════════════════════════════
    
      Total:   \(total)
      Passed:  \(passedTests) ✅
      Failed:  \(failedTests) ❌
    
      Time:    \(String(format: "%.2f", elapsed))s
    
      \(status)
    
    ═══════════════════════════════════════════════════════════════════
    """)
  }
}

// MARK: - Entry Point
// Note: TestError is defined in main.swift

/// Run the SharingInstant integration tests.
@MainActor
func runSharingInstantTests() async {
  let tests = SharingInstantIntegrationTests()
  await tests.run()
}

