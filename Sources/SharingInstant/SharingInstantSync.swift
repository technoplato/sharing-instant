import Foundation
import InstantDB

#if canImport(SwiftUI)
  import SwiftUI
#endif

/// Configuration types for InstantDB sync operations.
///
/// Use these types to configure how data is synchronized with InstantDB.
public enum SharingInstantSync {
  
  /// Configuration for syncing a collection of entities.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(
  ///   .instantSync(
  ///     configuration: .init(
  ///       namespace: "todos",
  ///       orderBy: .desc("createdAt"),
  ///       animation: .default
  ///     )
  ///   )
  /// )
  /// private var todos: IdentifiedArrayOf<Todo> = []
  /// ```
  public struct CollectionConfiguration<Value: Codable & EntityIdentifiable & Sendable>: Sendable {
    /// The InstantDB namespace (entity type) to sync.
    public let namespace: String
    
    /// Optional ordering for the results.
    public let orderBy: OrderBy?
    
    /// Optional animation to use when updating the UI.
    #if canImport(SwiftUI)
    public let animation: Animation?
    #endif
    
    /// Optional value to use during testing.
    public let testingValue: [Value]?
    
    #if canImport(SwiftUI)
    /// Creates a new collection configuration.
    ///
    /// - Parameters:
    ///   - namespace: The InstantDB namespace (entity type) to sync.
    ///   - orderBy: Optional ordering for the results.
    ///   - animation: Optional animation to use when updating the UI.
    ///   - testingValue: Optional value to use during testing.
    public init(
      namespace: String,
      orderBy: OrderBy? = nil,
      animation: Animation? = nil,
      testingValue: [Value]? = nil
    ) {
      self.namespace = namespace
      self.orderBy = orderBy
      self.animation = animation
      self.testingValue = testingValue
    }
    #else
    /// Creates a new collection configuration.
    ///
    /// - Parameters:
    ///   - namespace: The InstantDB namespace (entity type) to sync.
    ///   - orderBy: Optional ordering for the results.
    ///   - testingValue: Optional value to use during testing.
    public init(
      namespace: String,
      orderBy: OrderBy? = nil,
      testingValue: [Value]? = nil
    ) {
      self.namespace = namespace
      self.orderBy = orderBy
      self.testingValue = testingValue
    }
    #endif
  }
  
  /// Configuration for syncing a single entity document.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(
  ///   .instantSync(
  ///     configuration: .init(
  ///       namespace: "settings",
  ///       entityId: "user-settings"
  ///     )
  ///   )
  /// )
  /// private var settings: Settings = Settings.default
  /// ```
  public struct DocumentConfiguration<Value: Codable & Sendable>: Sendable {
    /// The InstantDB namespace (entity type).
    public let namespace: String
    
    /// The specific entity ID to sync.
    public let entityId: String
    
    /// Optional animation to use when updating the UI.
    #if canImport(SwiftUI)
    public let animation: Animation?
    #endif
    
    /// Optional value to use during testing.
    public let testingValue: Value?
    
    #if canImport(SwiftUI)
    /// Creates a new document configuration.
    ///
    /// - Parameters:
    ///   - namespace: The InstantDB namespace (entity type).
    ///   - entityId: The specific entity ID to sync.
    ///   - animation: Optional animation to use when updating the UI.
    ///   - testingValue: Optional value to use during testing.
    public init(
      namespace: String,
      entityId: String,
      animation: Animation? = nil,
      testingValue: Value? = nil
    ) {
      self.namespace = namespace
      self.entityId = entityId
      self.animation = animation
      self.testingValue = testingValue
    }
    #else
    /// Creates a new document configuration.
    ///
    /// - Parameters:
    ///   - namespace: The InstantDB namespace (entity type).
    ///   - entityId: The specific entity ID to sync.
    ///   - testingValue: Optional value to use during testing.
    public init(
      namespace: String,
      entityId: String,
      testingValue: Value? = nil
    ) {
      self.namespace = namespace
      self.entityId = entityId
      self.testingValue = testingValue
    }
    #endif
  }
  
  /// A protocol for custom sync requests.
  ///
  /// Conform to this protocol to define custom sync behavior:
  ///
  /// ```swift
  /// struct ActiveTodos: SharingInstantSync.KeyCollectionRequest {
  ///   typealias Value = Todo
  ///   let configuration: SharingInstantSync.CollectionConfiguration<Value>? = .init(
  ///     namespace: "todos",
  ///     orderBy: .asc("createdAt")
  ///   )
  /// }
  /// ```
  public protocol KeyCollectionRequest<Value>: Sendable {
    associatedtype Value: Codable & EntityIdentifiable & Sendable
    var configuration: CollectionConfiguration<Value>? { get }
  }
  
  /// A protocol for custom document sync requests.
  public protocol KeyDocumentRequest<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    var configuration: DocumentConfiguration<Value>? { get }
  }
}

/// Ordering direction for query results.
public struct OrderBy: Sendable, Equatable {
  /// The field to order by.
  public let field: String
  
  /// Whether to order in descending order.
  public let isDescending: Bool
  
  /// Creates an ascending order.
  ///
  /// - Parameter field: The field to order by.
  /// - Returns: An ascending order configuration.
  public static func asc(_ field: String) -> OrderBy {
    OrderBy(field: field, isDescending: false)
  }
  
  /// Creates a descending order.
  ///
  /// - Parameter field: The field to order by.
  /// - Returns: A descending order configuration.
  public static func desc(_ field: String) -> OrderBy {
    OrderBy(field: field, isDescending: true)
  }
}

