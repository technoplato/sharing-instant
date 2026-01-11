import InstantDB
import XCTest

@testable import SharingInstant

/// Tests for query/resolution behavior on TripleStore.
///
/// ## Upstream Source of Truth
///
/// These tests are ported from the TypeScript SDK:
/// - **File**: `instant/client/packages/core/__tests__/src/instaql.test.ts`
/// - **GitHub**: https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/instaql.test.ts
///
/// The "zeneca" test dataset used here mirrors the TypeScript SDK's test data:
/// - **Attrs**: `instant/client/packages/core/__tests__/src/data/zeneca/attrs.json`
/// - **GitHub**: https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/data/zeneca/attrs.json
///
/// ## Key Implementation Details
///
/// ### Link Resolution Depth
///
/// The `resolve()` function uses `maxDepth` (default: 10) to prevent infinite recursion
/// on bidirectional relationships. This matches the TypeScript SDK's behavior where
/// circular references are truncated at a configurable depth.
///
/// ### includedLinks Parameter
///
/// The `includedLinks` parameter (added for TypeScript SDK parity) controls which links
/// are resolved. This matches the TypeScript SDK's query-driven resolution where only
/// links explicitly requested in the query are populated.
///
/// See TypeScript implementation in `instant/client/packages/core/src/instaql.ts`:
/// - `extendObjects()` function (lines ~539-563)
/// - `linkIndex` for cardinality lookup (lines ~15-33 in linkIndex.ts)
///
/// ### Entity Resolution via TripleStore
///
/// Unlike the TypeScript SDK which uses InstaQL queries, Swift resolution works directly
/// on the TripleStore using the `resolve()` → `get<T>()` pattern. The resolved dictionary
/// is then decoded into Codable structs using JSONDecoder.
final class TripleStoreQueryTests: XCTestCase {

    // MARK: - Test 1: Get association (instaql.test.ts lines 383-395)

    /// Tests forward link resolution.
    /// TypeScript equivalent:
    /// ```typescript
    /// test('Get association', () => {
    ///   expect(query(ctx, {
    ///     users: {
    ///       bookshelves: {},  // Include linked entity
    ///       $: { where: { handle: 'alex' } },
    ///     },
    ///   }).data.users.map((x) => [x.handle, x.bookshelves.map((x) => x.name).sort()]),
    ///   ).toEqual([['alex', ['Nonfiction', 'Short Stories']]]);
    /// });
    /// ```
    func testGetForwardAssociation() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create user with two bookshelves
        let result = ZenecaTestData.createUserWithBookshelves(
            in: store,
            attrsStore: attrsStore,
            handle: "alex",
            bookshelfName: "Nonfiction",
            bookTitles: []
        )

        // Add a second bookshelf
        let secondShelfId = UUID().uuidString
        store.addStringTriple(
            entityId: secondShelfId,
            attributeId: ZenecaTestData.bookshelvesNameAttrId,
            value: "Short Stories",
            timestamp: 0
        )
        store.addRefTriple(
            entityId: result.userId,
            attributeId: ZenecaTestData.usersBooksshelvesAttrId,
            targetId: secondShelfId,
            timestamp: 0
        )

