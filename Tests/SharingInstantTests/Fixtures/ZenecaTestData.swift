import Foundation
import InstantDB

@testable import SharingInstant

// MARK: - Zeneca Test Data Factory

/// Provides attribute definitions and test data matching the TypeScript SDK's "zeneca" dataset.
///
/// ## Upstream Source of Truth
///
/// The zeneca test data is the canonical dataset used for link resolution testing in InstantDB:
/// - **Attrs JSON**: `instant/client/packages/core/__tests__/src/data/zeneca/attrs.json`
/// - **GitHub**: https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/data/zeneca/attrs.json
/// - **Triples JSON**: `instant/client/packages/core/__tests__/src/data/zeneca/triples.json`
/// - **GitHub**: https://github.com/instantdb/instant/blob/main/client/packages/core/__tests__/src/data/zeneca/triples.json
///
/// ## Schema Overview
///
/// ```
/// users ←→ bookshelves ←→ books
///   │                        │
///   └─ handle, email, etc.   └─ prequel → books (cascade)
///                            └─ next → books (reverse cascade)
/// ```
///
/// ## Attribute ID Convention
///
/// Attribute IDs in this file match the UUIDs from `attrs.json` to ensure
/// test data is compatible with the TypeScript SDK's test expectations.
///
/// ## Quirks and Edge Cases
///
/// ### unique? Field (Clojure naming)
///
/// The server uses Clojure predicate naming (`unique?` with `?`), but Swift's Codable
/// maps this via `CodingKeys`. When creating attributes manually via JSON, use `"unique?"`:
/// ```swift
/// dict["unique?"] = true  // Correct
/// dict["unique"] = true   // WRONG - won't be decoded
/// ```
///
/// ### Reverse Cardinality
///
/// The `unique?` field encodes REVERSE cardinality, not forward:
/// - `unique? = true` → reverse link is singular (e.g., `posts.author: Profile?`)
/// - `unique? = false/nil` → reverse link is array (e.g., `bookshelves.users: [User]?`)

enum ZenecaTestData {

    // MARK: - Entity IDs from zeneca dataset

    // Users
    static let joeId = "ce942051-2d74-404a-9c7d-4aa3f2d54ae4"
    static let alexId = "ad45e100-777a-4de8-8978-aa13200a4824"
    static let stopaId = "a55a5231-5c4d-4033-b859-7790c45c22d5"
    static let nicolegfId = "0f3d67fc-8b37-4b03-ac47-29fec4edc4f7"

    // MARK: - Attribute IDs from attrs.json

    // Users attributes
    static let usersIdAttrId = "5a4f5a6d-ba83-4bf0-ae78-27a863300224"
    static let usersHandleAttrId = "6a089759-2a2f-4898-9bb8-a7bc9f6f791a"
    static let usersEmailAttrId = "20b65ea3-faad-4e80-863e-87468ff7792f"
    static let usersFullNameAttrId = "6aa0c9c1-24f3-469d-9f73-e7c2d058f16b"
    static let usersCreatedAtAttrId = "2ffdf0fc-1561-4fc5-96db-2210a41adfa6"
    static let usersBooksshelvesAttrId = "24749f9e-9308-4457-b298-c4827975d563"

    // Bookshelves attributes
    static let bookshelvesIdAttrId = "1fcc2b72-02be-405b-918c-8e441f75dcab"
    static let bookshelvesNameAttrId = "820a827c-5ddf-4452-8263-dac7e6a53e56"
    static let bookshelvesDescAttrId = "f6e940f7-75fd-4aaf-9790-e183174c2abd"
    static let bookshelvesOrderAttrId = "c030a0a6-82cf-455f-9ecd-88c43cd11a4a"
    static let bookshelvesBooksAttrId = "fb032e43-46c7-48dc-85d8-6ab517c9f1d4"

