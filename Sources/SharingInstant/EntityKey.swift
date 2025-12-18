// EntityKey.swift
// SharingInstant
//
// A type-safe key for syncing entity collections with InstantDB.
// This enables the @Shared(Schema.todos) syntax.

import Dependencies
import Dispatch
import IdentifiedCollections
import InstantDB
import Sharing

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - EntityKey

/// A type-safe key for syncing an entity collection with InstantDB.
///
/// `EntityKey` enables zero-configuration sync with type safety:
///
/// ```swift
/// // Define your schema (usually generated from instant.schema.ts)
/// enum Schema {
///   static let todos = EntityKey<Todo>(namespace: "todos")
///   static let users = EntityKey<User>(namespace: "users")
/// }
///
/// // Use in SwiftUI views
/// @Shared(Schema.todos)
/// private var todos: IdentifiedArrayOf<Todo> = []
///
/// // With ordering
/// @Shared(Schema.todos.orderBy(\.createdAt, .desc))
/// private var todos: IdentifiedArrayOf<Todo> = []
/// ```
///
/// ## Query Modifiers
///
/// Chain modifiers to customize the query:
///
/// ```swift
/// Schema.todos
///   .orderBy(\.createdAt, .desc)  // Type-safe ordering
///   .limit(10)                     // Limit results
/// ```
///
/// ## Generated from Schema
///
/// Typically, `EntityKey` instances are generated from your `instant.schema.ts`
/// file using the `instant-schema` CLI tool or SPM build plugin.
public struct EntityKey<Entity: EntityIdentifiable & Sendable>: Hashable, Sendable {
  /// The InstantDB namespace (entity type name)
  public let namespace: String
  
  /// The field to order by (optional)
  public var orderByField: String?
  
  /// The order direction (optional)
  public var orderDirection: EntityKeyOrderDirection?
  
  /// Maximum number of results (optional)
  public var limitCount: Int?
  
  /// Where clause predicates (stored as field -> predicate dictionary)
  public var whereClauses: [String: EntityKeyPredicate]
  
  /// Links to include in query results (InstaQL-style nested queries)
  public var includedLinks: Set<String>
  
  /// Creates an EntityKey for the specified namespace.
  ///
  /// - Parameters:
  ///   - namespace: The InstantDB namespace (entity type name)
  ///   - orderByField: Optional field to order by
  ///   - orderDirection: Optional order direction
  ///   - limitCount: Optional limit on results
  ///   - whereClauses: Optional where clauses
  ///   - includedLinks: Optional links to include in results
  public init(
    namespace: String,
    orderByField: String? = nil,
    orderDirection: EntityKeyOrderDirection? = nil,
    limitCount: Int? = nil,
    whereClauses: [String: EntityKeyPredicate] = [:],
    includedLinks: Set<String> = []
  ) {
    self.namespace = namespace
    self.orderByField = orderByField
    self.orderDirection = orderDirection
    self.limitCount = limitCount
    self.whereClauses = whereClauses
    self.includedLinks = includedLinks
  }
  
  // MARK: - Query Modifiers
  
  /// Order results by a field using a type-safe KeyPath.
  ///
  /// ```swift
  /// Schema.todos.orderBy(\.createdAt, .desc)
  /// ```
  ///
  /// - Parameters:
  ///   - keyPath: KeyPath to the field to order by
  ///   - direction: The order direction (.asc or .desc)
  /// - Returns: A new EntityKey with the ordering applied
  public func orderBy<V>(
    _ keyPath: KeyPath<Entity, V>,
    _ direction: EntityKeyOrderDirection
  ) -> EntityKey<Entity> {
    var copy = self
    copy.orderByField = extractFieldName(from: keyPath)
    copy.orderDirection = direction
    return copy
  }
  
  /// Order results by a field name string.
  ///
  /// ```swift
  /// Schema.todos.orderBy("createdAt", .desc)
  /// ```
  ///
  /// - Parameters:
  ///   - field: The field name to order by
  ///   - direction: The order direction (.asc or .desc)
  /// - Returns: A new EntityKey with the ordering applied
  public func orderBy(
    _ field: String,
    _ direction: EntityKeyOrderDirection
  ) -> EntityKey<Entity> {
    var copy = self
    copy.orderByField = field
    copy.orderDirection = direction
    return copy
  }
  
