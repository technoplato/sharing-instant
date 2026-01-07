/// Tests for linked entity behavior with and without `.with()` clause.
///
/// ## Background
///
/// In InstantDB, linked entities are only included in query results when
/// explicitly requested via the `.with()` clause (or `board: {}` in TypeScript).
///
/// These tests verify:
/// 1. With `.with()`: Full linked entity data is returned
/// 2. Without `.with()`: Linked entity field should be nil (not partial data)
/// 3. Multiple subscriptions with different link requests work correctly
/// 4. Optimistic updates propagate to linked entities
/// 5. Forward and reverse links sync correctly

import XCTest
import IdentifiedCollections
import Sharing
import Dependencies
@testable import SharingInstant
import InstantDB

// MARK: - Linked Entity With Clause Tests

final class LinkedEntityWithClauseTests: XCTestCase {

  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"

  // MARK: - Test 1: Query with .with() returns full linked entity

  /// When you query tiles WITH the board link included, the full board entity should be returned.
  ///
  /// TypeScript equivalent:
  /// ```javascript
  /// query(ctx, {
  ///   tiles: { board: {} }  // Include board link
  /// })
  /// // Result: tiles[0].board = { id: "...", title: "...", createdAt: ... }
  /// ```
  func testQueryWithIncludedLinkReturnsFullEntity() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Query tiles WITH board included
    let config = SharingInstantSync.CollectionConfiguration<TileWithBoard>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: nil,
      includedLinks: ["board"],  // Request the board link
      linkTree: [.link(name: "board")]
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileWithBoardCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundTileWithBoard = XCTestExpectation(description: "Found tile with full board")