    // Books attributes
    static let booksIdAttrId = "6eebf15a-ed3c-4442-8869-a44a7c85a1be"
    static let booksTitleAttrId = "ed11294d-cd7d-4f3d-8918-4806c80b8a43"
    static let booksDescriptionAttrId = "275e5c3c-d565-4f5a-b832-4290cc6de915"
    static let booksPageCountAttrId = "d8b6b232-d081-412b-8a5e-1a43c0b2f7fc"
    static let booksIsbn13AttrId = "8f7805e4-6006-4450-b790-600bb382c765"
    static let booksThumbnailAttrId = "4edfae63-c83c-418b-9026-dacd13cdd6ac"
    static let bookPrequelAttrId = "ddf89ebc-71e9-4a9b-80f2-9c2380949661"
    static let bookNextAttrId = "f187a211-a2ef-48cc-8beb-e1abe01dedfe"

    // MARK: - AttrsStore Factory

    /// Creates an AttrsStore populated with all zeneca attributes.
    /// This matches the schema defined in attrs.json.
    static func createAttrsStore() throws -> AttrsStore {
        let store = AttrsStore()

        // ===== USERS =====

        // users.id (blob, one, unique, indexed)
        store.addAttr(try makeAttribute(
            id: usersIdAttrId,
            forwardIdentity: ["ce6155ef-e683-4084-bb5e-18757d30b79f", "users", "id"],
            reverseIdentity: ["8ec152fd-48de-471e-be4a-0853bd4143da", "users", "_id"],
            valueType: "blob",
            cardinality: "one",
            unique: true,
            indexed: true
        ))

        // users.handle (blob, one, unique, indexed)
        store.addAttr(try makeAttribute(
            id: usersHandleAttrId,
            forwardIdentity: ["5075336b-f433-4899-bea4-7180cacfd756", "users", "handle"],
            valueType: "blob",
            cardinality: "one",
            unique: true,
            indexed: true
        ))

        // users.email (blob, one, unique, indexed)
        store.addAttr(try makeAttribute(
            id: usersEmailAttrId,
            forwardIdentity: ["ee2c25e2-426c-4497-a8ef-f0cdae69f0ef", "users", "email"],
            valueType: "blob",
            cardinality: "one",
            unique: true,
            indexed: true
        ))

        // users.fullName (blob, one)
        store.addAttr(try makeAttribute(
            id: usersFullNameAttrId,
            forwardIdentity: ["74a38fb9-ff24-4c0e-9320-c271a04d8289", "users", "fullName"],
            valueType: "blob",
            cardinality: "one"
        ))

        // users.createdAt (blob, one)
        store.addAttr(try makeAttribute(
            id: usersCreatedAtAttrId,
            forwardIdentity: ["c3ad6196-f879-4d40-b2fd-40308ee9f857", "users", "createdAt"],
            valueType: "blob",
            cardinality: "one"
        ))

        // users.bookshelves (ref, many) -> bookshelves.users
        store.addAttr(try makeAttribute(
            id: usersBooksshelvesAttrId,
            forwardIdentity: ["f7c11599-b402-4b9e-844c-649be5a1bd40", "users", "bookshelves"],
            reverseIdentity: ["8e9d568f-8d26-4aa6-99f5-05740231760a", "bookshelves", "users"],
            valueType: "ref",
            cardinality: "many"
        ))

        // ===== BOOKSHELVES =====

        // bookshelves.id (blob, one, unique, indexed)
        store.addAttr(try makeAttribute(
            id: bookshelvesIdAttrId,
            forwardIdentity: ["a09d83c4-c587-41fd-b660-bd02a2269dfa", "bookshelves", "id"],
            reverseIdentity: ["fa2c2332-106d-4e76-b8a2-c4ce9b45b2e9", "bookshelves", "_id"],
            valueType: "blob",
            cardinality: "one",
            unique: true,
            indexed: true
        ))

        // bookshelves.name (blob, one)
        store.addAttr(try makeAttribute(
            id: bookshelvesNameAttrId,
            forwardIdentity: ["213381a7-b960-4e6e-99a5-58bf486ee006", "bookshelves", "name"],
            valueType: "blob",
            cardinality: "one"
        ))

        // bookshelves.desc (blob, one)
        store.addAttr(try makeAttribute(
            id: bookshelvesDescAttrId,
            forwardIdentity: ["deae96e9-7b44-4fbd-9f35-cffd3893c2b3", "bookshelves", "desc"],
            valueType: "blob",
            cardinality: "one"
        ))

        // bookshelves.order (blob, one)
        store.addAttr(try makeAttribute(
            id: bookshelvesOrderAttrId,
            forwardIdentity: ["57aa2446-33be-4494-8b76-e75629cdb1ad", "bookshelves", "order"],
            valueType: "blob",
            cardinality: "one"
        ))

        // bookshelves.books (ref, many) -> books.bookshelves
        store.addAttr(try makeAttribute(
            id: bookshelvesBooksAttrId,
            forwardIdentity: ["7e408400-5f7d-4682-86f3-07536e1803df", "bookshelves", "books"],
            reverseIdentity: ["af245099-e97b-4e49-a827-fa2e8fdcfbb6", "books", "bookshelves"],
            valueType: "ref",
            cardinality: "many"
        ))

        // ===== BOOKS =====

        // books.id (blob, one, unique, indexed)
        store.addAttr(try makeAttribute(
            id: booksIdAttrId,
            forwardIdentity: ["4ceb593d-8953-4441-81c4-21cc521ef6dd", "books", "id"],
            reverseIdentity: ["c6a7e114-6d74-4d25-bbcd-9fe00b16f1a5", "books", "_id"],
            valueType: "blob",
            cardinality: "one",
            unique: true,
            indexed: true
        ))

        // books.title (blob, one)
        store.addAttr(try makeAttribute(
            id: booksTitleAttrId,
            forwardIdentity: ["c1177d1f-d2af-469b-ade3-7132c9d6b06e", "books", "title"],
            valueType: "blob",
            cardinality: "one"
        ))

        // books.description (blob, one)
        store.addAttr(try makeAttribute(
            id: booksDescriptionAttrId,
            forwardIdentity: ["227d4bd6-aa9b-4004-ab7d-1b8033191c93", "books", "description"],
            valueType: "blob",
            cardinality: "one"
        ))

        // books.pageCount (blob, one)
        store.addAttr(try makeAttribute(
            id: booksPageCountAttrId,
            forwardIdentity: ["d6a60c9d-ec87-4951-a05b-6ae27d230a55", "books", "pageCount"],
            valueType: "blob",
            cardinality: "one"
        ))

        // books.isbn13 (blob, one)
        store.addAttr(try makeAttribute(
            id: booksIsbn13AttrId,
            forwardIdentity: ["4e7fb690-0281-4019-ae65-ddeb4d954507", "books", "isbn13"],
            valueType: "blob",
            cardinality: "one"
        ))

        // books.thumbnail (blob, one)
        store.addAttr(try makeAttribute(
            id: booksThumbnailAttrId,
            forwardIdentity: ["e8790a4d-48ef-4f0f-9986-622403591a2e", "books", "thumbnail"],
            valueType: "blob",
            cardinality: "one"
        ))

        // books.prequel (ref, one, on-delete: cascade) -> books.sequels
        store.addAttr(try makeAttribute(
            id: bookPrequelAttrId,
            forwardIdentity: ["caec81f9-5f14-4376-9842-fc0e6143c3ce", "books", "prequel"],
            reverseIdentity: ["e0b307a2-0679-4490-ba58-e9a5a17e4901", "books", "sequels"],
            valueType: "ref",
            cardinality: "one",
            onDelete: "cascade"
        ))

        // books.next (ref, many, unique, on-delete-reverse: cascade) -> books.previous
        store.addAttr(try makeAttribute(
            id: bookNextAttrId,
            forwardIdentity: ["e2f733eb-65ba-4a70-aa66-96aa0a51cdaa", "books", "next"],
            reverseIdentity: ["67e8fe91-22bd-4d94-b44b-6c8f6bbc9a2a", "books", "previous"],
            valueType: "ref",
            cardinality: "many",
            unique: true,
            onDeleteReverse: "cascade"
        ))

        return store
    }

