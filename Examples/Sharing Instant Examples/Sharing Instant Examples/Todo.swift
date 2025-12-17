//
//  Todo.swift
//  Sharing Instant Examples
//

import Foundation
import SharingInstant

/// A todo item that can be synced with InstantDB.
struct Todo: Codable, EntityIdentifiable, Sendable, Equatable {
  static let namespace: String = "todos"
  
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

