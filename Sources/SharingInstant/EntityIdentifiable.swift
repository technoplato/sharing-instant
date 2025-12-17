import Foundation
import InstantDB

/// A type that can be read/written from InstantDB via SharingInstant.
///
/// This protocol combines `InstantEntity` (which provides the namespace) with
/// `Identifiable` (which provides the entity ID). Your entity types should conform
/// to this protocol to work with `@Shared(.instantSync(...))`.
///
/// ## Example
///
/// ```swift
/// struct Todo: Codable, EntityIdentifiable, Sendable {
///   static var namespace: String { "todos" }
///   
///   var id: String
///   var title: String
///   var done: Bool
///   var createdAt: Date
/// }
/// ```
///
/// The `id` property is used as the entity ID in InstantDB's triple store.
/// It should be a stable, unique identifier (typically a UUID string).
///
/// The `namespace` property defines which InstantDB namespace this entity belongs to.
public protocol EntityIdentifiable: InstantEntity, Identifiable where ID == String {
  /// The unique identifier for this entity in InstantDB.
  ///
  /// This is used as the entity ID in the triple store and should be stable across
  /// the lifetime of the entity. Typically this is a UUID string.
  var id: String { get }
}

