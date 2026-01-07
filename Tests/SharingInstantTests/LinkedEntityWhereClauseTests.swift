/// Tests for where clause filtering by linked entity attributes.
///
/// ## Background
///
/// In InstantDB, you can filter entities by attributes of linked entities using
/// dot notation in where clauses. For example:
/// - `tiles.where("board.id", .eq(boardId))` - Filter tiles by their linked board's ID
/// - `users.where("bookshelves.name", .eq("Fiction"))` - Filter users by bookshelf name
///
/// The TypeScript SDK supports multiple syntaxes (from instaql.test.ts):
/// - `'bookshelves.id': bookshelf.id` - Dot notation with .id suffix
/// - `bookshelves: bookshelf.id` - Just the link field name with ID value
/// - `'users.id': stopa.id` - Reverse reference with .id
///
/// These tests verify that sharing-instant properly supports filtering by linked entities.

import XCTest
import IdentifiedCollections
import Sharing
import Dependencies
@testable import SharingInstant
import InstantDB

// MARK: - Linked Entity Where Clause Tests

final class LinkedEntityWhereClauseTests: XCTestCase {

  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"

  // Note: setUp doesn't require integration test gate
  // Individual tests that need network will call IntegrationTestGate.requireEnabled()

  // MARK: - Test 1: Filter by linked entity ID using dot notation (board.id)

  /// Tests filtering tiles by their linked board's ID using dot notation.
  ///
  /// Expected behavior from TypeScript SDK:
  /// ```javascript
  /// query(ctx, {
  ///   users: { $: { where: { 'bookshelves.id': bookshelf.id } } }
  /// })
  /// ```
  func testFilterByLinkedEntityIdDotNotation() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    // Create IDs upfront
    let boardId = UUID().uuidString.lowercased()
    let linkedTile1Id = UUID().uuidString.lowercased()
    let linkedTile2Id = UUID().uuidString.lowercased()
    let unlinkedTileId = UUID().uuidString.lowercased()

