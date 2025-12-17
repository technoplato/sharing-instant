import Foundation
import InstantDB

/// A unique identifier for a shared key request.
///
/// This is used to deduplicate shared references that point to the same data.
public struct UniqueRequestKeyID: Hashable, Sendable {
  private let appID: String
  private let namespace: String
  private let entityId: String?
  private let orderField: String?
  private let orderDescending: Bool?
  
  init(appID: String, namespace: String, entityId: String? = nil, orderBy: OrderBy? = nil) {
    self.appID = appID
    self.namespace = namespace
    self.entityId = entityId
    self.orderField = orderBy?.field
    self.orderDescending = orderBy?.isDescending
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(appID)
    hasher.combine(namespace)
    hasher.combine(entityId)
    hasher.combine(orderField)
    hasher.combine(orderDescending)
  }
  
  public static func == (lhs: UniqueRequestKeyID, rhs: UniqueRequestKeyID) -> Bool {
    lhs.appID == rhs.appID &&
    lhs.namespace == rhs.namespace &&
    lhs.entityId == rhs.entityId &&
    lhs.orderField == rhs.orderField &&
    lhs.orderDescending == rhs.orderDescending
  }
}

