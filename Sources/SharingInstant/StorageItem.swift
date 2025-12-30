import Foundation

// MARK: - StorageItem

/// A reactive snapshot of a single storage file.
///
/// Use ``SharedReaderKey/storageItem(_:)`` to access this from SwiftUI without managing bespoke
/// per-view state.
public struct StorageItem: Identifiable, Sendable, Equatable {
  public let ref: StorageRef
  public let status: StorageStatus

  /// The `$files` entity id, when known.
  ///
  /// ## Why This Exists
  /// InstantDB models files as entities in the special `$files` namespace. Linking a file to
  /// another entity uses the `$files` id, not the path. JavaScript clients return this id from
  /// `uploadFile`, so we surface it here for parity without forcing callers to run a separate
  /// query just to link.
  public let fileID: String?

  /// A server-provided URL (via `$files.url`) that can be used to render or download the file.
  ///
  /// - Note: This may be `nil` while an upload is in-flight, before the `$files` subscription
  ///   refreshes, or when permissions do not allow viewing `$files`.
  public let url: URL?

  /// A best-effort local preview for immediate rendering while uploads are in flight.
  public let localPreview: StorageLocalPreview?

  public var id: String { ref.id }

  public init(
    ref: StorageRef,
    status: StorageStatus,
    fileID: String?,
    url: URL?,
    localPreview: StorageLocalPreview?
  ) {
    self.ref = ref
    self.status = status
    self.fileID = fileID
    self.url = url
    self.localPreview = localPreview
  }
}

// MARK: - StorageStatus

public enum StorageStatus: Sendable, Equatable {
  case idle
  case queued
  case uploading(progress: Double?)
  case uploaded
  case deleting
  case deleted
  case failed(StorageFailure)

  public var isUploading: Bool {
    if case .uploading = self { return true }
    return false
  }

  public var isUploaded: Bool {
    if case .uploaded = self { return true }
    return false
  }

  public var isDeleting: Bool {
    if case .deleting = self { return true }
    return false
  }

  public var isDeleted: Bool {
    if case .deleted = self { return true }
    return false
  }

  public var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }

  public var failure: StorageFailure? {
    if case .failed(let failure) = self { return failure }
    return nil
  }
}

// MARK: - StorageFailure

/// A lightweight, user-presentable failure description.
///
/// We intentionally avoid storing `Error` values in shared state because most errors are not
/// `Sendable`/`Equatable`, and because views should be able to render failure information without
/// holding onto transient error objects.
public struct StorageFailure: Sendable, Equatable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

// MARK: - StorageLocalPreview

public struct StorageLocalPreview: Sendable, Equatable {
  public let fileURL: URL
  public let kind: StorageKind
  public let contentType: String?
  public let byteCount: Int64

  public init(
    fileURL: URL,
    kind: StorageKind,
    contentType: String?,
    byteCount: Int64
  ) {
    self.fileURL = fileURL
    self.kind = kind
    self.contentType = contentType
    self.byteCount = byteCount
  }
}