    // Subscribe FIRST to establish connection - this is how ReactorTests work
    let config = SharingInstantSync.CollectionConfiguration<Tile>(
      namespace: "tiles",
      orderBy: .asc("x"),
      whereClause: ["board.id": boardId],  // Dot notation: board.id
      includedLinks: [],
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundTiles = XCTestExpectation(description: "Found filtered tiles")

    let consumeTask = Task {
      var didMarkReady = false
      for await tiles in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(tiles)
        // We expect to find exactly 2 tiles (the linked ones)
        if await collector.count() >= 2 {
          foundTiles.fulfill()
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    // Wait for subscription to be ready before creating data
    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create a board
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Test Board for Where Clause",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create linked tiles
    let tile1Chunk = TransactionChunk(
      namespace: "tiles",
      id: linkedTile1Id,
      ops: [
        ["update", "tiles", linkedTile1Id, [
          "color": "red",
          "x": 0,
          "y": 0,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", linkedTile1Id, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tile1Chunk])

    let tile2Chunk = TransactionChunk(
      namespace: "tiles",
      id: linkedTile2Id,
      ops: [
        ["update", "tiles", linkedTile2Id, [
          "color": "blue",
          "x": 1,
          "y": 0,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", linkedTile2Id, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tile2Chunk])

    // Create unlinked tile (should NOT be returned)
    let tile3Chunk = TransactionChunk(
      namespace: "tiles",
      id: unlinkedTileId,
      ops: [["update", "tiles", unlinkedTileId, [
        "color": "green",
        "x": 2,
        "y": 0,
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tile3Chunk])

    // Wait for the linked tiles to appear
    await fulfillment(of: [foundTiles], timeout: 10)

    let tiles = await collector.getTiles()
    let tileIds = Set(tiles.map { $0.id.lowercased() })

    // Verify we got exactly the linked tiles
    XCTAssertEqual(tiles.count, 2, "Should find exactly 2 tiles linked to the board")
    XCTAssertTrue(tileIds.contains(linkedTile1Id), "Should include linked tile 1")
    XCTAssertTrue(tileIds.contains(linkedTile2Id), "Should include linked tile 2")
    XCTAssertFalse(tileIds.contains(unlinkedTileId), "Should NOT include unlinked tile")

    // Cleanup
    for id in [linkedTile1Id, linkedTile2Id, unlinkedTileId] {
      let deleteChunk = TransactionChunk(
        namespace: "tiles",
        id: id,
        ops: [["delete", "tiles", id]]
      )
      try await reactor.transact(appID: Self.testAppID, chunks: [deleteChunk])
    }
    let deleteBoardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["delete", "boards", boardId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteBoardChunk])
  }

  // MARK: - Test 2: Filter by link field name only (without .id suffix)

  /// Tests filtering tiles by passing just the link field name with an ID value.
  ///
  /// Expected behavior from TypeScript SDK:
  /// ```javascript
  /// query(ctx, {
  ///   users: { $: { where: { bookshelves: bookshelf.id } } }
  /// })
  /// ```
  func testFilterByLinkFieldNameOnly() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    // Create IDs upfront
    let boardId = UUID().uuidString.lowercased()
    let linkedTileId = UUID().uuidString.lowercased()

    // Subscribe FIRST to establish connection
    let config = SharingInstantSync.CollectionConfiguration<Tile>(
      namespace: "tiles",
      orderBy: nil,
      whereClause: ["board": boardId],  // Just link field name, no .id suffix
      includedLinks: [],
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundTile = XCTestExpectation(description: "Found filtered tile")

    let consumeTask = Task {
      var didMarkReady = false
      for await tiles in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(tiles)
        if await collector.contains(id: linkedTileId) {
          foundTile.fulfill()
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    // Wait for subscription to be ready
    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create a board
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "Test Board for Link Field",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    // Create a linked tile
    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: linkedTileId,
      ops: [
        ["update", "tiles", linkedTileId, [
          "color": "purple",
          "x": 0,
          "y": 0,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", linkedTileId, [
          "board": ["id": boardId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    await fulfillment(of: [foundTile], timeout: 10)

    let tiles = await collector.getTiles()

    XCTAssertEqual(tiles.count, 1, "Should find exactly 1 tile linked to the board")
    XCTAssertEqual(tiles.first?.id.lowercased(), linkedTileId, "Should find the correct tile")

    // Cleanup
    let deleteTileChunk = TransactionChunk(
      namespace: "tiles",
      id: linkedTileId,
      ops: [["delete", "tiles", linkedTileId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteTileChunk])
    let deleteBoardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["delete", "boards", boardId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteBoardChunk])
  }

  // MARK: - Test 3: Verify EntityKey type-safe where clause with linked entity

  /// Tests that the EntityKey API properly supports type-safe where clauses for linked entities.
  ///
  /// Currently, the API requires strings for link-based filtering:
  /// ```swift
  /// Schema.tiles.where("board.id", .eq(boardId))  // String-based, not type-safe
  /// ```
  ///
  /// We want a type-safe API like:
  /// ```swift
  /// Schema.tiles.where(\.board.id, .eq(boardId))  // KeyPath-based, type-safe
  /// // OR
  /// Schema.tiles.whereLinked(\.board, .eq(boardId))  // Specialized link filter
  /// ```
  func testEntityKeyWhereWithLinkedEntity() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    // Create IDs upfront
    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Test using EntityKey with string-based where clause (current API)
    let entityKey = Schema.tiles.where("board.id", .eq(boardId))

    // Get configuration from EntityKey
    let request = EntityKeyRequest(key: entityKey)
    guard let config = request.configuration else {
      XCTFail("EntityKeyRequest should have a configuration")
      return
    }

    // Verify the where clause is properly formed
    XCTAssertNotNil(config.whereClause, "Where clause should be set")
    XCTAssertEqual(config.whereClause?["board.id"] as? String, boardId,
                   "Where clause should contain board.id filter")

    // Subscribe FIRST to establish connection
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = TileCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundTile = XCTestExpectation(description: "Found tile via EntityKey")

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

    defer {
      consumeTask.cancel()
    }

    // Wait for subscription to be ready
    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create test data
    let boardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["update", "boards", boardId, [
        "title": "EntityKey Test Board",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [boardChunk])

    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "orange",
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

    await fulfillment(of: [foundTile], timeout: 10)

    let tiles = await collector.getTiles()
    XCTAssertEqual(tiles.count, 1, "EntityKey where clause should filter to 1 tile")
    XCTAssertEqual(tiles.first?.id.lowercased(), tileId)

    // Cleanup
    let deleteTileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [["delete", "tiles", tileId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteTileChunk])
    let deleteBoardChunk = TransactionChunk(
      namespace: "boards",
      id: boardId,
      ops: [["delete", "boards", boardId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteBoardChunk])
  }

  // MARK: - Test 4: Type-safe generated whereBoard API

  /// Tests the generated type-safe API for filtering tiles by board.
  ///
  /// The codegen generates type-safe methods like:
  /// ```swift
  /// Schema.tiles.whereBoard(id: boardId)      // Convenience method
  /// Schema.tiles.whereBoard(.eq(boardId))     // With predicate
  /// ```
  func testTypeSafeGeneratedWhereBoardAPI() throws {
    // Note: This test doesn't need network - it just tests the API
    let boardId = "test-board-type-safe-123"

    // Test 1: Convenience method whereBoard(id:)
    let key1 = Schema.tiles.whereBoard(id: boardId)
    XCTAssertEqual(key1.whereClauses.count, 1, "Should have 1 where clause")
    XCTAssertNotNil(key1.whereClauses["board.id"], "Should have board.id clause")
    if case .equals(let value) = key1.whereClauses["board.id"] {
      XCTAssertEqual(value.base as? String, boardId, "Should filter by correct board ID")
    } else {
      XCTFail("Expected .equals predicate")
    }

    // Test 2: Predicate method whereBoard(_ predicate:)
    let key2 = Schema.tiles.whereBoard(.eq(boardId))
    XCTAssertEqual(key2.whereClauses.count, 1, "Should have 1 where clause")
    XCTAssertNotNil(key2.whereClauses["board.id"], "Should have board.id clause")
    if case .equals(let value) = key2.whereClauses["board.id"] {
      XCTAssertEqual(value.base as? String, boardId, "Should filter by correct board ID")
    } else {
      XCTFail("Expected .equals predicate")
    }

    // Test 3: .in predicate for multiple board IDs
    let boardIds = ["board-1", "board-2", "board-3"]
    let key3 = Schema.tiles.whereBoard(.in(boardIds))
    XCTAssertEqual(key3.whereClauses.count, 1, "Should have 1 where clause")
    if case .isIn(let values) = key3.whereClauses["board.id"] {
      let stringValues = values.compactMap { $0.base as? String }
      XCTAssertEqual(stringValues, boardIds, "Should filter by correct board IDs")
    } else {
      XCTFail("Expected .isIn predicate")
    }

    // Test 4: Chaining with other methods
    let key4 = Schema.tiles
      .whereBoard(id: boardId)
      .orderBy(\.x, .asc)
      .limit(10)
    XCTAssertNotNil(key4.whereClauses["board.id"], "Should have board.id clause")
    XCTAssertEqual(key4.orderByField, "x", "Should have orderBy x")
    XCTAssertEqual(key4.orderDirection, .asc, "Should be ascending")
    XCTAssertEqual(key4.limitCount, 10, "Should have limit 10")
  }

  // MARK: - Test 5: Type-safe generated whereTiles reverse link API

  /// Tests the generated type-safe API for filtering boards by their tiles (reverse link).
  ///
  /// The codegen generates type-safe methods like:
  /// ```swift
  /// Schema.boards.whereTiles(id: tileId)
  /// ```
  func testTypeSafeGeneratedWhereTilesAPI() throws {
    // Note: This test doesn't need network - it just tests the API
    let tileId = "test-tile-type-safe-456"

    // Test the generated whereTiles method on boards
    let key = Schema.boards.whereTiles(id: tileId)

    XCTAssertEqual(key.whereClauses.count, 1, "Should have 1 where clause")
    XCTAssertNotNil(key.whereClauses["tiles.id"], "Should have tiles.id clause")

    if case .equals(let value) = key.whereClauses["tiles.id"] {
      XCTAssertEqual(value.base as? String, tileId, "Should filter by correct tile ID")
    } else {
      XCTFail("Expected .equals predicate")
    }
  }

  // MARK: - Test 6: Reverse link filtering (from parent to find children)

  /// Tests filtering boards to find those that have specific tiles linked to them.
  ///
  /// This is the reverse direction: instead of filtering tiles by board,
  /// we filter boards by the tiles they contain.
  ///
  /// Expected behavior from TypeScript SDK:
  /// ```javascript
  /// query(ctx, {
  ///   bookshelves: { $: { where: { 'users.handle': 'stopa' } } }
  /// })
  /// ```
  func testReverseLinkFiltering() async throws {
    try IntegrationTestGate.requireEnabled()
    let store = SharedTripleStore()
    let reactor = Reactor(store: store)

    // Create IDs upfront
    let boardWithTilesId = UUID().uuidString.lowercased()
    let boardWithoutTilesId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Subscribe FIRST with reverse link filter: boards that have this tile
    let config = SharingInstantSync.CollectionConfiguration<Board>(
      namespace: "boards",
      orderBy: nil,
      whereClause: ["tiles.id": tileId],  // Reverse link: filter boards by their tiles
      includedLinks: [],
      linkTree: []
    )
    let stream = await reactor.subscribe(appID: Self.testAppID, configuration: config)

    let collector = BoardCollector()
    let subscriptionReady = XCTestExpectation(description: "Subscription registered")
    let foundBoard = XCTestExpectation(description: "Found board via reverse link")

    let consumeTask = Task {
      var didMarkReady = false
      for await boards in stream {
        if !didMarkReady {
          didMarkReady = true
          subscriptionReady.fulfill()
        }
        await collector.update(boards)
        if await collector.contains(id: boardWithTilesId) {
          foundBoard.fulfill()
        }
      }
    }

    defer {
      consumeTask.cancel()
    }

    // Wait for subscription to be ready
    await fulfillment(of: [subscriptionReady], timeout: 10)

    // Create two boards
    let board1Chunk = TransactionChunk(
      namespace: "boards",
      id: boardWithTilesId,
      ops: [["update", "boards", boardWithTilesId, [
        "title": "Board With Tiles",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [board1Chunk])

    let board2Chunk = TransactionChunk(
      namespace: "boards",
      id: boardWithoutTilesId,
      ops: [["update", "boards", boardWithoutTilesId, [
        "title": "Board Without Tiles",
        "createdAt": Date().timeIntervalSince1970 * 1000
      ]]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [board2Chunk])

    // Create a tile linked to the first board
    let tileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [
        ["update", "tiles", tileId, [
          "color": "cyan",
          "x": 10,
          "y": 10,
          "createdAt": Date().timeIntervalSince1970 * 1000
        ]],
        ["link", "tiles", tileId, [
          "board": ["id": boardWithTilesId, "namespace": "boards"]
        ]]
      ]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [tileChunk])

    await fulfillment(of: [foundBoard], timeout: 10)

    let boards = await collector.getBoards()

    XCTAssertEqual(boards.count, 1, "Should find exactly 1 board with the specific tile")
    XCTAssertEqual(boards.first?.id.lowercased(), boardWithTilesId, "Should find the correct board")

    // Cleanup
    let deleteTileChunk = TransactionChunk(
      namespace: "tiles",
      id: tileId,
      ops: [["delete", "tiles", tileId]]
    )
    try await reactor.transact(appID: Self.testAppID, chunks: [deleteTileChunk])

    for id in [boardWithTilesId, boardWithoutTilesId] {
      let deleteBoardChunk = TransactionChunk(
        namespace: "boards",
        id: id,
        ops: [["delete", "boards", id]]
      )
      try await reactor.transact(appID: Self.testAppID, chunks: [deleteBoardChunk])
    }
  }
}

// MARK: - Thread-safe Collectors

private actor TileCollector {
  var tiles: [Tile] = []

  func update(_ newTiles: [Tile]) {
    tiles = newTiles
  }

  func getTiles() -> [Tile] {
    return tiles
  }

  func count() -> Int {
    return tiles.count
  }

  func contains(id: String) -> Bool {
    return tiles.contains { $0.id.lowercased() == id.lowercased() }
  }
}

private actor BoardCollector {
  var boards: [Board] = []

  func update(_ newBoards: [Board]) {
    boards = newBoards
  }

  func getBoards() -> [Board] {
    return boards
  }

  func count() -> Int {
    return boards.count
  }

  func contains(id: String) -> Bool {
    return boards.contains { $0.id.lowercased() == id.lowercased() }
  }
}
