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
  
  /// Creates an EntityKey for the specified namespace.
  ///
  /// - Parameters:
  ///   - namespace: The InstantDB namespace (entity type name)
  ///   - orderByField: Optional field to order by
  ///   - orderDirection: Optional order direction
  ///   - limitCount: Optional limit on results
  public init(
    namespace: String,
    orderByField: String? = nil,
    orderDirection: EntityKeyOrderDirection? = nil,
    limitCount: Int? = nil
  ) {
    self.namespace = namespace
    self.orderByField = orderByField
    self.orderDirection = orderDirection
    self.limitCount = limitCount
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
    // Extract field name from keyPath
    // This uses a simple approach - in production, consider using Mirror or codegen
    let keyPathString = String(describing: keyPath)
    // KeyPath string format is like \Entity.fieldName
    if let lastComponent = keyPathString.split(separator: ".").last {
      copy.orderByField = String(lastComponent)
    }
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
}

// MARK: - Order Direction

/// The order direction for EntityKey queries.
public enum EntityKeyOrderDirection: String, Sendable, Hashable {
  /// Ascending order (smallest to largest, oldest to newest)
  case asc
  
  /// Descending order (largest to smallest, newest to oldest)
  case desc
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
    return SharingInstantSync.CollectionConfiguration(
      namespace: key.namespace,
      orderBy: orderBy
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
    return SharingInstantQuery.Configuration(
      namespace: key.namespace,
      orderBy: orderBy,
      limit: key.limitCount
    )
  }
}

