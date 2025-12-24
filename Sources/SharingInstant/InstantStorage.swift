import Combine
import Dependencies
import Foundation
import InstantDB
import os.log

#if canImport(SwiftUI)
  import SwiftUI
#endif

// MARK: - Logging

private let logger = Logger(subsystem: "SharingInstant", category: "Storage")

// MARK: - InstantStorage

/// A coordinator for InstantDB file storage with an ergonomic SwiftUI API.
///
/// `InstantStorage` is designed to feel like a TanStack Query `useMutation`:
/// you can trigger storage actions imperatively while also observing a
/// first-class status enum to drive loading/error UI.
///
/// ## Why This Exists
/// InstantDB's JS clients expose `db.storage.*` helpers for upload/delete/linking.
/// The Swift core SDK (`instant-ios-sdk`) provides those HTTP endpoints on
/// `InstantClient.storage`, but callers would otherwise need to keep track of
/// local UI state such as "upload in flight", "last error", and "last result".
///
/// This wrapper centralizes that state so app code stays small and consistent.
///
/// ## Permissions
/// Storage operations are gated by InstantDB's permissions system via `$files`.
/// If your app has no `$files` rules, the server denies access by default.
///
/// - SeeAlso: https://www.instantdb.com/docs/storage
/// - SeeAlso: https://www.instantdb.com/docs/permissions
@MainActor
public final class InstantStorage: ObservableObject {

  // MARK: - Operation State

  /// State for an in-flight or completed storage operation.
  ///
  /// This is intentionally "mutation-shaped": it models a single operation at a time,
  /// which matches how SwiftUI screens typically present upload/delete actions.
  public enum OperationState<Success> {
    case idle
    case inFlight(startedAt: Date)
    case success(Success, finishedAt: Date)
    case failure(any Error, finishedAt: Date)

    public var isInFlight: Bool {
      if case .inFlight = self { return true }
      return false
    }

    public var value: Success? {
      if case .success(let value, _) = self { return value }
      return nil
    }

    public var error: (any Error)? {
      if case .failure(let error, _) = self { return error }
      return nil
    }
  }

  // MARK: - Result Types

  public struct UploadedFile: Sendable, Equatable {
    public let id: String
    public let path: String

    public init(id: String, path: String) {
      self.id = id
      self.path = path
    }
  }

  public struct DeletedFile: Sendable, Equatable {
    public let id: String?
    public let path: String

    public init(id: String?, path: String) {
      self.id = id
      self.path = path
    }
  }

  public struct FileLink: Sendable, Equatable {
    public let url: URL
    public let path: String

    public init(url: URL, path: String) {
      self.url = url
      self.path = path
    }
  }

  // MARK: - Properties

  public let appID: String

  @Published public private(set) var uploadState: OperationState<UploadedFile> = .idle
  @Published public private(set) var deleteState: OperationState<DeletedFile> = .idle
  @Published public private(set) var linkState: OperationState<FileLink> = .idle

  private var uploadTask: Task<UploadedFile, Error>?
  private var deleteTask: Task<DeletedFile, Error>?
  private var linkTask: Task<FileLink, Error>?

  // MARK: - Initialization

  /// Creates an InstantStorage coordinator.
  ///
  /// - Parameter appID: Optional app ID. Uses the default if not specified.
  public init(appID: String? = nil) {
    @Dependency(\.instantAppID) var defaultAppID
    self.appID = appID ?? defaultAppID
  }

  // MARK: - File Handles

  /// Creates a convenience wrapper for performing operations on a specific storage path.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let avatar = storage.file("\(user.id)/avatar.png")
  /// try await avatar.upload(data: pngData, options: .init(contentType: "image/png"))
  /// let url = try await avatar.link()
  /// ```
  public func file(_ path: String) -> FileHandle {
    FileHandle(storage: self, path: path)
  }

  public struct FileHandle {
    private let storage: InstantStorage
    public let path: String

    fileprivate init(storage: InstantStorage, path: String) {
      self.storage = storage
      self.path = path
    }

    @discardableResult
    public func upload(
      data: Data,
      options: StorageAPI.UploadOptions = .init()
    ) async throws -> UploadedFile {
      try await storage.uploadFile(path: path, data: data, options: options)
    }

    @discardableResult
    public func upload(
      fileURL: URL,
      options: StorageAPI.UploadOptions = .init()
    ) async throws -> UploadedFile {
      try await storage.uploadFile(path: path, fileURL: fileURL, options: options)
    }

    @discardableResult
    public func delete() async throws -> DeletedFile {
      try await storage.deleteFile(path: path)
    }

    @discardableResult
    public func link() async throws -> FileLink {
      try await storage.link(path: path)
    }
  }

  // MARK: - Upload

  /// Uploads a file to InstantDB storage at `path`.
  ///
  /// ## Overwrite Semantics
  /// Uploading to an existing path overwrites the previous contents (JS parity).
  ///
  /// - Parameters:
  ///   - path: Storage path, e.g. `"photos/demo.png"`.
  ///   - data: File data.
  ///   - options: Metadata such as content type / disposition.
  /// - Returns: The created/updated `$files` id plus the requested path.
  @discardableResult
  public func uploadFile(
    path: String,
    data: Data,
    options: StorageAPI.UploadOptions = .init()
  ) async throws -> UploadedFile {
    uploadTask?.cancel()

    let startedAt = Date()
    uploadState = .inFlight(startedAt: startedAt)

    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)