  /// Limit the number of results.
  ///
  /// ```swift
  /// Schema.todos.limit(10)
  /// ```
  ///
  /// - Parameter count: Maximum number of results to return
  /// - Returns: A new EntityKey with the limit applied
  public func limit(_ count: Int) -> EntityKey<Entity> {
    var copy = self
    copy.limitCount = count
    return copy
  }
  
  // MARK: - Where Clauses
  
  /// Filter results where a field equals a value.
  ///
  /// ```swift
  /// Schema.todos.where(\.done, .equals(false))
  /// Schema.todos.where(\.priority, .greaterThan(5))
  /// ```
  ///
  /// - Parameters:
  ///   - keyPath: KeyPath to the field to filter on
  ///   - predicate: The predicate to apply
  /// - Returns: A new EntityKey with the filter applied
  public func `where`<V: Hashable & Sendable>(
    _ keyPath: KeyPath<Entity, V>,
    _ predicate: EntityKeyPredicate
  ) -> EntityKey<Entity> {
    var copy = self
    let fieldName = extractFieldName(from: keyPath)
    copy.whereClauses[fieldName] = predicate
    return copy
  }
  
  /// Filter results where a field equals a value (string-based).
  ///
  /// ```swift
  /// Schema.todos.where("done", .equals(false))
  /// ```
  ///
  /// - Parameters:
  ///   - field: The field name to filter on
  ///   - predicate: The predicate to apply
  /// - Returns: A new EntityKey with the filter applied
  public func `where`(
    _ field: String,
    _ predicate: EntityKeyPredicate
  ) -> EntityKey<Entity> {
    var copy = self
    copy.whereClauses[field] = predicate
    return copy
  }
  
  // MARK: - Link Inclusion
  
  /// Include a related entity in the query results.
  ///
  /// ```swift
  /// // Include owner in todo results
  /// Schema.todos.with(\.owner)
  ///
  /// // Include multiple relations
  /// Schema.todos.with(\.owner).with(\.tags)
  /// ```
  ///
  /// - Parameter keyPath: KeyPath to the link field
  /// - Returns: A new EntityKey with the link inclusion
  public func with<V>(_ keyPath: KeyPath<Entity, V>) -> EntityKey<Entity> {
    var copy = self
    let fieldName = extractFieldName(from: keyPath)
    copy.includedLinks.insert(fieldName)
    return copy
  }
  
  /// Include a related entity by field name.
  ///
  /// - Parameter linkName: The name of the link field to include
  /// - Returns: A new EntityKey with the link inclusion
  public func with(_ linkName: String) -> EntityKey<Entity> {
    var copy = self
    copy.includedLinks.insert(linkName)
    return copy
  }
  
  // MARK: - Helpers
  
  private func extractFieldName<V>(from keyPath: KeyPath<Entity, V>) -> String {
    let keyPathString = String(describing: keyPath)
    if let lastComponent = keyPathString.split(separator: ".").last {
      return String(lastComponent)
    }
    return keyPathString
  }
}

// MARK: - Order Direction

/// The order direction for EntityKey queries.
public enum EntityKeyOrderDirection: String, Sendable, Hashable {
  /// Ascending order (smallest to largest, oldest to newest)
  case asc
  
  /// Descending order (largest to smallest, newest to oldest)
  case desc
}

// MARK: - Predicate

/// A predicate for filtering EntityKey queries.
///
/// Predicates support common comparison operations:
///
/// ```swift
/// .equals(value)       // field == value
/// .notEquals(value)    // field != value
/// .greaterThan(value)  // field > value
/// .greaterOrEqual(value) // field >= value
/// .lessThan(value)     // field < value
/// .lessOrEqual(value)  // field <= value
/// .isIn([values])      // field in [values]
/// .like(pattern)       // SQL LIKE pattern (case-sensitive)
/// .ilike(pattern)      // SQL LIKE pattern (case-insensitive)
/// .contains(text)      // Contains substring (case-insensitive)
/// .startsWith(text)    // Starts with prefix (case-insensitive)
/// .endsWith(text)      // Ends with suffix (case-insensitive)
/// ```
public enum EntityKeyPredicate: Hashable, Sendable {
  /// Equals comparison
  case equals(AnyHashableSendable)
  
