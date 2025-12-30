import Foundation

// MARK: - StorageSharedState

/// Internal mutable state for storage mutations.
///
/// ## Why This Exists
/// The core InstantDB storage API is request/response. In SwiftUI, callers typically want:
/// - a stable identifier to render immediately,
/// - per-item upload/delete status,
/// - retry/cancel,
/// without each view building its own state machine.
///
/// This state is kept in a Sharing `@Shared` store so it can be accessed from anywhere using
/// `@SharedReader` keys like `.storageFeed(...)` and `.storageItem(...)`.
struct StorageSharedState: Sendable, Equatable {
  var entries: [String: StorageEntry] = [:]
}

struct StorageEntry: Sendable, Equatable {
  var createdAt: Date
  var ref: StorageRef
  var status: StorageStatus
  var localPreview: StorageLocalPreview?

  /// Enough information to retry an upload.
  ///
  /// This keeps views simple: the UI does not need to retain raw bytes or file URLs.
  var uploadSource: StorageUploadSource?

  /// Server-side `$files` id returned from upload.
  var remoteFileID: String?
}

struct StorageUploadSource: Sendable, Equatable {
  var fileURL: URL
  var contentType: String?
  var contentDisposition: String?
}
