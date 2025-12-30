/// ═══════════════════════════════════════════════════════════════════════════════
/// SharedMutations.swift
/// Explicit mutation methods for @Shared InstantDB collections
/// ═══════════════════════════════════════════════════════════════════════════════
///
/// This file provides explicit mutation methods (create, delete, update, link, unlink)
/// that bypass the diff-based save() mechanism. These methods generate specific
/// transaction chunks and send them directly to the server.
///
/// ## Why This Exists
///
/// The default `$collection.withLock { }` approach triggers `save()` which computes
/// diffs between local and server state. This causes issues:
/// - Race conditions when multiple subscriptions exist for the same namespace
/// - Ghost deletions on app start
/// - Re-sync of deleted items when creating new items
///
/// ## How It Works
///
/// Instead of computing diffs, these methods:
/// 1. Apply the change optimistically to local state
/// 2. Generate a specific transaction chunk for the operation
/// 3. Send the chunk directly to the server via `directTransact()`
///
/// ## Usage
///
/// ```swift
/// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
///
/// // Create - explicit operation, no diff
/// try await $goals.create(Goal(id: id, title: "New Goal"))
///
/// // Delete - explicit operation, no diff
/// try await $goals.delete(id: goalId)
///
/// // Update - explicit operation, no diff
/// try await $goals.update(id: goalId) { $0.title = "Updated" }
///
/// // Link - explicit operation
/// try await $goals.link(goalId, "creator", to: profileId, namespace: "profiles")
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════════════

import Dependencies
import Foundation
import IdentifiedCollections
import InstantDB
import Sharing

// MARK: - Mutation Callbacks

/// TanStack Query-style callbacks for mutation operations.
///
/// These callbacks provide hooks into the mutation lifecycle, allowing you to
/// respond to different stages of a mutation operation.
///
/// ## Why This Exists
///
/// TanStack Query popularized this callback pattern for mutations because it provides:
/// - **Optimistic UI updates** via `onMutate` (before the server responds)
/// - **Success handling** via `onSuccess` (update UI, show toast, navigate)
/// - **Error handling** via `onError` (show error, revert optimistic update)
/// - **Cleanup** via `onSettled` (always runs, like `finally`)
///
/// ## Example
///
/// ```swift
/// $posts.createPost(
///   content: "Hello world",
///   callbacks: MutationCallbacks(
///     onMutate: {
///       print("Creating post...")
///     },
///     onSuccess: { post in
///       print("Created post: \(post.id)")
///     },
///     onError: { error in
///       print("Failed: \(error)")
///     },
///     onSettled: {
///       print("Done (success or failure)")
///     }
///   )
/// )
/// ```
public struct MutationCallbacks<T: Sendable>: Sendable {
  /// Called immediately before the mutation is executed.
  /// Use this for optimistic updates or loading states.
  public var onMutate: (@Sendable () -> Void)?
  
  /// Called when the mutation succeeds.
  /// Receives the result of the mutation (e.g., the created/updated entity).
  public var onSuccess: (@Sendable (T) -> Void)?
  
  /// Called when the mutation fails.
  /// Receives the error that occurred.
  public var onError: (@Sendable (Error) -> Void)?
  
  /// Called after the mutation completes, regardless of success or failure.
  /// Use this for cleanup, like dismissing loading states.
  public var onSettled: (@Sendable () -> Void)?
  
  public init(
    onMutate: (@Sendable () -> Void)? = nil,
    onSuccess: (@Sendable (T) -> Void)? = nil,
    onError: (@Sendable (Error) -> Void)? = nil,
    onSettled: (@Sendable () -> Void)? = nil
  ) {
    self.onMutate = onMutate
    self.onSuccess = onSuccess
    self.onError = onError
    self.onSettled = onSettled
  }
}

// MARK: - Explicit Mutation Methods for Shared Collections

extension Shared {
  
  // MARK: - Create
  
  /// Create a new entity and sync to InstantDB.
  ///
  /// This method:
  /// 1. Adds the entity to the local collection optimistically
  /// 2. Sends an explicit "update" transaction to the server
  ///
  /// Unlike `withLock { $0.append(entity) }`, this does NOT compute diffs.
  /// It sends exactly one transaction for the new entity.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
  ///
  /// let newGoal = Goal(id: UUID().uuidString, title: "Learn Swift")
  /// try await $goals.create(newGoal)
  /// ```
  ///
  /// - Parameter entity: The entity to create
  /// - Throws: If the transaction fails
  @MainActor
  public func create<Element: EntityIdentifiable & Encodable & Sendable>(
    _ entity: Element
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // 1. Apply optimistically to local state
    withLock { collection in
      var mutableCollection = collection
      mutableCollection.append(entity)
      collection = mutableCollection
    }
    
    // 2. Generate explicit transaction chunk
    let namespace = Element.namespace
    let attrs = try encodeEntityAttributes(entity)
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: entity.id,
      ops: [["update", namespace, entity.id, attrs]]
    )
    