  /// Not equals comparison
  case notEquals(AnyHashableSendable)
  
  /// Greater than comparison
  case greaterThan(AnyHashableSendable)
  
  /// Greater than or equal comparison
  case greaterOrEqual(AnyHashableSendable)
  
  /// Less than comparison
  case lessThan(AnyHashableSendable)
  
  /// Less than or equal comparison
  case lessOrEqual(AnyHashableSendable)
  
  /// In set comparison
  case isIn([AnyHashableSendable])
  
  /// Pattern matching (case-sensitive, SQL LIKE syntax: % for wildcard)
  case like(String)
  
  /// Pattern matching (case-insensitive, SQL LIKE syntax: % for wildcard)
  case ilike(String)
  
  // MARK: - Convenience Initializers
  
  /// Creates an equals predicate.
  public static func eq<V: Hashable & Sendable>(_ value: V) -> EntityKeyPredicate {
    .equals(AnyHashableSendable(value))
  }
  
  /// Creates a not-equals predicate.
  public static func neq<V: Hashable & Sendable>(_ value: V) -> EntityKeyPredicate {
    .notEquals(AnyHashableSendable(value))
  }
  
  /// Creates a greater-than predicate.
  public static func gt<V: Hashable & Sendable>(_ value: V) -> EntityKeyPredicate {
    .greaterThan(AnyHashableSendable(value))
  }
  
  /// Creates a greater-or-equal predicate.
  public static func gte<V: Hashable & Sendable>(_ value: V) -> EntityKeyPredicate {
    .greaterOrEqual(AnyHashableSendable(value))
  }
  
  /// Creates a less-than predicate.
  public static func lt<V: Hashable & Sendable>(_ value: V) -> EntityKeyPredicate {
    .lessThan(AnyHashableSendable(value))
  }
  
  /// Creates a less-or-equal predicate.
  public static func lte<V: Hashable & Sendable>(_ value: V) -> EntityKeyPredicate {
    .lessOrEqual(AnyHashableSendable(value))
  }
  
  /// Creates an in-set predicate.
  public static func `in`<V: Hashable & Sendable>(_ values: [V]) -> EntityKeyPredicate {
    .isIn(values.map { AnyHashableSendable($0) })
  }
  
  /// Creates a contains predicate (case-insensitive).
  /// Matches if the field contains the given substring.
  public static func contains(_ substring: String) -> EntityKeyPredicate {
    .ilike("%\(substring)%")
  }
  
  /// Creates a starts-with predicate (case-insensitive).
  /// Matches if the field starts with the given prefix.
  public static func startsWith(_ prefix: String) -> EntityKeyPredicate {
    .ilike("\(prefix)%")
  }
  
  /// Creates an ends-with predicate (case-insensitive).
  /// Matches if the field ends with the given suffix.
  public static func endsWith(_ suffix: String) -> EntityKeyPredicate {
    .ilike("%\(suffix)")
  }
  
  /// Convert to InstantDB where clause dictionary format
  func toWhereValue() -> Any {
    switch self {
    case .equals(let value):
      return value.base
    case .notEquals(let value):
      return ["$neq": value.base]
    case .greaterThan(let value):
      return ["$gt": value.base]
    case .greaterOrEqual(let value):
      return ["$gte": value.base]
    case .lessThan(let value):
      return ["$lt": value.base]
    case .lessOrEqual(let value):
      return ["$lte": value.base]
    case .isIn(let values):
      return ["$in": values.map { $0.base }]
    case .like(let pattern):
      return ["$like": pattern]
    case .ilike(let pattern):
      return ["$ilike": pattern]
    }
  }
}

/// Type-erased hashable sendable value for predicate storage.
public struct AnyHashableSendable: Hashable, Sendable {
  public let base: any Sendable
  private let _hashValue: Int
  private let _isEqual: @Sendable (Any) -> Bool
  
  public init<T: Hashable & Sendable>(_ value: T) {
    self.base = value
    self._hashValue = value.hashValue
    self._isEqual = { other in
      guard let other = other as? T else { return false }
      return value == other
    }
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(_hashValue)
  }
  
