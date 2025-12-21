import Foundation
import InstantDB

#if canImport(SwiftUI)
  import SwiftUI
#endif

/// Configuration types for InstantDB query operations.
///
/// Use these types to configure read-only queries with InstantDB.
public enum SharingInstantQuery {
  
  /// Configuration for querying a collection of entities.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @SharedReader(
  ///   .instantQuery(
  ///     configuration: .init(
  ///       namespace: "facts",
  ///       orderBy: .desc("count"),
  ///       animation: .default
  ///     )
  ///   )
  /// )
  /// private var facts: IdentifiedArrayOf<Fact> = []
  /// ```
  public struct Configuration<Value: Codable & Sendable>: @unchecked Sendable {
    /// The InstantDB namespace (entity type) to query.
    public let namespace: String
    
    /// Optional ordering for the results.
    public let orderBy: OrderBy?
    
    /// Optional limit on the number of results.
    public let limit: Int?
    
    /// Optional where clause for filtering results.
    /// Dictionary format: `["field": value]` or `["field": ["$operator": value]]`
    public let whereClause: [String: Any]?
    
    /// Links to include (legacy)
    public let includedLinks: Set<String>
    
    /// Recursively included links
    public let linkTree: [EntityQueryNode]
    
    /// Optional animation to use when updating the UI.
    #if canImport(SwiftUI)
    public let animation: Animation?
    #endif
    
    /// Optional value to use during testing.
    public let testingValue: [Value]?
    
    // Sendable conformance helper
    private let _whereClauseHash: Int?
    
    #if canImport(SwiftUI)
    /// Creates a new query configuration.
    public init(
      namespace: String,
      orderBy: OrderBy? = nil,
      limit: Int? = nil,
      whereClause: [String: Any]? = nil,
      includedLinks: Set<String> = [],
      linkTree: [EntityQueryNode] = [],
      animation: Animation? = nil,
      testingValue: [Value]? = nil
    ) {
      self.namespace = namespace
      self.orderBy = orderBy
      self.limit = limit
      self.whereClause = whereClause
      self.includedLinks = includedLinks
      self.linkTree = linkTree
      self._whereClauseHash = whereClause.map { Self.hashWhereClause($0) }
      self.animation = animation
      self.testingValue = testingValue
    }
    #else
    /// Creates a new query configuration.
    public init(
      namespace: String,
      orderBy: OrderBy? = nil,
      limit: Int? = nil,
      whereClause: [String: Any]? = nil,
      includedLinks: Set<String> = [],
      linkTree: [EntityQueryNode] = [],
      testingValue: [Value]? = nil
    ) {
      self.namespace = namespace
      self.orderBy = orderBy
      self.limit = limit
      self.whereClause = whereClause
      self.includedLinks = includedLinks
      self.linkTree = linkTree
      self._whereClauseHash = whereClause.map { Self.hashWhereClause($0) }
      self.testingValue = testingValue
    }
    #endif
    
    private static func hashWhereClause(_ clause: [String: Any]) -> Int {
      var hasher = Hasher()
      for key in clause.keys.sorted() {
        hasher.combine(key)
        hasher.combine(String(describing: clause[key]))
      }
      return hasher.finalize()
    }
  }
  
  /// A protocol for custom query requests.
  ///
  /// Conform to this protocol to define custom query behavior:
  ///
  /// ```swift
  /// struct TopFacts: SharingInstantQuery.KeyRequest {
  ///   typealias Value = Fact
  ///   let configuration: SharingInstantQuery.Configuration<Value>? = .init(
  ///     namespace: "facts",
  ///     orderBy: .desc("count"),
  ///     limit: 10
  ///   )
  /// }
  /// ```
  public protocol KeyRequest<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    var configuration: Configuration<Value>? { get }
  }
}