    // MARK: - Test Data Loaders

    /// Loads a minimal zeneca dataset into the store.
    /// Creates 4 users (joe, alex, stopa, nicolegf) with selected bookshelves and books.
    static func loadMinimalDataset(into store: InstantDB.TripleStore, attrsStore: AttrsStore) {
        let timestamp: Int64 = 0

        // Create Joe
        store.addStringTriple(entityId: joeId, attributeId: usersHandleAttrId, value: "joe", timestamp: timestamp)
        store.addStringTriple(entityId: joeId, attributeId: usersEmailAttrId, value: "joe@instantdb.com", timestamp: timestamp)
        store.addStringTriple(entityId: joeId, attributeId: usersFullNameAttrId, value: "Joe Averbukh", timestamp: timestamp)

        // Create Alex
        store.addStringTriple(entityId: alexId, attributeId: usersHandleAttrId, value: "alex", timestamp: timestamp)
        store.addStringTriple(entityId: alexId, attributeId: usersEmailAttrId, value: "alex@instantdb.com", timestamp: timestamp)
        store.addStringTriple(entityId: alexId, attributeId: usersFullNameAttrId, value: "Alex", timestamp: timestamp)

        // Create Stopa
        store.addStringTriple(entityId: stopaId, attributeId: usersHandleAttrId, value: "stopa", timestamp: timestamp)
        store.addStringTriple(entityId: stopaId, attributeId: usersEmailAttrId, value: "stopa@instantdb.com", timestamp: timestamp)
        store.addStringTriple(entityId: stopaId, attributeId: usersFullNameAttrId, value: "Stepan Parunashvili", timestamp: timestamp)

        // Create Nicole
        store.addStringTriple(entityId: nicolegfId, attributeId: usersHandleAttrId, value: "nicolegf", timestamp: timestamp)
        store.addStringTriple(entityId: nicolegfId, attributeId: usersEmailAttrId, value: "nicole@instantdb.com", timestamp: timestamp)
        store.addStringTriple(entityId: nicolegfId, attributeId: usersFullNameAttrId, value: "Nicole", timestamp: timestamp)
    }

