/// Tests for rapid transcription-style updates.
///
/// These tests verify that SharingInstant can handle rapid text updates
/// with the same timing as real-time speech transcription.
///
/// ## Background
///
/// Real speech transcription emits updates at irregular intervals:
/// - Multiple updates within milliseconds (e.g., 7ms, 8ms apart)
/// - Longer gaps between words (e.g., 800-1000ms)
/// - Final segment with word-level timing data (embedded JSON)
///
/// This mirrors the pattern from SpeechRecorderApp's RapidUpdateSharingInstantTest.

import XCTest
import IdentifiedCollections
import Sharing
import Dependencies
@testable import SharingInstant
import InstantDB

// MARK: - Test Data Structures

private struct SegmentUpdate {
  let delay: Int // milliseconds from start
  let text: String
}

private struct WordData {
  let text: String
  let startTime: Double
  let endTime: Double
}

private struct FinalUpdate {
  let delay: Int
  let text: String
  let words: [WordData]
}

private struct TestSegmentData {
  let index: Int
  let updates: [SegmentUpdate]
  let final: FinalUpdate
}

/// Simplified test data - single segment with rapid updates
private let testSegment = TestSegmentData(
  index: 0,
  updates: [
    SegmentUpdate(delay: 0, text: "T"),
    SegmentUpdate(delay: 7, text: "Test"),
    SegmentUpdate(delay: 8, text: "Testing"),
    SegmentUpdate(delay: 100, text: "Testing 12"),
    SegmentUpdate(delay: 102, text: "Testing 123"),
  ],
  final: FinalUpdate(
    delay: 500,
    text: "Testing 123.",
    words: [
      WordData(text: "Testing", startTime: 0.0, endTime: 0.5),
      WordData(text: "123.", startTime: 0.5, endTime: 1.0),
    ]
  )
)

// MARK: - Rapid Update Tests

final class RapidTranscriptionUpdateTests: XCTestCase {

  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"

  override func setUp() async throws {
    try await super.setUp()
    try IntegrationTestGate.requireEnabled()
  }

  // MARK: - Test 1: Rapid Updates Within Milliseconds