        // Verify forward association resolves
        let user: ZenecaUser? = store.get(id: result.userId, attrsStore: attrsStore)
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.handle, "alex")
        XCTAssertEqual(user?.bookshelves?.count, 2)

        let shelfNames = user?.bookshelves?.map { $0.name }.sorted()
        XCTAssertEqual(shelfNames, ["Nonfiction", "Short Stories"])
    }

    // MARK: - Test 2: Get reverse association (instaql.test.ts lines 397-409)

    /// Tests reverse link resolution.
    /// TypeScript equivalent:
    /// ```typescript
    /// test('Get reverse association', () => {
    ///   expect(query(ctx, {
    ///     bookshelves: {
    ///       users: {},  // Reverse link back to users
    ///       $: { where: { name: 'Short Stories' } },
    ///     },
    ///   }).data.bookshelves.map((x) => [x.name, x.users.map((x) => x.handle).sort()]),
    ///   ).toEqual([['Short Stories', ['alex']]]);
    /// });
    /// ```
    func testGetReverseAssociation() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create user
        let userId = UUID().uuidString
        store.addStringTriple(
            entityId: userId,
            attributeId: ZenecaTestData.usersHandleAttrId,
            value: "alex",
            timestamp: 0
        )

        // Create bookshelf
        let bookshelfId = UUID().uuidString
        store.addStringTriple(
            entityId: bookshelfId,
            attributeId: ZenecaTestData.bookshelvesNameAttrId,
            value: "Short Stories",
            timestamp: 0
        )

        // Link user -> bookshelf (forward direction)
        store.addRefTriple(
            entityId: userId,
            attributeId: ZenecaTestData.usersBooksshelvesAttrId,
            targetId: bookshelfId,
            timestamp: 0
        )

        // Verify REVERSE association: bookshelf -> users
        let bookshelf: ZenecaBookshelf? = store.get(id: bookshelfId, attrsStore: attrsStore)
        XCTAssertNotNil(bookshelf)
        XCTAssertEqual(bookshelf?.name, "Short Stories")

        // The reverse link (users) should resolve
        XCTAssertNotNil(bookshelf?.users, "Reverse link 'users' should resolve")
        XCTAssertEqual(bookshelf?.users?.count, 1)
        XCTAssertEqual(bookshelf?.users?.first?.handle, "alex")
    }

    // MARK: - Test 3: Get deep association (instaql.test.ts lines 411-433)

    /// Tests deep nested link traversal (3 levels).
    /// TypeScript equivalent:
    /// ```typescript
    /// test('Get deep association', () => {
    ///   expect(query(ctx, {
    ///     users: {
    ///       bookshelves: { books: {} },  // THREE levels deep
    ///       $: { where: { handle: 'alex' } },
    ///     },
    ///   }).data.users.flatMap((x) => x.bookshelves)
    ///     .flatMap((x) => x.books)
    ///     .map((x) => x.title)
    ///   ).toEqual([...]);
    /// });
    /// ```
    func testGetDeepAssociation() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create user with bookshelf containing books
        let result = ZenecaTestData.createUserWithBookshelves(
            in: store,
            attrsStore: attrsStore,
            handle: "alex",
            bookshelfName: "Nonfiction",
            bookTitles: ["Antifragile", "Atomic Habits", "Catch and Kill"]
        )

        // Verify deep association resolves: user -> bookshelves -> books
        let user: ZenecaUser? = store.get(id: result.userId, attrsStore: attrsStore)
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.handle, "alex")

        // Get books through nested path
        let books = user?.bookshelves?.flatMap { $0.books ?? [] }
        XCTAssertNotNil(books)
        XCTAssertEqual(books?.count, 3)

        let titles = books?.map { $0.title }.sorted()
        XCTAssertEqual(titles, ["Antifragile", "Atomic Habits", "Catch and Kill"])
    }

    // MARK: - Test 4: Nested wheres (conceptual - instaql.test.ts lines 435-454)
    // Note: Swift SDK doesn't have the same where clause mechanism as TypeScript.
    // This test demonstrates the expected filtering behavior at the application layer.

    func testNestedFiltering() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        let userId = UUID().uuidString
        store.addStringTriple(
            entityId: userId,
            attributeId: ZenecaTestData.usersHandleAttrId,
            value: "alex",
            timestamp: 0
        )

        // Create two bookshelves
        let shelf1Id = UUID().uuidString
        store.addStringTriple(
            entityId: shelf1Id,
            attributeId: ZenecaTestData.bookshelvesNameAttrId,
            value: "Short Stories",
            timestamp: 0
        )
        let shelf2Id = UUID().uuidString
        store.addStringTriple(
            entityId: shelf2Id,
            attributeId: ZenecaTestData.bookshelvesNameAttrId,
            value: "Nonfiction",
            timestamp: 0
        )

        // Link user to both
        store.addRefTriple(entityId: userId, attributeId: ZenecaTestData.usersBooksshelvesAttrId, targetId: shelf1Id, timestamp: 0)
        store.addRefTriple(entityId: userId, attributeId: ZenecaTestData.usersBooksshelvesAttrId, targetId: shelf2Id, timestamp: 0)

        // Add books to Short Stories shelf
        let book1Id = UUID().uuidString
        store.addStringTriple(entityId: book1Id, attributeId: ZenecaTestData.booksTitleAttrId, value: "The Paper Menagerie", timestamp: 0)
        store.addRefTriple(entityId: shelf1Id, attributeId: ZenecaTestData.bookshelvesBooksAttrId, targetId: book1Id, timestamp: 0)

        let book2Id = UUID().uuidString
        store.addStringTriple(entityId: book2Id, attributeId: ZenecaTestData.booksTitleAttrId, value: "Aesop's Fables", timestamp: 0)
        store.addRefTriple(entityId: shelf1Id, attributeId: ZenecaTestData.bookshelvesBooksAttrId, targetId: book2Id, timestamp: 0)

        // Resolve user
        let user: ZenecaUser? = store.get(id: userId, attrsStore: attrsStore)
        XCTAssertNotNil(user)

        // Application-level filtering: get only "Short Stories" bookshelf
        let shortStoriesShelf = user?.bookshelves?.first { $0.name == "Short Stories" }
        XCTAssertNotNil(shortStoriesShelf)
        XCTAssertEqual(shortStoriesShelf?.books?.count, 2)

        let titles = shortStoriesShelf?.books?.map { $0.title }.sorted()
        XCTAssertEqual(titles, ["Aesop's Fables", "The Paper Menagerie"])
    }

    // MARK: - Test 5: Multiple connections (instaql.test.ts lines 539-563)

    /// Tests entity with multiple different link types.
    func testMultipleConnections() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create bookshelf
        let bookshelfId = UUID().uuidString
        store.addStringTriple(
            entityId: bookshelfId,
            attributeId: ZenecaTestData.bookshelvesNameAttrId,
            value: "Short Stories",
            timestamp: 0
        )

        // Create user and link to bookshelf
        let userId = UUID().uuidString
        store.addStringTriple(
            entityId: userId,
            attributeId: ZenecaTestData.usersHandleAttrId,
            value: "alex",
            timestamp: 0
        )
        store.addRefTriple(
            entityId: userId,
            attributeId: ZenecaTestData.usersBooksshelvesAttrId,
            targetId: bookshelfId,
            timestamp: 0
        )

        // Create books and link to bookshelf
        let book1Id = UUID().uuidString
        store.addStringTriple(entityId: book1Id, attributeId: ZenecaTestData.booksTitleAttrId, value: "Aesop's Fables", timestamp: 0)
        store.addRefTriple(entityId: bookshelfId, attributeId: ZenecaTestData.bookshelvesBooksAttrId, targetId: book1Id, timestamp: 0)

        let book2Id = UUID().uuidString
        store.addStringTriple(entityId: book2Id, attributeId: ZenecaTestData.booksTitleAttrId, value: "Stories of Your Life", timestamp: 0)
        store.addRefTriple(entityId: bookshelfId, attributeId: ZenecaTestData.bookshelvesBooksAttrId, targetId: book2Id, timestamp: 0)

        // Resolve bookshelf with BOTH users (reverse) and books (forward)
        let bookshelf: ZenecaBookshelf? = store.get(id: bookshelfId, attrsStore: attrsStore)
        XCTAssertNotNil(bookshelf)
        XCTAssertEqual(bookshelf?.name, "Short Stories")

        // Verify users (reverse link)
        XCTAssertNotNil(bookshelf?.users)
        XCTAssertEqual(bookshelf?.users?.count, 1)
        XCTAssertEqual(bookshelf?.users?.first?.handle, "alex")

        // Verify books (forward link)
        XCTAssertNotNil(bookshelf?.books)
        XCTAssertEqual(bookshelf?.books?.count, 2)
        let bookTitles = bookshelf?.books?.map { $0.title }.sorted()
        XCTAssertEqual(bookTitles, ["Aesop's Fables", "Stories of Your Life"])
    }

    // MARK: - Test 6: Query forward references work (instaql.test.ts lines 565-586)

    /// Tests querying by forward link ID.
    func testForwardReferenceById() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create user with bookshelf
        let userId = UUID().uuidString
        store.addStringTriple(entityId: userId, attributeId: ZenecaTestData.usersHandleAttrId, value: "stopa", timestamp: 0)

        let bookshelfId = UUID().uuidString
        store.addStringTriple(entityId: bookshelfId, attributeId: ZenecaTestData.bookshelvesNameAttrId, value: "Favorites", timestamp: 0)
        store.addRefTriple(entityId: userId, attributeId: ZenecaTestData.usersBooksshelvesAttrId, targetId: bookshelfId, timestamp: 0)

        // Verify we can find the user through the bookshelf link
        let user: ZenecaUser? = store.get(id: userId, attrsStore: attrsStore)
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.handle, "stopa")
        XCTAssertEqual(user?.bookshelves?.first?.id, bookshelfId)
    }

    // MARK: - Test 7: Query reverse references work (instaql.test.ts lines 588-617)

    /// Tests querying by reverse link ID.
    func testReverseReferenceById() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create user
        let userId = UUID().uuidString
        store.addStringTriple(entityId: userId, attributeId: ZenecaTestData.usersHandleAttrId, value: "stopa", timestamp: 0)

        // Create multiple bookshelves linked to user
        var bookshelfIds: [String] = []
        for name in ["Shelf A", "Shelf B", "Shelf C"] {
            let shelfId = UUID().uuidString
            bookshelfIds.append(shelfId)
            store.addStringTriple(entityId: shelfId, attributeId: ZenecaTestData.bookshelvesNameAttrId, value: name, timestamp: 0)
            store.addRefTriple(entityId: userId, attributeId: ZenecaTestData.usersBooksshelvesAttrId, targetId: shelfId, timestamp: 0)
        }

        // Query from bookshelf side - verify reverse link finds user
        for shelfId in bookshelfIds {
            let shelf: ZenecaBookshelf? = store.get(id: shelfId, attrsStore: attrsStore)
            XCTAssertNotNil(shelf)
            XCTAssertNotNil(shelf?.users, "Reverse link should resolve")
            XCTAssertEqual(shelf?.users?.count, 1)
            XCTAssertEqual(shelf?.users?.first?.id, userId)
            XCTAssertEqual(shelf?.users?.first?.handle, "stopa")
        }
    }

    // MARK: - Test 8: Missing etype (instaql.test.ts lines 512-514)

    /// Tests behavior when querying for a non-existent entity type.
    func testMissingEntityType() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Try to get an entity that doesn't exist
        let nonExistent: ZenecaUser? = store.get(id: "non-existent-id", attrsStore: attrsStore)
        XCTAssertNil(nonExistent, "Non-existent entity should return nil")
    }

    // MARK: - Test 9: Missing inner etype (instaql.test.ts lines 516-527)

    /// Tests behavior when a linked entity type doesn't have any data.
    func testMissingInnerEntityType() throws {
        let attrsStore = try ZenecaTestData.createAttrsStore()
        let store = InstantDB.TripleStore()

        // Create user without any bookshelves
        let userId = UUID().uuidString
        store.addStringTriple(entityId: userId, attributeId: ZenecaTestData.usersHandleAttrId, value: "joe", timestamp: 0)

        // Resolve user - bookshelves should be empty/nil, not an error
        let user: ZenecaUser? = store.get(id: userId, attrsStore: attrsStore)
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.handle, "joe")

        // Bookshelves link exists but has no targets - should be nil or empty array
        XCTAssertTrue(
            user?.bookshelves == nil || user?.bookshelves?.isEmpty == true,
            "Missing inner entities should result in nil or empty array"
        )
    }
}