      let id = try await client.storage.uploadFile(path: path, data: data, options: options)
      return UploadedFile(id: id, path: path)
    }
    uploadTask = task

    do {
      let uploaded = try await task.value
      uploadState = .success(uploaded, finishedAt: Date())
      logger.info("Uploaded file (appID=\(self.appID), path=\(path), id=\(uploaded.id))")
      return uploaded
    } catch {
      uploadState = .failure(error, finishedAt: Date())
      logger.error("Upload failed (appID=\(self.appID), path=\(path)): \(error.localizedDescription)")
      throw error
    }
  }

  /// Uploads a file from disk to InstantDB storage at `path`.
  ///
  /// - Note: This reads the file into memory. For very large files, prefer streaming
  /// uploads from trusted server-side tooling.
  @discardableResult
  public func uploadFile(
    path: String,
    fileURL: URL,
    options: StorageAPI.UploadOptions = .init()
  ) async throws -> UploadedFile {
    let data = try Data(contentsOf: fileURL)
    return try await uploadFile(path: path, data: data, options: options)
  }

  /// Callback-style upload for use from synchronous contexts (e.g. SwiftUI button actions).
  @discardableResult
  public func uploadFile(
    path: String,
    data: Data,
    options: StorageAPI.UploadOptions = .init(),
    completion: @escaping @MainActor (Result<UploadedFile, any Error>) -> Void
  ) -> Task<UploadedFile, Error> {
    let task = Task { @MainActor in
      do {
        let value = try await self.uploadFile(path: path, data: data, options: options)
        completion(.success(value))
        return value
      } catch {
        completion(.failure(error))
        throw error
      }
    }

    return task
  }

  // MARK: - Delete

  /// Deletes a file by path.
  ///
  /// - Parameter path: Storage path, e.g. `"photos/demo.png"`.
  /// - Returns: The deleted `$files` id (if present) plus the requested path.
  @discardableResult
  public func deleteFile(path: String) async throws -> DeletedFile {
    deleteTask?.cancel()

    let startedAt = Date()
    deleteState = .inFlight(startedAt: startedAt)

    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      let deletedId = try await client.storage.deleteFile(path: path)
      return DeletedFile(id: deletedId, path: path)
    }
    deleteTask = task

    do {
      let deleted = try await task.value
      deleteState = .success(deleted, finishedAt: Date())
      logger.info("Deleted file (appID=\(self.appID), path=\(path), id=\(deleted.id ?? "nil"))")
      return deleted
    } catch {
      deleteState = .failure(error, finishedAt: Date())
      logger.error("Delete failed (appID=\(self.appID), path=\(path)): \(error.localizedDescription)")
      throw error
    }
  }

  /// Callback-style delete for use from synchronous contexts (e.g. SwiftUI button actions).
  @discardableResult
  public func deleteFile(
    path: String,
    completion: @escaping @MainActor (Result<DeletedFile, any Error>) -> Void
  ) -> Task<DeletedFile, Error> {
    let task = Task { @MainActor in
      do {
        let value = try await self.deleteFile(path: path)
        completion(.success(value))
        return value
      } catch {
        completion(.failure(error))
        throw error
      }
    }

    return task
  }

  // MARK: - Link / Download URL

  /// Returns a temporary, signed URL for downloading a file.
  ///
  /// - Important: This uses the legacy signed-download-url endpoint exposed by the JS SDK.
  /// Prefer querying `$files` and using URL metadata when available in your environment.
  @discardableResult
  public func link(path: String) async throws -> FileLink {
    linkTask?.cancel()

    let startedAt = Date()
    linkState = .inFlight(startedAt: startedAt)

    let task = Task { @MainActor in
      let client = InstantClientFactory.makeClient(appID: appID)
      let url = try await client.storage.downloadURL(path: path)
      return FileLink(url: url, path: path)
    }
    linkTask = task

    do {
      let link = try await task.value
      linkState = .success(link, finishedAt: Date())
      logger.info("Generated download URL (appID=\(self.appID), path=\(path))")
      return link
    } catch {
      linkState = .failure(error, finishedAt: Date())
      logger.error("Download URL failed (appID=\(self.appID), path=\(path)): \(error.localizedDescription)")
      throw error
    }
  }

  /// Callback-style link generation for use from synchronous contexts.
  @discardableResult
  public func link(
    path: String,
    completion: @escaping @MainActor (Result<FileLink, any Error>) -> Void
  ) -> Task<FileLink, Error> {
    let task = Task { @MainActor in
      do {
        let value = try await self.link(path: path)
        completion(.success(value))
        return value
      } catch {
        completion(.failure(error))
        throw error
      }
    }

    return task
  }

  // MARK: - Reset / Cancellation

  /// Cancels any in-flight upload and resets `uploadState` back to `.idle`.
  public func resetUpload() {
    uploadTask?.cancel()
    uploadTask = nil
    uploadState = .idle
  }

  /// Cancels any in-flight delete and resets `deleteState` back to `.idle`.
  public func resetDelete() {
    deleteTask?.cancel()
    deleteTask = nil
    deleteState = .idle
  }

  /// Cancels any in-flight link request and resets `linkState` back to `.idle`.
  public func resetLink() {
    linkTask?.cancel()
    linkTask = nil
    linkState = .idle
  }
}

// MARK: - Environment Key

#if canImport(SwiftUI)
/// Environment key for accessing InstantStorage.
private struct InstantStorageKey: EnvironmentKey {
  static let defaultValue: InstantStorage? = nil
}

extension EnvironmentValues {
  /// The InstantStorage coordinator for the current environment.
  public var instantStorage: InstantStorage? {
    get { self[InstantStorageKey.self] }
    set { self[InstantStorageKey.self] = newValue }
  }
}

extension View {
  /// Provides an InstantStorage coordinator to the view hierarchy.
  public func instantStorage(_ storage: InstantStorage) -> some View {
    environment(\.instantStorage, storage)
  }
}
#endif

