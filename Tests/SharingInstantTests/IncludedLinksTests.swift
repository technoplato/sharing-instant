import InstantDB
import XCTest

@testable import SharingInstant

/// Tests for the `includedLinks` parameter on TripleStore.resolve() and get().
///
/// ## Purpose
///
/// The `includedLinks` parameter allows callers to specify which links should be resolved,
/// matching the TypeScript SDK's query-driven link resolution behavior. Without this parameter,
/// all links would be resolved recursively (up to maxDepth), which can cause:
/// - Excessive memory usage on deeply nested or circular relationships
/// - Performance issues when only specific links are needed
/// - Decode failures when entity types don't match expected nested structures
///
/// ## Upstream Source of Truth
///
/// This feature mirrors the TypeScript SDK's query-driven resolution:
/// - **InstaQL Resolution**: `instant/client/packages/core/src/instaql.ts`
/// - **GitHub**: https://github.com/instantdb/instant/blob/main/client/packages/core/src/instaql.ts
///
/// In the TypeScript SDK, link resolution is controlled by the query structure:
/// ```typescript
/// // Only resolves 'bookshelves' link, not 'posts' or other links
/// query(ctx, { users: { bookshelves: {} } })
/// ```
///
/// The Swift `includedLinks` parameter provides equivalent functionality:
/// ```swift
/// // Only resolves 'bookshelves' link
/// store.get(id: userId, attrsStore: attrsStore, includedLinks: ["bookshelves"])
/// ```
///
/// ## Key Implementation Details
///
/// ### Filtering Logic
///
/// When `includedLinks` is specified:
/// - `nil` → resolve ALL links (default, backward-compatible behavior)
/// - `[]` (empty set) → resolve NO links (only scalar attributes)
/// - `["posts", "author"]` → resolve only specified links
///
/// ### Recursive Behavior
///
/// The `includedLinks` set is passed through to recursive `resolve()` calls, ensuring
/// consistent filtering at all depth levels. This prevents accidentally resolving
/// deeply nested links that weren't explicitly requested.
///
/// See: `TripleStore+Extensions.swift` lines ~48-61 (forward links) and ~119-123 (reverse links)
final class IncludedLinksTests: XCTestCase {

    // MARK: - Test Setup

    private var attrsStore: AttrsStore!
    private var store: InstantDB.TripleStore!
    private var profileId: String!
    private var postId1: String!
    private var postId2: String!

    override func setUp() async throws {
        try await super.setUp()

        // Create profile/posts schema (same as TripleStoreReverseLinkResolutionTests)
        attrsStore = try ProfilePostTestData.createAttrsStore()
        store = InstantDB.TripleStore()

        // Create a profile with two posts
        let result = ProfilePostTestData.createProfileWithPosts(
            in: store,
            handle: "alice",
            displayName: "Alice",
            postContents: ["Hello world!", "Second post"]
        )
        profileId = result.profileId
        postId1 = result.postIds[0]
        postId2 = result.postIds[1]
    }

    // MARK: - Test 1: includedLinks filters forward links

    /// When `includedLinks` is specified, only those links should be resolved.
    /// Forward links not in `includedLinks` should NOT be resolved.
    func testIncludedLinksFiltersForwardLinks() throws {
        // Resolve profile WITH posts link
        let profileWithPosts: TestProfile? = store.get(
            id: profileId,
            attrsStore: attrsStore,
            includedLinks: ["posts"]
        )

        XCTAssertNotNil(profileWithPosts)
        XCTAssertEqual(profileWithPosts?.handle, "alice")
        XCTAssertNotNil(profileWithPosts?.posts, "posts link should be resolved when included")
        XCTAssertEqual(profileWithPosts?.posts?.count, 2)

        // Resolve profile WITHOUT posts link (empty includedLinks)
        let profileWithoutPosts: TestProfile? = store.get(
            id: profileId,
            attrsStore: attrsStore,
            includedLinks: []  // Empty set = resolve NO links
        )

        XCTAssertNotNil(profileWithoutPosts)
        XCTAssertEqual(profileWithoutPosts?.handle, "alice")
        XCTAssertNil(profileWithoutPosts?.posts, "posts link should NOT be resolved when not included")
    }

    // MARK: - Test 2: includedLinks filters reverse links

    /// Reverse links not in `includedLinks` should NOT be resolved.
    /// In the profile/posts schema, posts.author is a reverse link from profiles.posts.
    func testIncludedLinksFiltersReverseLinks() throws {
        // Resolve post WITH author link
        let postWithAuthor: TestPost? = store.get(
            id: postId1,
            attrsStore: attrsStore,
            includedLinks: ["author"]
        )

        XCTAssertNotNil(postWithAuthor)
        XCTAssertEqual(postWithAuthor?.content, "Hello world!")
        XCTAssertNotNil(postWithAuthor?.author, "author (reverse link) should be resolved when included")
        XCTAssertEqual(postWithAuthor?.author?.handle, "alice")

        // Resolve post WITHOUT author link
        let postWithoutAuthor: TestPost? = store.get(
            id: postId1,
            attrsStore: attrsStore,
            includedLinks: []  // Empty set = resolve NO links
        )

        XCTAssertNotNil(postWithoutAuthor)
        XCTAssertEqual(postWithoutAuthor?.content, "Hello world!")
        XCTAssertNil(postWithoutAuthor?.author, "author (reverse link) should NOT be resolved when not included")
    }

