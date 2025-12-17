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
  public struct Configuration<Value: Codable & Sendable>: Sendable {
    /// The InstantDB namespace (entity type) to query.
    public let namespace: String
    
    /// Optional ordering for the results.
    public let orderBy: OrderBy?
    
    /// Optional limit on the number of results.
    public let limit: Int?
    
    /// Optional animation to use when updating the UI.
    #if canImport(SwiftUI)
    public let animation: Animation?
    #endif
    
    /// Optional value to use during testing.
    public let testingValue: [Value]?
    
    #if canImport(SwiftUI)
    /// Creates a new query configuration.
    ///
    /// - Parameters:
    ///   - namespace: The InstantDB namespace (entity type) to query.
    ///   - orderBy: Optional ordering for the results.
    ///   - limit: Optional limit on the number of results.
    ///   - animation: Optional animation to use when updating the UI.
    ///   - testingValue: Optional value to use during testing.
    public init(
      namespace: String,
      orderBy: OrderBy? = nil,
      limit: Int? = nil,
      animation: Animation? = nil,
      testingValue: [Value]? = nil
    ) {
      self.namespace = namespace
      self.orderBy = orderBy
      self.limit = limit
      self.animation = animation
      self.testingValue = testingValue
    }
    #else
    /// Creates a new query configuration.
    ///
    /// - Parameters:
    ///   - namespace: The InstantDB namespace (entity type) to query.
    ///   - orderBy: Optional ordering for the results.
    ///   - limit: Optional limit on the number of results.
    ///   - testingValue: Optional value to use during testing.
    public init(
      namespace: String,
      orderBy: OrderBy? = nil,
      limit: Int? = nil,
      testingValue: [Value]? = nil
    ) {
      self.namespace = namespace
      self.orderBy = orderBy
      self.limit = limit
      self.testingValue = testingValue
    }
    #endif
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