    /// Creates a user with bookshelves containing books for link resolution testing.
    /// Returns the IDs of created entities.
    static func createUserWithBookshelves(
        in store: InstantDB.TripleStore,
        attrsStore: AttrsStore,
        userId: String = UUID().uuidString,
        handle: String,
        bookshelfName: String,
        bookTitles: [String]
    ) -> (userId: String, bookshelfId: String, bookIds: [String]) {
        let timestamp: Int64 = 0
        let bookshelfId = UUID().uuidString
        var bookIds: [String] = []

        // Create user
        store.addStringTriple(entityId: userId, attributeId: usersHandleAttrId, value: handle, timestamp: timestamp)

        // Create bookshelf
        store.addStringTriple(entityId: bookshelfId, attributeId: bookshelvesNameAttrId, value: bookshelfName, timestamp: timestamp)

        // Link user -> bookshelf
        store.addRefTriple(entityId: userId, attributeId: usersBooksshelvesAttrId, targetId: bookshelfId, timestamp: timestamp)

        // Create books and link to bookshelf
        for title in bookTitles {
            let bookId = UUID().uuidString
            bookIds.append(bookId)
            store.addStringTriple(entityId: bookId, attributeId: booksTitleAttrId, value: title, timestamp: timestamp)
            store.addRefTriple(entityId: bookshelfId, attributeId: bookshelvesBooksAttrId, targetId: bookId, timestamp: timestamp)
        }

        return (userId, bookshelfId, bookIds)
    }
}