    // 3. Send directly to server (bypasses save() diff logic)
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  // MARK: - Delete
  
  /// Delete an entity by ID and sync to InstantDB.
  ///
  /// This method:
  /// 1. Removes the entity from the local collection optimistically
  /// 2. Sends an explicit "delete" transaction to the server
  ///
  /// Unlike `withLock { $0.remove(id:) }`, this does NOT compute diffs.
  /// It sends exactly one delete transaction.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
  ///
  /// try await $goals.delete(id: goal.id)
  /// ```
  ///
  /// - Parameter id: The ID of the entity to delete
  /// - Throws: If the transaction fails
  @MainActor
  public func delete<Element: EntityIdentifiable & Sendable>(
    id: String
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // 1. Apply optimistically to local state
    withLock { collection in
      var mutableCollection = collection
      mutableCollection.removeAll { $0.id == id }
      collection = mutableCollection
    }
    
    // 2. Generate explicit delete chunk
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["delete", namespace, id]]
    )
    
    // 3. Send directly to server
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  // MARK: - Update
  
  /// Update an entity's fields and sync to InstantDB.
  ///
  /// This method:
  /// 1. Updates the entity in the local collection optimistically
  /// 2. Sends an explicit "update" transaction with only the changed fields
  ///
  /// Unlike `withLock { $0[id].field = value }`, this does NOT compute diffs.
  /// It sends exactly one update transaction.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.goals)) var goals: [Goal]
  ///
  /// try await $goals.update(id: goal.id) { goal in
  ///   goal.title = "Updated Title"
  ///   goal.completed = true
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to update
  ///   - modify: A closure that modifies the entity
  /// - Throws: If the entity is not found or the transaction fails
  @MainActor
  public func update<Element: EntityIdentifiable & Encodable & Sendable>(
    id: String,
    _ modify: (inout Element) -> Void
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    var updatedEntity: Element?
    
    // 1. Apply optimistically to local state
    withLock { collection in
      var mutableCollection = Array(collection)
      if let index = mutableCollection.firstIndex(where: { $0.id == id }) {
        modify(&mutableCollection[index])
        updatedEntity = mutableCollection[index]
        collection = Value(mutableCollection)
      }
    }
    
    guard let entity = updatedEntity else {
      throw InstantMutationError.entityNotFound(id: id, namespace: Element.namespace)
    }
    
    // 2. Generate explicit update chunk
    let namespace = Element.namespace
    let attrs = try encodeEntityAttributes(entity)
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["update", namespace, id, attrs]]
    )
    
    // 3. Send directly to server
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  // MARK: - Link
  
  /// Link an entity to another entity.
  ///
  /// This method sends an explicit "link" transaction to the server.
  /// It does NOT modify local state (the link will be reflected when
  /// the subscription receives the updated data).
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Link a post to its author
  /// try await $posts.link(post.id, "author", to: profile.id, namespace: "profiles")
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to link from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - targetId: The ID of the entity to link to
  ///   - namespace: The namespace of the target entity
  /// - Throws: If the transaction fails
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to targetId: String,
    namespace targetNamespace: String
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["link", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Link an entity to another entity using the target entity directly.
  ///
  /// This is a convenience method that extracts the ID and namespace from the target entity.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Link a post to its author
  /// try await $posts.link(post.id, "author", to: profile)
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to link from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - target: The entity to link to
  /// - Throws: If the transaction fails
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to target: Target
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    try await link(id, label, to: target.id, namespace: Target.namespace)
  }
  
  // MARK: - Unlink
  
  /// Unlink an entity from another entity.
  ///
  /// This method sends an explicit "unlink" transaction to the server.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Unlink a post from its author
  /// try await $posts.unlink(post.id, "author", from: profile.id, namespace: "profiles")
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to unlink from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - targetId: The ID of the entity to unlink from
  ///   - namespace: The namespace of the target entity
  /// - Throws: If the transaction fails
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from targetId: String,
    namespace targetNamespace: String
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["unlink", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Unlink an entity from another entity using the target entity directly.
  ///
  /// This is a convenience method that extracts the ID and namespace from the target entity.
  ///
  /// ## Example
  ///
  /// ```swift
  /// @Shared(.instantSync(Schema.posts.with(\.author))) var posts: [Post]
  ///
  /// // Unlink a post from its author
  /// try await $posts.unlink(post.id, "author", from: profile)
  /// ```
  ///
  /// - Parameters:
  ///   - id: The ID of the entity to unlink from
  ///   - label: The link label (e.g., "author", "creator")
  ///   - target: The entity to unlink from
  /// - Throws: If the transaction fails
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from target: Target
  ) async throws where Value: RangeReplaceableCollection, Value.Element == Element {
    try await unlink(id, label, from: target.id, namespace: Target.namespace)
  }
}

