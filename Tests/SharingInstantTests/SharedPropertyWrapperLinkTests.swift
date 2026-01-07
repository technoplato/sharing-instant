/// Tests for @Shared property wrapper with schema-generated links.
///
/// These tests verify that the full @Shared API works correctly with:
/// 1. Schema.entity.with(\.linkedEntity) - type-safe link inclusion
/// 2. Generated mutation methods ($tiles.linkBoard, etc.)
/// 3. Type-safe where clause extensions (Schema.tiles.whereBoard(id:))
/// 4. Full CRUD operations with linked entities

import XCTest
import IdentifiedCollections
import Sharing
import Dependencies
@testable import SharingInstant

final class SharedPropertyWrapperLinkTests: XCTestCase {

  static let testAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"

  // MARK: - Test 1: Basic Schema Entity Key with Link

  /// Verify that Schema.tiles.with(\.board) creates the correct configuration.
  func testSchemaEntityKeyWithLink() {
    // This is a compile-time type safety test
    // Schema.tiles.with(\.board) should compile and produce correct config
    let key = Schema.tiles.with(\.board)

    // The key should have the link included
    XCTAssertEqual(key.namespace, "tiles")
    XCTAssertTrue(key.linkTree.contains { node in
      if case .link(name: "board", _, _, _, _, _) = node {
        return true
      }
      return false
    })
  }

  // MARK: - Test 2: Schema Entity Key with Multiple Links

  /// Verify chaining multiple .with() calls works.
  func testSchemaEntityKeyWithMultipleLinks() {
    // Schema.boards with both tiles links
    let key = Schema.boards.with(\.tiles).with(\.linkedTiles)

    XCTAssertEqual(key.namespace, "boards")
    XCTAssertEqual(key.linkTree.count, 2)

    let linkNames = key.linkTree.compactMap { node -> String? in
      if case .link(name: let name, _, _, _, _, _) = node {
        return name
      }
      return nil
    }
    XCTAssertTrue(linkNames.contains("tiles"))
    XCTAssertTrue(linkNames.contains("linkedTiles"))
  }

  // MARK: - Test 3: WhereBoard Extension Works

  /// Verify the generated whereBoard(id:) extension creates correct where clause.
  func testWhereBoardExtension() {
    let boardId = "test-board-id"
    let key = Schema.tiles.whereBoard(id: boardId)

    XCTAssertEqual(key.namespace, "tiles")

    // The where clause should contain board.id
    XCTAssertTrue(key.whereClauses.keys.contains("board.id"))

    if let predicate = key.whereClauses["board.id"] {
      if case .equals(let wrapped) = predicate {
        XCTAssertEqual(wrapped.base as? String, boardId)
      } else {
        XCTFail("Expected .equals predicate")
      }
    } else {
      XCTFail("Expected board.id where clause")
    }
  }

  // MARK: - Test 4: WhereBoard with .with() Combined

  /// Verify whereBoard and with can be combined.
  func testWhereBoardAndWithCombined() {
    let boardId = "test-board-id"
    let key = Schema.tiles
      .whereBoard(id: boardId)
      .with(\.board)

    XCTAssertEqual(key.namespace, "tiles")

    // Should have both where clause and link
    XCTAssertTrue(key.whereClauses.keys.contains("board.id"))
    XCTAssertTrue(key.linkTree.contains { node in
      if case .link(name: "board", _, _, _, _, _) = node {
        return true
      }
      return false
    })
  }

  // MARK: - Test 5: @Shared with .with() Returns Linked Entity

