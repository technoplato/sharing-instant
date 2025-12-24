import Foundation
import InstantDB

/// A unique identifier for a shared key request.
///
/// This is used to deduplicate shared references that point to the same InstantDB query.
///
/// ## Why This Exists
/// `@Shared` and `@SharedReader` use the key's `id` to decide whether two references
/// should share the same underlying subscription and cached value.
///
/// For InstantDB queries, the full query shape matters. If we only key by `namespace`
/// (and maybe `orderBy`), then distinct queries like:
/// - `todos` (all)
/// - `todos where done == false` (active)
/// - `todos where done == true` (completed)
///
/// can accidentally collide. That leads to confusing behavior where:
/// - Filters appear to “not work”
/// - Updates appear to “not propagate” because the view is reading from the wrong subscription
///
/// This type therefore incorporates the query configuration fields that impact results
/// (where clauses, limits, and link inclusion) into the identifier.
public struct UniqueRequestKeyID: Hashable, Sendable {
  private let appID: String
  private let namespace: String
  private let entityId: String?
  private let orderField: String?
  private let orderDescending: Bool?
  private let limit: Int?
  private let whereClauseJSON: Data?
  private let includedLinks: [String]
  private let linkTree: [EntityQueryNode]
  
  init(
    appID: String,
    namespace: String,
    entityId: String? = nil,
    orderBy: OrderBy? = nil,
    limit: Int? = nil,
    whereClause: [String: Any]? = nil,
    includedLinks: Set<String> = [],
    linkTree: [EntityQueryNode] = []
  ) {
    self.appID = appID
    self.namespace = namespace
    self.entityId = entityId
    self.orderField = orderBy?.field
    self.orderDescending = orderBy?.isDescending
    self.limit = limit
    self.whereClauseJSON = whereClause.flatMap { Self.canonicalJSONData($0) }
    self.includedLinks = includedLinks.sorted()
    self.linkTree = linkTree
  }

  private static func canonicalJSONData(_ dict: [String: Any]) -> Data? {
    let canonical = canonicalize(dict)
    guard JSONSerialization.isValidJSONObject(canonical) else { return nil }
    return try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
  }

  private static func canonicalize(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
      var result: [String: Any] = [:]
      for key in dict.keys.sorted() {
        result[key] = canonicalize(dict[key] as Any)
      }
      return result
    }

    if let array = value as? [Any] {
      return array.map { canonicalize($0) }
    }

    if let date = value as? Date {
      return date.timeIntervalSince1970 * 1_000
    }

    return value
  }
}
