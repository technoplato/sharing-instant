import Dependencies
import Foundation
import InstantDB
import Sharing

#if canImport(CryptoKit)
  import CryptoKit
#endif

#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - SharedReaderKey for Storage Client

extension SharedReaderKey where Self == InstantStorageClientKey.Default {
  /// A SharedReaderKey that exposes the storage client for the default app id.
  ///
  /// This is the mutation-style entry point used by the CaseStudies and recommended for apps:
  ///
  /// ```swift
  /// @SharedReader(.instantStorage) var storage
  ///
  /// let ref = storage.upload(image)
  /// ```
  public static var instantStorage: Self {
    Self[InstantStorageClientKey(appID: nil), default: InstantStorageClient(appID: nil)]
  }
}

public struct InstantStorageClientKey: SharedReaderKey {
  public typealias Value = InstantStorageClient

  let appID: String?

  public init(appID: String? = nil) {
    self.appID = appID
  }

  public var id: String {
    "storage-client-\(resolvedAppID)"
  }

  private var resolvedAppID: String {
    @Dependency(\.instantAppID) var defaultAppID
    return appID ?? defaultAppID
  }

  public func load(context: LoadContext<Value>, continuation: LoadContinuation<Value>) {
    continuation.resume(returning: InstantStorageClient(appID: appID))
  }

  public func subscribe(
    context: LoadContext<Value>,
    subscriber: SharedSubscriber<Value>
  ) -> SharedSubscription {
    subscriber.yield(InstantStorageClient(appID: appID))
    return SharedSubscription {}
  }
}

// MARK: - InstantStorageClient

/// A storage client that provides TanStack Query–style mutation ergonomics for SwiftUI.
///
/// ## Why This Exists
/// The core InstantDB storage API is `async` request/response. In SwiftUI, apps typically want:
/// - a stable reference (path) immediately for optimistic UI,
/// - per-item status (uploading/failed/retrying),
/// - simple retry/delete,
/// without each view maintaining bespoke state and task plumbing.
///
/// SharingInstant accomplishes this by:
/// - returning a ``StorageRef`` synchronously,
/// - storing upload/delete state in a Sharing `@Shared` store,
/// - exposing reactive projections via ``SharedReaderKey/storageItem(_:)`` and
///   ``SharedReaderKey/storageFeed(scope:)``.
public struct InstantStorageClient: Sendable {
  public let appID: String

