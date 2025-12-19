// Models/Todo.swift
//
// ⚠️ NOTE: This file is DEPRECATED
//
// The `Todo` type is now auto-generated in Sources/Generated/Entities.swift.
// This file is kept temporarily for reference but the demos should use the
// generated type instead.
//
// Key difference: Generated Todo uses `createdAt: Double` (Unix timestamp)
// while this version used `createdAt: Date`.
//
// TODO: Delete this file once all demos are updated to use the generated Todo.

import Foundation
import SharingInstant

// MARK: - Local Todo (DEPRECATED - use generated Todo from Entities.swift)

// The generated Todo in Sources/Generated/Entities.swift is:
//
// public struct Todo: EntityIdentifiable, Codable, Sendable {
//   public static var namespace: String { "todos" }
//   public var id: String
//   public var createdAt: Double  // Unix timestamp, not Date!
//   public var done: Bool
//   public var title: String
// }

/// A fact item for demonstrating read-only queries.
public struct Fact: Codable, EntityIdentifiable, Sendable, Equatable {
  public static var namespace: String { "facts" }
  
  public var id: String
  public var text: String
  public var count: Int
  
  public init(id: String = UUID().uuidString, text: String, count: Int = 0) {
    self.id = id
    self.text = text
    self.count = count
  }
}