// MARK: - IdentifiedArray Support

extension Shared {
  
  /// Create a new entity and sync to InstantDB (IdentifiedArray version).
  @MainActor
  public func create<Element: EntityIdentifiable & Encodable & Sendable>(
    _ entity: Element
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // 1. Apply optimistically
    _ = withLock { $0.append(entity) }
    
    // 2. Generate explicit transaction chunk
    let namespace = Element.namespace
    let attrs = try encodeEntityAttributes(entity)
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: entity.id,
      ops: [["update", namespace, entity.id, attrs]]
    )
    
    // 3. Send directly to server
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Delete an entity by ID and sync to InstantDB (IdentifiedArray version).
  @MainActor
  public func delete<Element: EntityIdentifiable & Sendable>(
    id: String
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    // 1. Apply optimistically
    _ = withLock { $0.remove(id: id) }
    
    // 2. Generate explicit delete chunk
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["delete", namespace, id]]
    )
    
    // 3. Send directly to server
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Update an entity's fields and sync to InstantDB (IdentifiedArray version).
  @MainActor
  public func update<Element: EntityIdentifiable & Encodable & Sendable>(
    id: String,
    _ modify: (inout Element) -> Void
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    var updatedEntity: Element?
    
    // 1. Apply optimistically
    withLock { collection in
      if var entity = collection[id: id] {
        modify(&entity)
        collection[id: id] = entity
        updatedEntity = entity
      }
    }
    
    guard let entity = updatedEntity else {
      throw InstantMutationError.entityNotFound(id: id, namespace: Element.namespace)
    }
    
    // 2. Generate explicit update chunk
    let namespace = Element.namespace
    let attrs = try encodeEntityAttributes(entity)
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["update", namespace, id, attrs]]
    )
    
    // 3. Send directly to server
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Link an entity to another entity (IdentifiedArray version).
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to targetId: String,
    namespace targetNamespace: String
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["link", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Link an entity to another entity using the target entity directly (IdentifiedArray version).
  @MainActor
  public func link<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    to target: Target
  ) async throws where Value == IdentifiedArrayOf<Element> {
    try await link(id, label, to: target.id, namespace: Target.namespace)
  }
  
  /// Unlink an entity from another entity (IdentifiedArray version).
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from targetId: String,
    namespace targetNamespace: String
  ) async throws where Value == IdentifiedArrayOf<Element> {
    @Dependency(\.instantReactor) var reactor
    @Dependency(\.instantAppID) var appID
    
    let namespace = Element.namespace
    
    let chunk = TransactionChunk(
      namespace: namespace,
      id: id,
      ops: [["unlink", namespace, id, [label: ["id": targetId, "namespace": targetNamespace]] as [String: Any]]]
    )
    
    try await reactor.transact(appID: appID, chunks: [chunk])
  }
  
  /// Unlink an entity from another entity using the target entity directly (IdentifiedArray version).
  @MainActor
  public func unlink<Element: EntityIdentifiable & Sendable, Target: EntityIdentifiable & Sendable>(
    _ id: String,
    _ label: String,
    from target: Target
  ) async throws where Value == IdentifiedArrayOf<Element> {
    try await unlink(id, label, from: target.id, namespace: Target.namespace)
  }
}

// MARK: - Errors

/// Errors that can occur during explicit mutations.
public enum InstantMutationError: Error, LocalizedError {
  case entityNotFound(id: String, namespace: String)
  case encodingFailed(Error)
  
  public var errorDescription: String? {
    switch self {
    case .entityNotFound(let id, let namespace):
      return "Entity not found: \(namespace)/\(id)"
    case .encodingFailed(let error):
      return "Failed to encode entity: \(error.localizedDescription)"
    }
  }
}

// MARK: - Helpers

/// Encode an entity's attributes to a dictionary for the transaction.
///
/// This extracts all properties except `id` and link properties (which are
/// handled separately via link operations).
private func encodeEntityAttributes<E: Encodable>(_ entity: E) throws -> [String: Any] {
  let encoder = JSONEncoder()
  let data = try encoder.encode(entity)
  
  guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw InstantMutationError.encodingFailed(
      NSError(domain: "SharingInstant", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Failed to convert encoded entity to dictionary"
      ])
    )
  }
  
  // Filter out id (handled separately) and link properties (arrays/objects)
  // Links should be handled via explicit link() calls
  var attrs: [String: Any] = [:]
  for (key, value) in dict {
    // Skip id - it's handled separately
    if key == "id" { continue }
    
    // Skip link properties (arrays and nested objects)
    // These should be handled via explicit link() calls
    if value is [Any] { continue }
    if value is [String: Any] { continue }
    
    attrs[key] = value
  }
  
  return attrs
}