  public static func == (lhs: AnyHashableSendable, rhs: AnyHashableSendable) -> Bool {
    lhs._isEqual(rhs.base)
  }
}

// MARK: - SharedReaderKey Extension

extension SharedReaderKey {
  /// Create a bidirectional sync key from an EntityKey.
  ///
  /// This enables the `@Shared(Schema.todos)` syntax:
  ///
  /// ```swift
  /// @Shared(Schema.todos)
  /// private var todos: IdentifiedArrayOf<Todo> = []
  ///
  /// // With ordering
  /// @Shared(Schema.todos.orderBy(\.createdAt, .desc))
  /// private var todos: IdentifiedArrayOf<Todo> = []
  /// ```
  ///
  /// - Parameter key: The EntityKey defining the sync
  /// - Returns: A SharedKey for use with @Shared
  public static func instantSync<E: EntityIdentifiable & Sendable>(
    _ key: EntityKey<E>
  ) -> Self where Self == InstantSyncCollectionKey<IdentifiedArrayOf<E>>.Default {
    Self[
      InstantSyncCollectionKey(
        request: EntityKeyRequest(key: key),
        appID: nil
      ),
      default: []
    ]
  }
  
  /// Create a read-only query key from an EntityKey.
  ///
  /// This enables the `@SharedReader(Schema.todos)` syntax:
  ///
  /// ```swift
  /// @SharedReader(Schema.todos)
  /// private var todos: IdentifiedArrayOf<Todo> = []
  ///
  /// // With ordering and limit
  /// @SharedReader(Schema.todos.orderBy(\.createdAt, .desc).limit(10))
  /// private var todos: IdentifiedArrayOf<Todo> = []
  /// ```
  ///
  /// - Parameter key: The EntityKey defining the query
  /// - Returns: A SharedReaderKey for use with @SharedReader
  public static func instantQuery<E: EntityIdentifiable & Sendable>(
    _ key: EntityKey<E>
  ) -> Self where Self == InstantQueryKey<IdentifiedArrayOf<E>>.Default {
    Self[
      InstantQueryKey(
        request: EntityKeyQueryRequest(key: key),
        appID: nil
      ),
      default: []
    ]
  }
}

// MARK: - Internal Request Types

/// Internal request type that bridges EntityKey to the sync infrastructure.
struct EntityKeyRequest<E: EntityIdentifiable & Sendable>: SharingInstantSync.KeyCollectionRequest {
  typealias Value = E
  let key: EntityKey<E>
  
  var configuration: SharingInstantSync.CollectionConfiguration<E>? {
    var orderBy: OrderBy? = nil
    if let field = key.orderByField, let direction = key.orderDirection {
      orderBy = direction == .desc ? .desc(field) : .asc(field)
    }
    
    // Convert EntityKey where clauses to dictionary format
    var whereClause: [String: Any]? = nil
    if !key.whereClauses.isEmpty {
      var clause: [String: Any] = [:]
      for (field, predicate) in key.whereClauses {
        clause[field] = predicate.toWhereValue()
      }
      whereClause = clause
    }
    
    return SharingInstantSync.CollectionConfiguration(
      namespace: key.namespace,
      orderBy: orderBy,
      whereClause: whereClause
    )
  }
}

/// Internal request type that bridges EntityKey to the query infrastructure.
struct EntityKeyQueryRequest<E: EntityIdentifiable & Sendable>: SharingInstantQuery.KeyRequest {
  typealias Value = E
  let key: EntityKey<E>
  
  var configuration: SharingInstantQuery.Configuration<E>? {
    var orderBy: OrderBy? = nil
    if let field = key.orderByField, let direction = key.orderDirection {
      orderBy = direction == .desc ? .desc(field) : .asc(field)
    }
    
    // Convert EntityKey where clauses to dictionary format
    var whereClause: [String: Any]? = nil
    if !key.whereClauses.isEmpty {
      var clause: [String: Any] = [:]
      for (field, predicate) in key.whereClauses {
        clause[field] = predicate.toWhereValue()
      }
      whereClause = clause
    }
    
    return SharingInstantQuery.Configuration(
      namespace: key.namespace,
      orderBy: orderBy,
      limit: key.limitCount,
      whereClause: whereClause
    )
  }
}

