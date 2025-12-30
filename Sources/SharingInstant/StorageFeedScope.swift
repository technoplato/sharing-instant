import Foundation

// MARK: - StorageFeedScope

/// Controls which `$files` are included in a storage feed subscription.
public enum StorageFeedScope: Sendable, Equatable {
  /// Only files whose path starts with the currently signed-in user's id.
  ///
  /// This matches the recommended permissions strategy:
  /// `data.path.startsWith(auth.id + '/')`.
  case user

  /// Files whose path starts with a custom prefix.
  case prefix(String)

  /// All files visible to the current session (not recommended for most apps).
  case all
}