  /// Integration test: @Shared with Schema.tiles.with(\.board) should return tiles with board data.
  @MainActor
  func testSharedWithLinkReturnsLinkedEntity() async throws {
    try IntegrationTestGate.requireEnabled()

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Use @Shared with .with() to include board link
    @Shared(.instantSync(Schema.tiles.with(\.board)))
    var tiles: IdentifiedArrayOf<Tile> = []

    // Wait for initial subscription
    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create board first
    @Shared(.instantSync(Schema.boards))
    var boards: IdentifiedArrayOf<Board> = []

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let board = Board(
      id: boardId,
      createdAt: Date().timeIntervalSince1970 * 1000,
      title: "Test Board via @Shared"
    )
    $boards.withLock { $0.append(board) }

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create tile with board link
    let tile = Tile(
      id: tileId,
      color: "sharedBlue",
      createdAt: Date().timeIntervalSince1970 * 1000,
      x: 5,
      y: 10,
      board: board  // Link to board
    )
    $tiles.withLock { $0.append(tile) }

    try await Task.sleep(nanoseconds: 3_000_000_000)

    // Verify tile exists with full board data
    let foundTile = tiles[id: tileId]
    XCTAssertNotNil(foundTile, "Tile should exist")
    XCTAssertNotNil(foundTile?.board, "Tile should have board link populated (using .with())")
    XCTAssertEqual(foundTile?.board?.id.lowercased(), boardId, "Board ID should match")
    XCTAssertEqual(foundTile?.board?.title, "Test Board via @Shared", "Board title should be populated")

    // Cleanup
    $tiles.withLock { $0.remove(id: tileId) }
    try await Task.sleep(nanoseconds: 500_000_000)
    $boards.withLock { $0.remove(id: boardId) }
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Test 6: @Shared WITHOUT .with() Returns Nil for Linked Entity

  /// Integration test: @Shared WITHOUT .with() should return nil for board field.
  @MainActor
  func testSharedWithoutLinkReturnsNilForLinkedEntity() async throws {
    try IntegrationTestGate.requireEnabled()

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Use @Shared WITHOUT .with() - should NOT include board data
    @Shared(.instantSync(Schema.tiles))
    var tiles: IdentifiedArrayOf<Tile> = []

    // Wait for initial subscription
    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create board
    @Shared(.instantSync(Schema.boards))
    var boards: IdentifiedArrayOf<Board> = []

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let board = Board(
      id: boardId,
      createdAt: Date().timeIntervalSince1970 * 1000,
      title: "Hidden Board"
    )
    $boards.withLock { $0.append(board) }

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create tile with board link
    let tile = Tile(
      id: tileId,
      color: "noLinkGreen",
      createdAt: Date().timeIntervalSince1970 * 1000,
      x: 0,
      y: 0,
      board: board
    )
    $tiles.withLock { $0.append(tile) }

    try await Task.sleep(nanoseconds: 3_000_000_000)

    // Verify tile exists but board should be nil (not requested with .with())
    let foundTile = tiles[id: tileId]
    XCTAssertNotNil(foundTile, "Tile should exist")
    // THIS IS THE KEY TEST: Without .with(), board should be nil
    XCTAssertNil(foundTile?.board, "Board should be nil when NOT requested via .with()")

    // Cleanup
    $tiles.withLock { $0.remove(id: tileId) }
    try await Task.sleep(nanoseconds: 500_000_000)
    $boards.withLock { $0.remove(id: boardId) }
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Test 7: Two @Shared Subscriptions with Different Link Requests

  /// Two @Shared properties - one with .with(\.board), one without.
  /// Each should get only what it requested.
  @MainActor
  func testTwoSharedSubscriptionsWithDifferentLinks() async throws {
    try IntegrationTestGate.requireEnabled()

    let boardId = UUID().uuidString.lowercased()
    let tileId = UUID().uuidString.lowercased()

    // Subscription 1: WITH board link
    @Shared(.instantSync(Schema.tiles.with(\.board)))
    var tilesWithBoard: IdentifiedArrayOf<Tile> = []

    // Subscription 2: WITHOUT board link
    @Shared(.instantSync(Schema.tiles))
    var tilesWithoutBoard: IdentifiedArrayOf<Tile> = []

    // Wait for subscriptions
    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create board
    @Shared(.instantSync(Schema.boards))
    var boards: IdentifiedArrayOf<Board> = []

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let board = Board(
      id: boardId,
      createdAt: Date().timeIntervalSince1970 * 1000,
      title: "Multi-Sub Board"
    )
    $boards.withLock { $0.append(board) }

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create tile with board link
    let tile = Tile(
      id: tileId,
      color: "multiSubPurple",
      createdAt: Date().timeIntervalSince1970 * 1000,
      x: 3,
      y: 3,
      board: board
    )
    $tilesWithBoard.withLock { $0.append(tile) }

    try await Task.sleep(nanoseconds: 3_000_000_000)

    // Subscription 1 (with .with()) should have full board
    let tile1 = tilesWithBoard[id: tileId]
    XCTAssertNotNil(tile1, "Tiles with board subscription should have tile")
    XCTAssertNotNil(tile1?.board, "Subscription with .with() should have board populated")
    XCTAssertEqual(tile1?.board?.title, "Multi-Sub Board", "Board should have full data")

    // Subscription 2 (without .with()) should have nil board
    let tile2 = tilesWithoutBoard[id: tileId]
    XCTAssertNotNil(tile2, "Tiles without board subscription should have tile")
    // THIS IS THE KEY TEST: Different subscriptions should get different data
    XCTAssertNil(tile2?.board, "Subscription without .with() should NOT have board")

    // Cleanup
    $tilesWithBoard.withLock { $0.remove(id: tileId) }
    try await Task.sleep(nanoseconds: 500_000_000)
    $boards.withLock { $0.remove(id: boardId) }
    try await Task.sleep(nanoseconds: 500_000_000)
  }

  // MARK: - Test 8: Post with Author Link (Microblog Pattern)

  /// Test the microblog pattern: posts with author link.
  @MainActor
  func testPostsWithAuthorLink() async throws {
    try IntegrationTestGate.requireEnabled()

    let profileId = UUID().uuidString.lowercased()
    let postId = UUID().uuidString.lowercased()

    // Create profile first
    @Shared(.instantSync(Schema.profiles))
    var profiles: IdentifiedArrayOf<Profile> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    let profile = Profile(
      id: profileId,
      avatarUrl: nil,
      bio: "Test bio",
      createdAt: Date().timeIntervalSince1970 * 1000,
      displayName: "Test Author",
      handle: "testauthor"
    )
    $profiles.withLock { $0.append(profile) }

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Query posts WITH author
    @Shared(.instantSync(Schema.posts.with(\.author)))
    var posts: IdentifiedArrayOf<Post> = []

    try await Task.sleep(nanoseconds: 2_000_000_000)

    // Create post with author link
    let post = Post(
      id: postId,
      content: "Hello from @Shared test!",
      createdAt: Date().timeIntervalSince1970 * 1000,
      imageUrl: nil,
      author: profile
    )
    $posts.withLock { $0.append(post) }

    try await Task.sleep(nanoseconds: 3_000_000_000)

    // Verify post has full author data
    let foundPost = posts[id: postId]
    XCTAssertNotNil(foundPost, "Post should exist")
    XCTAssertNotNil(foundPost?.author, "Post should have author link")
    XCTAssertEqual(foundPost?.author?.handle, "testauthor", "Author handle should match")
    XCTAssertEqual(foundPost?.author?.displayName, "Test Author", "Author displayName should match")

    // Cleanup
    $posts.withLock { $0.remove(id: postId) }
    try await Task.sleep(nanoseconds: 500_000_000)
    $profiles.withLock { $0.remove(id: profileId) }
    try await Task.sleep(nanoseconds: 500_000_000)
  }
}
