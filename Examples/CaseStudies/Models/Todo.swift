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
@preconcurrency import SharingInstant

// MARK: - Todo Entity

/// A todo item that can be synced with InstantDB.
///
/// Uses `createdAt: Double` (Unix timestamp) to match InstantDB's storage format.
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
  
  // Explicit nonisolated Codable
  nonisolated public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.createdAt = try container.decode(Double.self, forKey: .createdAt)
    self.done = try container.decode(Bool.self, forKey: .done)
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

// MARK: - Schema Extension for Entities

// These are defined in a nonisolated context to avoid @MainActor inference
nonisolated(unsafe) let _todoKey = EntityKey<Todo>(namespace: "todos")
nonisolated(unsafe) let _boardKey = EntityKey<Board>(namespace: "boards")
nonisolated(unsafe) let _factKey = EntityKey<Fact>(namespace: "facts")

public extension Schema {
  /// todos entity - bidirectional sync
  static var todos: EntityKey<Todo> { _todoKey }
  
  /// boards entity - bidirectional sync
  static var boards: EntityKey<Board> { _boardKey }
  
  /// facts entity - bidirectional sync
  static var facts: EntityKey<Fact> { _factKey }
}
