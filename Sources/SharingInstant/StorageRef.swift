import Foundation

// MARK: - StorageRef

/// A stable reference to a file stored in InstantDB.
///
/// `StorageRef` is intentionally lightweight and stable: it is safe to store in your own
/// app models (e.g. embed IDs in rich text, store a segment's attachments, etc.).
///
/// ## Design Goals
/// - **Stable identity**: the `path` is the identity, and does not change as the upload progresses.
/// - **Local-first rendering**: callers can optimistically render using a local preview while the
///   server catch-up happens via `$files`.
/// - **SwiftUI ergonomics**: pair a `StorageRef` with ``SharedReaderKey/storageItem(_:)`` to read
///   a reactive status (`uploading`, `failed`, `uploaded`) without bespoke per-view state.
public struct StorageRef: Identifiable, Codable, Hashable, Sendable, Equatable {
  /// The storage path. This is also the stable identity.
  public let path: String

  /// A best-effort classification of the file type for rendering and UX.
  public let kind: StorageKind

  /// Optional filename for display purposes (may differ from the final path component).
  public let displayName: String?

  public var id: String { path }

  public init(
    path: String,
    kind: StorageKind,
    displayName: String? = nil
  ) {
    self.path = path
    self.kind = kind
    self.displayName = displayName
  }
}

// MARK: - StorageKind

public enum StorageKind: String, Codable, Hashable, Sendable, Equatable {
  case image
  case video
  case text
  case binary

  public static func infer(path: String, contentType: String?) -> StorageKind {
    if let contentType = contentType?.lowercased() {
      if contentType.hasPrefix("image/") { return .image }
      if contentType.hasPrefix("video/") { return .video }
      if contentType.hasPrefix("text/") { return .text }
    }

    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    switch ext {
    case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp":
      return .image
    case "mov", "mp4", "m4v":
      return .video
    case "txt", "md", "json", "csv", "log":
      return .text
    default:
      return .binary
    }
  }
}