  public init(appID: String? = nil) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
  }

  // MARK: - Upload (Data)

  /// Upload raw bytes to InstantDB storage.
  ///
  /// This method returns a stable ``StorageRef`` immediately and kicks off an upload in the
  /// background. Use ``SharedReaderKey/storageItem(_:)`` to observe status changes.
  @MainActor
  @discardableResult
  public func upload(
    data: Data,
    filename: String,
    contentType: String? = nil,
    contentDisposition: String? = "inline",
    folder: String = "uploads",
    scope: StorageFeedScope = .user,
    onSuccess: (@MainActor (StorageRef) -> Void)? = nil,
    onFailure: (@MainActor (StorageRef, any Error) -> Void)? = nil
  ) -> StorageRef {
    let resolvedContentType = contentType ?? Self.inferContentType(filename: filename)
    let kind = StorageKind.infer(path: filename, contentType: resolvedContentType)

    let sha = Self.sha256Hex(data)
    let ext = URL(fileURLWithPath: filename).pathExtension
    let fileComponent = ext.isEmpty ? sha : "\(sha).\(ext)"

    let path = buildPath(
      scope: scope,
      folder: folder,
      fileComponent: fileComponent
    )

    let ref = StorageRef(path: path, kind: kind, displayName: filename)
    let localURL = Self.writeToTemporaryDirectory(
      data: data,
      preferredFilename: fileComponent
    )

    upsertEntry(
      ref: ref,
      status: .uploading(progress: nil),
      localPreview: StorageLocalPreview(
        fileURL: localURL,
        kind: kind,
        contentType: resolvedContentType,
        byteCount: Int64(data.count)
      ),
      uploadSource: StorageUploadSource(
        fileURL: localURL,
        contentType: resolvedContentType,
        contentDisposition: contentDisposition
      )
    )

    startUploadTask(
      ref: ref,
      onSuccess: onSuccess,
      onFailure: onFailure
    )

    return ref
  }

  // MARK: - Upload (File URL)

  /// Upload a local file by URL.
  ///
  /// - Note: This copies the selected file into a temporary location so it can be retried without
  ///   relying on security-scoped bookmarks.
  @MainActor
  @discardableResult
  public func upload(
    fileURL: URL,
    contentType: String? = nil,
    contentDisposition: String? = "inline",
    folder: String = "uploads",
    scope: StorageFeedScope = .user,
    onSuccess: (@MainActor (StorageRef) -> Void)? = nil,
    onFailure: (@MainActor (StorageRef, any Error) -> Void)? = nil
  ) -> StorageRef {
    let needsAccess = fileURL.startAccessingSecurityScopedResource()
    defer {
      if needsAccess {
        fileURL.stopAccessingSecurityScopedResource()
      }
    }

    let filename = fileURL.lastPathComponent
    let resolvedContentType = contentType ?? Self.inferContentType(filename: filename)

    let data = (try? Data(contentsOf: fileURL)) ?? Data()
    return upload(
      data: data,
      filename: filename,
      contentType: resolvedContentType,
      contentDisposition: contentDisposition,
      folder: folder,
      scope: scope,
      onSuccess: onSuccess,
      onFailure: onFailure
    )
  }

  #if canImport(UIKit)
    /// Upload an image.
    ///
    /// This uses a JPEG encoding by default to keep payload sizes reasonable for mobile uploads.
    @MainActor
    @discardableResult
    public func upload(
      image: UIImage,
      filename: String = "image.jpg",
      jpegQuality: CGFloat = 0.85,
      contentDisposition: String? = "inline",
      folder: String = "uploads",
      scope: StorageFeedScope = .user,
      onSuccess: (@MainActor (StorageRef) -> Void)? = nil,
      onFailure: (@MainActor (StorageRef, any Error) -> Void)? = nil
    ) -> StorageRef {
      let data = image.jpegData(compressionQuality: jpegQuality) ?? Data()
      return upload(
        data: data,
        filename: filename,
        contentType: "image/jpeg",
        contentDisposition: contentDisposition,
        folder: folder,
        scope: scope,
        onSuccess: onSuccess,
        onFailure: onFailure
      )
    }
  #endif

  // MARK: - Delete

  @MainActor
  public func delete(
    _ ref: StorageRef,
    onSuccess: (@MainActor (StorageRef) -> Void)? = nil,
    onFailure: (@MainActor (StorageRef, any Error) -> Void)? = nil
  ) {
    updateStatus(path: ref.path, status: .deleting)

    let appID = self.appID
    let path = ref.path

    let task = Task { @MainActor in
      do {
        let client = InstantClientFactory.makeClient(appID: appID)
        _ = try await client.storage.deleteFile(path: path)

        updateStatus(path: path, status: .deleted)
        onSuccess?(ref)
      } catch {
        updateStatus(path: path, status: .failed(StorageFailure(message: error.localizedDescription)))
        onFailure?(ref, error)
      }
    }

    Task {
      await StorageTaskCoordinator.shared.startDelete(path: path, task: task)
    }
  }

  // MARK: - Retry

  /// Retry the upload for a previously-created `StorageRef` if we still have a local source.
  @MainActor
  public func retry(
    _ ref: StorageRef,
    onSuccess: (@MainActor (StorageRef) -> Void)? = nil,
    onFailure: (@MainActor (StorageRef, any Error) -> Void)? = nil
  ) {
    startUploadTask(ref: ref, onSuccess: onSuccess, onFailure: onFailure)
  }

  // MARK: - Private Helpers

  @MainActor
  private func startUploadTask(
    ref: StorageRef,
    onSuccess: (@MainActor (StorageRef) -> Void)?,
    onFailure: (@MainActor (StorageRef, any Error) -> Void)?
  ) {
    let appID = self.appID
    let path = ref.path

    let task = Task { @MainActor in
      let uploadSource = entry(forPath: path)?.uploadSource

      guard let uploadSource else {
        updateStatus(path: path, status: .failed(StorageFailure(message: "Missing local upload source for retry.")))
        return
      }

      updateStatus(path: path, status: .uploading(progress: nil))

      do {
        let data = try Data(contentsOf: uploadSource.fileURL)
        let client = InstantClientFactory.makeClient(appID: appID)
        let fileID = try await client.storage.uploadFile(
          path: path,
          data: data,
          options: .init(
            contentType: uploadSource.contentType,
            contentDisposition: uploadSource.contentDisposition
          )
        )

        setUploaded(path: path, remoteFileID: fileID)
        onSuccess?(ref)
      } catch {
        updateStatus(path: path, status: .failed(StorageFailure(message: error.localizedDescription)))
        onFailure?(ref, error)
      }
    }

    Task {
      await StorageTaskCoordinator.shared.startUpload(path: path, task: task)
    }
  }

  @MainActor
  private func buildPath(
    scope: StorageFeedScope,
    folder: String,
    fileComponent: String
  ) -> String {
    let sanitizedFolder = folder
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let prefix: String
    switch scope {
    case .user:
      let client = InstantClientFactory.makeClient(appID: appID)
      let userId = client.authManager.state.user?.id
      prefix = userId.map { "\($0)/" } ?? ""
    case .prefix(let customPrefix):
      let trimmed = customPrefix
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      prefix = trimmed.isEmpty ? "" : "\(trimmed)/"
    case .all:
      prefix = ""
    }

    if sanitizedFolder.isEmpty {
      return "\(prefix)\(fileComponent)"
    }

    return "\(prefix)\(sanitizedFolder)/\(fileComponent)"
  }

  private func storageStateShared() -> Shared<StorageSharedState> {
    StorageSharedStore.state(appID: appID)
  }

  @MainActor
  private func entry(forPath path: String) -> StorageEntry? {
    let state = storageStateShared()
    return state.wrappedValue.entries[path]
  }

  @MainActor
  private func upsertEntry(
    ref: StorageRef,
    status: StorageStatus,
    localPreview: StorageLocalPreview?,
    uploadSource: StorageUploadSource?
  ) {
    let state = storageStateShared()
    state.withLock { state in
      let existing = state.entries[ref.path]
      state.entries[ref.path] = StorageEntry(
        createdAt: existing?.createdAt ?? Date(),
        ref: ref,
        status: status,
        localPreview: localPreview ?? existing?.localPreview,
        uploadSource: uploadSource ?? existing?.uploadSource,
        remoteFileID: existing?.remoteFileID
      )
    }

    StorageNotifications.postStateDidChange(appID: appID, path: ref.path)
  }

  @MainActor
  private func updateStatus(path: String, status: StorageStatus) {
    let state = storageStateShared()
    state.withLock { state in
      guard var entry = state.entries[path] else { return }
      entry.status = status
      state.entries[path] = entry
    }

    StorageNotifications.postStateDidChange(appID: appID, path: path)
  }

  @MainActor
  private func setUploaded(path: String, remoteFileID: String) {
    let state = storageStateShared()
    state.withLock { state in
      guard var entry = state.entries[path] else { return }
      entry.status = .uploaded
      entry.remoteFileID = remoteFileID
      state.entries[path] = entry
    }

    StorageNotifications.postStateDidChange(appID: appID, path: path)
  }

  private static func writeToTemporaryDirectory(
    data: Data,
    preferredFilename: String
  ) -> URL {
    let safeName = preferredFilename
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/", with: "-")

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString.lowercased())
      .appendingPathComponent(safeName)

    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try? data.write(to: url, options: [.atomic])
    return url
  }

  private static func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
      let digest = SHA256.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    #else
      return String(data.hashValue)
    #endif
  }

  private static func inferContentType(filename: String) -> String? {
    #if canImport(UniformTypeIdentifiers)
      let ext = URL(fileURLWithPath: filename).pathExtension
      return UTType(filenameExtension: ext)?.preferredMIMEType
    #else
      return nil
    #endif
  }
}
