// Models/Todo.swift
//
// ⚠️ TEMPORARY MANUAL DEFINITIONS
//
// These types should eventually be AUTO-GENERATED from `instant.schema.ts` by
// the InstantSchemaCodegen tool. For now, they're defined manually for CaseStudies.
//
// These types use explicit `nonisolated` conformances for all protocol requirements
// to satisfy Swift 6 strict concurrency requirements.

import Foundation
import InstantDB
@preconcurrency import SharingInstant

// MARK: - Todo Entity

/// A todo item that can be synced with InstantDB.
///
/// Uses `createdAt: Double` (Unix timestamp) to match InstantDB's storage format.
/// The decoder handles InstantDB's number/bool encoding quirks for the `done` field.
public struct Todo: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var createdAt: Double
  public var done: Bool
  public var title: String
  
  public init(
    id: String = UUID().uuidString,
    createdAt: Double = Date().timeIntervalSince1970,
    done: Bool = false,
    title: String
  ) {
    self.id = id
    self.createdAt = createdAt
    self.done = done
    self.title = title
  }
  
  // Explicit nonisolated Equatable
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.createdAt == rhs.createdAt && lhs.done == rhs.done && lhs.title == rhs.title
  }
  
  // Explicit nonisolated Codable with flexible bool decoding
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.createdAt = try container.decode(Double.self, forKey: .createdAt)
    // Use FlexibleBool to handle both Bool and Int from InstantDB
    let flexibleDone = try container.decode(FlexibleBool.self, forKey: .done)
    self.done = flexibleDone.wrappedValue
    self.title = try container.decode(String.self, forKey: .title)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(done, forKey: .done)
    try container.encode(title, forKey: .title)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, createdAt, done, title
  }
}

nonisolated extension Todo: EntityIdentifiable {
  public static var namespace: String { "todos" }
}

// MARK: - Board Entity (for TileGameDemo)

/// A game board that can be synced with InstantDB.
public struct Board: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var state: [String: String]
  
  public init(id: String = UUID().uuidString, state: [String: String] = [:]) {
    self.id = id
    self.state = state
  }
  
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.state == rhs.state
  }
  
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.state = try container.decode([String: String].self, forKey: .state)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(state, forKey: .state)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, state
  }
}

nonisolated extension Board: EntityIdentifiable {
  public static var namespace: String { "boards" }
}

// MARK: - Fact Entity

/// A fact item for demonstrating read-only queries.
public struct Fact: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var text: String
  public var count: Int
  
  public init(id: String = UUID().uuidString, text: String, count: Int = 0) {
    self.id = id
    self.text = text
    self.count = count
  }
  
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.text == rhs.text && lhs.count == rhs.count
  }
  
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.text = try container.decode(String.self, forKey: .text)
    self.count = try container.decode(Int.self, forKey: .count)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(text, forKey: .text)
    try container.encode(count, forKey: .count)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, text, count
  }
}

nonisolated extension Fact: EntityIdentifiable {
  public static var namespace: String { "facts" }
}

// MARK: - Profile Entity (for MicroblogDemo)

/// A user profile for the microblog demo.
public struct Profile: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var displayName: String
  public var handle: String
  public var bio: String?
  public var avatarUrl: String?
  public var createdAt: Double
  
  // Link: posts (populated when queried with .with(\.posts))
  public var posts: [Post]?
  
  public init(
    id: String = UUID().uuidString,
    displayName: String,
    handle: String,
    bio: String? = nil,
    avatarUrl: String? = nil,
    createdAt: Double = Date().timeIntervalSince1970,
    posts: [Post]? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.handle = handle
    self.bio = bio
    self.avatarUrl = avatarUrl
    self.createdAt = createdAt
    self.posts = posts
  }
  
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.handle == rhs.handle
  }
  
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.displayName = try container.decode(String.self, forKey: .displayName)
    self.handle = try container.decode(String.self, forKey: .handle)
    self.bio = try container.decodeIfPresent(String.self, forKey: .bio)
    self.avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
    self.createdAt = try container.decode(Double.self, forKey: .createdAt)
    self.posts = try container.decodeIfPresent([Post].self, forKey: .posts)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(handle, forKey: .handle)
    try container.encodeIfPresent(bio, forKey: .bio)
    try container.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(posts, forKey: .posts)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, displayName, handle, bio, avatarUrl, createdAt, posts
  }
}

nonisolated extension Profile: EntityIdentifiable {
  public static var namespace: String { "profiles" }
}

// MARK: - Comment Entity (for Recursive and MicroblogDemo)

