import Foundation
import InstantDB

@testable import SharingInstant

// MARK: - Zeneca Test Domain Entities
// Mirrors TypeScript: instant/client/packages/core/__tests__/src/data/zeneca/
//
// The "zeneca" test data represents a books/bookshelves/users domain used
// extensively in the TypeScript SDK tests. These Swift structs allow us to
// port those tests and verify link resolution parity.

/// A user in the zeneca test domain.
/// Links: users -> bookshelves (forward, many)
struct ZenecaUser: Codable, Sendable, Equatable {
    var id: String
    var handle: String
    var email: String?
    var fullName: String?
    var createdAt: String?

    // Forward link: users -> bookshelves (cardinality: many)
    var bookshelves: [ZenecaBookshelf]?
}

/// A bookshelf in the zeneca test domain.
/// Links:
/// - bookshelves -> books (forward, many)
/// - bookshelves -> users (reverse from users.bookshelves)
struct ZenecaBookshelf: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var desc: String?
    var order: Int?

    // Forward link: bookshelves -> books (cardinality: many)
    var books: [ZenecaBook]?

    // Reverse link: from users.bookshelves
    var users: [ZenecaUser]?
}

/// A book in the zeneca test domain.
/// Links:
/// - books -> bookshelves (reverse from bookshelves.books)
/// - books -> prequel (forward, one, cascade delete)
/// - books -> sequels (reverse from prequel)
/// - books -> next (forward, many, cascade delete reverse)
/// - books -> previous (reverse from next)
///
/// NOTE: Using `final class` instead of `struct` because books have self-referential
/// links (prequel, sequels, next, previous). Swift value types cannot contain themselves.
final class ZenecaBook: Codable, @unchecked Sendable, Equatable {
    var id: String
    var title: String
    var description: String?
    var pageCount: Int?
    var isbn13: String?
    var thumbnail: String?

    // Reverse link: from bookshelves.books
    var bookshelves: [ZenecaBookshelf]?

    // Forward link: books -> prequel (cardinality: one, on-delete: cascade)
    var prequel: ZenecaBook?

    // Reverse link: from prequel (books that have this book as prequel)
    var sequels: [ZenecaBook]?

    // Forward link: books -> next (cardinality: many, on-delete-reverse: cascade)
    var next: [ZenecaBook]?

    // Reverse link: from next (singular because books.next has unique: true)
    var previous: ZenecaBook?

    init(id: String, title: String, description: String? = nil, pageCount: Int? = nil,
         isbn13: String? = nil, thumbnail: String? = nil, bookshelves: [ZenecaBookshelf]? = nil,
         prequel: ZenecaBook? = nil, sequels: [ZenecaBook]? = nil,
         next: [ZenecaBook]? = nil, previous: ZenecaBook? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.pageCount = pageCount
        self.isbn13 = isbn13
        self.thumbnail = thumbnail
        self.bookshelves = bookshelves
        self.prequel = prequel
        self.sequels = sequels
        self.next = next
        self.previous = previous
    }

    static func == (lhs: ZenecaBook, rhs: ZenecaBook) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }
}

// MARK: - Simple Test Entities for IncludedLinks Tests

/// A simple post entity for testing includedLinks filtering.
/// Uses the same structure as existing TripleStoreReverseLinkResolutionTests.
struct TestPost: Codable, Sendable, Equatable {
    var id: String
    var content: String
    var createdAt: Double?

    // Reverse link: from profiles.posts
    var author: TestProfile?
}

/// A simple profile entity for testing includedLinks filtering.
struct TestProfile: Codable, Sendable, Equatable {
    var id: String
    var handle: String
    var displayName: String?
    var createdAt: Double?

    // Forward link: profiles -> posts (cardinality: many)
    var posts: [TestPost]?
}

// MARK: - Games Entity for Deep Merge Tests

/// A game entity with nested JSON state for testing deep merge operations.
struct ZenecaGame: Codable, Sendable, Equatable {
    var id: String
    var state: GameState?

    struct GameState: Codable, Sendable, Equatable {
        var score: Int?
        var level: Int?
        var playerStats: PlayerStats?
        var inventory: [String]?
        var locations: [String?]?

        struct PlayerStats: Codable, Sendable, Equatable {
            var health: Int?
            var mana: Int?
            var stamina: Int?
            var ambitions: Ambitions?

            struct Ambitions: Codable, Sendable, Equatable {
                var win: Bool?
                var acquireWisdom: Bool?
                var find: [String]?
            }
        }
    }
}

// MARK: - Fake Users and Todos for Recursive Link Tests

/// A fake user for testing recursive links where entities share the same ID.
struct FakeUser: Codable, Sendable, Equatable {
    var id: String
    var email: String?

    // Reverse link: from todos.createdBy
    var todos: [FakeTodo]?
}

/// A todo for testing recursive links where entities share the same ID.
struct FakeTodo: Codable, Sendable, Equatable {
    var id: String
    var title: String?
    var completed: Bool?

    // Forward link: todos -> createdBy (cardinality: one, on-delete: cascade)
    var createdBy: FakeUser?
}
