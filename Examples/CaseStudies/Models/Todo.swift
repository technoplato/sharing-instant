import Foundation
import SharingInstant

/// A todo item that can be synced with InstantDB.
struct Todo: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "todos" }
  
  var id: String
  var title: String
  var done: Bool
  var createdAt: Date
  
  init(
    id: String = UUID().uuidString,
    title: String,
    done: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.done = done
    self.createdAt = createdAt
  }
}

/// A fact item for demonstrating read-only queries.
struct Fact: Codable, EntityIdentifiable, Sendable, Equatable {
  static var namespace: String { "facts" }
  
  var id: String
  var text: String
  var count: Int
  
  init(id: String = UUID().uuidString, text: String, count: Int = 0) {
    self.id = id
    self.text = text
    self.count = count
  }
}