public struct Comment: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var text: String
  public var createdAt: Double
  
  // Link: author (populated when queried with .with(\.author))
  public var author: Profile?
  // Link: post (populated when queried with .with(\.post))
  public var post: Post?
  
  public init(
    id: String = UUID().uuidString,
    text: String,
    createdAt: Double = Date().timeIntervalSince1970,
    author: Profile? = nil,
    post: Post? = nil
  ) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.author = author
    self.post = post
  }
  
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.text == rhs.text && lhs.createdAt == rhs.createdAt
  }
  
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.text = try container.decode(String.self, forKey: .text)
    self.createdAt = try container.decode(Double.self, forKey: .createdAt)
    self.author = try container.decodeIfPresent(Profile.self, forKey: .author)
    self.post = try container.decodeIfPresent(Post.self, forKey: .post)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(text, forKey: .text)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(author, forKey: .author)
    try container.encodeIfPresent(post, forKey: .post)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, text, createdAt, author, post
  }
}

nonisolated extension Comment: EntityIdentifiable {
  public static var namespace: String { "comments" }
}

// MARK: - Post Entity (for MicroblogDemo)

/// A post/tweet for the microblog demo.
/// The decoder handles InstantDB's number/bool encoding quirks for `likesCount`.
public struct Post: Sendable, Identifiable, Codable, Equatable {
  public var id: String
  public var content: String
  public var imageUrl: String?
  public var createdAt: Double
  public var likesCount: Double
  
  // Link: author (populated when queried with .with(\.author))
  public var author: Profile?
  // Link: replies (populated when queried with .with(\.replies))
  public var replies: [Comment]?
  
  // Explicitly add replies to init, equality, codable would be lengthy here.
  // Instead, let's just make `replies` var mutable and optional.
  // Wait, I need to update init/Codable to support it or the demo won't work (data conversion).
  
  public init(
    id: String = UUID().uuidString,
    content: String,
    imageUrl: String? = nil,
    createdAt: Double = Date().timeIntervalSince1970,
    likesCount: Double = 0,
    author: Profile? = nil,
    replies: [Comment]? = nil
  ) {
    self.id = id
    self.content = content
    self.imageUrl = imageUrl
    self.createdAt = createdAt
    self.likesCount = likesCount
    self.author = author
    self.replies = replies
  }
  
  nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.content == rhs.content && lhs.createdAt == rhs.createdAt && lhs.replies == rhs.replies
  }
  
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.content = try container.decode(String.self, forKey: .content)
    self.imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
    self.createdAt = try container.decode(Double.self, forKey: .createdAt)
    // Use FlexibleDouble to handle both Double and Bool from InstantDB
    let flexibleLikesCount = try container.decode(FlexibleDouble.self, forKey: .likesCount)
    self.likesCount = flexibleLikesCount.wrappedValue
    self.author = try container.decodeIfPresent(Profile.self, forKey: .author)
    self.replies = try container.decodeIfPresent([Comment].self, forKey: .replies)
  }
  
  nonisolated public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(imageUrl, forKey: .imageUrl)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(likesCount, forKey: .likesCount)
    try container.encodeIfPresent(author, forKey: .author)
    try container.encodeIfPresent(replies, forKey: .replies)
  }
  
  private enum CodingKeys: String, CodingKey {
    case id, content, imageUrl, createdAt, likesCount, author, replies
  }
}

nonisolated extension Post: EntityIdentifiable {
  public static var namespace: String { "posts" }
}

// MARK: - Schema Extension for Entities

// These are defined in a nonisolated context to avoid @MainActor inference
let _todoKey = EntityKey<Todo>(namespace: "todos")
let _boardKey = EntityKey<Board>(namespace: "boards")
let _factKey = EntityKey<Fact>(namespace: "facts")
let _profileKey = EntityKey<Profile>(namespace: "profiles")
let _postKey = EntityKey<Post>(namespace: "posts")
let _commentKey = EntityKey<Comment>(namespace: "comments")

public extension Schema {
  /// todos entity - bidirectional sync
  static var todos: EntityKey<Todo> { _todoKey }
  
  /// boards entity - bidirectional sync
  static var boards: EntityKey<Board> { _boardKey }
  
  /// facts entity - bidirectional sync
  static var facts: EntityKey<Fact> { _factKey }
  
  /// profiles entity - bidirectional sync (for MicroblogDemo)
  static var profiles: EntityKey<Profile> { _profileKey }
  
  /// posts entity - bidirectional sync (for MicroblogDemo)
  static var posts: EntityKey<Post> { _postKey }
  
  /// comments entity - bidirectional sync (for RecursiveDemo)
  /// Note: We invoke .replies on Schema.posts, which links to Schema.comments
  static var comments: EntityKey<Comment> { _commentKey }
}