  /// Tests that rapid updates (within milliseconds) are handled correctly.
  ///
  /// This simulates speech transcription where multiple text updates arrive
  /// in quick succession (e.g., 7ms, 8ms apart).
  func testRapidUpdatesWithinMilliseconds() async throws {
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let segmentId = UUID().uuidString.lowercased()
    let runId = UUID().uuidString.lowercased()

    // Create transcription run first
    let runChunk = TransactionChunk(
      namespace: "transcriptionRuns",
      id: runId,
      ops: [["update", "transcriptionRuns", runId, [
        "toolVersion": "test-1.0",
        "executedAt": ISO8601DateFormatter().string(from: Date())
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [runChunk])

    // Subscribe to segments
    let config = SharingInstantSync.CollectionConfiguration<TranscriptionSegment>(
      namespace: "transcriptionSegments",
      orderBy: .asc("segmentIndex"),
      includedLinks: [],
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = SegmentCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription ready")

    let consumeTask = Task {
      for await segments in stream {
        await collector.update(segments)
        if await !collector.getIsReady() {
          await collector.markReady()
          subscriptionReady.fulfill()
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Simulate rapid updates
    let startTime = Date()

    for (index, update) in testSegment.updates.enumerated() {
      // Wait for the specified delay
      let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
      let waitTime = update.delay - elapsed
      if waitTime > 0 {
        try await Task.sleep(for: .milliseconds(waitTime))
      }

      let now = ISO8601DateFormatter().string(from: Date())

      // Create/update segment
      let segmentChunk = TransactionChunk(
        namespace: "transcriptionSegments",
        id: segmentId,
        ops: [["update", "transcriptionSegments", segmentId, [
          "text": update.text,
          "startTime": 0.0,
          "endTime": Double(update.text.count) * 0.05,
          "segmentIndex": 0,
          "isFinalized": false,
          "ingestedAt": now
        ]]]
      )
      try await reactor.transact(appID: Self.testAppID, chunks: [segmentChunk])

      // Link on first update
      if index == 0 {
        let linkChunk = TransactionChunk(
          namespace: "transcriptionSegments",
          id: segmentId,
          ops: [["link", "transcriptionSegments", segmentId, [
            "transcriptionRun": ["id": runId, "namespace": "transcriptionRuns"]
          ]]]
        )
        try await reactor.transact(appID: Self.testAppID, chunks: [linkChunk])
      }
    }

    // Wait briefly for optimistic updates to settle
    try await Task.sleep(nanoseconds: 100_000_000) // 100ms

    // Verify segment exists with latest text
    let containsSegment = await collector.contains(id: segmentId)
    let currentSegment = await collector.getSegment(id: segmentId)

    XCTAssertTrue(containsSegment, "Segment should exist after rapid updates")
    XCTAssertEqual(
      currentSegment?.text,
      testSegment.updates.last?.text,
      "Segment text should match the last update"
    )
    XCTAssertFalse(currentSegment?.isFinalized ?? true, "Segment should not be finalized yet")

    // Cleanup
    let deleteSegment = TransactionChunk(
      namespace: "transcriptionSegments",
      id: segmentId,
      ops: [["delete", "transcriptionSegments", segmentId]]
    )
    let deleteRun = TransactionChunk(
      namespace: "transcriptionRuns",
      id: runId,
      ops: [["delete", "transcriptionRuns", runId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteSegment, deleteRun])
  }

  // MARK: - Test 2: Final Segment with Embedded Words JSON

  /// Tests that finalized segments with embedded word-level timing data work correctly.
  ///
  /// Words are stored as a JSON array in the segment, not as separate entities.
  func testFinalSegmentWithEmbeddedWords() async throws {
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let segmentId = UUID().uuidString.lowercased()
    let runId = UUID().uuidString.lowercased()

    // Create transcription run
    let runChunk = TransactionChunk(
      namespace: "transcriptionRuns",
      id: runId,
      ops: [["update", "transcriptionRuns", runId, [
        "toolVersion": "test-1.0",
        "executedAt": ISO8601DateFormatter().string(from: Date())
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [runChunk])

    // Create finalized segment with words
    let words: [[String: Any]] = testSegment.final.words.map { word in
      [
        "text": word.text,
        "startTime": word.startTime,
        "endTime": word.endTime
      ]
    }

    let now = ISO8601DateFormatter().string(from: Date())
    let segmentChunk = TransactionChunk(
      namespace: "transcriptionSegments",
      id: segmentId,
      ops: [["update", "transcriptionSegments", segmentId, [
        "text": testSegment.final.text,
        "startTime": testSegment.final.words.first?.startTime ?? 0.0,
        "endTime": testSegment.final.words.last?.endTime ?? 0.0,
        "segmentIndex": 0,
        "isFinalized": true,
        "ingestedAt": now,
        "words": words
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [segmentChunk])

    // Subscribe to verify
    let config = SharingInstantSync.CollectionConfiguration<TranscriptionSegment>(
      namespace: "transcriptionSegments",
      orderBy: .asc("segmentIndex"),
      includedLinks: [],
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = SegmentCollector()
    let foundSegment = XCTestExpectation(description: "Found segment")

    let consumeTask = Task {
      for await segments in stream {
        await collector.update(segments)
        if await collector.contains(id: segmentId) {
          foundSegment.fulfill()
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    await fulfillment(of: [foundSegment], timeout: 10)

    let segment = await collector.getSegment(id: segmentId)

    XCTAssertNotNil(segment, "Segment should exist")
    XCTAssertEqual(segment?.text, testSegment.final.text, "Text should match")
    XCTAssertTrue(segment?.isFinalized ?? false, "Segment should be finalized")
    XCTAssertEqual(segment?.words?.count, testSegment.final.words.count, "Should have \(testSegment.final.words.count) words")

    // Verify word content
    if let segmentWords = segment?.words {
      for (index, word) in segmentWords.enumerated() {
        let expected = testSegment.final.words[index]
        XCTAssertEqual(word.text, expected.text, "Word \(index) text should match")
        XCTAssertEqual(word.startTime, expected.startTime, accuracy: 0.01, "Word \(index) startTime should match")
        XCTAssertEqual(word.endTime, expected.endTime, accuracy: 0.01, "Word \(index) endTime should match")
      }
    }

    // Cleanup
    let deleteSegment = TransactionChunk(
      namespace: "transcriptionSegments",
      id: segmentId,
      ops: [["delete", "transcriptionSegments", segmentId]]
    )
    let deleteRun = TransactionChunk(
      namespace: "transcriptionRuns",
      id: runId,
      ops: [["delete", "transcriptionRuns", runId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteSegment, deleteRun])
  }

  // MARK: - Test 3: Full Transcription Flow (Volatile → Final)

  /// Tests the complete flow of volatile updates followed by finalization.
  func testVolatileToFinalTransition() async throws {
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let segmentId = UUID().uuidString.lowercased()
    let runId = UUID().uuidString.lowercased()
    let mediaId = UUID().uuidString.lowercased()

    // Create media first
    let mediaChunk = TransactionChunk(
      namespace: "media",
      id: mediaId,
      ops: [["update", "media", mediaId, [
        "title": "Test Recording",
        "durationSeconds": 10,
        "mediaType": "audio",
        "ingestedAt": ISO8601DateFormatter().string(from: Date())
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [mediaChunk])

    // Create run and link to media
    let runChunk = TransactionChunk(
      namespace: "transcriptionRuns",
      id: runId,
      ops: [
        ["update", "transcriptionRuns", runId, [
          "toolVersion": "test-1.0",
          "executedAt": ISO8601DateFormatter().string(from: Date())
        ]],
        ["link", "transcriptionRuns", runId, [
          "media": ["id": mediaId, "namespace": "media"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [runChunk])

    // Subscribe
    let config = SharingInstantSync.CollectionConfiguration<TranscriptionSegment>(
      namespace: "transcriptionSegments",
      orderBy: .asc("segmentIndex"),
      includedLinks: [],
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = SegmentCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription ready")

    let consumeTask = Task {
      for await segments in stream {
        await collector.update(segments)
        if await !collector.getIsReady() {
          await collector.markReady()
          subscriptionReady.fulfill()
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    let startTime = Date()

    // Send volatile updates
    for update in testSegment.updates {
      let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
      let waitTime = update.delay - elapsed
      if waitTime > 0 {
        try? await Task.sleep(for: .milliseconds(waitTime))
      }

      let now = ISO8601DateFormatter().string(from: Date())
      let segmentChunk = TransactionChunk(
        namespace: "transcriptionSegments",
        id: segmentId,
        ops: [["update", "transcriptionSegments", segmentId, [
          "text": update.text,
          "startTime": 0.0,
          "endTime": Double(update.text.count) * 0.05,
          "segmentIndex": 0,
          "isFinalized": false,
          "ingestedAt": now
        ]]]
      )
      try await reactor.transact(appID: Self.testAppID, chunks: [segmentChunk])
    }

    // Wait for final delay
    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
    let waitTime = testSegment.final.delay - elapsed
    if waitTime > 0 {
      try? await Task.sleep(for: .milliseconds(waitTime))
    }

    // Finalize with words
    let words: [[String: Any]] = testSegment.final.words.map { word in
      ["text": word.text, "startTime": word.startTime, "endTime": word.endTime]
    }

    let now = ISO8601DateFormatter().string(from: Date())
    let finalChunk = TransactionChunk(
      namespace: "transcriptionSegments",
      id: segmentId,
      ops: [
        ["update", "transcriptionSegments", segmentId, [
          "text": testSegment.final.text,
          "startTime": testSegment.final.words.first?.startTime ?? 0.0,
          "endTime": testSegment.final.words.last?.endTime ?? 0.0,
          "segmentIndex": 0,
          "isFinalized": true,
          "ingestedAt": now,
          "words": words
        ]],
        ["link", "transcriptionSegments", segmentId, [
          "transcriptionRun": ["id": runId, "namespace": "transcriptionRuns"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [finalChunk])

    // Wait for propagation
    try await Task.sleep(nanoseconds: 500_000_000) // 500ms

    // Verify final state
    let segment = await collector.getSegment(id: segmentId)

    XCTAssertNotNil(segment, "Finalized segment should exist")
    XCTAssertEqual(segment?.text, testSegment.final.text, "Final text should match")
    XCTAssertTrue(segment?.isFinalized ?? false, "Should be finalized")
    XCTAssertEqual(segment?.words?.count, testSegment.final.words.count, "Should have words")

    // Cleanup
    let cleanupChunks = [
      TransactionChunk(namespace: "transcriptionSegments", id: segmentId, ops: [["delete", "transcriptionSegments", segmentId]]),
      TransactionChunk(namespace: "transcriptionRuns", id: runId, ops: [["delete", "transcriptionRuns", runId]]),
      TransactionChunk(namespace: "media", id: mediaId, ops: [["delete", "media", mediaId]])
    ]
    for chunk in cleanupChunks {
      try await reactor.transact(appID: Self.testAppID, chunks: [chunk])
    }
  }
}

// MARK: - Thread-safe Segment Collector

private actor SegmentCollector {
  var segments: [TranscriptionSegment] = []
  var isReady = false

  func update(_ newSegments: [TranscriptionSegment]) {
    segments = newSegments
  }

  func markReady() {
    isReady = true
  }

  func getSegments() -> [TranscriptionSegment] {
    return segments
  }

  func getIsReady() -> Bool {
    return isReady
  }

  func contains(id: String) -> Bool {
    return segments.contains { $0.id.lowercased() == id.lowercased() }
  }

  func getSegment(id: String) -> TranscriptionSegment? {
    return segments.first { $0.id.lowercased() == id.lowercased() }
  }
}