// MARK: - Profile/Post Test Data for IncludedLinks Tests

enum ProfilePostTestData {
    // Attribute IDs for profiles/posts domain
    static let profilesDisplayNameAttrId = "attr-profiles-displayName"
    static let profilesHandleAttrId = "attr-profiles-handle"
    static let profilesCreatedAtAttrId = "attr-profiles-createdAt"
    static let postsContentAttrId = "attr-posts-content"
    static let postsCreatedAtAttrId = "attr-posts-createdAt"
    static let profilesPostsAttrId = "attr-profiles-posts"

    /// Creates an AttrsStore for profile/post testing (same as TripleStoreReverseLinkResolutionTests).
    static func createAttrsStore() throws -> AttrsStore {
        let store = AttrsStore()

        // profiles.displayName
        store.addAttr(try makeAttribute(
            id: profilesDisplayNameAttrId,
            forwardIdentity: ["ident-profiles-displayName", "profiles", "displayName"],
            valueType: "blob",
            cardinality: "one"
        ))

        // profiles.handle
        store.addAttr(try makeAttribute(
            id: profilesHandleAttrId,
            forwardIdentity: ["ident-profiles-handle", "profiles", "handle"],
            valueType: "blob",
            cardinality: "one"
        ))

        // profiles.createdAt
        store.addAttr(try makeAttribute(
            id: profilesCreatedAtAttrId,
            forwardIdentity: ["ident-profiles-createdAt", "profiles", "createdAt"],
            valueType: "blob",
            cardinality: "one"
        ))

        // posts.content
        store.addAttr(try makeAttribute(
            id: postsContentAttrId,
            forwardIdentity: ["ident-posts-content", "posts", "content"],
            valueType: "blob",
            cardinality: "one"
        ))

        // posts.createdAt
        store.addAttr(try makeAttribute(
            id: postsCreatedAtAttrId,
            forwardIdentity: ["ident-posts-createdAt", "posts", "createdAt"],
            valueType: "blob",
            cardinality: "one"
        ))

        // profiles.posts (ref, many) -> posts.author
        // `unique: true` means the reverse ("author") is singular - each post has ONE author
        store.addAttr(try makeAttribute(
            id: profilesPostsAttrId,
            forwardIdentity: ["ident-profiles-posts", "profiles", "posts"],
            reverseIdentity: ["ident-posts-author", "posts", "author"],
            valueType: "ref",
            cardinality: "many",
            unique: true  // Reverse is singular (posts.author -> one profile)
        ))

        return store
    }

    /// Creates a profile with posts for link resolution testing.
    static func createProfileWithPosts(
        in store: InstantDB.TripleStore,
        profileId: String = UUID().uuidString,
        handle: String,
        displayName: String,
        postContents: [String]
    ) -> (profileId: String, postIds: [String]) {
        let timestamp: Int64 = 0
        var postIds: [String] = []

        // Create profile
        store.addStringTriple(entityId: profileId, attributeId: profilesHandleAttrId, value: handle, timestamp: timestamp)
        store.addStringTriple(entityId: profileId, attributeId: profilesDisplayNameAttrId, value: displayName, timestamp: timestamp)

        // Create posts and link to profile
        for content in postContents {
            let postId = UUID().uuidString
            postIds.append(postId)
            store.addStringTriple(entityId: postId, attributeId: postsContentAttrId, value: content, timestamp: timestamp)
            // Link profile -> post (forward direction)
            store.addRefTriple(entityId: profileId, attributeId: profilesPostsAttrId, targetId: postId, timestamp: timestamp)
        }

        return (profileId, postIds)
    }
}