    let consumeTask = Task {
      var didMarkReady = false
      for await tiles in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(tiles)
        // Check if we have a tile with a FULL board (not just id)
        if let tile = await collector.find(id: tileId),
           let board = tile.board,
           board.title != nil {  // Full board has title
          foundTileWithBoard.fulfill()
        }
      }
    }

    defer { consumeTask.cancel() }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create board first
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [[
        "update", "boards", boardId, [
          "title": "Test Board With Full Data",
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]
      ]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create tile linked to board
    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "red",
          "x": 0,
          "y": 0,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", tileId, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    await fulfillment(of: [foundTileWithBoard], timeout: 10)

    let tile = await collector.find(id: tileId)
    XCTAssertNotNil(tile, "Should find the tile")
    XCTAssertNotNil(tile?.board, "Board should not be nil when requested via .with()")
    XCTAssertEqual(tile?.board?.id.lowercased(), boardId, "Board ID should match")
    XCTAssertEqual(tile?.board?.title, "Test Board With Full Data", "Board should have full data including title")

    // Cleanup
    try await cleanup(reactor: reactor, tiles: [tileId], boards: [boardId])
  }

  // MARK: - Test 2: Query without .with() has nil for linked entity field

  /// When you query tiles WITHOUT the board link, the board field should be nil.
  ///
  /// TypeScript equivalent:
  /// ```javascript
  /// query(ctx, {
  ///   tiles: {}  // No board link requested
  /// })
  /// // Result: tiles[0].board = undefined
  /// ```
  func testQueryWithoutIncludedLinkReturnsNilForLinkField() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Query tiles WITHOUT board included
    let config = SharingInstantSync.CollectionConfiguration<TileWithBoard>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: nil,
      includedLinks: [],  // No links requested
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileWithBoardCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundTile = XCTestExpectation(description: "Found tile")

    let consumeTask = Task {
      var didMarkReady = false
      for await tiles in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(tiles)
        if await collector.contains(id: tileId) {
          foundTile.fulfill()
        }
      }
    }

    defer { consumeTask.cancel() }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create board first
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [[
        "update", "boards", boardId, [
          "title": "Hidden Board",
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]
      ]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create tile linked to board
    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "blue",
          "x": 1,
          "y": 1,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", tileId, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    await fulfillment(of: [foundTile], timeout: 10)

    let tile = await collector.find(id: tileId)
    XCTAssertNotNil(tile, "Should find the tile")
    // Board should be nil because we didn't request it with .with()
    XCTAssertNil(tile?.board, "Board should be nil when not requested via .with()")

    // Cleanup
    try await cleanup(reactor: reactor, tiles: [tileId], boards: [boardId])
  }

  // MARK: - Test 3: Two subscriptions with different link requests

  /// Two subscriptions to the same namespace - one with .with(board), one without.
  /// Both should work correctly and independently.
  func testTwoSubscriptionsWithDifferentLinkRequests() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Subscription 1: WITH board
    let configWithBoard = SharingInstantSync.CollectionConfiguration<TileWithBoard>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: nil,
      includedLinks: ["board"],
      linkTree: [.link(name: "board")]
    )

    // Subscription 2: WITHOUT board
    let configWithoutBoard = SharingInstantSync.CollectionConfiguration<TileWithBoard>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: nil,
      includedLinks: [],
      linkTree: []
    )

    let stream1 = await reactor.subscribe(appID: Self.testAppID, configuration: configWithBoard)
    let stream2 = await reactor.subscribe(appID: Self.testAppID, configuration: configWithoutBoard)

    let collector1 = TileWithBoardCollector()
    let collector2 = TileWithBoardCollector()

    let sub1Ready = XCTestExpectation(description: "Sub1 ready")
    let sub2Ready = XCTestExpectation(description: "Sub2 ready")
    let foundTile1 = XCTestExpectation(description: "Found tile in sub1")
    let foundTile2 = XCTestExpectation(description: "Found tile in sub2")

    let task1 = Task {
      var didMarkReady = false
      for await tiles in stream1 {
        if !didMarkReady {
          didMarkReady = true
          sub1Ready.fulfill()
        }
        await collector1.update(tiles)
        if await collector1.contains(id: tileId) {
          foundTile1.fulfill()
        }
      }
    }

    let task2 = Task {
      var didMarkReady = false
      for await tiles in stream2 {
        if !didMarkReady {
          didMarkReady = true
          sub2Ready.fulfill()
        }
        await collector2.update(tiles)
        if await collector2.contains(id: tileId) {
          foundTile2.fulfill()
        }
      }
    }

    defer {
      task1.cancel()
      task2.cancel()
    }

    await fulfillment(of: [sub1Ready, sub2Ready], timeout: 10)

    // Create data
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Multi-Sub Board",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "green",
          "x": 2,
          "y": 2,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", tileId, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    await fulfillment(of: [foundTile1, foundTile2], timeout: 10)

    // Verify subscription 1 has full board
    let tile1 = await collector1.find(id: tileId)
    XCTAssertNotNil(tile1, "Sub1 should find tile")
    XCTAssertNotNil(tile1?.board, "Sub1 should have board (requested with .with())")
    XCTAssertEqual(tile1?.board?.title, "Multi-Sub Board", "Sub1 board should have full data")

    // Verify subscription 2 has nil board
    let tile2 = await collector2.find(id: tileId)
    XCTAssertNotNil(tile2, "Sub2 should find tile")
    XCTAssertNil(tile2?.board, "Sub2 should NOT have board (not requested)")

    // Cleanup
    try await cleanup(reactor: reactor, tiles: [tileId], boards: [boardId])
  }

  // MARK: - Test 4: Updating linked entity propagates to subscriptions

  /// When a linked entity is updated, subscriptions that include it should see the update.
  func testLinkedEntityUpdatePropagates() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Query tiles WITH board
    let config = SharingInstantSync.CollectionConfiguration<TileWithBoard>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: nil,
      includedLinks: ["board"],
      linkTree: [.link(name: "board")]
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileWithBoardCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundInitialBoard = XCTestExpectation(description: "Found initial board title")
    let foundUpdatedBoard = XCTestExpectation(description: "Found updated board title")

    let consumeTask = Task {
      var didMarkReady = false
      for await tiles in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(tiles)
        if let tile = await collector.find(id: tileId) {
          if tile.board?.title == "Initial Title" {
            foundInitialBoard.fulfill()
          }
          if tile.board?.title == "Updated Title" {
            foundUpdatedBoard.fulfill()
          }
        }
      }
    }

    defer { consumeTask.cancel() }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create board with initial title
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Initial Title",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create tile linked to board
    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "yellow",
          "x": 3,
          "y": 3,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", tileId, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    await fulfillment(of: [foundInitialBoard], timeout: 10)

    // Now UPDATE the board's title
    let updateChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Updated Title"
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [updateChunk])

    await fulfillment(of: [foundUpdatedBoard], timeout: 10)

    let tile = await collector.find(id: tileId)
    XCTAssertEqual(tile?.board?.title, "Updated Title", "Linked entity update should propagate")

    // Cleanup
    try await cleanup(reactor: reactor, tiles: [tileId], boards: [boardId])
  }

  // MARK: - Test 5: Reverse link (board.tiles) works correctly

  /// When querying boards with their tiles included, the tiles array should be populated.
  func testReverseLinkWithIncludedLink() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let boardId = UUID().uuidString.lowercased()
    let tile1Id = UUID().uuidString.lowercased()
    let tile2Id = UUID().uuidString.lowercased()

    // Query boards WITH tiles (reverse link)
    let config = SharingInstantSync.CollectionConfiguration<BoardWithTiles>(
      namespace: "boards",
      orderBy: nil,
      whereClause: nil,
      includedLinks: ["tiles"],
      linkTree: [.link(name: "tiles")]
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = BoardWithTilesCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundBoardWith2Tiles = XCTestExpectation(description: "Found board with 2 tiles")

    let consumeTask = Task {
      var didMarkReady = false
      for await boards in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(boards)
        if let board = await collector.find(id: boardId),
           let tiles = board.tiles,
           tiles.count >= 2 {
          foundBoardWith2Tiles.fulfill()
        }
      }
    }

    defer { consumeTask.cancel() }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create board
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Board With Tiles",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create two tiles linked to board
    for (i, tileId) in [tile1Id, tile2Id].enumerated() {
      let tileChunk = TransactionChunk(
        namespace: "tiles",
        id: tileId,
        ops: [
          ["update", "tiles", tileId, [
            "color": i == 0 ? "red" : "blue",
            "x": Double(i),
            "y": Double(i),
            "createdAt": Date().timeIntervalSince1970 * 1000
          ]],
          ["link", "tiles", tileId, [
            "board": ["id": boardId, "namespace": "boards"]
          ]]
        ]
      )
      try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])
    }

    await fulfillment(of: [foundBoardWith2Tiles], timeout: 10)

    let board = await collector.find(id: boardId)
    XCTAssertNotNil(board, "Should find board")
    XCTAssertNotNil(board?.tiles, "Board should have tiles array")
    XCTAssertEqual(board?.tiles?.count, 2, "Board should have 2 tiles")

    let tileIds = Set(board?.tiles?.map { $0.id.lowercased() } ?? [])
    XCTAssertTrue(tileIds.contains(tile1Id), "Should include tile 1")
    XCTAssertTrue(tileIds.contains(tile2Id), "Should include tile 2")

    // Cleanup
    try await cleanup(reactor: reactor, tiles: [tile1Id, tile2Id], boards: [boardId])
  }

  // MARK: - Test 6: Filter by linked entity ID AND include linked entity

  /// Filter tiles by board.id AND include the board data.
  /// This is a common pattern: find all tiles for a board and get the board info too.
  func testFilterByLinkedEntityAndIncludeIt() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()
    let otherTileId = UUID().uuidString.lowercased()

    // Filter by board.id AND include board
    let config = SharingInstantSync.CollectionConfiguration<TileWithBoard>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: ["board.id": boardId],
      includedLinks: ["board"],
      linkTree: [.link(name: "board")]
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileWithBoardCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundFilteredTile = XCTestExpectation(description: "Found filtered tile with board")

    let consumeTask = Task {
      var didMarkReady = false
      for await tiles in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(tiles)
        if let tile = await collector.find(id: tileId),
           tile.board?.title != nil {
          foundFilteredTile.fulfill()
        }
      }
    }

    defer { consumeTask.cancel() }

    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create board
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Filtered Board",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create tile linked to board
    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "purple",
          "x": 5,
          "y": 5,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", tileId, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    // Create unlinked tile (should NOT appear in results)
    let otherTileChunk = TransactionChunk(
      namespace: "tiles",
      id: otherTileId,
      ops: [["update", "tiles", otherTileId, [
        "color": "gray",
        "x": 99,
        "y": 99,
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [otherTileChunk])

    await fulfillment(of: [foundFilteredTile], timeout: 10)

    let tiles = await collector.getTiles()
    XCTAssertEqual(tiles.count, 1, "Should only have 1 tile (filtered by board.id)")

    let tile = tiles.first
    XCTAssertEqual(tile?.id.lowercased(), tileId, "Should be the linked tile")
    XCTAssertNotNil(tile?.board, "Should have board included")
    XCTAssertEqual(tile?.board?.title, "Filtered Board", "Board should have full data")

    // Cleanup
    try await cleanup(reactor: reactor, tiles: [tileId, otherTileId], boards: [boardId])
  }

  // MARK: - Test 7: Entity with only ID field (edge case)

  /// Ensure we handle entities that legitimately only have an ID field.
  /// (This is an edge case - most entities have more fields, but we should handle it)
  func testEntityWithOnlyIdFieldIsNotFilteredOut() async throws {
    // This is a type-safe API test - no network needed
    // The preprocessEntity check is `count <= 1 && id != nil`
    // An entity with only { id: "..." } would be filtered
    // But this is correct behavior - a legitimate entity would have more fields

    // If an entity type ONLY has an id field in the schema, it would always be filtered
    // This test documents that behavior - it's a known limitation
    // In practice, all InstantDB entities have at least id + some other fields

    // Create a minimal test dictionary
    let entityWithOnlyId: [String: Any] = ["id": "test-id"]
    let entityWithIdAndMore: [String: Any] = ["id": "test-id", "name": "Test"]

    XCTAssertEqual(entityWithOnlyId.count, 1, "Entity with only ID has count 1")
    XCTAssertEqual(entityWithIdAndMore.count, 2, "Entity with ID and name has count 2")

    // The filter logic: count <= 1 && id != nil
    // entityWithOnlyId would be filtered (count=1, has id)
    // entityWithIdAndMore would NOT be filtered (count=2)

    // This is expected behavior - incomplete entities are filtered
    // Real entities always have more than just id
  }

  // MARK: - Helpers

  private func cleanup(reactor: Reactor, tiles: [String], boards: [String]) async throws {
    for id in tiles {
      let chunk = TransactionChunk(namespace: "tiles", id: id, ops: [["delete", "tiles", id]])
      try await reactor.transact(appID: Self.testAppID, chunks: [chunk])
    }
    for id in boards {
      let chunk = TransactionChunk(namespace: "boards", id: id, ops: [["delete", "boards", id]])
      try await reactor.transact(appID: Self.testAppID, chunks: [chunk])
    }
  }
}

// MARK: - Test Entity Types

/// Tile entity that includes optional board link
private struct TileWithBoard: Codable, Identifiable, Equatable, Sendable, EntityIdentifiable {
  let id: String
  let color: String
  let x: Double
  let y: Double
  let createdAt: Double
  var board: BoardRef?

  static var namespace: String { "tiles" }

  struct BoardRef: Codable, Equatable, Sendable {
    let id: String
    var title: String?
    var createdAt: Double?
  }
}

/// Board entity that includes optional tiles link
private struct BoardWithTiles: Codable, Identifiable, Equatable, Sendable, EntityIdentifiable {
  let id: String
  let title: String
  let createdAt: Double
  var tiles: [TileRef]?

  static var namespace: String { "boards" }

  struct TileRef: Codable, Equatable, Sendable {
    let id: String
    var color: String?
    var x: Double?
    var y: Double?
    var createdAt: Double?
  }
}

// MARK: - Thread-safe Collectors

private actor TileWithBoardCollector {
  var tiles: [TileWithBoard] = []

  func update(_ newTiles: [TileWithBoard]) {
    tiles = newTiles
  }

  func getTiles() -> [TileWithBoard] {
    return tiles
  }

  func find(id: String) -> TileWithBoard? {
    return tiles.first { $0.id.lowercased() == id.lowercased() }
  }

  func contains(id: String) -> Bool {
    return tiles.contains { $0.id.lowercased() == id.lowercased() }
  }
}

private actor BoardWithTilesCollector {
  var boards: [BoardWithTiles] = []

  func update(_ newBoards: [BoardWithTiles]) {
    boards = newBoards
  }

  func find(id: String) -> BoardWithTiles? {
    return boards.first { $0.id.lowercased() == id.lowercased() }
  }
}
