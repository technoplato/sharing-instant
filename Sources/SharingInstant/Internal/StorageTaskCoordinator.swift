import Foundation

// MARK: - StorageTaskCoordinator

/// Manages in-flight storage tasks by path.
///
/// ## Why This Exists
/// Storage mutations are triggered from many places (buttons, screenshot watcher, drag-and-drop),
/// and SwiftUI views may be recreated frequently. This coordinator keeps the task lifetime
/// independent from any particular view instance, while shared state in `StorageSharedState`
/// provides the reactive UI surface.
actor StorageTaskCoordinator {
  static let shared = StorageTaskCoordinator()

  private var uploads: [String: Task<Void, Never>] = [:]
  private var deletes: [String: Task<Void, Never>] = [:]

  func startUpload(path: String, task: Task<Void, Never>) {
    uploads[path]?.cancel()
    uploads[path] = task
  }

  func startDelete(path: String, task: Task<Void, Never>) {
    deletes[path]?.cancel()
    deletes[path] = task
  }

  func cancelUpload(path: String) {
    uploads[path]?.cancel()
    uploads.removeValue(forKey: path)
  }

  func cancelDelete(path: String) {
    deletes[path]?.cancel()
    deletes.removeValue(forKey: path)
  }
}

