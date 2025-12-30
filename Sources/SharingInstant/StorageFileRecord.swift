import Foundation
import InstantDB

// MARK: - StorageFileRecord

/// Minimal `$files` entity model used by SharingInstant for storage queries.
///
/// The server augments `$files` query results with a `url` field (derived from location-id)
/// that can be used directly for rendering/serving.
public struct StorageFileRecord: Codable, EntityIdentifiable, Sendable, Equatable {
  public static var namespace: String { "$files" }

  public var id: String
  public var path: String
  public var url: String?
  public var contentType: String?
  public var contentDisposition: String?

  enum CodingKeys: String, CodingKey {
    case id
    case path
    case url
    case contentType = "content-type"
    case contentDisposition = "content-disposition"
  }

  public init(
    id: String,
    path: String,
    url: String? = nil,
    contentType: String? = nil,
    contentDisposition: String? = nil
  ) {
    self.id = id
    self.path = path
    self.url = url
    self.contentType = contentType
    self.contentDisposition = contentDisposition
  }
}