    // MARK: - Test 3: Empty includedLinks resolves no links

    /// When `includedLinks` is an empty set, NO links should be resolved.
    /// This prevents the default "resolve all links" behavior.
    func testEmptyIncludedLinksResolvesNoLinks() throws {
        // Resolve profile with empty includedLinks
        let profile: TestProfile? = store.get(
            id: profileId,
            attrsStore: attrsStore,
            includedLinks: []
        )

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.handle, "alice")
        XCTAssertEqual(profile?.displayName, "Alice")

        // No links should be resolved
        XCTAssertNil(profile?.posts, "posts should NOT be resolved with empty includedLinks")

        // Resolve post with empty includedLinks
        let post: TestPost? = store.get(
            id: postId1,
            attrsStore: attrsStore,
            includedLinks: []
        )

        XCTAssertNotNil(post)
        XCTAssertEqual(post?.content, "Hello world!")
        XCTAssertNil(post?.author, "author should NOT be resolved with empty includedLinks")
    }

    // MARK: - Test 4: nil includedLinks resolves all links (default behavior)

    /// When `includedLinks` is nil (not specified), ALL links should be resolved.
    /// This preserves backward compatibility with existing code.
    func testNilIncludedLinksResolvesAllLinks() throws {
        // Resolve profile with nil includedLinks (default)
        let profile: TestProfile? = store.get(
            id: profileId,
            attrsStore: attrsStore
            // includedLinks not specified = nil = resolve all
        )

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.handle, "alice")

        // All links should be resolved (existing default behavior)
        XCTAssertNotNil(profile?.posts, "posts should be resolved with nil includedLinks")
        XCTAssertEqual(profile?.posts?.count, 2)

        // Verify posts have their reverse link resolved too
        // (This may cause circular reference, but maxDepth should prevent infinite loop)
        let firstPost = profile?.posts?.first
        XCTAssertNotNil(firstPost?.author, "author should also resolve with nil includedLinks")
    }

    // MARK: - Test 5: includedLinks passes through recursively

    /// When resolving nested links, `includedLinks` should be passed through
    /// to recursive calls, limiting resolution at all levels.
    func testIncludedLinksPassesThroughRecursively() throws {
        // Create a deeper structure: profile -> posts -> (author back to profile)
        // When we resolve profile with only ["posts"], the posts should resolve
        // but the author on each post should NOT resolve (not in includedLinks)

        let profile: TestProfile? = store.get(
            id: profileId,
            attrsStore: attrsStore,
            includedLinks: ["posts"]  // Only resolve posts, not author
        )

        XCTAssertNotNil(profile)
        XCTAssertNotNil(profile?.posts)
        XCTAssertEqual(profile?.posts?.count, 2)

        // Check that posts were resolved
        // Note: Posts are not guaranteed to be in any particular order
        let postContents = profile?.posts?.map { $0.content }.sorted()
        XCTAssertEqual(postContents, ["Hello world!", "Second post"])

        // The author link on each post should NOT be resolved
        // because "author" is not in includedLinks
        for post in profile?.posts ?? [] {
            XCTAssertNil(
                post.author,
                "Nested 'author' link should NOT resolve when not in includedLinks"
            )
        }
    }

    // MARK: - Test 6: includedLinks with multiple link names

    /// Multiple link names can be specified in includedLinks.
    func testIncludedLinksWithMultipleLinkNames() throws {
        // For this test, we need an entity with multiple different link types
        // Let's use the Zeneca data with users -> bookshelves -> books

        let zenecaAttrs = try ZenecaTestData.createAttrsStore()
        let zenecaStore = InstantDB.TripleStore()

        // Create user with bookshelf containing books
        let result = ZenecaTestData.createUserWithBookshelves(
            in: zenecaStore,
            attrsStore: zenecaAttrs,
            handle: "testuser",
            bookshelfName: "My Shelf",
            bookTitles: ["Book 1", "Book 2"]
        )

        // Resolve user with only "bookshelves" in includedLinks
        let user: ZenecaUser? = zenecaStore.get(
            id: result.userId,
            attrsStore: zenecaAttrs,
            includedLinks: ["bookshelves"]
        )

        XCTAssertNotNil(user)
        XCTAssertEqual(user?.handle, "testuser")
        XCTAssertNotNil(user?.bookshelves)
        XCTAssertEqual(user?.bookshelves?.count, 1)

        // The bookshelf is resolved, but its books should NOT be
        // (because "books" is not in includedLinks)
        let shelf = user?.bookshelves?.first
        XCTAssertNotNil(shelf)
        XCTAssertEqual(shelf?.name, "My Shelf")

        // Books should not be resolved
        XCTAssertNil(
            shelf?.books,
            "Nested 'books' link should NOT resolve when not in includedLinks"
        )
    }

    // MARK: - Test 7: resolve() method also supports includedLinks

    /// The raw resolve() method should also support includedLinks.
    func testResolveMethodSupportsIncludedLinks() throws {
        // Use resolve() directly instead of get()
        let dict = store.resolve(
            id: profileId,
            attrsStore: attrsStore,
            includedLinks: []  // No links
        )

        XCTAssertEqual(dict["handle"] as? String, "alice")
        XCTAssertEqual(dict["displayName"] as? String, "Alice")

        // posts should NOT be in the dictionary
        XCTAssertNil(dict["posts"], "posts should not be in dict with empty includedLinks")
    }
}
